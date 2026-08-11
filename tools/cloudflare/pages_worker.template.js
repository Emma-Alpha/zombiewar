const WASM_OBJECT_KEY = "__WASM_OBJECT_KEY__";
// The key embeds the SHA-256 of the wasm bytes, so any byte change produces a
// brand-new object. The response is safe to cache in the browser: a new deploy
// always serves a different key.
const CACHE_CONTROL = "public, max-age=31536000, immutable";
const ERROR_CACHE_CONTROL = "no-store, no-cache, must-revalidate, max-age=0";

function buildHeaders(object) {
	const headers = new Headers();
	if (typeof object.writeHttpMetadata === "function") {
		object.writeHttpMetadata(headers);
	}
	// application/octet-stream, NOT application/wasm. Cloudflare Pages' edge
	// compression (both Brotli and gzip) corrupts this large R2-backed binary
	// response, so we must keep the edge from treating it as compressible.
	// Marking the payload octet-stream makes the edge pass it through untouched.
	// The Godot/Emscripten loader fetches the bytes itself (arrayBuffer), so the
	// MIME type does not affect instantiation.
	headers.set("Content-Type", "application/octet-stream");
	headers.set("Cache-Control", CACHE_CONTROL);
	headers.set("Cross-Origin-Opener-Policy", "same-origin");
	headers.set("Cross-Origin-Embedder-Policy", "require-corp");
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

async function serveWasm(request, env) {
	const isHead = request.method === "HEAD";
	try {
		const object = isHead
			? await env.GAME_ASSETS.head(WASM_OBJECT_KEY)
			: await env.GAME_ASSETS.get(WASM_OBJECT_KEY);
		if (object === null) {
			return errorResponse(503, `WASM object is unavailable: ${WASM_OBJECT_KEY}`);
		}
		// Buffer the body instead of streaming object.body: the Pages edge mangles
		// large streamed binary responses. An ArrayBuffer passes through intact.
		const body = isHead ? null : await object.arrayBuffer();
		return new Response(body, {
			status: 200,
			headers: buildHeaders(object),
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
