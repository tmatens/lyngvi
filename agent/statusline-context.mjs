#!/usr/bin/env node
// Status line: shows context-window usage for the current session.
// Reads the session JSON Claude Code pipes on stdin, opens the transcript,
// finds the last main-chain assistant turn, and renders its prompt size as a
// percentage of the model's context window. No network, no deps.

import fs from "node:fs";

function readStdin() {
  try { return fs.readFileSync(0, "utf8"); } catch { return ""; }
}

function contextWindow(modelId = "") {
  // The 1M-context variant tags the id with [1m]; everything else is 200k.
  return /\[1m\]|1m/i.test(modelId) ? 1_000_000 : 200_000;
}

function lastUsage(transcriptPath) {
  let raw;
  try { raw = fs.readFileSync(transcriptPath, "utf8"); } catch { return null; }
  const lines = raw.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    // Only the main conversation counts toward the window — skip subagent sidechains.
    if (o?.isSidechain) continue;
    const u = o?.message?.usage;
    if (u && (u.input_tokens != null || u.cache_read_input_tokens != null)) {
      return (u.input_tokens || 0) +
             (u.cache_creation_input_tokens || 0) +
             (u.cache_read_input_tokens || 0);
    }
  }
  return null;
}

function main() {
  let data = {};
  try { data = JSON.parse(readStdin() || "{}"); } catch {}

  const modelId = data?.model?.id || "";
  const name = data?.model?.display_name || modelId || "model";
  const win = contextWindow(modelId);
  const used = lastUsage(data?.transcript_path);

  if (used == null) {
    process.stdout.write(`${name} | ctx —`);
    return;
  }

  const pct = Math.round((used / win) * 100);
  const k = (n) => (n >= 1000 ? `${Math.round(n / 1000)}k` : `${n}`);
  // Simple severity cue once context gets tight (auto-compact looms near the top).
  const flag = pct >= 90 ? " ⚠" : pct >= 75 ? " !" : "";
  process.stdout.write(`${name} | ctx ${pct}% (${k(used)}/${k(win)})${flag}`);
}

main();
