import { badRequest } from './http.js';
import type { PlayerSession } from '../types.js';

/**
 * ============================================================================
 *  THIS IS NOT AUTHENTICATION. READ BEFORE TRUSTING ANYTHING IN HERE.
 * ============================================================================
 *
 * `POST /api/auth/anon` exchanges a *client-generated device id* for a token.
 * There is no password, no registration, no verification. Anyone can send any
 * device id, including someone else's. A token proves exactly one thing: that
 * its holder called /api/auth/anon at some point.
 *
 * So why does it exist at all?
 *
 *   Because the *shape* of the interface is more expensive to change than its
 *   implementation. Every downstream endpoint, the client's request pipeline
 *   and the room handshake all have to agree on "where does identity live in a
 *   request". Deciding that now -- `Authorization: Bearer <token>` -- costs one
 *   file. Retrofitting it later costs every endpoint and call site.
 *
 * When platform accounts arrive, the change is confined to this file plus the
 * body validation in routes/auth.ts. The header, the response shape and every
 * downstream endpoint stay byte-for-byte identical.
 *
 * The `authenticated: false` / `auth_mode` fields in the response are the
 * contract by which the Godot client learns this. The leaderboard panel keys
 * its 「未认证」 badge off `authenticated`, NOT off "I got a token back".
 */
export const AUTH_MODE = 'anonymous_device' as const;

export const NICKNAME_MIN_LENGTH = 2;
export const NICKNAME_MAX_LENGTH = 12;

/**
 * Substring blocklist, matched case-folded. Deliberately short: this is a
 * courtesy filter over a 12-character field, not moderation. Duplicates are
 * allowed -- players are distinguished by player_id, never by nickname.
 */
export const NICKNAME_BLOCKLIST: readonly string[] = [
  'admin',
  'administrator',
  'root',
  'system',
  'moderator',
  'official',
  'null',
  'undefined',
  'fuck',
  'shit',
  '管理员',
  '客服',
  '官方',
];

/**
 * 2-12 characters, counted as code points rather than UTF-16 units, so
 * 「僵尸猎人」 is 4 characters and not 8. The Godot side counts the same way
 * (`String.length()` is code points), which is why both ends agree.
 */
export function normalizeNickname(raw: unknown): string {
  if (typeof raw !== 'string') {
    throw badRequest('invalid_body', 'nickname is required and must be a string');
  }
  const nickname = raw.trim();
  const length = [...nickname].length;
  if (length < NICKNAME_MIN_LENGTH || length > NICKNAME_MAX_LENGTH) {
    throw badRequest(
      'invalid_nickname',
      `nickname must be ${NICKNAME_MIN_LENGTH}-${NICKNAME_MAX_LENGTH} characters, got ${length}`,
    );
  }
  // Control characters would corrupt logs and any UI that renders the roster.
  if (/[\u0000-\u001f\u007f]/.test(nickname)) {
    throw badRequest('invalid_nickname', 'nickname must not contain control characters');
  }
  const folded = nickname.toLowerCase();
  if (NICKNAME_BLOCKLIST.some((word) => folded.includes(word))) {
    throw badRequest('nickname_blocked', 'nickname contains a blocked word');
  }
  return nickname;
}

/**
 * The client generates a UUIDv4 on first run and stores it in
 * `user://identity.cfg`. We only shape-check it: it is a stable handle, not a
 * credential, and pretending otherwise would be the lie this file exists to
 * avoid.
 */
export function normalizeDeviceId(raw: unknown): string {
  if (typeof raw !== 'string') {
    throw badRequest('invalid_body', 'device_id is required and must be a string');
  }
  const deviceId = raw.trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(deviceId)) {
    throw badRequest('invalid_device_id', 'device_id must be a lowercase UUID (36 characters)');
  }
  return deviceId;
}

function mintToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  // base64url by hand: btoa is the only encoder in the Workers runtime and it
  // emits standard base64, whose `+` and `/` are not URL/header safe.
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/**
 * Upserts the player row and mints a fresh token.
 *
 * Same device_id -> same player_id, forever: that is the whole point of
 * persisting `players`, and it is what makes a leaderboard entry survive the
 * app being closed. The token, by contrast, is per-call and expires; it lives
 * in D1 rather than memory only because Workers isolates share nothing.
 */
export async function authenticateDevice(
  db: D1Database,
  deviceId: string,
  nickname: string,
  ttlSeconds: number,
  now: number = Date.now(),
): Promise<PlayerSession> {
  const existing = await db
    .prepare('SELECT player_id FROM players WHERE device_id = ?')
    .bind(deviceId)
    .first<{ player_id: string }>();
  const playerId = existing === null ? crypto.randomUUID() : existing.player_id;

  const token = mintToken();
  const statements: D1PreparedStatement[] = [];
  if (existing === null) {
    statements.push(
      db
        .prepare(
          'INSERT INTO players (player_id, device_id, nickname, created_at, last_seen) ' +
            'VALUES (?, ?, ?, ?, ?)',
        )
        .bind(playerId, deviceId, nickname, now, now),
    );
  } else {
    statements.push(
      db
        .prepare('UPDATE players SET nickname = ?, last_seen = ? WHERE player_id = ?')
        .bind(nickname, now, playerId),
    );
  }
  statements.push(
    db
      .prepare(
        'INSERT INTO sessions (token, player_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
      )
      .bind(token, playerId, now, now + ttlSeconds * 1000),
  );
  // Opportunistic sweep. There is no cron on the free plan and an unbounded
  // `sessions` table is the one thing here that grows without a ceiling.
  statements.push(db.prepare('DELETE FROM sessions WHERE expires_at < ?').bind(now));
  await db.batch(statements);

  return { token, playerId, nickname };
}

/** Resolves a bearer token. Returns null for unknown, absent or expired tokens. */
export async function resolveSession(
  db: D1Database,
  token: string | undefined,
  now: number = Date.now(),
): Promise<PlayerSession | null> {
  if (token === undefined || token === '') return null;
  const row = await db
    .prepare(
      `SELECT s.token AS token, s.player_id AS player_id, COALESCE(p.nickname, '') AS nickname
         FROM sessions s
         LEFT JOIN players p ON p.player_id = s.player_id
        WHERE s.token = ? AND s.expires_at > ?`,
    )
    .bind(token, now)
    .first<{ token: string; player_id: string; nickname: string }>();
  if (row === null) return null;
  return { token: row.token, playerId: row.player_id, nickname: row.nickname };
}
