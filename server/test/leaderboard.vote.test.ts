import { describe, expect, it } from 'vitest';

import {
  MIN_MATCH_DURATION_MS,
  crossValidateReports,
  maxKillsForWave,
  type MatchReport,
} from '../src/lib/leaderboard.js';

const LONG_ENOUGH = MIN_MATCH_DURATION_MS + 1;

function report(playerId: string, teamWave: number, kills: Record<string, number>): MatchReport {
  return { player_id: playerId, team_wave: teamWave, player_kills: kills };
}

describe('crossValidateReports', () => {
  it('accepts a unanimous room', () => {
    const kills = { '0': 41, '1': 33 };
    const vote = crossValidateReports(
      [report('a', 7, kills), report('b', 7, kills)],
      ['a', 'b'],
      LONG_ENOUGH,
    );
    expect(vote.status).toBe('accepted');
    expect(vote.team_wave).toBe(7);
    expect(vote.dissenters).toEqual([]);
  });

  it('discards a single deviating client but still accepts the majority', () => {
    const honest = { '0': 41, '1': 33, '2': 12 };
    const vote = crossValidateReports(
      [
        report('a', 7, honest),
        report('b', 7, honest),
        report('c', 99, { '0': 9999, '1': 0, '2': 0 }),
      ],
      ['a', 'b', 'c'],
      LONG_ENOUGH,
    );
    expect(vote.status).toBe('accepted');
    expect(vote.team_wave).toBe(7);
    expect(vote.dissenters).toEqual(['c']);
  });

  it('voids a 2-player room whose clients disagree', () => {
    const vote = crossValidateReports(
      [report('a', 7, { '0': 41 }), report('b', 8, { '0': 41 })],
      ['a', 'b'],
      LONG_ENOUGH,
    );
    expect(vote.status).toBe('no_majority');
    // Nobody is named: with two votes and no tiebreaker there is no reference
    // to have deviated from.
    expect(vote.dissenters).toEqual([]);
  });

  it('never ranks a solo room', () => {
    const vote = crossValidateReports([report('a', 7, { '0': 41 })], ['a'], LONG_ENOUGH);
    expect(vote.status).toBe('too_few_players');
  });

  it('rejects a room where only one of two seats reported', () => {
    // Per-upload tallying would call this unanimous and write it unverified.
    const vote = crossValidateReports([report('a', 7, { '0': 41 })], ['a', 'b'], LONG_ENOUGH);
    expect(vote.status).toBe('no_majority');
  });

  it('counts one ballot per seat, so repeated uploads cannot manufacture a majority', () => {
    const forged = { '0': 500 };
    const honest = { '0': 10, '1': 10, '2': 10, '3': 10 };
    const vote = crossValidateReports(
      [
        report('a', 50, forged),
        report('a', 50, forged),
        report('a', 50, forged),
        report('b', 7, honest),
      ],
      ['a', 'b', 'c', 'd'],
      LONG_ENOUGH,
    );
    // 'a' cast one ballot, not three -- so there is no majority, not a forged one.
    expect(vote.status).toBe('no_majority');
  });

  it('ignores reports from player_ids that never sat in the match', () => {
    const kills = { '0': 5, '1': 5 };
    const vote = crossValidateReports(
      [report('a', 3, kills), report('b', 3, kills), report('intruder', 200, { '0': 9999 })],
      ['a', 'b'],
      LONG_ENOUGH,
    );
    expect(vote.status).toBe('accepted');
    expect(vote.dissenters).toEqual([]);
  });

  it('voids a match shorter than the floor even when everyone agrees', () => {
    const kills = { '0': 41, '1': 33 };
    const vote = crossValidateReports(
      [report('a', 7, kills), report('b', 7, kills)],
      ['a', 'b'],
      1_000,
    );
    expect(vote.status).toBe('too_short');
  });

  it('caps kills against the wave count after the vote, not before', () => {
    const overCap = { '0': maxKillsForWave(3) + 1 };
    const vote = crossValidateReports(
      [report('a', 3, overCap), report('b', 3, overCap)],
      ['a', 'b'],
      LONG_ENOUGH,
    );
    expect(vote.status).toBe('out_of_range');
  });

  it('rejects a wave count outside 1..MAX_TEAM_WAVE', () => {
    const kills = { '0': 1 };
    expect(
      crossValidateReports([report('a', 0, kills), report('b', 0, kills)], ['a', 'b'], LONG_ENOUGH)
        .status,
    ).toBe('out_of_range');
    expect(
      crossValidateReports(
        [report('a', 10_000, kills), report('b', 10_000, kills)],
        ['a', 'b'],
        LONG_ENOUGH,
      ).status,
    ).toBe('out_of_range');
  });

  it('treats reports with the same numbers in a different key order as identical', () => {
    const vote = crossValidateReports(
      [report('a', 4, { '0': 1, '1': 2 }), report('b', 4, { '1': 2, '0': 1 })],
      ['a', 'b'],
      LONG_ENOUGH,
    );
    expect(vote.status).toBe('accepted');
    expect(vote.dissenters).toEqual([]);
  });
});
