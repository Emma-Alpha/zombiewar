import assert from "node:assert/strict";
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(TEST_DIR, "../..");
const NO_CACHE = "no-store, no-cache, must-revalidate, max-age=0";
const DEPLOYMENT_URL = "https://abc123.zombiewar.pages.dev";
const PRODUCTION_URL = "https://zombiewar.pages.dev";
const FAKE_WASM = "fake wasm contents\n";

function parseJsonc(source) {
	return JSON.parse(
		source
			.replace(/\/\*[\s\S]*?\*\//g, "")
			.replace(/^\s*\/\/.*$/gm, "")
			.replace(/,\s*([}\]])/g, "$1"),
	);
}

function parseHeaders(source) {
	const rules = new Map();
	let currentPath = null;
	for (const line of source.split(/\r?\n/)) {
		if (line.trim() === "") continue;
		if (!/^\s/.test(line)) {
			currentPath = line.trim();
			rules.set(currentPath, new Map());
			continue;
		}
		assert.notEqual(currentPath, null, `Header without path: ${line}`);
		const separator = line.indexOf(":");
		assert.notEqual(separator, -1, `Malformed header: ${line}`);
		rules.get(currentPath).set(
			line.slice(0, separator).trim().toLowerCase(),
			line.slice(separator + 1).trim(),
		);
	}
	return rules;
}

async function createFixture(t, configure = (config) => config) {
	const fixtureRoot = await mkdtemp(path.join(tmpdir(), "zombiewar-cloudflare-test-"));
	t.after(() => rm(fixtureRoot, { recursive: true, force: true }));
	const repoRoot = path.join(fixtureRoot, "repo");
	const cloudflareDir = path.join(repoRoot, "tools", "cloudflare");
	const fakeBin = path.join(fixtureRoot, "fake-bin");
	await mkdir(cloudflareDir, { recursive: true });
	await mkdir(fakeBin, { recursive: true });

	for (const fileName of [
		"deploy_r2_pages.sh",
		"pages_worker.template.js",
		"_routes.json",
		"_headers",
	]) {
		await copyFile(
			path.join(REPO_ROOT, "tools", "cloudflare", fileName),
			path.join(cloudflareDir, fileName),
		);
	}
	await chmod(path.join(cloudflareDir, "deploy_r2_pages.sh"), 0o755);

	const config = parseJsonc(await readFile(path.join(REPO_ROOT, "wrangler.jsonc"), "utf8"));
	await writeFile(
		path.join(repoRoot, "wrangler.jsonc"),
		`${JSON.stringify(configure(config), null, 2)}\n`,
	);

	const remoteLog = path.join(fixtureRoot, "remote.log");
	const curlState = path.join(fixtureRoot, "curl-state");
	const fakeGodot = path.join(fakeBin, "fake-godot");
	await writeFile(fakeGodot, `#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
const output = process.argv.at(-1);
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, "<html>fake export</html>\\n");
fs.writeFileSync(path.join(path.dirname(output), "index.wasm"), ${JSON.stringify(FAKE_WASM)});
fs.writeFileSync(path.join(path.dirname(output), "index.pck"), "fake pck\\n");
`);
	await chmod(fakeGodot, 0o755);

	const fakeNpx = path.join(fakeBin, "npx");
	await writeFile(fakeNpx, `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_REMOTE_LOG, "npx " + args.join(" ") + "\\n");
if (args.includes("put") && process.env.FAKE_R2_PUT_FAIL === "1") process.exit(41);
if (args.includes("deploy")) {
	console.log(process.env.FAKE_DEPLOY_OUTPUT ?? "✨ Deployment complete! Take a peek over at " + process.env.FAKE_DEPLOYMENT_URL);
}
`);
	await chmod(fakeNpx, 0o755);

	const fakeCurl = path.join(fakeBin, "curl");
	await writeFile(fakeCurl, `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
const url = args.at(-1);
const isHead = args.includes("--head");
const isWasm = new URL(url).pathname.endsWith("/index.wasm");
const method = isHead ? "HEAD" : "GET";
fs.appendFileSync(process.env.FAKE_REMOTE_LOG, "curl " + method + " " + url + "\\n");
const count = fs.existsSync(process.env.FAKE_CURL_STATE)
	? Number(fs.readFileSync(process.env.FAKE_CURL_STATE, "utf8"))
	: 0;
fs.writeFileSync(process.env.FAKE_CURL_STATE, String(count + 1));
const headers = [
	"HTTP/2 200",
	"Content-Type: " + (isWasm ? "application/wasm" : "text/html; charset=utf-8"),
	"Cache-Control: ${NO_CACHE}",
	"Cross-Origin-Opener-Policy: same-origin",
	"Cross-Origin-Embedder-Policy: require-corp",
	"",
	"",
].join("\\r\\n");
if (isHead) {
	process.stdout.write(headers);
	process.exit(0);
}
const headerIndex = args.indexOf("--dump-header");
const outputIndex = args.indexOf("--output");
fs.writeFileSync(args[headerIndex + 1], headers);
fs.writeFileSync(
	args[outputIndex + 1],
	process.env.FAKE_WASM_HASH_MISMATCH === "1" ? "wrong wasm\\n" : ${JSON.stringify(FAKE_WASM)},
);
`);
	await chmod(fakeCurl, 0o755);

	return {
		repoRoot,
		scriptPath: path.join(cloudflareDir, "deploy_r2_pages.sh"),
		fakeBin,
		fakeGodot,
		remoteLog,
		curlState,
	};
}

function runDeploy(fixture, env = {}) {
	return spawnSync("bash", [fixture.scriptPath], {
		cwd: fixture.repoRoot,
		encoding: "utf8",
		env: {
			...process.env,
			PATH: `${fixture.fakeBin}:${process.env.PATH}`,
			GODOT_BIN: fixture.fakeGodot,
			CLOUDFLARE_PAGES_PROJECT: "zombiewar",
			CLOUDFLARE_BRANCH: "main",
			DEPLOY_VERIFY_RETRY_DELAY_SECONDS: "0",
			FAKE_DEPLOYMENT_URL: DEPLOYMENT_URL,
			FAKE_REMOTE_LOG: fixture.remoteLog,
			FAKE_CURL_STATE: fixture.curlState,
			...env,
		},
	});
}

async function readRemoteLog(fixture) {
	try {
		return await readFile(fixture.remoteLog, "utf8");
	} catch (error) {
		if (error.code === "ENOENT") return "";
		throw error;
	}
}

test("Cloudflare config, routes, and headers preserve the deployment contract", async () => {
	const config = parseJsonc(await readFile(path.join(REPO_ROOT, "wrangler.jsonc"), "utf8"));
	assert.equal(config.pages_build_output_dir, "./build/cloudflare-pages");
	const bindings = config.r2_buckets.filter(({ binding }) => binding === "GAME_ASSETS");
	assert.equal(bindings.length, 1);
	assert.equal(bindings[0].bucket_name, "zombiewar-assets");

	const routes = JSON.parse(
		await readFile(path.join(REPO_ROOT, "tools", "cloudflare", "_routes.json"), "utf8"),
	);
	assert.deepEqual(routes, { version: 1, include: ["/index.wasm"], exclude: [] });

	const headers = parseHeaders(
		await readFile(path.join(REPO_ROOT, "tools", "cloudflare", "_headers"), "utf8"),
	);
	assert.equal(headers.get("/*").get("cross-origin-opener-policy"), "same-origin");
	assert.equal(headers.get("/*").get("cross-origin-embedder-policy"), "require-corp");
	assert.equal(headers.get("/").get("cache-control"), NO_CACHE);
	assert.equal(headers.get("/index.html").get("cache-control"), NO_CACHE);
});

test("deploy uses the configured bucket, uploads before Pages, verifies the deployment URL, and rebuilds exports", async (t) => {
	const fixture = await createFixture(t, (config) => {
		config.r2_buckets[0].bucket_name = "configured-test-assets";
		return config;
	});
	await mkdir(path.join(fixture.repoRoot, "build", "web"), { recursive: true });
	await mkdir(path.join(fixture.repoRoot, "build", "cloudflare-pages"), { recursive: true });
	await writeFile(path.join(fixture.repoRoot, "build", "web", "stale-small.txt"), "stale\n");
	await writeFile(path.join(fixture.repoRoot, "build", "cloudflare-pages", "stale-small.txt"), "stale\n");

	const result = runDeploy(fixture);
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const log = await readRemoteLog(fixture);
	const uploadIndex = log.indexOf("r2 object put configured-test-assets/wasm/index-");
	const deployIndex = log.indexOf("pages deploy");
	assert.notEqual(uploadIndex, -1, log);
	assert.notEqual(deployIndex, -1, log);
	assert.ok(uploadIndex < deployIndex, log);
	assert.match(log, new RegExp(`curl HEAD ${DEPLOYMENT_URL}/\\n`));
	assert.match(log, new RegExp(`curl GET ${DEPLOYMENT_URL}/index\\.wasm\\n`));
	assert.match(log, new RegExp(`curl HEAD ${PRODUCTION_URL}/\\n`));
	await assert.rejects(readFile(path.join(fixture.repoRoot, "build", "web", "stale-small.txt")));
	await assert.rejects(readFile(path.join(fixture.repoRoot, "build", "cloudflare-pages", "stale-small.txt")));
});

test("an R2 upload failure prevents Pages deployment", async (t) => {
	const fixture = await createFixture(t);
	const result = runDeploy(fixture, { FAKE_R2_PUT_FAIL: "1" });
	assert.notEqual(result.status, 0, result.stdout);
	const log = await readRemoteLog(fixture);
	assert.match(log, /r2 object put/);
	assert.doesNotMatch(log, /pages deploy/);
	assert.doesNotMatch(log, /curl /);
});

test("preview deployment verifies only its deployment-specific URL", async (t) => {
	const fixture = await createFixture(t);
	const result = runDeploy(fixture, { CLOUDFLARE_BRANCH: "feature-preview" });
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const log = await readRemoteLog(fixture);
	assert.match(log, new RegExp(`curl HEAD ${DEPLOYMENT_URL}/\\n`));
	assert.match(log, new RegExp(`curl GET ${DEPLOYMENT_URL}/index\\.wasm\\n`));
	assert.doesNotMatch(log, new RegExp(PRODUCTION_URL.replaceAll(".", "\\.")));
});

test("deploy extracts only the deployment-complete URL amid unrelated Pages URLs", async (t) => {
	const fixture = await createFixture(t);
	const result = runDeploy(fixture, {
		CLOUDFLARE_BRANCH: "feature-preview",
		FAKE_DEPLOY_OUTPUT: [
			"See https://unrelated.other-project.pages.dev for another project.",
			"Preview alias: https://feature-preview.zombiewar.pages.dev",
			"Production alias: https://zombiewar.pages.dev",
			`✨ Deployment complete! Take a peek over at ${DEPLOYMENT_URL}`,
		].join("\n"),
	});
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const log = await readRemoteLog(fixture);
	assert.match(log, new RegExp(`curl HEAD ${DEPLOYMENT_URL}/\\n`));
	assert.doesNotMatch(log, /curl .+unrelated\.other-project\.pages\.dev/);
	assert.doesNotMatch(log, /curl .+feature-preview\.zombiewar\.pages\.dev/);
	assert.doesNotMatch(log, /curl .+https:\/\/zombiewar\.pages\.dev(?:\/|$)/);
});

for (const [name, deployOutput] of [
	[
		"invalid project URL",
		"✨ Deployment complete! Take a peek over at https://unrelated.other-project.pages.dev",
	],
	[
		"preview alias URL",
		"✨ Deployment complete! Take a peek over at https://feature-preview.zombiewar.pages.dev",
	],
	[
		"production alias URL",
		"✨ Deployment complete! Take a peek over at https://zombiewar.pages.dev",
	],
	[
		"missing deployment-complete result",
		`Uploaded successfully: ${DEPLOYMENT_URL}`,
	],
	[
		"ambiguous result URLs",
		[
			`✨ Deployment complete! Take a peek over at ${DEPLOYMENT_URL}`,
			"✨ Deployment complete! Take a peek over at https://def456.zombiewar.pages.dev",
		].join("\n"),
	],
]) {
	test(`${name} in a deployment result fails before verification`, async (t) => {
		const fixture = await createFixture(t);
		const result = runDeploy(fixture, {
			CLOUDFLARE_BRANCH: "feature-preview",
			FAKE_DEPLOY_OUTPUT: deployOutput,
		});
		assert.notEqual(result.status, 0, result.stdout);
		assert.doesNotMatch(await readRemoteLog(fixture), /curl /);
	});
}

for (const [name, configure] of [
	["missing", (config) => ({ ...config, r2_buckets: [] })],
	["duplicate", (config) => ({ ...config, r2_buckets: [config.r2_buckets[0], { ...config.r2_buckets[0] }] })],
	["empty", (config) => {
		config.r2_buckets[0].bucket_name = "";
		return config;
	}],
]) {
	test(`${name} GAME_ASSETS bucket configuration fails before remote operations`, async (t) => {
		const fixture = await createFixture(t, configure);
		const result = runDeploy(fixture);
		assert.notEqual(result.status, 0, result.stdout);
		assert.equal(await readRemoteLog(fixture), "");
	});
}

test("a downloaded WASM hash mismatch fails after finite verification retries", async (t) => {
	const fixture = await createFixture(t);
	const result = runDeploy(fixture, { FAKE_WASM_HASH_MISMATCH: "1" });
	assert.notEqual(result.status, 0, result.stdout);
	const log = await readRemoteLog(fixture);
	const wasmDownloads = log
		.split("\n")
		.filter((line) => line === `curl GET ${DEPLOYMENT_URL}/index.wasm`);
	assert.equal(wasmDownloads.length, 5, log);
	assert.doesNotMatch(log, new RegExp(PRODUCTION_URL.replaceAll(".", "\\.")));
});
