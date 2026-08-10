/**
 * Wire protocol. Mirrored verbatim by the Godot client in
 * `res://scripts/net/lobby_protocol.gd`. Two copies, and a client-side
 * validation script that diffs them against `protocol/fixtures/`.
 *
 * The handshake rejects a version mismatch instead of tolerating it: turning a
 * silent cross-repo drift into one loud failure at connect time, with both
 * version numbers in the close reason, is worth more than any compatibility
 * shim. See close code 4001 below.
 */
export const PROTOCOL_VERSION = 2;

/** Lobby and control messages. */
export const OPCODE_LOBBY_MIN = 0x00;
export const OPCODE_LOBBY_MAX = 0x7f;

/** Reserved wholesale for the sync layer. */
export const OPCODE_SYNC_MIN = 0x80;
export const OPCODE_SYNC_MAX = 0xff;

export function isLobbyOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_LOBBY_MIN && opcode <= OPCODE_LOBBY_MAX;
}

export function isSyncOpcode(opcode: number): boolean {
  return Number.isInteger(opcode) && opcode >= OPCODE_SYNC_MIN && opcode <= OPCODE_SYNC_MAX;
}

/** WebSocket close codes. 4000-4999 is the application-defined range. */
export const CLOSE_PROTOCOL_MISMATCH = 4001;
export const CLOSE_ROOM_FULL = 4002;
export const CLOSE_BAD_MESSAGE = 4003;
export const CLOSE_KICKED = 4004;
export const CLOSE_ROOM_CLOSED = 4005;

/**
 * Simulation tick rate. MUST equal 1 / SimClock.TICK_SECONDS on the client.
 * The server owns the tick counter during a match and paces frames at this
 * rate; clients never advance a tick the server has not sent.
 */
export const TICK_HZ = 20;
export const TICK_MS = 1000 / TICK_HZ;

/**
 * Fixed-point scale for every float that crosses the wire and then enters the
 * simulation. It is deliberately the same 1000 as SimWorld.POSITION_QUANTIZATION:
 * the simulation already rounds player positions to millimetres, so sending the
 * pre-rounded integer means the value the sim consumes is bit-identical on every
 * client without any client having to trust its own float formatting.
 */
export const QUANT = 1000;

export function quantize(value: number): number {
  return Math.round(value * QUANT);
}

export function dequantize(value: number): number {
  return value / QUANT;
}

/** Input bit flags packed into `PlayerCommand.b`. */
export const BIT_USE_PRESSED = 1 << 0;
export const BIT_USE_JUST_PRESSED = 1 << 1;
export const BIT_PREV_EQUIPMENT = 1 << 2;
export const BIT_NEXT_EQUIPMENT = 1 << 3;
export const BIT_CONFIRM = 1 << 4;
export const BIT_ALIVE = 1 << 5;
export const BIT_PRESENT = 1 << 6;

/** Simulation request kinds raised by a player during one tick. */
export const EVENT_SHOT = 0;
export const EVENT_MELEE = 1;
export const EVENT_SPREAD_RESET = 2;

export interface SimEvent {
  /** EVENT_* discriminant. */
  k: number;
  /** Weapon profile index (shot / spread_reset). */
  w?: number;
  /** Quantized origin [x, z] and its height. */
  o?: [number, number];
  oy?: number;
  /** Quantized aim direction [x, z]. */
  a?: [number, number];
  /** Quantized melee damage / reach / half width. */
  d?: number;
  r?: number;
  hw?: number;
}

/**
 * One player's contribution to one tick. Every field is already quantized, so
 * the server never does arithmetic on gameplay values -- it only relays them.
 */
export interface PlayerCommand {
  /** Quantized move vector [x, y]. */
  m: [number, number];
  /** Packed BIT_* flags. */
  b: number;
  /** Quantized world position [x, z]. Feeds SimWorld.set_player_snapshot. */
  p: [number, number];
  /** Simulation requests raised this tick. Omitted when empty. */
  e?: SimEvent[];
  /** Optional frame hash sample for desync detection. */
  h?: string;
  /** Set when this player asked for a new wave on this tick. */
  w?: boolean;
}

export const EMPTY_COMMAND: PlayerCommand = { m: [0, 0], b: 0, p: [0, 0] };

/** A frame is what every client steps its simulation on. Same bytes, everyone. */
export interface Frame {
  type: 'f';
  /** Tick index this frame advances the simulation to. Monotonic from 0. */
  t: number;
  /** Index is the slot. `null` means the seat is empty or has never reported. */
  s: Array<PlayerCommand | null>;
  /** True when a new wave must be queued on this exact tick. */
  w?: boolean;
}

export type RoomState = 'lobby' | 'playing' | 'ended';

export interface RosterEntry {
  slot: number;
  player_id: string;
  nickname: string;
  ready: boolean;
  connected: boolean;
}

/**
 * Validates a command shape before it is relayed. A malformed command is
 * dropped rather than repaired: a repaired command is a command that differs
 * between the sender's simulation and everyone else's, which is a desync with
 * extra steps.
 */
export function parseCommand(raw: unknown): PlayerCommand | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const value = raw as Record<string, unknown>;
  const move = value['m'];
  const position = value['p'];
  if (!isIntPair(move) || !isIntPair(position)) return null;
  const bits = value['b'];
  if (typeof bits !== 'number' || !Number.isInteger(bits) || bits < 0 || bits > 0xff) return null;

  const command: PlayerCommand = { m: move, b: bits, p: position };
  const events = value['e'];
  if (Array.isArray(events)) {
    const parsed: SimEvent[] = [];
    // A single tick cannot legitimately raise more requests than this; the cap
    // is what stops one client from making every other client's tick expensive.
    for (const entry of events.slice(0, 8)) {
      const event = parseEvent(entry);
      if (event !== null) parsed.push(event);
    }
    if (parsed.length > 0) command.e = parsed;
  }
  const hash = value['h'];
  if (typeof hash === 'string' && hash.length <= 32) command.h = hash;
  if (value['w'] === true) command.w = true;
  return command;
}

function parseEvent(raw: unknown): SimEvent | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const value = raw as Record<string, unknown>;
  const kind = value['k'];
  if (kind !== EVENT_SHOT && kind !== EVENT_MELEE && kind !== EVENT_SPREAD_RESET) return null;
  const event: SimEvent = { k: kind };
  for (const key of ['w', 'oy', 'd', 'r', 'hw'] as const) {
    const entry = value[key];
    if (typeof entry === 'number' && Number.isInteger(entry)) event[key] = entry;
  }
  for (const key of ['o', 'a'] as const) {
    const entry = value[key];
    if (isIntPair(entry)) event[key] = entry;
  }
  return event;
}

function isIntPair(value: unknown): value is [number, number] {
  return (
    Array.isArray(value) &&
    value.length === 2 &&
    typeof value[0] === 'number' &&
    typeof value[1] === 'number' &&
    Number.isInteger(value[0]) &&
    Number.isInteger(value[1])
  );
}
