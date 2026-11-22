"use strict";

const { readFileSync } = require("node:fs");
const required = ["Claim class", "Verdict", "Commands and results",
  "What this proves", "What this does not prove"];

function validate(markdown, expectedHead) {
  const lines = markdown.split(/\r\n|\n|\r/);
  const start = lines.findIndex(line => line.trim().toLowerCase() === "## evidence");
  if (start < 0) throw new Error("missing exact '## Evidence' section");

  const fields = new Map();
  for (const line of lines.slice(start + 1)) {
    if (line.trimStart().startsWith("## ")) break;
    const match = line.trim().match(/^\*\*([^*]+):\*\*(.*)$/);
    if (!match) continue;
    const [, label, tail] = match;
    if (![...required, "Evidence URL", "Evidence SHA"].includes(label)) continue;
    if (fields.has(label)) throw new Error("duplicate evidence field: " + label);
    const value = tail.trim();
    if (!value || /<!--|-->/.test(value)) {
      if (label === "Evidence URL") continue;
      throw new Error("placeholder or empty evidence field: " + label);
    }
    fields.set(label, value);
  }

  for (const label of required) {
    if (!fields.has(label)) throw new Error("missing evidence field: " + label);
  }
  for (const label of required.slice(2)) {
    if (/^(n\/a|na|none|tbd|todo|trust me)$/.test(fields.get(label).toLowerCase().replace(/\.+$/, ""))) {
      throw new Error("placeholder evidence field: " + label);
    }
  }

  const kind = fields.get("Claim class").toLowerCase();
  const verdict = fields.get("Verdict").toUpperCase();
  if (!["tooling", "documentation-only", "production"].includes(kind)) {
    throw new Error("unsupported claim class");
  }
  if (verdict !== "PASS" && verdict !== "PARTIAL") throw new Error("verdict does not pass");
  if (kind === "production") {
    if (verdict !== "PASS") throw new Error("production evidence requires PASS");
    const url = fields.get("Evidence URL") || "";
    if (!/^https:\/\/gist\.github\.com\/[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[0-9a-fA-F]{16,}(?:[/?#].*)?$/.test(url)) {
      throw new Error("production evidence requires a gist owner and artifact ID");
    }
    const sha = fields.get("Evidence SHA") || "";
    if (!/^[0-9a-f]{40}$/.test(sha) || sha !== expectedHead) {
      throw new Error("production evidence SHA must match the trusted PR head");
    }
  }
}

try {
  validate(readFileSync(0, "utf8"), process.env.PR_HEAD_SHA);
  console.log("Evidence Gate: PASS");
} catch (error) {
  console.error("Evidence Gate: FAIL: " + error.message);
  process.exitCode = 1;
}
