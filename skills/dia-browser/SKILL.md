---
name: dia-browser
description: Drives the user's own running Dia browser (with all their logged-in accounts) through agent-browser over CDP instead of launching a fresh Chrome. Use whenever a browser task needs the user's existing sessions — Gmail, GitHub, Cloudflare, dashboards, anything they are already signed in to — or the user mentions Dia, "my browser", "my tabs", "đang login sẵn", or complains that agent-browser keeps opening Chrome and asking them to log in again. Also use to diagnose "Operation timed out", "connection refused" on port 9222, a stuck "Allow debugging connection?" dialog, or to install/uninstall the DiaAutoAllow helper. Load the agent-browser skill for the command reference; this skill covers only connecting to Dia.
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
  they are doing.
- **Reuse the default session.** Every new `--session <name>` opens a new CDP connection and
  triggers one consent dialog. DiaAutoAllow handles it, but reusing the default session is
  faster.
- **Treat it as the user's real accounts.** Sending mail, posting, paying, deleting or
  changing settings acts as the user. Confirm before any outward-facing or irreversible action.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Operation timed out` on the first command | Consent dialog waiting and DiaAutoAllow not running or lacking Accessibility | Run `scripts/doctor.sh`; check `pm2 logs dia-auto-allow` for errors; the runner's process (`node` for pm2, or `DiaAutoAllow.app`) must be enabled in System Settings → Privacy & Security → Accessibility |
| Connection refused on 9222 | Dia was restarted and remote debugging is off | Ask the user to re-enable it at `chrome://inspect/#remote-debugging` |
| agent-browser opens a new Chrome | `cdp` missing from `~/.agent-browser/config.json` | `scripts/install.sh`, or pass `--cdp 9222` |
| Needs a clean, logged-out browser (QA) | The Dia default is wrong for this task | Bypass the user config: `echo '{}' > /tmp/ab-clean.json` then `agent-browser --config /tmp/ab-clean.json --session qa …` |

## Why not Claude in Chrome

`claude --chrome` registers its native messaging host for Google Chrome only, and Dia does not
pick up a host copied into its own `NativeMessagingHosts` folder, so Claude Code cannot reach
the Claude extension inside Dia. CDP through agent-browser is the path that works.
