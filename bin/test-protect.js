#!/usr/bin/env node
// Test protection for qwen-first.sh: reads `git diff -U0 <tests commit> -- <file>` on stdin and
// the current file (argv[2]). Prints "<n> existing assertion(s) removed or changed" if a removed
// line contained an assertion that no longer exists in the file (whitespace ignored, so
// reformatting and line wrapping are fine), otherwise nothing.
const fs = require("fs");
const diff = fs.readFileSync(0, "utf8").split("\n");
let now = "";
try {
  now = fs.readFileSync(process.argv[2], "utf8").replace(/\s+/g, "");
} catch {
  console.log("file unreadable");
  process.exit(0);
}
// Python (assert, pytest.raises, unittest), JS/TS (expect, chai should, node:test/ava t.*)
const ASSERT = /\b(assert\w*|expect|should)\b|\.to[A-Z]\w*\(|pytest\.raises|\bt\.(is|deepEqual|true|false|throws)\b/;
let n = 0;
for (const line of diff) {
  if (!line.startsWith("-") || line.startsWith("---")) continue;
  const body = line.slice(1);
  if (ASSERT.test(body) && !now.includes(body.replace(/\s+/g, ""))) n++;
}
if (n) console.log(n + " existing assertion(s) removed or changed");
