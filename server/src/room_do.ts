import {
  BIT_PRESENT,
  CLOSE_BAD_MESSAGE,
  CLOSE_CANNOT_RESUME,
  CLOSE_PROTOCOL_MISMATCH,
  CLOSE_RECONNECTED_ELSEWHERE,
  CLOSE_ROOM_CLOSED,
  CLOSE_ROOM_FULL,
  PROTOCOL_VERSION,
  STICKY_BITS,
  TICK_MS,
  mergeCommand,
  parseCommand,
  type Frame,
  type PlayerCommand,
  type RoomState,
  type RosterEntry,
} from './lib/protocol.js';
import { FrameHistory } from './lib/frame_history.js';
import { submitMatchResult, type MatchReport } from './lib/leaderboard.js';
import { resolveSession } from './lib/sessions.js';
import { CURRENT_SEASON, MAX_PLAYERS_PER_ROOM, type Env } from './types.js';

/** Seats with no traffic for this long are dropped so a slot is not held forever. */
const HEARTBEAT_INTERVAL_MS = 5_000;
const CONNECTION_TIMEOUT_MS = 20_000;

/**
 * How long the room waits for stragglers' result reports after the first one
 * arrives. A client that crashed at the moment of defeat must not hold the
 * remaining players' scores hostage.
 */
const RESULT_GRACE_MS = 8_000;

/** A room with nobody in it stops its loop and lets the object be evicted. */
interface Seat {
  playerId: string;
  nickname: string;
  ready: boolean;
  socket: WebSocket | null;
  lastSeenAt: number;
}

/**
 * The authoritative room.
 *
 * Two responsibilities that look separable but are not: the lobby decides WHO
 * is in which slot, and the frame relay decides WHAT each slot did on each
 * tick. They share the slot table, and a seat changing hands mid-match would
 * silently rewrite history for every client -- which is why the roster is
 * frozen for the duration of a match and a disconnect leaves the seat present
 * but inactive rather than freeing it.
 */
export class RoomDurableObject implements DurableObject {
  private readonly state: DurableObjectState;
  private readonly env: Env;

  private code = '';
  private isPublic = true;
  private roomState: RoomState = 'lobby';
  private hostSlot = -1;

  private readonly seats: Array<Seat | null> = new Array(MAX_PLAYERS_PER_ROOM).fill(null);
  private readonly sockets = new Map<WebSocket, number>();

  /** Match state. Meaningful only while roomState === 'playing'. */
  private tick = 0;
  private seed = 0;
  private matchStartedAt = 0;
  private latest: Array<PlayerCommand | null> = new Array(MAX_PLAYERS_PER_ROOM).fill(null);
  private waveRequested = false;
  private loop: ReturnType<typeof setInterval> | null = null;
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private reports = new Map<string, MatchReport>();
  private resultTimer: ReturnType<typeof setTimeout> | null = null;
  /** slot -> last reported frame hash, for desync detection. */
  private hashes = new Map<number, string>();
  /** Serialises `onJoin` so seats are handed out in the order clients arrived. */
  private joinQueue: Promise<void> = Promise.resolve();
  /** Broadcast frames kept so a rejoining client can replay the gap it missed. */
  private readonly history = new FrameHistory();

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.state.blockConcurrencyWhile(async () => {
      this.code = (await this.state.storage.get<string>('code')) ?? '';
      this.isPublic = (await this.state.storage.get<boolean>('is_public')) ?? true;
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (url.pathname) {
      case '/init':
        return this.handleInit(request);
      case '/info':
        return Response.json(this.info());
      case '/ws':
        return this.handleUpgrade(request);
      default:
        return new Response('not found', { status: 404 });
    }
  }

  private async handleInit(request: Request): Promise<Response> {
    const body = (await request.json()) as { code?: string; is_public?: boolean };
    if (this.code !== '') {
      // Already initialised. Re-initialising would orphan the seated players.
      return Response.json({ ok: false, error: 'already_initialised' }, { status: 409 });
    }
    this.code = String(body.code ?? '');
    this.isPublic = body.is_public !== false;
    await this.state.storage.put({ code: this.code, is_public: this.isPublic });
    return Response.json({ ok: true, code: this.code });
  }

  private info(): {
    exists: boolean;
    code: string;
    state: RoomState;
    player_count: number;
    max_players: number;
    host_nickname: string;
    is_public: boolean;
  } {
    const host = this.hostSlot >= 0 ? this.seats[this.hostSlot] : null;
    return {
      exists: this.code !== '',
      code: this.code,
      state: this.roomState,
      player_count: this.occupiedSeats().length,
      max_players: MAX_PLAYERS_PER_ROOM,
      host_nickname: host?.nickname ?? '',
      is_public: this.isPublic,
    };
  }

  private handleUpgrade(request: Request): Response {
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 426 });
    }
    if (this.code === '') {
      return new Response('room not found', { status: 404 });
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    // Plain accept(), NOT the hibernation API: a hibernating object cannot hold
    // the 50ms frame timer, and the frame timer is the whole point of the room.
    server.accept();
    server.addEventListener('message', (event) => {
      void this.onMessage(server, event);
    });
    server.addEventListener('close', () => {
      this.onDisconnect(server);
    });
    server.addEventListener('error', () => {
      this.onDisconnect(server);
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  // ---------------------------------------------------------------- messages

  private async onMessage(socket: WebSocket, event: MessageEvent): Promise<void> {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(typeof event.data === 'string' ? event.data : '') as Record<
        string,
        unknown
      >;
    } catch {
      socket.close(CLOSE_BAD_MESSAGE, 'malformed json');
      return;
    }
    const type = message['type'];
    if (typeof type !== 'string') {
      socket.close(CLOSE_BAD_MESSAGE, 'missing type');
      return;
    }

    if (type === 'join') {
      // Serialised, because onJoin awaits a D1 lookup *before* it picks a seat.
      // Two joins in flight therefore race on that await, and the slower query
      // loses the lower slot no matter who connected first -- observed live as
      // the second player becoming host roughly half the time. Chaining keeps
      // seats in arrival order without moving identity resolution.
      this.joinQueue = this.joinQueue
        .then(() => this.onJoin(socket, message))
        .catch((error: unknown) => {
          console.error(`join failed room=${this.code}: ${String(error)}`);
        });
      await this.joinQueue;
      return;
    }

    const slot = this.sockets.get(socket);
    if (slot === undefined) {
      socket.close(CLOSE_BAD_MESSAGE, 'join first');
      return;
    }
    const seat = this.seats[slot];
    if (seat == null) return;
    seat.lastSeenAt = Date.now();

    switch (type) {
      case 'pong':
        return;
      case 'ready':
        seat.ready = message['ready'] === true;
        this.broadcastRoster();
        return;
      case 'start':
        if (slot === this.hostSlot) this.startMatch();
        return;
      case 'cmd':
        this.onCommand(slot, message);
        return;
      case 'result':
        await this.onResult(seat, message);
        return;
      case 'leave':
        socket.close(1000, 'left');
        this.onDisconnect(socket);
        return;
      default:
        return;
    }
  }

  private async onJoin(socket: WebSocket, message: Record<string, unknown>): Promise<void> {
    const version = message['protocol_version'];
    if (version !== PROTOCOL_VERSION) {
      // Rejecting rather than tolerating: this turns a silent cross-repo drift
      // into one loud failure at connect time, carrying both version numbers.
      socket.close(
        CLOSE_PROTOCOL_MISMATCH,
        `protocol mismatch peer=${String(version)} local=${PROTOCOL_VERSION}`,
      );
      return;
    }
    if (this.sockets.has(socket)) return;

    const token = typeof message['token'] === 'string' ? message['token'] : undefined;
    const session = await resolveSession(this.env.DB, token);
    const playerId = session?.playerId ?? `anon-${crypto.randomUUID()}`;
    const nickname =
      (typeof message['nickname'] === 'string' && message['nickname'].trim() !== ''
        ? message['nickname'].trim()
        : session?.nickname) || '玩家';

    // The tick this client has already simulated its way to. -1 from a client
    // with no simulation yet, which during a match means it needs the whole
    // history and will only be admitted if the history still reaches tick 0.
    const resumeTick =
      typeof message['resume_tick'] === 'number' && Number.isInteger(message['resume_tick'])
        ? (message['resume_tick'] as number)
        : -1;
    const resumeFrom = resumeTick + 1;

    // Reconnect: a seat already held by this player_id is reclaimed rather than
    // duplicated. This is what makes a dropped phone able to rejoin its own
    // slot mid-match instead of watching its body stand there until the end.
    let slot = this.seats.findIndex((seat) => seat !== null && seat.playerId === playerId);
    if (slot < 0) {
      if (this.roomState !== 'lobby') {
        socket.close(CLOSE_ROOM_FULL, 'match already started');
        return;
      }
      slot = this.seats.findIndex((seat) => seat === null);
      if (slot < 0) {
        socket.close(CLOSE_ROOM_FULL, 'room is full');
        return;
      }
      this.seats[slot] = { playerId, nickname, ready: false, socket, lastSeenAt: Date.now() };
    } else {
      // Decided before the seat changes hands: a rejoin that cannot be replayed
      // must leave the room exactly as it found it, so the player can try again
      // rather than lose the seat to a half-finished handover.
      if (this.roomState === 'playing' && !this.history.covers(resumeFrom)) {
        socket.close(
          CLOSE_CANNOT_RESUME,
          `cannot replay from tick ${resumeFrom}; history starts at ${this.history.oldestTick}`,
        );
        return;
      }
      const seat = this.seats[slot]!;
      seat.socket?.close(CLOSE_RECONNECTED_ELSEWHERE, 'reconnected elsewhere');
      seat.socket = socket;
      seat.nickname = nickname;
      seat.lastSeenAt = Date.now();
    }
    this.sockets.set(socket, slot);
    if (this.hostSlot < 0) this.hostSlot = slot;

    this.send(socket, {
      type: 'welcome',
      protocol_version: PROTOCOL_VERSION,
      slot,
      player_id: playerId,
      room_code: this.code,
      state: this.roomState,
      // A mid-match rejoin needs the seed and the tick it is landing on, or it
      // would replay the match from zero against everyone else's live frames.
      seed: this.seed,
      tick: this.tick,
    });
    // Replay the gap before the roster goes out, so the frames the client needs
    // are already queued behind the welcome it just acted on.
    if (this.roomState === 'playing') {
      for (const chunk of this.history.chunksFrom(resumeFrom)) {
        this.sendEncoded(socket, chunk);
      }
    }
    this.broadcastRoster();
    this.ensureHeartbeat();
    void this.publishDirectory();
  }

  private onCommand(slot: number, message: Record<string, unknown>): void {
    if (this.roomState !== 'playing') return;
    const command = parseCommand(message['c']);
    if (command === null) return;
    // Merged, not overwritten: several commands landing in one pump window is
    // the normal shape of a client that stalled and caught up, and the ones
    // that are not the last still carry shots that were really fired.
    this.latest[slot] = mergeCommand(this.latest[slot] ?? null, command);
    if (command.w === true) this.waveRequested = true;
    if (command.h !== undefined) this.checkHash(slot, command.h, Number(message['ht'] ?? -1));
  }

  /**
   * Desync detection. Clients periodically attach the hash of their simulation
   * at a tick they name; the first two seats to report a given tick set the
   * reference, and any later disagreement is broadcast.
   *
   * The room does NOT try to repair a desync. It cannot -- it holds no
   * simulation of its own. Saying so loudly is the whole feature: an unreported
   * desync surfaces as "the zombies killed me but not you", hours later, with
   * nothing to point at.
   */
  private checkHash(slot: number, hash: string, tick: number): void {
    if (tick < 0) return;
    const key = `${tick}`;
    const seen = this.hashes.get(tick);
    if (seen === undefined) {
      this.hashes.set(tick, hash);
      // Only the most recent samples matter; anything older cannot be compared
      // against a client that has already moved past it.
      if (this.hashes.size > 64) {
        const oldest = this.hashes.keys().next();
        if (oldest.done !== true) this.hashes.delete(oldest.value);
      }
      return;
    }
    if (seen === hash) return;
    console.warn(`desync room=${this.code} tick=${key} slot=${slot} ${seen} != ${hash}`);
    this.broadcast({ type: 'desync', tick, slot, expected: seen, actual: hash });
  }

  private async onResult(seat: Seat, message: Record<string, unknown>): Promise<void> {
    if (this.roomState === 'lobby') return;
    const teamWave = message['team_wave'];
    const kills = message['player_kills'];
    if (typeof teamWave !== 'number' || typeof kills !== 'object' || kills === null) return;
    const playerKills: Record<string, number> = {};
    for (const [slot, value] of Object.entries(kills as Record<string, unknown>)) {
      if (typeof value === 'number' && Number.isInteger(value) && value >= 0) {
        playerKills[slot] = value;
      }
    }
    if (!this.reports.has(seat.playerId)) {
      this.reports.set(seat.playerId, {
        player_id: seat.playerId,
        team_wave: teamWave,
        player_kills: playerKills,
      });
    }
    this.stopLoop();
    if (this.reports.size >= this.occupiedSeats().length) {
      await this.finishMatch();
      return;
    }
    if (this.resultTimer === null) {
      this.resultTimer = setTimeout(() => {
        void this.finishMatch();
      }, RESULT_GRACE_MS);
    }
  }

  // ------------------------------------------------------------------- match

  private startMatch(): void {
    if (this.roomState !== 'lobby') return;
    if (this.occupiedSeats().length === 0) return;

    // Compact the seats to 0..n-1 before anything reads them. A lobby that
    // lost its middle player leaves a hole, and every client would then have to
    // reason about "slot 2 exists but slot 1 does not" when spawning bodies and
    // indexing SimWorld's fixed slot arrays. Closing the hole here means the
    // client only ever sees a dense roster, and the `start` message carries the
    // final numbering so nobody acts on the pre-compaction one.
    const compacted = this.occupiedSeats().map((entry) => entry.seat);
    this.seats.fill(null);
    for (let index = 0; index < compacted.length; index += 1) {
      this.seats[index] = compacted[index]!;
    }
    this.sockets.clear();
    for (let index = 0; index < this.seats.length; index += 1) {
      const socket = this.seats[index]?.socket;
      if (socket != null) this.sockets.set(socket, index);
    }
    this.hostSlot = this.seats.findIndex((seat) => seat !== null);
    const occupied = this.occupiedSeats();

    this.roomState = 'playing';
    this.tick = 0;
    // The seed is the room's, not any client's: every client's DeterministicRng
    // is derived from it, so a client picking its own would desync by design.
    this.seed = (crypto.getRandomValues(new Uint32Array(1))[0]! % 2_000_000_000) + 1;
    this.matchStartedAt = Date.now();
    this.latest = new Array(MAX_PLAYERS_PER_ROOM).fill(null);
    this.waveRequested = false;
    this.reports.clear();
    this.hashes.clear();
    // Last match's frames would replay into this one's tick numbering.
    this.history.clear();

    this.broadcast({
      type: 'start',
      seed: this.seed,
      tick: 0,
      // player_id is here so a client can re-derive its own slot after the
      // compaction above without trusting the one it got at welcome time.
      slots: occupied.map((entry) => ({
        slot: entry.slot,
        nickname: entry.seat.nickname,
        player_id: entry.seat.playerId,
      })),
    });
    this.startLoop();
    void this.publishDirectory();
  }

  /**
   * The frame pump. Every client steps its simulation exactly once per frame
   * received here, so this interval -- not any client's render loop -- is what
   * the match's clock actually is.
   */
  private startLoop(): void {
    this.stopLoop();
    this.loop = setInterval(() => {
      this.pumpFrame();
    }, TICK_MS);
  }

  private stopLoop(): void {
    if (this.loop !== null) {
      clearInterval(this.loop);
      this.loop = null;
    }
  }

  private pumpFrame(): void {
    if (this.roomState !== 'playing') {
      this.stopLoop();
      return;
    }
    const frame: Frame = { type: 'f', t: this.tick, s: this.latest.slice() };
    if (this.waveRequested) frame.w = true;
    // Encoded once and remembered as the same bytes that went out: a replayed
    // frame must be the frame, not a re-serialisation of state that has since
    // moved on.
    const encoded = JSON.stringify(frame);
    this.broadcastEncoded(encoded);
    this.history.push(this.tick, encoded);

    this.tick += 1;
    this.waveRequested = false;
    // Held state repeats when a packet is late; edges and one-shot events must
    // NOT. Repeating `use_just_pressed` would fire the weapon again every tick
    // a packet went missing, on every client, identically -- a desync-free bug
    // is still a bug.
    for (let slot = 0; slot < this.latest.length; slot += 1) {
      const command = this.latest[slot];
      if (command == null) continue;
      command.b &= STICKY_BITS;
      delete command.e;
      delete command.w;
      delete command.h;
    }
  }

  private async finishMatch(): Promise<void> {
    if (this.roomState === 'ended') return;
    this.roomState = 'ended';
    this.stopLoop();
    if (this.resultTimer !== null) {
      clearTimeout(this.resultTimer);
      this.resultTimer = null;
    }

    const slots = this.occupiedSeats().map((entry) => ({
      slot: entry.slot,
      player_id: entry.seat.playerId,
    }));
    const outcome = await submitMatchResult(this.env.DB, {
      roomId: `${this.code}-${this.matchStartedAt}`,
      season: CURRENT_SEASON,
      slots,
      reports: [...this.reports.values()],
      durationMs: Date.now() - this.matchStartedAt,
    });
    this.broadcast({
      type: 'end',
      status: outcome.status,
      team_wave: outcome.team_wave,
      player_kills: outcome.player_kills,
      persisted: outcome.persisted,
      reason: outcome.reason,
    });

    // Back to the lobby so the same room can run another match.
    this.roomState = 'lobby';
    this.reports.clear();
    this.hashes.clear();
    for (const seat of this.seats) if (seat !== null) seat.ready = false;
    this.broadcastRoster();
    void this.publishDirectory();
  }

  // -------------------------------------------------------------- membership

  private onDisconnect(socket: WebSocket): void {
    const slot = this.sockets.get(socket);
    this.sockets.delete(socket);
    if (slot === undefined) return;
    const seat = this.seats[slot];
    if (seat == null || seat.socket !== socket) return;
    seat.socket = null;

    if (this.roomState === 'playing') {
      // The seat stays, so the slot table -- and therefore every client's
      // simulation -- is unchanged. The player is simply reported absent, and
      // may reclaim the seat by reconnecting.
      const command = this.latest[slot];
      if (command != null) command.b &= ~BIT_PRESENT;
    } else {
      this.seats[slot] = null;
      if (this.hostSlot === slot) {
        this.hostSlot = this.seats.findIndex((entry) => entry !== null);
      }
    }
    this.broadcastRoster();
    void this.publishDirectory();

    if (this.occupiedSeats().every((entry) => entry.seat.socket === null)) {
      this.stopLoop();
      this.stopHeartbeat();
    }
  }

  private ensureHeartbeat(): void {
    if (this.heartbeat !== null) return;
    this.heartbeat = setInterval(() => {
      const now = Date.now();
      for (const [socket, slot] of [...this.sockets]) {
        const seat = this.seats[slot];
        if (seat == null) continue;
        if (now - seat.lastSeenAt > CONNECTION_TIMEOUT_MS) {
          socket.close(CLOSE_ROOM_CLOSED, 'timed out');
          this.onDisconnect(socket);
          continue;
        }
        this.send(socket, { type: 'ping', t: now });
      }
      if (this.sockets.size === 0) this.stopHeartbeat();
    }, HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeat !== null) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
  }

  private occupiedSeats(): Array<{ slot: number; seat: Seat }> {
    const result: Array<{ slot: number; seat: Seat }> = [];
    for (let slot = 0; slot < this.seats.length; slot += 1) {
      const seat = this.seats[slot];
      if (seat != null) result.push({ slot, seat });
    }
    return result;
  }

  private roster(): RosterEntry[] {
    return this.occupiedSeats().map(({ slot, seat }) => ({
      slot,
      player_id: seat.playerId,
      nickname: seat.nickname,
      ready: seat.ready,
      connected: seat.socket !== null,
    }));
  }

  private broadcastRoster(): void {
    this.broadcast({
      type: 'roster',
      state: this.roomState,
      host_slot: this.hostSlot,
      players: this.roster(),
    });
  }

  /**
   * Mirrors the room into the D1 directory that `GET /api/rooms` reads. Best
   * effort on purpose: the directory is a browse convenience, and a room whose
   * row failed to update is still reachable by its code.
   */
  private async publishDirectory(): Promise<void> {
    if (this.code === '') return;
    const info = this.info();
    const now = Date.now();
    try {
      await this.env.DB.prepare(
        `INSERT INTO rooms (code, is_public, state, host_nickname, player_count, max_players, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(code) DO UPDATE SET
           is_public = excluded.is_public,
           state = excluded.state,
           host_nickname = excluded.host_nickname,
           player_count = excluded.player_count,
           updated_at = excluded.updated_at`,
      )
        .bind(
          this.code,
          info.is_public ? 1 : 0,
          info.state,
          info.host_nickname,
          info.player_count,
          info.max_players,
          now,
          now,
        )
        .run();
    } catch (error: unknown) {
      console.warn(`room directory update failed code=${this.code}: ${String(error)}`);
    }
  }

  private send(socket: WebSocket, payload: unknown): void {
    this.sendEncoded(socket, JSON.stringify(payload));
  }

  private sendEncoded(socket: WebSocket, encoded: string): void {
    try {
      socket.send(encoded);
    } catch {
      this.onDisconnect(socket);
    }
  }

  private broadcast(payload: unknown): void {
    this.broadcastEncoded(JSON.stringify(payload));
  }

  private broadcastEncoded(encoded: string): void {
    for (const socket of [...this.sockets.keys()]) {
      try {
        socket.send(encoded);
      } catch {
        this.onDisconnect(socket);
      }
    }
  }
}
