import { BACKFILL_CHUNK_FRAMES, FRAME_HISTORY_LIMIT } from './protocol.js';

interface HistoryEntry {
  tick: number;
  /** The frame exactly as it went out, so a replay is byte-identical to the live broadcast. */
  encoded: string;
}

/**
 * The frames the room has already broadcast, newest last.
 *
 * A client that drops out and comes back has a simulation frozen at whatever
 * tick it last applied. Lockstep gives it no way to skip forward -- every tick
 * in between changed where the zombies are -- so the only honest options are to
 * replay the gap or refuse the rejoin. This holds the material for the first.
 *
 * Entries keep the encoded string rather than the `Frame` object on purpose:
 * `pumpFrame` mutates the command objects a frame references immediately after
 * broadcasting it, so anything holding the object would watch its history get
 * rewritten one tick later.
 */
export class FrameHistory {
  private entries: HistoryEntry[] = [];

  get size(): number {
    return this.entries.length;
  }

  /** Tick of the oldest frame still held, or null when nothing has been pumped. */
  get oldestTick(): number | null {
    return this.entries[0]?.tick ?? null;
  }

  clear(): void {
    this.entries = [];
  }

  push(tick: number, encoded: string): void {
    this.entries.push({ tick, encoded });
    if (this.entries.length > FRAME_HISTORY_LIMIT) this.entries.shift();
  }

  /**
   * Whether the gap starting at `fromTick` can be replayed in full. A partial
   * replay is worse than none: it lands the client on a tick it never simulated
   * its way to, which is the desync it was trying to avoid.
   */
  covers(fromTick: number): boolean {
    const oldest = this.oldestTick;
    if (oldest === null) return true;
    return fromTick >= oldest;
  }

  /**
   * Ready-to-send backfill payloads covering `fromTick` onward, in order.
   * Chunked because a 30-second gap is several hundred frames and one message
   * carrying all of them would crowd the platform's per-message ceiling.
   */
  chunksFrom(fromTick: number): string[] {
    const oldest = this.oldestTick;
    if (oldest === null) return [];
    const start = Math.max(0, fromTick - oldest);
    const chunks: string[] = [];
    for (let index = start; index < this.entries.length; index += BACKFILL_CHUNK_FRAMES) {
      const frames = this.entries
        .slice(index, index + BACKFILL_CHUNK_FRAMES)
        .map((entry) => entry.encoded)
        .join(',');
      chunks.push(`{"type":"backfill","frames":[${frames}]}`);
    }
    return chunks;
  }
}
