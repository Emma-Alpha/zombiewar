import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { HTTPException } from 'hono/http-exception';

import {
  countLeaderboard,
  readLeaderboard,
  readPlayerBest,
  readTeamLeaderboard,
} from './lib/leaderboard.js';
import { badRequest, extractBearerToken, notFound, readPaging, unauthorized } from './lib/http.js';
import { PROTOCOL_VERSION, TICK_HZ } from './lib/protocol.js';
import {
  allocateRoomCode,
  isRoomCode,
  normalizeRoomCode,
  RoomCodeExhaustedError,
} from './lib/room_code.js';
import {
  AUTH_MODE,
  authenticateDevice,
  normalizeDeviceId,
  normalizeNickname,
  resolveSession,
} from './lib/sessions.js';
import { CURRENT_SEASON, MAX_PLAYERS_PER_ROOM, isBoardId, type Env } from './types.js';

export { RoomDurableObject } from './room_do.js';

/**
 * Rooms whose directory row has not been touched in this long are treated as
 * gone. The Durable Object updates its row on every membership change, so a row
 * this stale means the object was evicted with nobody in it.
 */
const ROOM_DIRECTORY_TTL_MS = 120_000;

const app = new Hono<{ Bindings: Env }>();

app.use(
  '*',
  cors({
    origin: (origin: string, c): string => {
      const allowed: string = (c.env as Env).ZW_CORS_ORIGIN ?? '*';
      if (allowed === '*') return origin ?? '*';
      const list: string[] = allowed.split(',').map((entry: string) => entry.trim());
      return list.includes(origin) ? origin : (list[0] ?? '');
    },
    allowMethods: ['GET', 'POST', 'OPTIONS'],
    allowHeaders: ['Content-Type', 'Authorization', 'X-Player-Token'],
    maxAge: 86_400,
  }),
);

app.onError((error, c) => {
  if (error instanceof HTTPException) {
    const response = error.getResponse();
    if (response !== undefined) return response;
  }
  console.error(`unhandled error: ${String(error)}`);
  return c.json({ error: 'internal_error', message: 'unexpected server error' }, 500);
});

// ------------------------------------------------------------------ metadata

app.get('/api/health', (c) =>
  c.json({
    ok: true,
    protocol_version: PROTOCOL_VERSION,
    tick_hz: TICK_HZ,
    max_players: MAX_PLAYERS_PER_ROOM,
  }),
);

/**
 * The root is an API host with no site on it, so it would otherwise answer a
 * bare `404 Not Found`. That page cannot be told apart from a dead service by
 * anyone who opens the domain in a browser -- which is the first thing anyone
 * does when the game reports a connection problem. Say what this host is and
 * where the endpoints live instead.
 */
app.get('/', (c) =>
  c.json({
    service: 'zombiewar-server',
    ok: true,
    protocol_version: PROTOCOL_VERSION,
    message:
      'zombiewar 的联机后端。这里没有网页，只有 API。健康检查见 /api/health。',
    endpoints: {
      health: '/api/health',
      auth: 'POST /api/auth/anon',
      leaderboards: ['/api/leaderboard/team', '/api/leaderboard/kills'],
      rooms: ['POST /api/rooms', 'GET /api/rooms', 'GET /api/rooms/:code'],
      room_socket: 'GET /ws/rooms/:code (websocket upgrade)',
    },
  }),
);

app.notFound((c) =>
  c.json(
    {
      error: 'not_found',
      message: `没有这个端点：${new URL(c.req.url).pathname}。可用端点见 /`,
    },
    404,
  ),
);

// --------------------------------------------------------------------- auth

app.post('/api/auth/anon', async (c) => {
  const body = await readJson(c.req.raw);
  const deviceId = normalizeDeviceId(body['device_id']);
  const nickname = normalizeNickname(body['nickname']);
  const ttl = Number.parseInt(c.env.ZW_SESSION_TTL_SECONDS ?? '604800', 10) || 604_800;
  const session = await authenticateDevice(c.env.DB, deviceId, nickname, ttl);
  return c.json({
    // The client keys its 「未认证」 badge off this field, not off "I got a
    // token back". See the header of lib/sessions.ts.
    authenticated: false,
    auth_mode: AUTH_MODE,
    protocol_version: PROTOCOL_VERSION,
    token: session.token,
    player_id: session.playerId,
    nickname: session.nickname,
  });
});

// -------------------------------------------------------------- leaderboards

app.get('/api/leaderboard/team', async (c) => {
  const { limit, offset } = readPaging(new URL(c.req.url), maxLimit(c.env));
  const [entries, total] = await Promise.all([
    readTeamLeaderboard(c.env.DB, CURRENT_SEASON, limit, offset),
    countLeaderboard(c.env.DB, 'team_waves', CURRENT_SEASON),
  ]);
  return c.json({ board: 'team_waves', season: CURRENT_SEASON, limit, offset, total, entries });
});

app.get('/api/leaderboard/kills', async (c) => {
  const { limit, offset } = readPaging(new URL(c.req.url), maxLimit(c.env));
  const [entries, total] = await Promise.all([
    readLeaderboard(c.env.DB, 'player_kills', CURRENT_SEASON, limit, offset),
    countLeaderboard(c.env.DB, 'player_kills', CURRENT_SEASON),
  ]);
  return c.json({ board: 'player_kills', season: CURRENT_SEASON, limit, offset, total, entries });
});

app.get('/api/leaderboard/me', async (c) => {
  const board = c.req.query('board') ?? 'player_kills';
  if (!isBoardId(board)) throw badRequest('invalid_board', `unknown board ${board}`);
  const session = await resolveSession(c.env.DB, extractBearerToken(c.req.raw.headers));
  if (session === null) throw unauthorized('no_session', 'a player token is required');
  const entry = await readPlayerBest(c.env.DB, board, CURRENT_SEASON, session.playerId);
  return c.json({ board, season: CURRENT_SEASON, entry });
});

// --------------------------------------------------------------------- rooms

app.post('/api/rooms', async (c) => {
  const body = await readJson(c.req.raw).catch(() => ({}) as Record<string, unknown>);
  const isPublic = body['is_public'] !== false;
  let code: string;
  try {
    code = await allocateRoomCode(async (candidate) => {
      const row = await c.env.DB.prepare(
        'SELECT code FROM rooms WHERE code = ? AND updated_at > ?',
      )
        .bind(candidate, Date.now() - ROOM_DIRECTORY_TTL_MS)
        .first<{ code: string }>();
      return row !== null;
    });
  } catch (error: unknown) {
    if (error instanceof RoomCodeExhaustedError) {
      throw badRequest('code_exhausted', 'could not allocate a free room code, try again');
    }
    throw error;
  }

  const stub = c.env.ROOMS.get(c.env.ROOMS.idFromName(code));
  const response = await stub.fetch('https://room/init', {
    method: 'POST',
    body: JSON.stringify({ code, is_public: isPublic }),
  });
  if (!response.ok) throw badRequest('room_init_failed', 'could not create the room');

  const now = Date.now();
  await c.env.DB.prepare(
    `INSERT INTO rooms (code, is_public, state, host_nickname, player_count, max_players, created_at, updated_at)
     VALUES (?, ?, 'lobby', '', 0, ?, ?, ?)
     ON CONFLICT(code) DO UPDATE SET
       is_public = excluded.is_public, state = 'lobby', player_count = 0, updated_at = excluded.updated_at`,
  )
    .bind(code, isPublic ? 1 : 0, MAX_PLAYERS_PER_ROOM, now, now)
    .run();

  return c.json({ code, is_public: isPublic, max_players: MAX_PLAYERS_PER_ROOM });
});

app.get('/api/rooms', async (c) => {
  const { limit } = readPaging(new URL(c.req.url), 50);
  const result = await c.env.DB.prepare(
    `SELECT code, state, host_nickname, player_count, max_players
       FROM rooms
      WHERE is_public = 1 AND state = 'lobby' AND player_count > 0 AND player_count < max_players
        AND updated_at > ?
      ORDER BY updated_at DESC
      LIMIT ?`,
  )
    .bind(Date.now() - ROOM_DIRECTORY_TTL_MS, limit)
    .all();
  return c.json({ rooms: result.results });
});

app.get('/api/rooms/:code', async (c) => {
  const code = normalizeRoomCode(c.req.param('code'));
  if (!isRoomCode(code)) throw badRequest('invalid_code', 'room code must be 6 characters');
  const stub = c.env.ROOMS.get(c.env.ROOMS.idFromName(code));
  const response = await stub.fetch('https://room/info');
  const info = (await response.json()) as { exists: boolean };
  if (!info.exists) throw notFound('room_not_found', `no room with code ${code}`);
  return c.json(info);
});

/**
 * WebSocket entry. The Worker does no protocol work here on purpose: everything
 * about a room lives in its Durable Object, and routing the raw upgrade through
 * means there is exactly one place that can be wrong about a room's state.
 */
app.get('/ws/rooms/:code', async (c) => {
  const code = normalizeRoomCode(c.req.param('code'));
  if (!isRoomCode(code)) return c.text('invalid room code', 400);
  const stub = c.env.ROOMS.get(c.env.ROOMS.idFromName(code));
  return stub.fetch(new Request('https://room/ws', c.req.raw));
});

// ------------------------------------------------------------------- helpers

function maxLimit(env: Env): number {
  return Number.parseInt(env.ZW_MAX_LEADERBOARD_LIMIT ?? '100', 10) || 100;
}

async function readJson(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    if (typeof body !== 'object' || body === null) {
      throw badRequest('invalid_body', 'request body must be a JSON object');
    }
    return body as Record<string, unknown>;
  } catch (error: unknown) {
    if (error instanceof HTTPException) throw error;
    throw badRequest('invalid_body', 'request body must be valid JSON');
  }
}

export default app;
