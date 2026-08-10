/**
 * 房间码要被人念出来再手输，所以字母表剔除了 I / O / 0 / 1 这四个易混字符。
 * 剩余 32 个符号 × 6 位 ≈ 1.07e9 种组合，配合 allocateRoomCode 的重试足够。
 */
export const ROOM_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export const ROOM_CODE_LENGTH = 6;
export const ROOM_CODE_MAX_ATTEMPTS = 64;

export type RandomIndex = (maxExclusive: number) => number;

export class RoomCodeExhaustedError extends Error {
  readonly code = 'code_exhausted';

  constructor(readonly attempts: number) {
    super(`could not allocate a free room code after ${attempts} attempts`);
    this.name = 'RoomCodeExhaustedError';
  }
}

/**
 * Rejection sampling over crypto.getRandomValues. The naive `% alphabet.length`
 * would bias the first 32 of 256 byte values upward -- harmless for a room code,
 * but this is also the only randomness source in the file and the next thing to
 * reach for it may not be so forgiving.
 */
export function randomIndex(maxExclusive: number): number {
  const limit = Math.floor(256 / maxExclusive) * maxExclusive;
  const buffer = new Uint8Array(1);
  for (;;) {
    crypto.getRandomValues(buffer);
    const value = buffer[0]!;
    if (value < limit) return value % maxExclusive;
  }
}

export function normalizeRoomCode(value: string): string {
  return value.trim().toUpperCase();
}

export function isRoomCode(value: string): boolean {
  if (value.length !== ROOM_CODE_LENGTH) return false;
  for (const character of value) {
    if (!ROOM_CODE_ALPHABET.includes(character)) return false;
  }
  return true;
}

export function generateRoomCode(random: RandomIndex = randomIndex): string {
  let code = '';
  for (let position = 0; position < ROOM_CODE_LENGTH; position += 1) {
    code += ROOM_CODE_ALPHABET[random(ROOM_CODE_ALPHABET.length)] ?? 'A';
  }
  return code;
}

export async function allocateRoomCode(
  isTaken: (code: string) => Promise<boolean>,
  random: RandomIndex = randomIndex,
): Promise<string> {
  for (let attempt = 0; attempt < ROOM_CODE_MAX_ATTEMPTS; attempt += 1) {
    const code = generateRoomCode(random);
    if (!(await isTaken(code))) return code;
  }
  throw new RoomCodeExhaustedError(ROOM_CODE_MAX_ATTEMPTS);
}
