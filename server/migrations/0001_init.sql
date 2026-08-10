-- zombiewar D1 schema.
--
-- Ported from the Node/better-sqlite3 server. Two differences forced by D1:
--   1. `sessions` is a table rather than an in-memory Map. Workers isolates do
--      not share memory, so a token minted by one request must be resolvable by
--      any other isolate.
--   2. `rooms` is a table rather than a Map in the room server process. It is
--      the public room directory only -- the authoritative room state lives in
--      the Durable Object. Rows here are a denormalised index, and a stale row
--      is harmless because `GET /api/rooms` filters on `updated_at`.

CREATE TABLE IF NOT EXISTS players (
  player_id  TEXT PRIMARY KEY,
  device_id  TEXT UNIQUE NOT NULL,
  nickname   TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  token      TEXT PRIMARY KEY,
  player_id  TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON sessions(expires_at);

CREATE TABLE IF NOT EXISTS scores (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  board      TEXT NOT NULL,
  season     INTEGER NOT NULL,
  player_id  TEXT NOT NULL,
  room_id    TEXT NOT NULL,
  value      INTEGER NOT NULL,
  extra      TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_scores_rank ON scores(board, season, value DESC);
CREATE INDEX IF NOT EXISTS idx_scores_player ON scores(board, season, player_id);
CREATE INDEX IF NOT EXISTS idx_scores_room ON scores(board, season, room_id);

CREATE TABLE IF NOT EXISTS rooms (
  code          TEXT PRIMARY KEY,
  is_public     INTEGER NOT NULL DEFAULT 1,
  state         TEXT NOT NULL DEFAULT 'lobby',
  host_nickname TEXT NOT NULL DEFAULT '',
  player_count  INTEGER NOT NULL DEFAULT 0,
  max_players   INTEGER NOT NULL DEFAULT 4,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rooms_browse ON rooms(is_public, state, updated_at DESC);
