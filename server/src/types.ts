export interface Env {
  DB: D1Database;
  ROOMS: DurableObjectNamespace;
  ZW_CORS_ORIGIN: string;
  ZW_MAX_LEADERBOARD_LIMIT: string;
  ZW_SESSION_TTL_SECONDS: string;
}

/**
 * The two boards this round ships. Anything else is rejected at the route,
 * because an unbounded `board` column is an unbounded table scan waiting to
 * happen and a typo that silently creates a third leaderboard.
 */
export type BoardId = 'team_waves' | 'player_kills';

export const BOARD_IDS: readonly BoardId[] = ['team_waves', 'player_kills'];

export function isBoardId(value: string): value is BoardId {
  return (BOARD_IDS as readonly string[]).includes(value);
}

/** Season is reserved in the schema but frozen at 0 for this round. */
export const CURRENT_SEASON = 0;

/** Hard ceiling on room occupancy. Mirrors SimWorld.MAX_PLAYER_SLOTS. */
export const MAX_PLAYERS_PER_ROOM = 4;

/** One rendered leaderboard row. `rank` is 1-based and includes the offset. */
export interface LeaderboardEntry {
  rank: number;
  player_id: string;
  nickname: string;
  value: number;
  created_at: number;
}

export interface PlayerSession {
  token: string;
  playerId: string;
  nickname: string;
}
