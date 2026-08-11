const WASM_OBJECT_KEY = "__WASM_OBJECT_KEY__";
// The key embeds the SHA-256 of the wasm bytes, so any byte change produces a
// brand-new URL space. That makes the object safe to cache forever: there is no
// stale-cache risk because a new deploy always serves a different key.
const CACHE_CONTROL = "public, max-age=31536000, immutable";
const ERROR_CACHE_CONTROL = "no-store, no-cache, must-revalidate, max-age=0";

function acceptsBrotli(request) {
	const header = request.headers.get("Accept-Encoding");
	if (header === null) return false;
	return header.split(",").some((token) => token.trim().toLowerCase().startsWith("br"));
}

function buildHeaders(object, { brotli }) {
	const headers = new Headers();
	if (typeof object.writeHttpMetadata === "function") {
		object.writeHttpMetadata(headers);
	}
	// Always the decompressed type: when we send the Brotli object we set
	// Content-Encoding so the browser decodes it back to application/wasm.
	headers.set("Content-Type", "application/wasm");
	if (brotli) headers.set("Content-Encoding", "br");
	headers.set("Cache-Control", CACHE_CONTROL);
	headers.set("Cross-Origin-Opener-Policy", "same-origin");
	headers.set("Cross-Origin-Embedder-Policy", "require-corp");
	// The response now varies on Accept-Encoding; tell caches so a br body is
	// never served to a client that only asked for identity.
	headers.set("Vary", "Accept-Encoding");
	if (object.httpEtag) headers.set("ETag", object.httpEtag);
	return headers;
}

function errorResponse(status, message) {
	return new Response(message, {
		status,
		headers: {
			"Content-Type": "text/plain; charset=utf-8",
			"Cache-Control": ERROR_CACHE_CONTROL,
		},
	});
}

async function readObject(request, env, key) {
	return request.method === "HEAD"
		? await env.GAME_ASSETS.head(key)
		: await env.GAME_ASSETS.get(key);
}

async function serveWasm(request, env) {
	const isHead = request.method === "HEAD";
	// Prefer the pre-compressed object when the client takes Brotli. The `.br`
	// sibling is uploaded alongside the raw wasm by deploy_r2_pages.sh; if it is
	// missing (older deploy) we fall back to the raw object so nothing breaks.
	if (acceptsBrotli(request)) {
		try {
			const brotliObject = await readObject(request, env, `${WASM_OBJECT_KEY}.br`);
			if (brotliObject !== null) {
				return new Response(isHead ? null : brotliObject.body, {
					status: 200,
					headers: buildHeaders(brotliObject, { brotli: true }),
				});
			}
		} catch (error) {
			console.error("Unable to read Brotli WASM from R2; falling back to raw", error);
		}
	}
	try {
		const object = await readObject(request, env, WASM_OBJECT_KEY);
		if (object === null) {
			return errorResponse(503, `WASM object is unavailable: ${WASM_OBJECT_KEY}`);
		}
		return new Response(isHead ? null : object.body, {
			status: 200,
			headers: buildHeaders(object, { brotli: false }),
		});
	} catch (error) {
		console.error("Unable to read WASM from R2", error);
		return errorResponse(502, "Unable to read WASM from R2");
	}
}

export default {
	async fetch(request, env) {
		const url = new URL(request.url);
		if (url.pathname === "/index.wasm") {
			if (request.method !== "GET" && request.method !== "HEAD") {
				return new Response("Method Not Allowed", {
					status: 405,
					headers: { Allow: "GET, HEAD" },
				});
			}
			return serveWasm(request, env);
		}
		return env.ASSETS.fetch(request);
	},
};
