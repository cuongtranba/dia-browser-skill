#!/usr/bin/env node
// Gives an agent its own browser for any Dia profile, logged in as that profile, without
// touching Dia's windows.
//
//   dia-profile.mjs list                          profiles, whether Dia has them loaded, sessions
//   dia-profile.mjs open <profile> [url] [--headed]
//                                                 start session "dia-<profile>" (headless unless
//                                                 --headed) seeded with the profile's live cookies
//   dia-profile.mjs ab <profile> <agent-browser args...>
//                                                 run agent-browser against that session
//   dia-profile.mjs close <profile>               stop the session
//
// How: the profile's cookies are read from the running Dia over CDP (Network.getAllCookies in
// one of the profile's own tabs, already decrypted), then set into a separate agent-browser
// browser with Storage.setCookies. Nothing is clicked in Dia and no cookie touches the disk.
// Copying the profile folder does not work: headless Chromium cannot read the "Dia Safe Storage"
// Keychain key, so every cookie fails to decrypt. CDP only sees profiles Dia has loaded, so a
// profile needs at least one open window in Dia.
//
// Sessions run with an empty agent-browser config. The user config points agent-browser at Dia
// ("cdp": "9222"), and a single call on the session without the empty config re-attaches it to
// Dia, so always go through `ab`.

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const USER_DATA = join(homedir(), "Library/Application Support/Dia/User Data");
const PORT_FILE = join(USER_DATA, "DevToolsActivePort");
const EMPTY_CONFIG = join(homedir(), ".agent-browser/dia-profile-empty.json");
const MIN_MATCH = 0.5;

function die(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

// ---- profiles on disk ---------------------------------------------------------------------

function profiles() {
  const state = JSON.parse(readFileSync(join(USER_DATA, "Local State"), "utf8"));
  const cache = state.profile?.info_cache ?? {};
  return Object.entries(cache)
    .map(([dir, info]) => ({ dir, name: info.name || dir }))
    .sort((a, b) => (a.dir === "Default" ? -1 : b.dir === "Default" ? 1 : a.name.localeCompare(b.name)));
}

function findProfile(query) {
  const all = profiles();
  const q = query.toLowerCase();
  const hit = all.find((p) => p.dir.toLowerCase() === q || p.name.toLowerCase() === q);
  if (hit) return hit;
  const names = all.map((p) => (p.dir === "Default" ? `${p.name} (or "Default")` : p.name)).join(", ");
  die(`no Dia profile "${query}". Profiles: ${names}`);
}

const slug = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const sessionOf = (profile) => `dia-${slug(profile.dir === "Default" ? "default" : profile.name)}`;
const cookieKey = (host, name, path) => `${host}\t${name}\t${path}`;

function storedCookieKeys(profile) {
  const db = join(USER_DATA, profile.dir, "Cookies");
  if (!existsSync(db)) return new Set();
  const out = execFileSync(
    "sqlite3",
    ["-readonly", `file:${db}?immutable=1`, "select host_key || char(9) || name || char(9) || path from cookies"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  return new Set(out.split("\n").filter(Boolean));
}

// ---- CDP ----------------------------------------------------------------------------------

async function connect(url) {
  const ws = new WebSocket(url);
  const pending = new Map();
  let nextId = 0;
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    const waiter = pending.get(msg.id);
    if (!waiter) return;
    pending.delete(msg.id);
    if (msg.error) waiter.reject(new Error(msg.error.message));
    else waiter.resolve(msg.result);
  };
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("CDP connection timed out (is DiaAutoAllow running?)")), 30_000);
    ws.onopen = () => { clearTimeout(timer); resolve(); };
    ws.onerror = () => { clearTimeout(timer); reject(new Error(`cannot reach ${url}`)); };
  });
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
    });
  return { send, close: () => ws.close() };
}

function liveDiaUrl() {
  if (!existsSync(PORT_FILE)) die("Dia remote debugging is off: enable it at chrome://inspect/#remote-debugging");
  const [port, path] = readFileSync(PORT_FILE, "utf8").trim().split("\n");
  return `ws://127.0.0.1:${port}${path}`;
}

// Cookies of every profile Dia has loaded, keyed by browser context.
async function liveCookiesByContext() {
  const dia = await connect(liveDiaUrl());
  try {
    const { targetInfos } = await dia.send("Target.getTargets");
    const pageOf = new Map();
    for (const t of targetInfos.filter((t) => t.type === "page")) {
      const current = pageOf.get(t.browserContextId);
      if (!current || (!current.url.startsWith("http") && t.url.startsWith("http"))) pageOf.set(t.browserContextId, t);
    }
    const result = new Map();
    for (const [context, page] of pageOf) {
      const { sessionId } = await dia.send("Target.attachToTarget", { targetId: page.targetId, flatten: true });
      try {
        result.set(context, (await dia.send("Network.getAllCookies", {}, sessionId)).cookies);
      } finally {
        await dia.send("Target.detachFromTarget", { sessionId }).catch(() => {});
      }
    }
    return result;
  } finally {
    dia.close();
  }
}

// Which loaded context is this profile: the one whose cookies best match the profile's own
// cookie database (read-only; only host, name and path are compared).
function matchProfile(profile, byContext) {
  const stored = storedCookieKeys(profile);
  let best = null;
  for (const [context, cookies] of byContext) {
    if (cookies.length === 0) continue;
    const hits = cookies.filter((c) => stored.has(cookieKey(c.domain, c.name, c.path))).length;
    const score = hits / cookies.length;
    if (hits > 0 && score >= MIN_MATCH && (!best || score > best.score)) best = { context, cookies, score };
  }
  return best;
}

// ---- agent-browser ------------------------------------------------------------------------

function agentBrowserArgs(profile, args) {
  if (!existsSync(EMPTY_CONFIG)) {
    mkdirSync(dirname(EMPTY_CONFIG), { recursive: true });
    writeFileSync(EMPTY_CONFIG, "{}\n");
  }
  return ["--config", EMPTY_CONFIG, "--session", sessionOf(profile), ...args];
}

function agentBrowser(profile, ...args) {
  return execFileSync("agent-browser", agentBrowserArgs(profile, args), {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function sessionRunning(profile) {
  const info = JSON.parse(agentBrowser(profile, "session", "info", "--json")).data;
  return Boolean(info.active && info.runtime?.browserLaunched);
}

// ---- commands -----------------------------------------------------------------------------

async function list() {
  const byContext = await liveCookiesByContext();
  for (const profile of profiles()) {
    const loaded = matchProfile(profile, byContext) ? "loaded in Dia" : "not loaded in Dia (open a window with it)";
    const session = sessionRunning(profile) ? `session ${sessionOf(profile)} running` : "no session";
    const alias = profile.dir === "Default" ? ' (or "Default")' : "";
    console.log(`${profile.name}${alias}\t${loaded}\t${session}`);
  }
}

async function open(query, url, headed) {
  const profile = findProfile(query);
  const match = matchProfile(profile, await liveCookiesByContext());
  if (!match) {
    die(`Dia has not loaded profile "${profile.name}". Open a Dia window with that profile, then retry.`);
  }

  // `get cdp-url` launches the browser if the session has none and leaves a running one's pages
  // alone, so re-running `open` only refreshes the cookies.
  const cdpUrl = agentBrowser(profile, ...(headed ? ["--headed"] : []), "get", "cdp-url").match(/ws:\/\/\S+/)?.[0];
  if (!cdpUrl) die(`agent-browser did not report a CDP URL for session ${sessionOf(profile)}`);
  const browser = await connect(cdpUrl);
  try {
    await browser.send("Storage.clearCookies");
    const cookies = match.cookies.map(({ size, session, expires, ...rest }) => (session || expires <= 0 ? rest : { ...rest, expires }));
    await browser.send("Storage.setCookies", { cookies });
  } finally {
    browser.close();
  }
  if (url) agentBrowser(profile, "open", url);

  console.log(`session ${sessionOf(profile)} is ready with ${match.cookies.length} cookies from Dia profile "${profile.name}"${headed ? " (headed)" : " (headless)"}.`);
  console.log(`drive it with: ${process.argv[1]} ab ${JSON.stringify(query)} <agent-browser command>`);
}

function ab(query, args) {
  const profile = findProfile(query);
  const run = spawnSync("agent-browser", agentBrowserArgs(profile, args), { stdio: "inherit" });
  process.exit(run.status ?? 1);
}

function close(query) {
  const profile = findProfile(query);
  if (!sessionRunning(profile)) return console.log(`no session ${sessionOf(profile)} running`);
  agentBrowser(profile, "close");
  console.log(`closed session ${sessionOf(profile)}`);
}

const [command, ...rest] = process.argv.slice(2);
try {
  if (command === "list") await list();
  else if (command === "open" && rest[0]) {
    const headed = rest.includes("--headed");
    const [profile, url] = rest.filter((a) => a !== "--headed");
    await open(profile, url, headed);
  } else if (command === "ab" && rest[0] && rest.length > 1) ab(rest[0], rest.slice(1));
  else if (command === "close" && rest[0]) close(rest[0]);
  else die("usage: dia-profile.mjs list | open <profile> [url] [--headed] | ab <profile> <agent-browser args...> | close <profile>");
} catch (error) {
  die(error instanceof Error ? error.message : String(error));
}
