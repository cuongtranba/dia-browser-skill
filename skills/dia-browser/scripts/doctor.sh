#!/usr/bin/env bash
# Reports each link in the agent-browser -> Dia chain and how to fix the first broken one.
set -uo pipefail

APP="$HOME/Applications/DiaAutoAllow.app"
PORT_FILE="$HOME/Library/Application Support/Dia/User Data/DevToolsActivePort"
CONFIG="$HOME/.agent-browser/config.json"
STATUS_FILE="${DIA_AUTO_ALLOW_STATUS:-$HOME/Library/Application Support/dia-browser-skill/watcher.status}"
STATUS_MAX_AGE=30   # the watcher rewrites its status file every 10 s
CDP_TIMEOUT="${DIA_CDP_TIMEOUT:-10}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

REPO_URL="https://github.com/cuongtranba/dia-browser-skill"
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n        fix: %s\n' "$1" "$2"; fail=1; }

printf 'dia-browser %s (report problems: %s/issues)\n' \
  "$(sed -n 's/^version: *//p' "$HERE/../SKILL.md" 2>/dev/null | head -1)" "$REPO_URL"

command -v agent-browser >/dev/null \
  && ok "agent-browser $(agent-browser --version 2>/dev/null | awk '{print $2}')" \
  || bad "agent-browser not installed" "npm i -g agent-browser"

node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if (( node_major >= 22 )) && command -v sqlite3 >/dev/null; then
  ok "node $node_major and sqlite3 (for dia-profile.mjs)"
else
  bad "dia-profile.mjs needs Node 22+ and sqlite3" "install Node 22 or newer (sqlite3 ships with macOS)"
fi

pgrep -x Dia >/dev/null && ok "Dia is running" || bad "Dia is not running" "open -a Dia"

port=""
[[ -f "$PORT_FILE" ]] && port="$(head -1 "$PORT_FILE")"
if [[ -n "$port" ]] && lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q '^Dia'; then
  ok "Dia remote debugging listens on 127.0.0.1:$port"
else
  bad "Dia remote debugging is off" "in Dia open chrome://inspect/#remote-debugging and enable it"
fi

if [[ -f "$CONFIG" ]] && grep -q '"cdp"' "$CONFIG"; then
  cdp="$(grep -o '"cdp"[^,}]*' "$CONFIG" | grep -o '[0-9]\+' | head -1)"
  if [[ -n "$port" && "$cdp" != "$port" ]]; then
    bad "agent-browser cdp=$cdp but Dia listens on $port" "DIA_CDP_PORT=$port $(dirname "$0")/install.sh"
  else
    ok "agent-browser defaults to cdp $cdp"
  fi
else
  bad "agent-browser has no cdp default" "$(dirname "$0")/install.sh"
fi

runner=""
if command -v pm2 >/dev/null && pm2 describe dia-auto-allow 2>/dev/null | grep -q 'status.*online'; then
  runner=pm2
  ok "DiaAutoAllow process is online under pm2 (logs: pm2 logs dia-auto-allow, all lines go to the error log)"
elif pgrep -f "$APP/Contents/MacOS/applet" >/dev/null; then
  runner=app
  ok "DiaAutoAllow.app is running"
else
  bad "DiaAutoAllow is not running" "$HERE/install.sh"
fi

# The watcher reports what it sees through Accessibility. A shell cannot test that: macOS
# grants Accessibility per process, and the watcher is not a child of this shell.
accessibility_owner() {
  if [[ "$runner" == pm2 ]]; then
    local pid daemon bin
    pid="$(pm2 pid dia-auto-allow 2>/dev/null | head -1)"
    daemon="$(ps -o ppid= -p "${pid:-0}" 2>/dev/null | tr -d ' ')"
    bin="$(lsof -a -nP -p "${daemon:-0}" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    printf 'the pm2 daemon (parent of osascript), binary %s' "${bin:-node}"
  else
    printf '%s' "$APP"
  fi
}

if [[ -n "$runner" ]]; then
  if [[ ! -f "$STATUS_FILE" ]]; then
    bad "DiaAutoAllow is running but has never reported (no $STATUS_FILE)" \
        "it runs an older script without diagnostics: $HERE/install.sh"
  else
    IFS=$'\t' read -r st_epoch st_state st_detail < "$STATUS_FILE" || true
    age=$(( $(date +%s) - ${st_epoch:-0} ))
    if (( age > STATUS_MAX_AGE )); then
      bad "DiaAutoAllow last reported ${age}s ago, so the watch loop is stuck or dead" \
          "pm2 restart dia-auto-allow (or quit and reopen DiaAutoAllow.app), then re-run doctor"
    else
      case "$st_state" in
        ok)     ok "DiaAutoAllow reads Dia's windows through Accessibility ($st_detail, reported ${age}s ago)" ;;
        no-dia) ok "DiaAutoAllow is waiting for Dia to start" ;;
        denied) bad "DiaAutoAllow has no Accessibility access: $st_detail" \
                    "enable $(accessibility_owner) in System Settings > Privacy & Security > Accessibility, then re-run doctor" ;;
        *)      bad "DiaAutoAllow cannot read Dia's windows: ${st_detail:-$st_state}" \
                    "pm2 logs dia-auto-allow, or run: osascript $HERE/DiaAutoAllow.applescript" ;;
      esac
    fi
  fi
fi

# End to end: open a real CDP websocket to Dia with a hard timeout. This is what hangs when the
# consent sheet is not answered. It pops one consent sheet in Dia for about a second.
if [[ -n "$port" ]] && (( node_major >= 22 )) && [[ -f "$PORT_FILE" ]] && pgrep -x Dia >/dev/null; then
  ws_url="ws://127.0.0.1:$port$(sed -n 2p "$PORT_FILE")"
  if took="$(node -e '
    const t0 = Date.now();
    const finish = (code, msg) => { console.log(msg); process.exit(code); };
    const ws = new WebSocket(process.argv[1]);
    ws.onopen = () => finish(0, ((Date.now() - t0) / 1000).toFixed(1));
    ws.onerror = () => finish(1, "connection error");
    setTimeout(() => finish(2, "no answer"), Number(process.argv[2]) * 1000);
  ' "$ws_url" "$CDP_TIMEOUT" 2>&1)"; then
    ok "a CDP connection to Dia completed in ${took}s"
  else
    bad "a CDP connection to Dia did not complete within ${CDP_TIMEOUT}s ($took)" \
        "click Allow if Dia shows \"Allow debugging connection?\"; if the watcher check above is ok, kill stale clients with: pkill -9 -f agent-browser, then re-run doctor"
  fi
fi

exit "$fail"
