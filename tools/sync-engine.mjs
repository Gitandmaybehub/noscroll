#!/usr/bin/env node
// Rebuild the engine and copy it + the rule bundles into both app targets.
// Both shells MUST carry the identical engine bundle — that is the architecture.
//
// This is the cross-platform twin of tools/sync-engine.sh. It exists because
// Windows has no `bash` on PATH by default, and `bash tools/sync-engine.sh`
// is the very first command a Windows user following the build guide would
// hit that fails with "'bash' is not recognized". Node is already a hard
// requirement (pnpm needs it), so `node tools/sync-engine.mjs` works
// unmodified on Windows, macOS and Linux.
//
// Logic below is a line-for-line port of the .sh version — keep them in sync.

import { spawnSync } from 'node:child_process';
import { mkdirSync, copyFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const engineDir = path.join(repoRoot, 'engine');
const androidRulesDir = path.join(repoRoot, 'android/app/src/main/assets/rules');
const iosRulesDir = path.join(repoRoot, 'ios/NoScroll/Resources/Rules');
const engineOut = path.join(engineDir, 'dist/noscroll.js');
const rulesDir = path.join(repoRoot, 'rules');

function run(cmd, args, cwd) {
  // shell: true only on Windows, where pnpm is a .cmd shim that Node cannot
  // exec directly. POSIX doesn't need it — and skipping it there avoids
  // Node's shell-plus-array-args deprecation warning.
  const result = spawnSync(cmd, args, { cwd, stdio: 'inherit', shell: process.platform === 'win32' });
  if (result.error) {
    console.error(`Failed to run "${cmd} ${args.join(' ')}": ${result.error.message}`);
    process.exit(1);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function copyJsonFiles(fromDir, toDir) {
  for (const entry of readdirSync(fromDir)) {
    if (entry.endsWith('.json')) {
      copyFileSync(path.join(fromDir, entry), path.join(toDir, entry));
    }
  }
}

run('pnpm', ['build'], engineDir);

mkdirSync(androidRulesDir, { recursive: true });
mkdirSync(iosRulesDir, { recursive: true });

copyFileSync(engineOut, path.join(repoRoot, 'android/app/src/main/assets/noscroll.js'));
copyFileSync(engineOut, path.join(repoRoot, 'ios/NoScroll/Resources/noscroll.js'));

copyJsonFiles(rulesDir, androidRulesDir);
copyJsonFiles(rulesDir, iosRulesDir);

const bytes = statSync(engineOut).size;
console.log(`engine + rules synced to both shells (${bytes} bytes)`);
