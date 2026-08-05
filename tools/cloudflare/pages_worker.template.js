const WASM_OBJECT_KEY = "__WASM_OBJECT_KEY__";
const CACHE_CONTROL = "no-store, no-cache, must-revalidate, max-age=0";

function buildHeaders(object) {
	const headers = new Headers();
	if (typeof object.writeHttpMetadata === "function") {
		object.writeHttpMetadata(headers);
	}
	headers.set("Content-Type", "application/wasm");
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
			"Cache-Control": CACHE_CONTROL,
		},
	});
}

async function serveWasm(request, env) {
	try {
		const object = request.method === "HEAD"
			? await env.GAME_ASSETS.head(WASM_OBJECT_KEY)
			: await env.GAME_ASSETS.get(WASM_OBJECT_KEY);
		if (object === null) {
			return errorResponse(503, `WASM object is unavailable: ${WASM_OBJECT_KEY}`);
		}
		return new Response(request.method === "HEAD" ? null : object.body, {
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
