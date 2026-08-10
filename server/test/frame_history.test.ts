import { describe, expect, it } from 'vitest';

import { FrameHistory } from '../src/lib/frame_history.js';
import { BACKFILL_CHUNK_FRAMES, FRAME_HISTORY_LIMIT } from '../src/lib/protocol.js';

function fill(history: FrameHistory, from: number, count: number): void {
  for (let tick = from; tick < from + count; tick += 1) {
    history.push(tick, JSON.stringify({ type: 'f', t: tick, s: [] }));
  }
}

function framesIn(chunks: string[]): Array<{ t: number }> {
  return chunks.flatMap((chunk) => (JSON.parse(chunk) as { frames: Array<{ t: number }> }).frames);
}

describe('FrameHistory', () => {
  it('has nothing missing before the first pump', () => {
    const history = new FrameHistory();
    expect(history.oldestTick).toBeNull();
    expect(history.covers(0)).toBe(true);
    expect(history.chunksFrom(0)).toEqual([]);
  });

  it('drops the oldest frame once it is full', () => {
    const history = new FrameHistory();
    fill(history, 0, FRAME_HISTORY_LIMIT + 10);
    expect(history.size).toBe(FRAME_HISTORY_LIMIT);
    expect(history.oldestTick).toBe(10);
  });

  it('refuses a gap that reaches back further than it holds', () => {
    const history = new FrameHistory();
    fill(history, 0, FRAME_HISTORY_LIMIT + 10);
    // Tick 9 has been evicted, so a client stopped at tick 8 cannot be walked
    // forward -- there is no frame 9 left to walk it with.
    expect(history.covers(9)).toBe(false);
    expect(history.covers(10)).toBe(true);
  });

  it('replays exactly the frames the client is missing', () => {
    const history = new FrameHistory();
    fill(history, 0, 50);
    const frames = framesIn(history.chunksFrom(47));
    expect(frames.map((frame) => frame.t)).toEqual([47, 48, 49]);
  });

  it('replays the whole match for a client that simulated nothing', () => {
    const history = new FrameHistory();
    fill(history, 0, 30);
    expect(framesIn(history.chunksFrom(0)).map((frame) => frame.t)).toEqual(
      Array.from({ length: 30 }, (_value, index) => index),
    );
  });

  it('sends nothing to a client that is already current', () => {
    const history = new FrameHistory();
    fill(history, 0, 30);
    expect(history.chunksFrom(30)).toEqual([]);
  });

  it('splits a long replay into bounded chunks that stay in order', () => {
    const history = new FrameHistory();
    fill(history, 0, FRAME_HISTORY_LIMIT);
    const chunks = history.chunksFrom(0);
    expect(chunks.length).toBe(Math.ceil(FRAME_HISTORY_LIMIT / BACKFILL_CHUNK_FRAMES));
    for (const chunk of chunks) {
      const parsed = JSON.parse(chunk) as { type: string; frames: unknown[] };
      expect(parsed.type).toBe('backfill');
      expect(parsed.frames.length).toBeLessThanOrEqual(BACKFILL_CHUNK_FRAMES);
    }
    expect(framesIn(chunks).map((frame) => frame.t)).toEqual(
      Array.from({ length: FRAME_HISTORY_LIMIT }, (_value, index) => index),
    );
  });

  it('replays the bytes that were broadcast, not a re-serialisation', () => {
    // pumpFrame strips edges off the command objects a frame references right
    // after sending it. Anything that kept the object would replay a frame that
    // never went out.
    const history = new FrameHistory();
    const command = { m: [1, 1], b: 0b11, p: [0, 0], e: [{ k: 0 }] };
    const frame = { type: 'f', t: 0, s: [command] };
    // Snapshotted before the mutation: `frame.s[0]` *is* `command`, so a live
    // reference here would quietly move with it and assert nothing.
    const asBroadcast = structuredClone(frame);
    history.push(0, JSON.stringify(frame));
    command.b = 0;
    command.e = [];
    expect(framesIn(history.chunksFrom(0))).toEqual([asBroadcast]);
  });

  it('forgets the previous match so its ticks cannot replay into the next', () => {
    const history = new FrameHistory();
    fill(history, 0, 30);
    history.clear();
    expect(history.oldestTick).toBeNull();
    expect(history.chunksFrom(0)).toEqual([]);
  });
});
