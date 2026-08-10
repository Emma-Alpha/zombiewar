import { HTTPException } from 'hono/http-exception';

/**
 * Every error the client sees has a machine-readable `code` beside the human
 * `message`. The Godot side branches on `code` and only ever displays
 * `message`, so wording can change without breaking a client.
 */
export function apiError(status: number, code: string, message: string): HTTPException {
  return new HTTPException(status as 400, {
    res: Response.json({ error: code, message }, { status }),
  });
}

export function badRequest(code: string, message: string): HTTPException {
  return apiError(400, code, message);
}

export function unauthorized(code: string, message: string): HTTPException {
  return apiError(401, code, message);
}

export function notFound(code: string, message: string): HTTPException {
  return apiError(404, code, message);
}

export function conflict(code: string, message: string): HTTPException {
  return apiError(409, code, message);
}

/**
 * Extracts a bearer token from `Authorization: Bearer <token>`, falling back to
 * `X-Player-Token` for clients that cannot set Authorization. Godot's
 * HTTPRequest can set either; the fallback exists because a browser preflight
 * on Authorization is one more thing to get wrong on a cross-origin Worker.
 */
export function extractBearerToken(headers: Headers): string | undefined {
  const auth = headers.get('authorization');
  if (auth !== null) {
    const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
    if (match !== null) {
      const token = match[1]!.trim();
      if (token !== '') return token;
    }
  }
  const alt = headers.get('x-player-token');
  if (alt !== null && alt.trim() !== '') return alt.trim();
  return undefined;
}

/** Clamps `?limit=` / `?offset=` without ever throwing on garbage input. */
export function readPaging(
  url: URL,
  maxLimit: number,
): { limit: number; offset: number } {
  const rawLimit = Number.parseInt(url.searchParams.get('limit') ?? '', 10);
  const rawOffset = Number.parseInt(url.searchParams.get('offset') ?? '', 10);
  const limit = Number.isFinite(rawLimit) ? Math.min(Math.max(rawLimit, 1), maxLimit) : 20;
  const offset = Number.isFinite(rawOffset) ? Math.max(rawOffset, 0) : 0;
  return { limit, offset };
}
