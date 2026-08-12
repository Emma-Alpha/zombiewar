/**
 * Room decisions that are pure functions of the seat table.
 *
 * They live here rather than inside the Durable Object so they can be tested
 * without standing up a WebSocket and a DurableObjectState: the rules are the
 * part that is worth testing, and the object around them is plumbing.
 */

import { CONTENT_ID_MAX_LENGTH } from './protocol.js';

const CONTENT_ID_PATTERN = new RegExp(`^[a-z0-9_]{1,${CONTENT_ID_MAX_LENGTH}}$`);

/**
 * Shape-only validation for a content identifier (character id, map id).
 *
 * Deliberately not an allowlist: the server does not know the game's content,
 * and keeping one here would mean deploying the Worker every time a character
 * is added. The client refuses to enter a match carrying an id its own catalog
 * does not have, which is where an unknown id actually gets caught.
 */
export function isValidContentId(value: unknown): value is string {
  return typeof value === 'string' && CONTENT_ID_PATTERN.test(value);
}

/**
 * The host may start once every *other* occupied seat is ready. The host's own
 * flag is ignored -- pressing start is the host's readiness.
 */
export function allNonHostSeatsReady(
  seats: ReadonlyArray<{ ready: boolean } | null>,
  hostSlot: number,
): boolean {
  if (hostSlot < 0) return false;
  return seats.every((seat, slot) => seat === null || slot === hostSlot || seat.ready);
}
