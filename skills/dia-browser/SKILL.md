---
name: dia-browser
description: Drives the user's own running Dia browser (with all their logged-in accounts) through agent-browser over CDP instead of launching a fresh Chrome. Use whenever a browser task needs the user's existing sessions — Gmail, GitHub, Cloudflare, dashboards, anything they are already signed in to — or the user mentions Dia, "my browser", "my tabs", "đang login sẵn", or complains that agent-browser keeps opening Chrome and asking them to log in again. Also use when a task needs a specific Dia profile (another account, "profile cuong-dev", "dùng profile khác"): scripts/dia-profile.mjs gives that profile its own headless agent-browser session with the profile's live cookies, without touching Dia's windows. Also use to diagnose "Operation timed out", "connection refused" on port 9222, a stuck "Allow debugging connection?" dialog, or to install/uninstall the DiaAutoAllow helper. Load the agent-browser skill for the command reference; this skill covers only connecting to Dia.
---

# dia-browser

agent-browser drives the user's real Dia browser over the Chrome DevTools Protocol. Every
logged-in account in Dia is available, so never ask the user to log in again and never launch
a separate Chrome for these tasks.

For the commands themselves (snapshot, click, fill, wait…) run `agent-browser skills get core`.

## How the connection works

| Link | State when healthy |
| --- | --- |
| Dia remote debugging | On at `chrome://inspect/#remote-debugging`; Dia listens on `127.0.0.1:9222` |
| agent-browser default | `~/.agent-browser/config.json` has `"cdp": "9222"`, so no flag is needed |
| Consent dialog | Dia asks "Allow debugging connection?" for every **new** CDP connection; DiaAutoAllow (pm2 process `dia-auto-allow`, or `DiaAutoAllow.app`) clicks Allow within about a second |

## Before the first command

Run `scripts/doctor.sh` (in this skill's folder). It checks every link above and prints the
fix for the first broken one. If the helper was never installed, run `scripts/install.sh`.

## Rules

- **Do not close the browser.** `agent-browser close` on a CDP session only detaches the
  agent-browser daemon; never run anything that quits Dia or closes tabs you did not open.
- **Open your own tab.** Use `agent-browser tab new <url>` for work and close only that tab when
  done. The user is browsing in the same window; acting on their active tab can clobber what
  they are doing. A new tab always lands in Dia's default profile; for another profile use
  `scripts/dia-profile.mjs` (below).
- **Never drive Dia's menus or switch a window's profile.** The user browses in Dia while you
  work, so the front window can change under you, and switching a window's profile also
  restores that profile's tabs into it. Profile work goes through `dia-profile.mjs`, which
  only reads cookies from Dia.
- **Reuse the default session.** Every new `--session <name>` opens a new CDP connection and
  triggers one consent dialog. DiaAutoAllow handles it, but reusing the default session is
  faster.
- **Treat it as the user's real accounts.** Sending mail, posting, paying, deleting or
  changing settings acts as the user. Confirm before any outward-facing or irreversible action.

## Other Dia profiles

`scripts/dia-profile.mjs` runs a profile in its own agent-browser session, `dia-<profile>`,
headless by default. It reads that profile's cookies from the running Dia over CDP (read-only,
already decrypted, never written to disk) and sets them into the session, so the session is
logged in as that profile while Dia's windows stay untouched. Sessions of different profiles
run side by side.

```bash
P=~/.agents/skills/dia-browser/scripts/dia-profile.mjs
$P list                                   # profiles, loaded in Dia or not, running sessions
$P open cuong-dev https://github.com      # start or refresh the session (add --headed to watch)
$P ab cuong-dev snapshot -i               # any agent-browser command, against that session
$P ab cuong-dev click @e3
$P close cuong-dev                        # stop the session when done
```

- **Always go through `ab`.** It adds `--config` (an empty config) and `--session dia-<profile>`.
  A plain `agent-browser --session dia-<profile> …` picks up the user config's `"cdp": "9222"`
  and re-attaches that session to Dia.
- **The profile must be loaded in Dia.** CDP only sees profiles that have an open Dia window.
  If `open` reports the profile is not loaded, ask the user to open a Dia window with it
  (File → New Window, then Window → Space 1 → the profile); do not do it yourself.
- **Names:** use the profile's name from `list`, or `Default` for the main profile. Dia profiles
  that share the main profile's data (for example "AI" and "Space 1") are `Default` here.
- **Cookies only, and a snapshot.** Logins kept in localStorage do not carry over, and logins
  made in Dia later need `open` again (it refreshes cookies and keeps the session's pages).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Operation timed out` on the first command | Consent dialog waiting and DiaAutoAllow not running or lacking Accessibility | Run `scripts/doctor.sh`; check `pm2 logs dia-auto-allow` for errors; the runner's process (`node` for pm2, or `DiaAutoAllow.app`) must be enabled in System Settings → Privacy & Security → Accessibility |
| Connection refused on 9222 | Dia was restarted and remote debugging is off | Ask the user to re-enable it at `chrome://inspect/#remote-debugging` |
| agent-browser opens a new Chrome | `cdp` missing from `~/.agent-browser/config.json` | `scripts/install.sh`, or pass `--cdp 9222` |
| `Dia has not loaded profile "…"` | No Dia window uses that profile | Ask the user to open one (File → New Window, then switch it to the profile) |
| A profile session shows Dia's tabs | It was called without `ab`, so it re-attached to Dia | `dia-profile.mjs close <profile>`, then `open` again and use `ab` only |
| A site in a profile session asks to log in | That site keeps its login in localStorage, or the login is newer than the session | Run `open` again; if it still asks, do that task in Dia itself |
| Needs a clean, logged-out browser (QA) | The Dia default is wrong for this task | Bypass the user config: `echo '{}' > /tmp/ab-clean.json` then `agent-browser --config /tmp/ab-clean.json --session qa …` |

## Why not Claude in Chrome

`claude --chrome` registers its native messaging host for Google Chrome only, and Dia does not
pick up a host copied into its own `NativeMessagingHosts` folder, so Claude Code cannot reach
the Claude extension inside Dia. CDP through agent-browser is the path that works.
