/**
 * dsh-desktop-shell-plus — host half.
 *
 * Keeps two upstream things patched, idempotently, from inside DSH:
 *
 *   1. the dsh-desktop-shell launcher (`DSHLauncher.exe`): per-monitor DPI awareness, a dark
 *      branded splash instead of the blank white wait panel, a dark DWM caption, window-bounds
 *      memory and an F12/Ctrl+R key bridge. The patched source ships in `src/`, the build goes
 *      to `<home>/DSHLauncher-custom-v<N>.exe` and every existing shortcut is repointed at it;
 *   2. the right-side panel of the web UI: `@deepseek-ai/dsh-client-ui-layout` hardcodes a
 *      45%-of-viewport first-open width for the right rail; this narrows it to 20%.
 *
 * Both are cheap to re-apply and are re-applied on boot, because a dsh-desktop-shell upgrade
 * restores its own `DSHLauncher.exe` and a dsh upgrade brings a fresh, unpatched layout package.
 *
 * Routes (loopback only):
 *   GET  /api/desktop-plus/status  -> what is installed / patched / stale
 *   POST /api/desktop-plus/apply   -> re-apply ({launcher?,rightbar?,shortcuts?})
 *
 * Windows only. Nothing here downloads anything: the launcher source and the scripts ship in
 * this package, and compilation uses the csc.exe that ships with .NET Framework 4.x.
 * @module dsh-desktop-shell-plus
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Stable Cordis plugin name — must equal the package name. */
export const name = "dsh-desktop-shell-plus";
/** Required services. */
export const inject = ["webServer"];

const HERE = dirname(fileURLToPath(import.meta.url));
const PKG_ROOT = join(HERE, "..");
const SCRIPTS = join(PKG_ROOT, "scripts");
const PATCHED_SOURCE = join(PKG_ROOT, "src", "DSHLauncher.patched.cs");
const PATCHED_ICON = join(PKG_ROOT, "src", "DSHLauncher.ico");
const CSC = "C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe";
const LAYOUT_PKG = join("@deepseek-ai", "dsh-client-ui-layout", "lib", "client.js");
const RATIO_PATCHED = "const RIGHTBAR_DEFAULT_RATIO = .2;";
const RATIO_ORIGINAL = "const RIGHTBAR_DEFAULT_RATIO = .45;";
const PS_TIMEOUT_MS = Number(process.env.DSH_DESKTOP_PLUS_TIMEOUT_MS ?? 300_000);
const AUTO_DELAY_MS = Number(process.env.DSH_DESKTOP_PLUS_AUTO_DELAY_MS ?? 3000);

/** Launcher home: where dsh-desktop-shell installs its exe, config and shortcuts. */
export function resolveHome(env = process.env) {
  const pinned = env.DSH_DESKTOP_HOME ?? "";
  if (pinned !== "") return pinned;
  return join(env.USERPROFILE ?? env.HOME ?? "", "dsh-desktop");
}

/** Newest `@deepseek-ai/dsh-client-ui-layout` copy on disk, or "". */
export function resolveLayoutClient(env = process.env) {
  const pinned = env.DSH_DESKTOP_PLUS_LAYOUT ?? "";
  if (pinned !== "") return pinned;
  const roots = [
    join(env.LOCALAPPDATA ?? "", "npm-cache", "_npx"),
    join(env.APPDATA ?? "", "npm", "node_modules")
  ];
  const hits = [];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    let entries = [];
    try { entries = readdirSync(root); } catch { continue; }
    for (const entry of entries) {
      const candidate = entry === "node_modules"
        ? join(root, LAYOUT_PKG)
        : join(root, entry, "node_modules", LAYOUT_PKG);
      if (existsSync(candidate)) hits.push(candidate);
    }
  }
  hits.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return hits[0] ?? "";
}

/** Current launcher build in the home, per `custom/build-name.txt`, or "". */
export function liveBuild(home) {
  const nameFile = join(home, "custom", "build-name.txt");
  if (!existsSync(nameFile)) return "";
  const leaf = readFileSync(nameFile, "utf8").trim();
  if (leaf === "" || !existsSync(join(home, leaf))) return "";
  return join(home, leaf);
}

function buildList(home) {
  if (!existsSync(home)) return [];
  return readdirSync(home)
    .filter((file) => /^DSHLauncher-custom-v\d+\.exe$/.test(file))
    .map((file) => {
      const path = join(home, file);
      const stat = statSync(path);
      return { file, bytes: stat.size, mtime: stat.mtime.toISOString() };
    })
    .sort((a, b) => (a.mtime < b.mtime ? 1 : -1));
}

/** Everything the settings UI / a human wants to know before trusting the patch state. */
export function readStatus(env = process.env) {
  const home = resolveHome(env);
  const layout = resolveLayoutClient(env);
  let rightbar = "missing";
  if (layout !== "") {
    const text = readFileSync(layout, "utf8");
    if (text.includes(RATIO_PATCHED)) rightbar = "patched";
    else if (text.includes(RATIO_ORIGINAL)) rightbar = "original";
    else rightbar = "unknown";
  }
  const live = liveBuild(home);
  return {
    platform: process.platform,
    supported: process.platform === "win32",
    home,
    homeExists: existsSync(home),
    shellInstalled: existsSync(join(home, "DSHLauncher.exe")),
    liveBuild: live,
    builds: buildList(home),
    patchedSourcePresent: existsSync(PATCHED_SOURCE),
    compilerPresent: existsSync(CSC),
    shortcutsFrozen: existsSync(join(home, ".shortcuts-frozen")),
    rightbar: { client: layout, state: rightbar }
  };
}

function runPowerShell(script, args) {
  if (!existsSync(script)) return { script, ok: false, code: -1, stderr: `script missing: ${script}` };
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, ...args],
    { timeout: PS_TIMEOUT_MS, encoding: "utf8", windowsHide: true }
  );
  const out = (result.stdout ?? "").trim();
  const err = (result.stderr ?? "").trim();
  return {
    script,
    ok: result.status === 0,
    code: result.status ?? -1,
    stdout: out.length > 4000 ? `${out.slice(0, 4000)}…` : out,
    stderr: err.length > 2000 ? `${err.slice(0, 2000)}…` : err
  };
}

/**
 * Re-apply the patches.
 *
 * `launcher`: rebuild the patched exe when the live build is missing or older than the shipped
 * source, then repoint the existing shortcuts. `rightbar`: narrow the right rail. `shortcuts`:
 * freeze the plugin's boot-time shortcut repair so renamed links survive. `auto` is the boot
 * path: it starts from `launcher` only when there is something to do, so a steady state boot
 * costs one `existsSync` and nothing else.
 */
export function applyPatches(options = {}, env = process.env) {
  const home = resolveHome(env);
  const auto = options.auto === true;
  const steps = [];
  if (process.platform !== "win32") {
    return { ok: false, reason: "windows only", steps };
  }
  if (!existsSync(home)) {
    return { ok: false, reason: `dsh-desktop-shell is not installed (no ${home})`, steps };
  }

  const wantRightbar = options.rightbar !== false;
  const wantShortcuts = options.shortcuts !== false;
  let wantLauncher = options.launcher !== false;

  if (wantLauncher) {
    const live = liveBuild(home);
    const stale = live === "" || statSync(PATCHED_SOURCE).mtimeMs > statSync(live).mtimeMs;
    if (auto && !stale) wantLauncher = false;
    else {
      steps.push(runPowerShell(join(SCRIPTS, "rebuild-launcher.ps1"), ["-LauncherHome", home, "-Quiet"]));
    }
  }
  if (wantRightbar) {
    const layout = resolveLayoutClient(env);
    const args = layout === "" ? [] : ["-DshRoot", dirname(dirname(dirname(dirname(dirname(layout)))))];
    steps.push(runPowerShell(join(SCRIPTS, "patch-rightbar-width.ps1"), args));
  }
  if (wantShortcuts) {
    steps.push(runPowerShell(join(SCRIPTS, "patch-shortcuts.ps1"), ["-LauncherHome", home]));
  }
  const ok = steps.every((step) => step.ok !== false);
  return { ok, steps, status: readStatus(env) };
}

function isLoopback(req) {
  const address = req?.socket?.remoteAddress ?? "";
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

function writeJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(payload);
}

async function readJsonBody(req) {
  if (req.method === "GET" || req.method === "HEAD") return null;
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
    if (chunks.reduce((total, part) => total + part.length, 0) > 64 * 1024) return null;
  }
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (text === "") return {};
  try { return JSON.parse(text); } catch { return null; }
}

function makeRoutes(env, logger) {
  return [
    {
      kind: "exact",
      path: "/api/desktop-plus/status",
      handler: (req, res) => {
        if (!isLoopback(req)) { writeJson(res, 403, { error: "forbidden" }); return; }
        if ((req.method ?? "GET") !== "GET") { writeJson(res, 405, { error: "method not allowed" }); return; }
        writeJson(res, 200, readStatus(env));
      }
    },
    {
      kind: "exact",
      path: "/api/desktop-plus/apply",
      handler: async (req, res) => {
        if (!isLoopback(req)) { writeJson(res, 403, { error: "forbidden" }); return; }
        if (req.method !== "POST") { writeJson(res, 405, { error: "method not allowed" }); return; }
        const body = (await readJsonBody(req)) ?? {};
        logger(`apply requested (${JSON.stringify(body)})`);
        try {
          const report = applyPatches({
            launcher: body.launcher,
            rightbar: body.rightbar,
            shortcuts: body.shortcuts
          }, env);
          writeJson(res, report.ok ? 200 : 500, report);
        } catch (error) {
          writeJson(res, 500, { ok: false, error: String((error && error.message) || error) });
        }
      }
    }
  ];
}

/**
 * @param ctx - plugin context carrying the webServer service.
 */
export function apply(ctx) {
  const env = process.env;
  const logger = (message) => {
    try { ctx.logger?.info?.(`[desktop-plus] ${message}`); } catch { /* logging must never break activation */ }
  };

  const register = ctx.webServer?.register?.bind(ctx.webServer);
  if (typeof register !== "function") { logger("no webServer service; routes not registered"); return; }
  for (const route of makeRoutes(env, logger)) register(route);

  if (process.platform !== "win32") { logger("windows only; boot-time re-apply skipped"); return; }
  if (!existsSync(resolveHome(env))) { logger("dsh-desktop-shell not installed; boot-time re-apply skipped"); return; }

  const timer = setTimeout(() => {
    try {
      const report = applyPatches({ auto: true }, env);
      logger(report.ok ? "boot-time re-apply ok" : `boot-time re-apply: ${report.reason ?? "one or more steps failed"}`);
      for (const step of report.steps ?? []) {
        logger(`${step.ok ? "ok" : "FAILED"} ${step.script.split(/[\\/]/).pop()} (${step.code})`);
      }
    } catch (error) {
      logger(`boot-time re-apply failed: ${String((error && error.message) || error)}`);
    }
  }, AUTO_DELAY_MS);
  if (typeof timer.unref === "function") timer.unref();
}
