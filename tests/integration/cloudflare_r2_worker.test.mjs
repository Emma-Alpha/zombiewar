import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const CACHE_CONTROL = "no-store, no-cache, must-revalidate, max-age=0";

const template = await readFile(
	new URL("../../tools/cloudflare/pages_worker.template.js", import.meta.url),
	"utf8",
);
const source = template.replaceAll("__WASM_OBJECT_KEY__", "wasm/index-test.wasm");
const moduleUrl = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`;
const worker = (await import(moduleUrl)).default;

function createObject() {
	return {
		body: new Response(new Uint8Array([0, 97, 115, 109])).body,
		httpEtag: '"test-etag"',
		writeHttpMetadata(headers) {
			headers.set("Content-Type", "application/octet-stream");
		},
	};
}

function createEnv({ missing = false, failure = false } = {}) {
	return {
		GAME_ASSETS: {
			async get(key) {
				assert.equal(key, "wasm/index-test.wasm");
				if (failure) throw new Error("r2 unavailable");
				return missing ? null : createObject();
			},
			async head(key) {
				assert.equal(key, "wasm/index-test.wasm");
				if (failure) throw new Error("r2 unavailable");
				return missing ? null : createObject();
			},
		},
		ASSETS: {
			async fetch() {
				return new Response("static asset", { status: 200 });
			},
		},
	};
}

test("GET /index.wasm streams the versioned R2 object", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm"),
		createEnv(),
	);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get("content-type"), "application/wasm");
	assert.equal(response.headers.get("cache-control"), CACHE_CONTROL);
	assert.equal(response.headers.get("cross-origin-opener-policy"), "same-origin");
	assert.equal(response.headers.get("cross-origin-embedder-policy"), "require-corp");
	assert.equal(response.headers.get("etag"), '"test-etag"');
	assert.deepEqual(new Uint8Array(await response.arrayBuffer()), new Uint8Array([0, 97, 115, 109]));
});

test("HEAD /index.wasm returns metadata without a body", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm", { method: "HEAD" }),
		createEnv(),
	);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get("content-type"), "application/wasm");
	assert.equal(response.headers.get("cache-control"), CACHE_CONTROL);
	assert.equal(response.headers.get("cross-origin-opener-policy"), "same-origin");
	assert.equal(response.headers.get("cross-origin-embedder-policy"), "require-corp");
	assert.equal(response.headers.get("etag"), '"test-etag"');
	assert.equal(await response.text(), "");
});

test("unsupported /index.wasm methods return 405", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm", { method: "POST" }),
		createEnv(),
	);
	assert.equal(response.status, 405);
	assert.equal(response.headers.get("allow"), "GET, HEAD");
});

test("missing R2 objects return 503", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.wasm"),
		createEnv({ missing: true }),
	);
	assert.equal(response.status, 503);
});

test("R2 failures return 502", async () => {
	const originalConsoleError = console.error;
	console.error = () => {};
	try {
		const response = await worker.fetch(
			new Request("https://zombiewar.pages.dev/index.wasm"),
			createEnv({ failure: true }),
		);
		assert.equal(response.status, 502);
	} finally {
		console.error = originalConsoleError;
	}
});

test("other paths fall back to Pages static assets", async () => {
	const response = await worker.fetch(
		new Request("https://zombiewar.pages.dev/index.html"),
		createEnv(),
	);
	assert.equal(await response.text(), "static asset");
});
