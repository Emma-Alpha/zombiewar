import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const workflowPath = new URL(
	"../../.github/workflows/deploy-cloudflare.yml",
	import.meta.url,
);

async function readWorkflow() {
	return readFile(workflowPath, "utf8");
}

test("Cloudflare deployment runs only for published GitHub Releases", async () => {
	const workflow = await readWorkflow();
	assert.match(workflow, /^on:\s*\n\s*release:\s*\n\s*types:\s*\[published\]\s*$/m);
	assert.doesNotMatch(workflow, /^\s*(push|pull_request|schedule):/m);
});

test("Cloudflare deployment checks out the published Release tag", async () => {
	const workflow = await readWorkflow();
	assert.match(workflow, /ref:\s*\$\{\{\s*github\.event\.release\.tag_name\s*\}\}/);
});

test("Cloudflare deployment tests before publishing and uses only Secrets", async () => {
	const workflow = await readWorkflow();
	const testIndex = workflow.indexOf("./tests/run_tests.sh");
	const deployIndex = workflow.indexOf("bash tools/cloudflare/deploy_r2_pages.sh");
	assert.ok(testIndex >= 0, "workflow must run the full Godot suite");
	assert.ok(deployIndex > testIndex, "workflow must deploy only after tests");
	assert.match(workflow, /CLOUDFLARE_API_TOKEN:\s*\$\{\{\s*secrets\.CLOUDFLARE_API_TOKEN\s*\}\}/);
	assert.match(workflow, /CLOUDFLARE_ACCOUNT_ID:\s*\$\{\{\s*secrets\.CLOUDFLARE_ACCOUNT_ID\s*\}\}/);
	assert.match(workflow, /CLOUDFLARE_BRANCH:\s*main/);
});

test("Cloudflare deployment uses least privilege and serial production releases", async () => {
	const workflow = await readWorkflow();
	assert.match(workflow, /permissions:\s*\n\s*contents:\s*read/);
	assert.match(workflow, /concurrency:\s*\n\s*group:\s*cloudflare-production-deploy\s*\n\s*cancel-in-progress:\s*false/);
});
