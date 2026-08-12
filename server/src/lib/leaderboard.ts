import type { BoardId, LeaderboardEntry } from '../types.js';

/**
 * ============================================================================
 *  THERE IS NO PUBLIC SCORE SUBMISSION ENDPOINT.
 * ============================================================================
 *
 * `submitMatchResult()` below is the ONLY way a row enters `scores`, and it is
 * called by the room Durable Object after a match ends. No route file may
 * import it. That is the entire anti-cheat foundation: a client that cannot
 * reach a write path cannot forge a score, whatever it does to its own memory.
 *
 * What a client CAN do is lie in its `result` report. That is what
 * `crossValidateReports()` is for: every client runs the same deterministic
 * simulation, so in a healthy match the reported numbers are byte-identical.
 * A single deviating client is discarded; a room with no majority is voided.
 *
 * A one-player room has nobody to cross-check against, so it is never written.
 * This is the unavoidable price of majority voting under anonymous identity,
 * and the client UI states it up front (「至少 2 人才能上榜」).
 */

/** Nobody survives 200 waves. Anything past this is a forged report. */
export const MAX_TEAM_WAVE = 200;

/**
 * Kill ceiling per wave. Derived from the default map data, not invented:
 * resources/maps/demo/demo_map.tres authors 60 zombies per wave. The headroom
 * above that absorbs future map tuning; anything higher is a forged report.
 * If the ranked map's MapDefinition wave count changes, this MUST change with
 * it.
 */
export const MAX_ZOMBIES_PER_WAVE = 96;

/** A "match" shorter than this cannot have produced a real wave count. */
export const MIN_MATCH_DURATION_MS = 30_000;

/** Fewer participants than this and nothing is written. */
export const MIN_PLAYERS_FOR_RANKING = 2;

export function maxKillsForWave(teamWave: number): number {
  return teamWave * MAX_ZOMBIES_PER_WAVE;
}

/**
 * One row per player: their single best score on this board and season.
 *
 * `s.created_at` is a bare column beside `MAX(s.value)`. In SQLite -- and only
 * SQLite -- that is defined behaviour: with a min/max aggregate, bare columns
 * take their values from the row that produced the extreme. So `created_at` is
 * the timestamp OF the best run, not of an arbitrary one, which is what the
 * tie-break below needs to be stable.
 */
export async function readLeaderboard(
  db: D1Database,
  board: BoardId,
  season: number,
  limit: number,
  offset: number,
): Promise<LeaderboardEntry[]> {
  const result = await db
    .prepare(
      `SELECT s.player_id              AS player_id,
              COALESCE(p.nickname, '') AS nickname,
              MAX(s.value)             AS value,
              s.created_at             AS created_at
         FROM scores s
         LEFT JOIN players p ON p.player_id = s.player_id
        WHERE s.board = ? AND s.season = ?
        GROUP BY s.player_id
        ORDER BY value DESC, created_at ASC, player_id ASC
        LIMIT ? OFFSET ?`,
    )
    .bind(board, season, limit, offset)
    .all<{ player_id: string; nickname: string; value: number; created_at: number }>();
  return result.results.map((row, index) => ({
    rank: offset + index + 1,
    player_id: row.player_id,
    nickname: row.nickname,
    value: row.value,
    created_at: row.created_at,
  }));
}

/**
 * U+001F. A nickname can never contain it: normalizeNickname() rejects control
 * characters, so it is the one separator GROUP_CONCAT cannot collide with.
 */
const MEMBER_SEPARATOR = String.fromCharCode(31);

/**
 * The `team_waves` board rendered as what it actually is: a TEAM board.
 *
 * `scores` still carries one `team_waves` row per participant -- `/me` needs a
 * row keyed by player_id to answer "my rank" -- but reading that table with
 * readLeaderboard() would put four identical rows on the public board for a
 * single 4-player run, with no way to tell one team's run from four solo ones.
 * So the public read groups by `room_id`: one row per match, with every
 * member's nickname joined into `nickname` for display and kept verbatim in
 * `members`. `player_id` carries the room id here -- it is the identity of the
 * row, and the client only uses it as an opaque key.
 */
export async function readTeamLeaderboard(
  db: D1Database,
  season: number,
  limit: number,
  offset: number,
): Promise<Array<LeaderboardEntry & { members: string[] }>> {
  const result = await db
    .prepare(
      `SELECT s.room_id    AS room_id,
              MAX(s.value) AS value,
              s.created_at AS created_at,
              GROUP_CONCAT(COALESCE(p.nickname, ''), char(31)) AS members
         FROM scores s
         LEFT JOIN players p ON p.player_id = s.player_id
        WHERE s.board = 'team_waves' AND s.season = ?
        GROUP BY s.room_id
        ORDER BY value DESC, created_at ASC, room_id ASC
        LIMIT ? OFFSET ?`,
    )
    .bind(season, limit, offset)
    .all<{ room_id: string; value: number; created_at: number; members: string | null }>();
  return result.results.map((row, index) => {
    const members = (row.members ?? '').split(MEMBER_SEPARATOR).filter((name) => name !== '');
    return {
      rank: offset + index + 1,
      player_id: row.room_id,
      nickname: members.join('、'),
      value: row.value,
      created_at: row.created_at,
      members,
    };
  });
}

/**
 * How many rows the board has in total, so the client can tell "this page is
 * full" from "there is a next page". Without it a panel showing exactly
 * PAGE_SIZE entries has to guess, and guessing wrong lands the player on an
 * empty page that looks identical to an empty leaderboard.
 *
 * Counts the same unit each board is rendered in: rooms for the team board,
 * players for the kills board.
 */
export async function countLeaderboard(
  db: D1Database,
  board: BoardId,
  season: number,
): Promise<number> {
  // The column name is chosen from a closed set, never interpolated from input.
  const column = board === 'team_waves' ? 'room_id' : 'player_id';
  const row = await db
    .prepare(`SELECT COUNT(DISTINCT ${column}) AS n FROM scores WHERE board = ? AND season = ?`)
    .bind(board, season)
    .first<{ n: number }>();
  return row?.n ?? 0;
}

/**
 * This player's best score plus its rank. The "ahead of me" predicate mirrors
 * the ORDER BY in readLeaderboard exactly -- value first, then earlier timestamp
 * wins, then player_id -- so the rank reported here is the row number the player
 * would occupy in the paged list.
 */
export async function readPlayerBest(
  db: D1Database,
  board: BoardId,
  season: number,
  playerId: string,
): Promise<LeaderboardEntry | null> {
  const best = await db
    .prepare(
      `SELECT MAX(value) AS value, created_at AS created_at
         FROM scores
        WHERE board = ? AND season = ? AND player_id = ?`,
    )
    .bind(board, season, playerId)
    .first<{ value: number | null; created_at: number | null }>();
  if (best === null || best.value === null || best.created_at === null) return null;

  const ahead = await db
    .prepare(
      `SELECT COUNT(*) AS ahead FROM (
          SELECT player_id AS pid, MAX(value) AS best, created_at AS at
            FROM scores
           WHERE board = ? AND season = ?
           GROUP BY player_id
       )
       WHERE best > ?
          OR (best = ? AND (at < ? OR (at = ? AND pid < ?)))`,
    )
    .bind(board, season, best.value, best.value, best.created_at, best.created_at, playerId)
    .first<{ ahead: number }>();

  const player = await db
    .prepare('SELECT nickname FROM players WHERE player_id = ?')
    .bind(playerId)
    .first<{ nickname: string }>();

  return {
    rank: (ahead?.ahead ?? 0) + 1,
    player_id: playerId,
    nickname: player?.nickname ?? '',
    value: best.value,
    created_at: best.created_at,
  };
}

/** One occupied seat in the finished match. `slot` is 0-based, as in-game. */
export interface MatchSlot {
  slot: number;
  player_id: string;
}

/**
 * One client's `result` upload. `player_kills` is keyed by slot index rendered
 * as a decimal string, because that is what JSON object keys are.
 */
export interface MatchReport {
  player_id: string;
  team_wave: number;
  player_kills: Record<string, number>;
}

export type VoteStatus =
  | 'accepted'
  | 'no_majority'
  | 'too_few_players'
  | 'too_short'
  | 'out_of_range';

export interface VoteResult {
  status: VoteStatus;
  team_wave: number;
  player_kills: Record<string, number>;
  /** player_ids whose report disagreed with the majority. Sorted, deduped. */
  dissenters: string[];
  reason: string;
}

/** Stable string form of a report's payload, so identical reports hash equal. */
function reportKey(report: MatchReport): string {
  const slots = Object.keys(report.player_kills).sort((a, b) => Number(a) - Number(b));
  const kills = slots.map((slot) => `${slot}:${report.player_kills[slot] ?? 0}`);
  return `w=${report.team_wave}|k=${kills.join(',')}`;
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0;
}

function voided(status: VoteStatus, reason: string, dissenters: string[] = []): VoteResult {
  return { status, team_wave: 0, player_kills: {}, dissenters, reason };
}

/**
 * Majority vote over the clients' reports, then server-side sanity caps.
 *
 * The order matters: vote FIRST, cap SECOND. A cap applied before the vote
 * would let one liar with an in-range number drag the whole room into an
 * argument the vote is there to settle.
 *
 * The quorum is over SEATS, not over uploads, and that distinction is the whole
 * anti-cheat foundation. Three ways a per-upload tally loses to a single liar,
 * all of them closed here:
 *
 *   1. Only one client uploads in a 2-player room. Per-upload, that one report
 *      is "unanimous" and writes the whole room's scores unverified. Here it is
 *      one ballot, below MIN_PLAYERS_FOR_RANKING, so the match is voided.
 *   2. One client uploads the same forged report three times in a 4-player
 *      room and manufactures a 3-vs-1 majority. Here one seat casts one ballot;
 *      the first upload from a seat wins and the rest are dropped.
 *   3. A `player_id` that never sat in this match uploads a report. Here it is
 *      not in `slots`, so it is not counted at all.
 *
 * "Majority" is strict and measured against the number of seats: a winner needs
 * more than half of the room to agree, and never fewer than two clients. Two
 * clients that disagree therefore produce no majority -- with two votes and no
 * tiebreaker there is no evidence.
 */
export function crossValidateReports(
  reports: MatchReport[],
  slotPlayerIds: string[],
  durationMs: number,
): VoteResult {
  const playerCount = slotPlayerIds.length;
  if (playerCount < MIN_PLAYERS_FOR_RANKING) {
    return voided(
      'too_few_players',
      `a ${playerCount}-player room has nothing to cross-check against; ` +
        `${MIN_PLAYERS_FOR_RANKING} players are required to rank`,
    );
  }
  if (durationMs < MIN_MATCH_DURATION_MS) {
    return voided('too_short', `match lasted ${durationMs}ms, below ${MIN_MATCH_DURATION_MS}ms`);
  }
  if (reports.length === 0) {
    return voided('no_majority', 'no client reported a result');
  }

  const seatIds = new Set(slotPlayerIds);
  const byPlayer = new Map<string, MatchReport>();
  for (const report of reports) {
    if (!seatIds.has(report.player_id)) continue; // non-participant
    if (byPlayer.has(report.player_id)) continue; // one vote per seat, first wins
    byPlayer.set(report.player_id, report);
  }
  const ballots = [...byPlayer.values()];
  if (ballots.length < MIN_PLAYERS_FOR_RANKING) {
    return voided(
      'no_majority',
      `only ${ballots.length} of ${playerCount} seats reported; ` +
        `${MIN_PLAYERS_FOR_RANKING} independent reports are required to cross-check`,
    );
  }

  const tally = new Map<string, { count: number; report: MatchReport }>();
  for (const report of ballots) {
    const key = reportKey(report);
    const bucket = tally.get(key);
    if (bucket === undefined) tally.set(key, { count: 1, report });
    else bucket.count += 1;
  }

  let winnerKey = '';
  let winner: MatchReport | null = null;
  let winnerCount = 0;
  for (const [key, bucket] of tally) {
    if (bucket.count > winnerCount) {
      winnerKey = key;
      winner = bucket.report;
      winnerCount = bucket.count;
    }
  }
  if (winner === null || winnerCount * 2 <= playerCount || winnerCount < MIN_PLAYERS_FOR_RANKING) {
    // No dissenters on purpose. The match is voided, so nobody was outvoted --
    // there is no reference to have deviated from. Naming every honest client
    // here would poison the audit trail used to find tampering.
    return voided(
      'no_majority',
      `no strict majority among ${ballots.length} reports from ${playerCount} seats ` +
        `(best agreement was ${winnerCount}); nobody is singled out because there is ` +
        `no reference to deviate from`,
    );
  }

  const dissenters = [
    ...new Set(
      ballots.filter((report) => reportKey(report) !== winnerKey).map((report) => report.player_id),
    ),
  ].sort();

  const teamWave = winner.team_wave;
  if (!Number.isInteger(teamWave) || teamWave < 1 || teamWave > MAX_TEAM_WAVE) {
    return voided(
      'out_of_range',
      `team_wave ${teamWave} is outside 1..${MAX_TEAM_WAVE}`,
      dissenters,
    );
  }
  const killCap = maxKillsForWave(teamWave);
  for (const [slot, kills] of Object.entries(winner.player_kills)) {
    if (!isNonNegativeInteger(kills) || kills > killCap) {
      return voided(
        'out_of_range',
        `slot ${slot} reported ${String(kills)} kills, outside 0..${killCap} for wave ${teamWave}`,
        dissenters,
      );
    }
  }

  return {
    status: 'accepted',
    team_wave: teamWave,
    player_kills: { ...winner.player_kills },
    dissenters,
    reason:
      dissenters.length === 0
        ? 'unanimous'
        : `majority of ${winnerCount}/${ballots.length}; discarded ${dissenters.length} deviating report(s)`,
  };
}

export interface SubmitMatchOptions {
  roomId: string;
  season: number;
  slots: MatchSlot[];
  reports: MatchReport[];
  durationMs: number;
  now?: number;
}

export type SubmitMatchResult = VoteResult & {
  /** Rows inserted into `scores`. Zero whenever nothing was persisted. */
  written: number;
  /**
   * False when the vote failed OR the write threw. The room broadcasts
   * 「成绩未保存」 off this, and a D1 failure must never take the match down
   * with it -- a lost leaderboard row is not worth ending everyone's session.
   */
  persisted: boolean;
};

/**
 * INTERNAL. Called by the room Durable Object after a match ends. No HTTP route
 * may import this -- see the header of this file.
 *
 * The team wave is written under EVERY participating player_id -- including
 * seats that never uploaded a report. `team_waves` is a team achievement, and
 * `/me` answers "my best run" from these per-player rows; the PUBLIC team board
 * then groups them back by `room_id` (readTeamLeaderboard) so one match shows as
 * one row.
 *
 * `extra` carries the slot (and, on the kills board, the wave) as JSON so a
 * later audit can reconstruct the match without a second table.
 */
export async function submitMatchResult(
  db: D1Database,
  options: SubmitMatchOptions,
): Promise<SubmitMatchResult> {
  const vote = crossValidateReports(
    options.reports,
    options.slots.map((slot) => slot.player_id),
    options.durationMs,
  );
  if (vote.status !== 'accepted') {
    console.warn(
      `match voided room=${options.roomId} status=${vote.status}: ${vote.reason}`,
    );
    return { ...vote, written: 0, persisted: false };
  }
  if (vote.dissenters.length > 0) {
    // 该客户端可能已不同步或被篡改. Either way it is worth a line in the log --
    // a client that deviates twice is a lead, not noise.
    console.warn(
      `discarded deviating match reports room=${options.roomId} dissenters=${vote.dissenters.join(',')}`,
    );
  }

  const ts = options.now ?? Date.now();
  const insert = db.prepare(
    'INSERT INTO scores (board, season, player_id, room_id, value, extra, created_at) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
  );
  const statements: D1PreparedStatement[] = [];
  for (const slot of options.slots) {
    statements.push(
      insert.bind(
        'team_waves',
        options.season,
        slot.player_id,
        options.roomId,
        vote.team_wave,
        JSON.stringify({ slot: slot.slot }),
        ts,
      ),
    );
    statements.push(
      insert.bind(
        'player_kills',
        options.season,
        slot.player_id,
        options.roomId,
        vote.player_kills[String(slot.slot)] ?? 0,
        JSON.stringify({ slot: slot.slot, team_wave: vote.team_wave }),
        ts,
      ),
    );
  }

  try {
    // D1 runs a batch as one transaction, so the room either lands whole or not
    // at all. A half-written room would show a team wave with missing members.
    await db.batch(statements);
    return { ...vote, written: statements.length, persisted: true };
  } catch (error: unknown) {
    console.error(`d1 write failed room=${options.roomId}: ${String(error)}`);
    return { ...vote, written: 0, persisted: false };
  }
}
