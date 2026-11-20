#!/usr/bin/env node
// PreToolUse hook only for the local worker (loaded via --settings by local-worker.sh when
// WORKER_GUARD=1). Three jobs:
//  1. Detect dangerous patterns (rm -rf on roots, force push, reset --hard without git status,
//     curl|sh, secret files, sudo). GUARD_MODE=log (default) only logs,
//     GUARD_MODE=block denies the call.
//  2. Count identical calls in a row, write a log entry from 4 on.
//  3. Run test commands (npm test, pytest, npm run build ...) through test-wrap.sh, so the
//     model only sees exit code, error lines and the last 40 lines (TEST_WRAP=0 turns it off).
// Log: ~/.claude/logs/worker-guard.log. Any error in the hook itself lets the call through
// (fail open) and is logged as HOOK-ERROR.
const fs = require("fs");
const os = require("os");
const path = require("path");

const HOME = os.homedir();
const LOGDIR = path.join(HOME, ".claude", "logs");
const LOG = path.join(LOGDIR, "worker-guard.log");
const STATEDIR = path.join(HOME, ".claude", "state", "guard");
const MODE = (process.env.GUARD_MODE || "log").toLowerCase() === "block" ? "block" : "log";
const RUN = process.env.WORKER_RUN_ID || "-";
const REPEAT_LIMIT = 4;

let sess = "-";

function log(kind, fields) {
  try {
    fs.mkdirSync(LOGDIR, { recursive: true });
    const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    const extra = Object.entries(fields)
      .map(([k, v]) => `${k}=${String(v).replace(/\s+/g, " ").slice(0, 300)}`)
      .join(" ");
    fs.appendFileSync(LOG, `${ts} run=${RUN} sess=${sess} ${kind} ${extra}\n`);
  } catch {
    // Log errors must not stop the worker
  }
}

function out(obj) {
  if (obj) process.stdout.write(JSON.stringify(obj));
  process.exit(0);
}

// --- Protection rules ----------------------------------------------------------
// Targets rm -rf must never point to: roots, home, drive, system folders (also below them)
const HOME_FWD = HOME.replace(/\\/g, "/");
const HOME_MSYS = HOME_FWD.replace(/^([A-Za-z]):/, (_, d) => "/" + d.toLowerCase());
const ROOT_TARGETS = new Set(
  ["/", "/*", "~", "~/", "~/*", "$HOME", "$HOME/", "$HOME/*", "${HOME}", "${HOME}/", "${HOME}/*",
   "$USERPROFILE", "%USERPROFILE%",
   HOME_FWD, HOME_FWD + "/", HOME_FWD + "/*", HOME_MSYS, HOME_MSYS + "/", HOME_MSYS + "/*",
   "/c", "/c/", "/c/*", "/c/Users", "/c/Users/", "c:", "c:/", "c:/*", "c:\\", "c:\\*", "c:/users", "c:\\users"]
    .map((s) => s.toLowerCase())
);
const SYSTEM_PREFIX = /^(\/(bin|boot|dev|etc|lib|lib64|opt|proc|root|sbin|sys|usr|var|system|library|applications)(\/|$)|(\/c\/|c:[\\/])(windows|program files|program files \(x86\)|programdata)([\\/]|$))/i;

function unquote(s) {
  return s.replace(/^["']|["']$/g, "");
}

// Split a command into sub-commands at ; && || | and newlines (rough, good enough for patterns)
function segments(cmd) {
  return cmd.split(/\n|;|&&|\|\||\|/).map((s) => s.trim()).filter(Boolean);
}

function words(seg) {
  return (seg.match(/"[^"]*"|'[^']*'|\S+/g) || []).map(unquote);
}

function checkRm(seg) {
  const w = words(seg);
  const idx = w.findIndex((x) => /^(\\)?rm$/.test(x) || /\/rm$/.test(x));
  if (idx < 0) return null;
  const args = w.slice(idx + 1);
  const flags = args.filter((a) => a.startsWith("-"));
  const joined = flags.filter((f) => !f.startsWith("--")).join("");
  const rec = /r/i.test(joined) || flags.includes("--recursive");
  const force = /f/.test(joined) || flags.includes("--force");
  if (!rec || !force) return null;
  for (const t of args.filter((a) => !a.startsWith("-"))) {
    const low = t.toLowerCase();
    const n = low.replace(/[\\/]+$/, "") || "/";
    if (ROOT_TARGETS.has(low) || ROOT_TARGETS.has(n) || SYSTEM_PREFIX.test(t)) {
      return `rm -rf on ${t}`;
    }
  }
  return null;
}

function checkPush(seg) {
  if (!/\bgit\b.*\bpush\b/.test(seg)) return null;
  const w = words(seg).slice(words(seg).indexOf("push") + 1);
  for (const a of w) {
    if (a === "--force" || a === "--mirror") return `git push ${a}`;
    if (/^-[a-zA-Z]*f[a-zA-Z]*$/.test(a) && !a.startsWith("--")) return `git push ${a}`;
    if (/^\+[^\s]+/.test(a)) return `git push with +refspec (${a})`;
  }
  return null; // --force-with-lease and --force-if-includes stay allowed
}

function checkReset(seg, statusSeen) {
  if (statusSeen) return null;
  if (/\bgit\b.*\breset\b.*--hard\b/.test(seg)) return "git reset --hard without prior git status";
  if (/\bgit\b.*\bcheckout\b\s+(--\s+)?\.(\s|$)/.test(seg)) return "git checkout . without prior git status";
  if (/\bgit\b.*\brestore\b\s+(--\S+\s+)*\.(\s|$)/.test(seg)) return "git restore . without prior git status";
  return null;
}

function checkPipeShell(cmd) {
  if (/\b(curl|wget)\b[^|;&\n]*\|\s*(sudo\s+)?(env\s+)?(ba|z|da|k)?sh\b/.test(cmd)) return "curl/wget | sh";
  if (/\b(curl|wget)\b[^|;&\n]*\|\s*(sudo\s+)?python\d*(\.\d+)?\b/.test(cmd)) return "curl/wget | python";
  if (/\b(ba|z)?sh\s+(-c\s+)?["']?\$\(\s*(curl|wget)\b/.test(cmd)) return "sh $(curl ...)";
  if (/\b(ba|z)?sh\s+<\(\s*(curl|wget)\b/.test(cmd)) return "sh <(curl ...)";
  return null;
}

// Secret files and folders. .env.example/.sample/.template stay allowed.
const SECRET_RE = new RegExp(
  "(^|[\\s/\\\\'\"=:~(])(" +
    "\\.ssh|\\.aws|\\.gnupg|\\.kube|\\.docker" +
  ")([\\\\/]|$|[\\s'\")])" +
  "|(^|[\\s/\\\\'\"=:~(])(" +
    "\\.netrc|\\.git-credentials|\\.npmrc|\\.pypirc" +
  ")($|[\\s'\")])" +
  "|(^|[\\s/\\\\'\"=:~(<])\\.env(\\.(?!example\\b|sample\\b|template\\b|dist\\b)[\\w-]+)?($|[\\s'\";|&)>])",
  "i"
);

function checkSecret(text) {
  const m = SECRET_RE.exec(text);
  if (!m) return null;
  return `secret path ${m[0].trim().replace(/^[=:~('"]+/, "")}`;
}

function checkSudo(seg) {
  return /^(\S+=\S+\s+)*sudo\b/.test(seg) ? "sudo" : null;
}

// --- Test commands ----------------------------------------------------------------
const TEST_RE = /(^|[\s;&|(])((npm|pnpm|yarn|bun)\s+(run\s+)?(test|build)\b|npx\s+(vitest|jest|mocha|playwright\s+test)\b|(python\d*|py)\s+-m\s+(pytest|unittest)\b|pytest\b|vitest\b|jest\b|cargo\s+(test|build)\b|go\s+test\b|dotnet\s+test\b|mvn\s+test\b|gradle\w*\s+test\b)/;

// --- State per worker session -------------------------------------------------------
function statePath() {
  const key = String(sess).replace(/[^\w-]/g, "_") || "nosess";
  return path.join(STATEDIR, `${key}.json`);
}
function loadState() {
  try { return JSON.parse(fs.readFileSync(statePath(), "utf8")); } catch { return { statusSeen: false, last: "", count: 0 }; }
}
function saveState(st) {
  try { fs.mkdirSync(STATEDIR, { recursive: true }); fs.writeFileSync(statePath(), JSON.stringify(st)); } catch {}
}

// --- Main ---------------------------------------------------------------------------
function main(raw) {
  const ev = JSON.parse(raw || "{}");
  sess = String(ev.session_id || "-").slice(0, 8);
  const tool = ev.tool_name || "";
  const inp = ev.tool_input || {};
  const st = loadState();

  // 2. Repeats: same command or same file directly in a row
  const target = inp.command || inp.file_path || inp.path || inp.pattern || "";
  const key = `${tool}\u0000${target}`;
  if (key === st.last) st.count += 1; else { st.last = key; st.count = 1; }
  if (st.count >= REPEAT_LIMIT) log("REPEAT", { n: st.count, tool, target });

  // 1. Protection rules
  const hits = [];
  if (tool === "Bash") {
    const cmd = String(inp.command || "");
    const segs = segments(cmd);
    // git status in the same command before the reset counts too
    let seen = st.statusSeen;
    for (const s of segs) {
      if (/\bgit\b(\s+-\S+)*\s+status\b/.test(s)) seen = true;
      for (const r of [checkRm(s), checkPush(s), checkReset(s, seen), checkSudo(s)]) if (r) hits.push(r);
    }
    st.statusSeen = seen;
    const p = checkPipeShell(cmd); if (p) hits.push(p);
    const sec = checkSecret(cmd); if (sec) hits.push(sec);
  } else if (["Write", "Edit", "Read", "MultiEdit", "NotebookEdit"].includes(tool)) {
    const fp = String(inp.file_path || inp.notebook_path || "");
    const sec = checkSecret(fp.replace(/\\/g, "/")); if (sec) hits.push(sec);
  }
  saveState(st);

  if (hits.length) {
    const reason = [...new Set(hits)].join("; ");
    log("HIT", { mode: MODE, rule: reason, tool, target });
    if (MODE === "block") {
      out({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: `Worker guard blocked: ${reason}. This command is not allowed for the worker; solve the task without it.`,
        },
      });
    }
    // Log mode: let it run (and no test rewrite, so the command stays unchanged)
    out(null);
  }

  // 3. Limit test output
  if (tool === "Bash" && process.env.TEST_WRAP !== "0") {
    const cmd = String(inp.command || "");
    if (TEST_RE.test(cmd) && !cmd.includes("test-wrap.sh")) {
      const b64 = Buffer.from(cmd, "utf8").toString("base64");
      const wrapped = `bash "$HOME/.claude/bin/test-wrap.sh" ${b64}`;
      log("TESTWRAP", { tool, target: cmd });
      out({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "allow",
          permissionDecisionReason: "Test output is shortened (full output under ~/.claude/logs/)",
          updatedInput: { ...inp, command: wrapped },
        },
      });
    }
  }
  out(null);
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => (buf += c));
process.stdin.on("end", () => {
  try {
    main(buf);
  } catch (e) {
    log("HOOK-ERROR", { error: e && e.stack ? e.stack.split("\n").slice(0, 2).join(" | ") : String(e) });
    process.exit(0); // fail open
  }
});
process.stdin.on("error", (e) => {
  log("HOOK-ERROR", { error: String(e) });
  process.exit(0);
});
