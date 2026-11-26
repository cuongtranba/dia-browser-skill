#!/usr/bin/env bash
# Reverses install.sh: stops DiaAutoAllow (pm2 process or app and its login item)
# and removes the "cdp" default from ~/.agent-browser/config.json.
set -euo pipefail

APP="$HOME/Applications/DiaAutoAllow.app"
CONFIG="$HOME/.agent-browser/config.json"

if command -v pm2 >/dev/null && pm2 delete dia-auto-allow >/dev/null 2>&1; then
  pm2 save >/dev/null
fi
pkill -f "$APP/Contents/MacOS/applet" 2>/dev/null || true
osascript -e 'tell application "System Events" to delete (every login item whose name is "DiaAutoAllow")' >/dev/null 2>&1 || true
rm -rf "$APP"

if [[ -f "$CONFIG" ]]; then
  osascript -l JavaScript - "$CONFIG" <<'JXA' >/dev/null
ObjC.import("Foundation");
function run(argv) {
  const path = argv[0];
  const raw = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
  const cfg = raw && raw.trim() ? JSON.parse(raw) : {};
  delete cfg.cdp;
  $(JSON.stringify(cfg, null, 2) + "\n").writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
JXA
fi

echo "==> Removed DiaAutoAllow and the agent-browser cdp default."
echo "==> If you used the app runner, also remove DiaAutoAllow from System Settings > Privacy & Security > Accessibility."
echo "==> Turn off remote debugging in Dia at chrome://inspect/#remote-debugging."
