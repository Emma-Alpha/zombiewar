// 本地实测用静态服务器：模拟 Cloudflare Pages 的关键响应头与 wasm 提供方式。
// - 全部响应带 COOP: same-origin / COEP: require-corp（crossOriginIsolated，
//   与线上 _headers 一致，是 Godot Web 能跑的前提）。
// - /index.wasm 给 application/octet-stream 且不压缩，绕开线上边缘压缩坑。
// - 根路径与 .pck no-store，避免浏览器缓存旧的 index.html/.pck。
// 用法: node tools/serve_web_local.js [port]   （服务 build/cloudflare-pages）
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..", "build", "cloudflare-pages");
const PORT = process.argv[2] ? Number(process.argv[2]) : (process.env.PORT ? Number(process.env.PORT) : 8787);

const MIME = {
	".html": "text/html; charset=utf-8",
	".js": "application/javascript; charset=utf-8",
	".wasm": "application/octet-stream",
	".pck": "application/octet-stream",
	".png": "image/png",
	".svg": "image/svg+xml",
	".json": "application/json; charset=utf-8",
	".ico": "image/x-icon",
};

const server = http.createServer((req, res) => {
	const url = new URL(req.url, "http://localhost");
	let pathname = decodeURIComponent(url.pathname);
	if (pathname === "/") pathname = "/index.html";
	const filePath = path.join(ROOT, path.normalize(pathname));
	if (!filePath.startsWith(ROOT)) {
		res.writeHead(403).end("Forbidden");
		return;
	}
	fs.readFile(filePath, (err, data) => {
		res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
		res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");
		if (err) {
			res.writeHead(404, { "Content-Type": "text/plain" }).end("Not Found");
			return;
		}
		const ext = path.extname(filePath).toLowerCase();
		res.setHeader("Content-Type", MIME[ext] || "application/octet-stream");
		if (ext === ".html" || ext === ".pck") {
			res.setHeader("Cache-Control", "no-store");
		}
		res.writeHead(200).end(data);
	});
});

server.listen(PORT, () => {
	console.log(`serving ${ROOT} on http://localhost:${PORT}`);
});
