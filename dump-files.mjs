// dump-files.mjs
import fs from "fs";
import path from "path";
import { execSync } from "child_process";

const rootDir = process.cwd();
const outFile = path.join(rootDir, "dump.txt");

function getTrackedFiles() {
  const output = execSync("git ls-files", {
    cwd: rootDir,
    encoding: "utf8",
  });

  return output
    .split("\n")
    .map(l => l.trim())
    .filter(Boolean);
}

function main() {
  const files = getTrackedFiles();

  fs.writeFileSync(outFile, "=== Git‑tracked files ===\n\n");

  for (const file of files) {
    fs.appendFileSync(outFile, file + "\n");
  }

  console.log(`Wrote ${files.length} tracked files to dump.txt`);
}

main();