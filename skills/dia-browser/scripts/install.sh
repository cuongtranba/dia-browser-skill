#!/usr/bin/env bash
# Sets up agent-browser to drive the Dia browser you already use, with your logins:
#   1. runs DiaAutoAllow, which clicks "Allow" on Dia's "Allow debugging connection?" sheet;
#   2. points agent-browser at Dia by default ("cdp": "9222" in ~/.agent-browser/config.json).
#
# DiaAutoAllow needs macOS Accessibility, granted to the process macOS counts as responsible
# for the osascript that runs it. Runners:
#   pm2 (default when pm2 is installed): `osascript DiaAutoAllow.applescript watch` as a pm2
#        process. pm2 starts it from its daemon (a node process, parent of osascript), so the
#        grant belongs to that daemon's node binary, not to the osascript pm2 lists as its
#        "script path". If that node is already under System Settings > Privacy & Security >
#        Accessibility there is nothing to grant. This script verifies it instead of assuming.
#   app: ~/Applications/DiaAutoAllow.app, a stay-open applet started at login. It needs its own
#        Accessibility grant, and a rebuild invalidates it, so it is rebuilt only when the
#        AppleScript changed.
# Choose with DIA_AUTO_ALLOW_RUNNER=pm2|app. Safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/DiaAutoAllow.applescript"
PM2_NAME="dia-auto-allow"
APP="$HOME/Applications/DiaAutoAllow.app"
PLIST="$APP/Contents/Info.plist"
BUNDLE_ID="io.github.dia-browser-skill.DiaAutoAllow"
CDP_PORT="${DIA_CDP_PORT:-9222}"
CONFIG="$HOME/.agent-browser/config.json"
STATUS_FILE="${DIA_AUTO_ALLOW_STATUS:-$HOME/Library/Application Support/dia-browser-skill/watcher.status}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ -d /Applications/Dia.app ]] || die "Dia is not installed in /Applications."
command -v agent-browser >/dev/null || die "agent-browser is not installed: npm i -g agent-browser"

runner="${DIA_AUTO_ALLOW_RUNNER:-}"
if [[ -z "$runner" ]]; then
  command -v pm2 >/dev/null && runner=pm2 || runner=app
fi
[[ "$runner" == pm2 || "$runner" == app ]] || die "DIA_AUTO_ALLOW_RUNNER must be pm2 or app, got: $runner"

remove_app() {
  pkill -f "$APP/Contents/MacOS/applet" 2>/dev/null || true
  osascript -e 'tell application "System Events" to delete (every login item whose name is "DiaAutoAllow")' >/dev/null 2>&1 || true
  rm -rf "$APP"
}

install_pm2() {
  command -v pm2 >/dev/null || die "pm2 is not installed: npm i -g pm2 (or DIA_AUTO_ALLOW_RUNNER=app)"
  [[ -d "$APP" ]] && { say "Removing the DiaAutoAllow.app runner"; remove_app; }
  pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
  # pm2's default log prefix is local time without an offset; add the offset so lines are unambiguous.
  pm2 start osascript --name "$PM2_NAME" --log-date-format "YYYY-MM-DD HH:mm:ss Z" -- "$SRC" watch >/dev/null
  pm2 save >/dev/null
  say "DiaAutoAllow runs under pm2 as \"$PM2_NAME\"."
  say "Logs: pm2 logs $PM2_NAME. osascript logs to stderr, so every line is in the error log"
  say "(~/.pm2/logs/$PM2_NAME-error.log) and the out log stays empty. That is normal."
  say "Make pm2 start at login: pm2 startup."
}

install_app() {
  pm2 delete "$PM2_NAME" >/dev/null 2>&1 && pm2 save >/dev/null 2>&1 || true
  local src_hash installed_hash
  src_hash="$(shasum -a 256 "$SRC" | cut -d' ' -f1)"
  installed_hash="$(/usr/libexec/PlistBuddy -c 'Print :DiaAutoAllowSourceHash' "$PLIST" 2>/dev/null || true)"
  if [[ "$src_hash" == "$installed_hash" ]]; then
    say "DiaAutoAllow.app is up to date."
  else
    say "Building $APP"
    remove_app
    mkdir -p "$(dirname "$APP")"
    osacompile -s -o "$APP" "$SRC"
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :DiaAutoAllowSourceHash string $src_hash" "$PLIST"
    codesign --force --sign - "$APP" >/dev/null 2>&1
    say "Grant Accessibility: System Settings > Privacy & Security > Accessibility, click +,"
    say "choose $APP and enable it."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  fi
  if ! osascript -e 'tell application "System Events" to get the name of every login item' | grep -q DiaAutoAllow; then
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP\", hidden:true}" >/dev/null
  fi
  pgrep -f "$APP/Contents/MacOS/applet" >/dev/null || open "$APP"
  say "DiaAutoAllow.app is running and starts at login."
}

# Waits for the fresh watcher to report what it sees through Accessibility, and says so. The
# grant belongs to the watcher's own process, so only the watcher can tell.
verify_watcher() {
  rm -f "$STATUS_FILE"
  local i state detail
  for i in $(seq 1 15); do
    [[ -f "$STATUS_FILE" ]] && break
    sleep 1
  done
  if [[ ! -f "$STATUS_FILE" ]]; then
    say "WARNING: DiaAutoAllow did not report within 15 s. Check: $HERE/doctor.sh"
    return 0
  fi
  IFS=$'\t' read -r _ state detail < "$STATUS_FILE" || true
  case "$state" in
    ok)     say "Verified: DiaAutoAllow reads Dia's windows through Accessibility ($detail)." ;;
    no-dia) say "DiaAutoAllow is waiting for Dia to start; run $HERE/doctor.sh once Dia is open to verify Accessibility." ;;
    denied) say "WARNING: DiaAutoAllow has no Accessibility access ($detail)."
            say "Enable the process that runs it in System Settings > Privacy & Security > Accessibility,"
            say "then run $HERE/doctor.sh (it names the exact process)." ;;
    *)      say "WARNING: DiaAutoAllow cannot read Dia's windows: ${detail:-$state}. Check: $HERE/doctor.sh" ;;
  esac
}

"install_$runner"
verify_watcher

say "Setting \"cdp\": \"$CDP_PORT\" in $CONFIG"
mkdir -p "$(dirname "$CONFIG")"
osascript -l JavaScript - "$CONFIG" "$CDP_PORT" <<'JXA' >/dev/null
ObjC.import("Foundation");
function run(argv) {
  const [path, port] = argv;
  let cfg = {};
  if ($.NSFileManager.defaultManager.fileExistsAtPath(path)) {
    const raw = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js;
    if (raw && raw.trim()) cfg = JSON.parse(raw);
  }
  cfg.cdp = port;
  $(JSON.stringify(cfg, null, 2) + "\n").writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
JXA

cat <<EOF
==> Last manual step, once per Dia launch:
    open chrome://inspect/#remote-debugging in Dia and turn on
    "Allow remote debugging for this browser instance".
==> Check everything with: $HERE/doctor.sh
EOF
