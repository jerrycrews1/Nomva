#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const dotenv = require(path.join(process.cwd(), "node_modules", "dotenv"));

const [, , targetPath, patchPath] = process.argv;

if (!targetPath || !patchPath) {
  console.error("Usage: merge_env_patch.js <target-env> <patch-env>");
  process.exit(64);
}

const resolvedTarget = path.resolve(targetPath);
const resolvedPatch = path.resolve(patchPath);
const updates = dotenv.parse(fs.readFileSync(resolvedPatch));
let contents = fs.existsSync(resolvedTarget)
  ? fs.readFileSync(resolvedTarget, "utf8")
  : "";

for (const [key, value] of Object.entries(updates)) {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const linePattern = new RegExp(`^${escapedKey}=.*$`, "m");
  const replacement = `${key}=${value}`;

  if (linePattern.test(contents)) {
    contents = contents.replace(linePattern, replacement);
  } else {
    if (contents && !contents.endsWith("\n")) {
      contents += "\n";
    }
    contents += `${replacement}\n`;
  }
}

fs.writeFileSync(resolvedTarget, contents, { mode: 0o600 });
