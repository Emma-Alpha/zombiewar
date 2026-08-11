#!/usr/bin/env node
// Brotli-compress a file to `<input>.br` using the quality that balances ratio
// against deploy time (measured on this project's engine wasm: q9 lands ~20% of
// original in a few seconds, while q11 only shaves ~2% more for ~30x the time).
// The deploy script uploads the `.br` sibling to R2 next to the raw object.
const fs = require("node:fs");
const zlib = require("node:zlib");

const input = process.argv[2];
if (!input) {
	console.error("Usage: compress_brotli.js <input-file> [output-file]");
	process.exit(2);
}
const output = process.argv[3] ?? `${input}.br`;

const source = fs.readFileSync(input);
const compressed = zlib.brotliCompressSync(source, {
	params: {
		[zlib.constants.BROTLI_PARAM_QUALITY]: 9,
		// Larger window helps the multi-megabyte engine binary find repeats.
		[zlib.constants.BROTLI_PARAM_SIZE_HINT]: source.length,
	},
});
fs.writeFileSync(output, compressed);
console.log(
	`Brotli ${input} -> ${output}: ${source.length} -> ${compressed.length} bytes ` +
		`(${Math.round((compressed.length / source.length) * 100)}%)`,
);
