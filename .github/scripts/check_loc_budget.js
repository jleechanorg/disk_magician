"use strict";

const { execFileSync } = require("node:child_process");
const { extname } = require("node:path").posix;
const suffixes = new Set(".bash .c .cc .cpp .cs .go .h .hpp .java .js .jsx .kt .m .mm .php .pl .py .rb .rs .sh .swift .ts .tsx .vue".split(" "));
const excluded = new Set(".git .venv __pycache__ build dist docs evidence findings_wiki node_modules roadmap target test tests testing vendor".split(" "));

function git(args, input) {
  return execFileSync("git", args, { input, maxBuffer: 32 * 1024 * 1024 });
}

function measure(revision) {
  const records = git(["ls-tree", "-rz", "--full-tree", revision]).toString().split("\0");
  const sources = [];
  for (const record of records) {
    if (!record) continue;
    const tab = record.indexOf("\t");
    const [mode, type, oid] = record.slice(0, tab).split(" ");
    const path = record.slice(tab + 1);
    const parts = path.toLowerCase().split("/");
    const filename = parts.pop();
    if (type !== "blob" || !["100644", "100755"].includes(mode) ||
        !suffixes.has(extname(filename)) || parts[0] === ".github" ||
        parts.some(part => excluded.has(part)) || path.startsWith("src/disk_magician/") ||
        /(?:^test_|_test\.|\.test\.|\.spec\.)/.test(filename)) continue;
    sources.push({ oid, rust: path.startsWith("rust/") && path.endsWith(".rs") });
  }

  const counts = { rust: 0, legacy: 0 };
  if (!sources.length) return counts;
  const blobs = git(["cat-file", "--batch"], sources.map(source => source.oid + "\n").join(""));
  let cursor = 0;
  for (const source of sources) {
    const end = blobs.indexOf(10, cursor);
    if (end < 0) throw new Error("truncated Git blob header");
    const [oid, type, bytes] = blobs.subarray(cursor, end).toString().split(" ");
    const size = Number(bytes);
    cursor = end + 1;
    if (oid !== source.oid || type !== "blob" || !Number.isSafeInteger(size) ||
        size < 0 || blobs[cursor + size] !== 10) throw new Error("invalid Git blob");
    const data = blobs.subarray(cursor, cursor + size);
    cursor += size + 1;
    if (data.includes(0)) continue;
    let lines = data.length && data[data.length - 1] !== 10 ? 1 : 0;
    for (const byte of data) if (byte === 10) lines++;
    counts[source.rust ? "rust" : "legacy"] += lines;
  }
  return counts;
}

try {
  const [base, head, rustLimitArg, legacyLimitArg] = process.argv.slice(2);
  const rustLimit = Number(rustLimitArg);
  const legacyLimit = Number(legacyLimitArg);
  if (!base || !head || !Number.isSafeInteger(rustLimit) || rustLimit < 0 ||
      !Number.isSafeInteger(legacyLimit) || legacyLimit < 0) {
    throw new Error("expected base, head and nonnegative integer limits");
  }
  const mergeBase = git(["merge-base", base, head]).toString().trim();
  const before = measure(mergeBase);
  const after = measure(head);
  const delta = after.legacy - before.legacy;
  console.log("Rust production LOC: " + after.rust + " / " + rustLimit);
  console.log("Legacy production net delta: " + delta + " / +" + legacyLimit);
  if (after.rust > rustLimit || delta > legacyLimit) throw new Error("LOC budget exceeded");
} catch (error) {
  console.error("LOC budget: " + error.message);
  process.exitCode = 1;
}
