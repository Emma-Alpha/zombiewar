import { describe, expect, it } from 'vitest';

import { allNonHostSeatsReady, isValidContentId } from '../src/lib/room_rules.js';

describe('isValidContentId', () => {
  it('accepts lowercase, digits and underscore', () => {
    expect(isValidContentId('survivor_red')).toBe(true);
    expect(isValidContentId('map01')).toBe(true);
    expect(isValidContentId('a')).toBe(true);
  });

  it('rejects anything the client could not have produced', () => {
    expect(isValidContentId('')).toBe(false);
    expect(isValidContentId('Survivor')).toBe(false);
    expect(isValidContentId('survivor-red')).toBe(false);
    expect(isValidContentId('survivor red')).toBe(false);
    expect(isValidContentId('a'.repeat(33))).toBe(false);
    expect(isValidContentId(null)).toBe(false);
    expect(isValidContentId(42)).toBe(false);
    expect(isValidContentId(undefined)).toBe(false);
  });

  it('accepts exactly the length ceiling', () => {
    expect(isValidContentId('a'.repeat(32))).toBe(true);
  });
});

describe('allNonHostSeatsReady', () => {
  const seat = (ready: boolean) => ({ ready });

  it('is true for a lone host', () => {
    expect(allNonHostSeatsReady([seat(false), null, null, null], 0)).toBe(true);
  });

  it('ignores the host own ready flag', () => {
    expect(allNonHostSeatsReady([seat(false), seat(true), null, null], 0)).toBe(true);
  });

  it('is false while any guest is not ready', () => {
    expect(allNonHostSeatsReady([seat(true), seat(true), seat(false), null], 0)).toBe(false);
  });

  it('is true when every guest is ready', () => {
    expect(allNonHostSeatsReady([seat(false), seat(true), seat(true), null], 0)).toBe(true);
  });

  it('honours a host that is not in slot 0', () => {
    // 房主迁移后 hostSlot 可能是任意一个座位，闸门必须跟着走。
    expect(allNonHostSeatsReady([seat(false), seat(true), null, null], 1)).toBe(false);
    expect(allNonHostSeatsReady([seat(true), seat(false), null, null], 1)).toBe(true);
  });

  it('is false when there is no host at all', () => {
    // hostSlot 为 -1 意味着房间是空的，开局没有意义。
    expect(allNonHostSeatsReady([null, null, null, null], -1)).toBe(false);
  });
});
