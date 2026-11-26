#!/usr/bin/env bash
# Reports each link in the agent-browser -> Dia chain and how to fix the first broken one.
set -uo pipefail

APP="$HOME/Applications/DiaAutoAllow.app"
PORT_FILE="$HOME/Library/Application Support/Dia/User Data/DevToolsActivePort"
CONFIG="$HOME/.agent-browser/config.json"
fail=0

ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n        fix: %s\n' "$1" "$2"; fail=1; }

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

if command -v pm2 >/dev/null && pm2 describe dia-auto-allow 2>/dev/null | grep -q 'status.*online'; then
  ok "DiaAutoAllow is running under pm2 (pm2 logs dia-auto-allow)"
elif pgrep -f "$APP/Contents/MacOS/applet" >/dev/null; then
  ok "DiaAutoAllow.app is running"
else
  bad "DiaAutoAllow is not running" "$(dirname "$0")/install.sh"
fi

exit "$fail"
