import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  BIT_ALIVE,
  BIT_PRESENT,
  BIT_USE_JUST_PRESSED,
  BIT_USE_PRESSED,
  EVENT_SHOT,
  PROTOCOL_VERSION,
  QUANT,
  TICK_HZ,
  TICK_MS,
  isLobbyOpcode,
  isSyncOpcode,
  parseCommand,
} from '../src/lib/protocol.js';

const CLIENT_PROTOCOL = resolve(import.meta.dirname, '../../scripts/net/lobby_protocol.gd');

function readGdConstant(source: string, name: string): number {
  // `1 << 3` first: its leading `1` is itself a valid literal, so a
  // literal-first reader would silently read every bit flag as 1.
  const shift = new RegExp(`const ${name} := 1 << (\\d+)`).exec(source);
  if (shift !== null) return 1 << Number.parseInt(shift[1]!, 10);
  const match = new RegExp(`const ${name} := (0x[0-9A-Fa-f]+|\\d+)`).exec(source);
  if (match === null) throw new Error(`client protocol has no constant ${name}`);
  return Number(match[1]);
}

describe('protocol constants', () => {
  const source = readFileSync(CLIENT_PROTOCOL, 'utf8');

  it.each([
    ['PROTOCOL_VERSION', PROTOCOL_VERSION],
    ['TICK_HZ', TICK_HZ],
    ['BIT_USE_PRESSED', BIT_USE_PRESSED],
    ['BIT_USE_JUST_PRESSED', BIT_USE_JUST_PRESSED],
    ['BIT_ALIVE', BIT_ALIVE],
    ['BIT_PRESENT', BIT_PRESENT],
    ['EVENT_SHOT', EVENT_SHOT],
  ])('%s matches the Godot client', (name, expected) => {
    expect(readGdConstant(source, name)).toBe(expected);
  });

  it('shares the quantisation scale with the client', () => {
    // The client spells it as a float (1000.0) because GDScript needs it that way.
    expect(new RegExp(`const QUANT := ${QUANT}\\.0`).test(source)).toBe(true);
  });

  it('paces frames at exactly the tick rate', () => {
    expect(TICK_MS).toBe(50);
    expect(1000 / TICK_HZ).toBe(TICK_MS);
  });

  it('keeps the lobby and sync opcode ranges disjoint', () => {
    expect(isLobbyOpcode(0x7f)).toBe(true);
    expect(isSyncOpcode(0x7f)).toBe(false);
    expect(isLobbyOpcode(0x80)).toBe(false);
    expect(isSyncOpcode(0x80)).toBe(true);
  });
});

describe('parseCommand', () => {
  const valid = { m: [100, 0], b: BIT_ALIVE | BIT_PRESENT, p: [1000, -2000] };

  it('accepts a well-formed command', () => {
    expect(parseCommand(valid)).toEqual(valid);
  });

  it.each([
    ['non-integer position', { ...valid, p: [1.5, 2] }],
    ['short move pair', { ...valid, m: [1] }],
    ['missing bits', { m: [0, 0], p: [0, 0] }],
    ['out-of-range bits', { ...valid, b: 999 }],
    ['not an object', 'nope'],
    ['null', null],
  ])('drops a command with %s', (_label, input) => {
    expect(parseCommand(input)).toBeNull();
  });

  it('caps the events a single tick may raise', () => {
    const events = Array.from({ length: 20 }, () => ({ k: EVENT_SHOT, w: 0 }));
    const parsed = parseCommand({ ...valid, e: events });
    expect(parsed?.e?.length).toBe(8);
  });

  it('drops unknown event kinds rather than repairing them', () => {
    // A repaired command differs between the sender's simulation and everyone
    // else's, which is a desync with extra steps.
    const parsed = parseCommand({ ...valid, e: [{ k: 99 }, { k: EVENT_SHOT, w: 1 }] });
    expect(parsed?.e).toEqual([{ k: EVENT_SHOT, w: 1 }]);
  });

  it('ignores an over-long hash', () => {
    expect(parseCommand({ ...valid, h: 'x'.repeat(64) })?.h).toBeUndefined();
  });
});
