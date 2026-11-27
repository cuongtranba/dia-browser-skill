# dia-browser-skill

An agent skill that lets [agent-browser](https://github.com/vercel-labs/agent-browser) drive the
**Dia browser you already use**, with every account you are already logged in to, instead of
launching a fresh Chrome that makes you sign in again.

It works with Claude Code, Codex, Kanna and any agent that loads skills from `~/.agents/skills`.
The skill sits next to the upstream `agent-browser` skill, which keeps updating on its own.

Version 0.2.0 (the `version` in `skills/dia-browser/SKILL.md`; `scripts/doctor.sh` prints it).
Report problems at https://github.com/cuongtranba/dia-browser-skill/issues and include the
doctor output.

> **Security warning.** This setup opens Dia to full remote control from any program on your
> machine, and auto-accepts Dia's "Allow debugging connection?" dialog. Anything that can reach
> `127.0.0.1:9222` gets your cookies, sessions and tabs. Use it only on a personal machine you
> trust, and turn remote debugging off when you do not need it.

## Install

```bash
npm i -g agent-browser                          # if not installed yet
npx skills add cuongtranba/dia-browser-skill    # installs the dia-browser skill
~/.agents/skills/dia-browser/scripts/install.sh # one-time machine setup
```

`install.sh` does two things, and is safe to re-run:

1. Starts **DiaAutoAllow**, a small AppleScript that checks Dia once a second and clicks
   **Allow** on the "Allow debugging connection?" sheet (and on nothing else). It needs macOS
   **Accessibility**, granted to the process macOS counts as responsible for the `osascript`
   that runs it:
   - **pm2** (default when `pm2` is installed): runs `osascript DiaAutoAllow.applescript watch`
     as the pm2 process `dia-auto-allow` (its pm2 `script path` is `/usr/bin/osascript`) with
     log timestamps that carry the UTC offset, and saves the pm2 list. pm2 starts it from its
     daemon, a `node` process, so the grant that counts is the one on **that daemon's `node`
     binary**, not on osascript. If that `node` is already enabled under Accessibility there is
     nothing to grant. It is not assumed: `install.sh` and `doctor.sh` check it, and `doctor.sh`
     names the exact binary when it is missing. pm2 must start at login (`pm2 startup`).
   - **app** (`DIA_AUTO_ALLOW_RUNNER=app`): builds `~/Applications/DiaAutoAllow.app`, a stay-open
     applet in Login Items. Add it under Privacy & Security → Accessibility with **+** and enable
     it. Every rebuild invalidates that grant, so the app is rebuilt only when the script changes.

   After starting, `install.sh` waits for the watcher to report whether it can read Dia's
   windows and prints a warning if it cannot.
2. Sets `"cdp": "9222"` in `~/.agent-browser/config.json`, so every `agent-browser` command
   targets Dia without a flag.

Then, in Dia, open `chrome://inspect/#remote-debugging` and turn on **Allow remote debugging for
this browser instance**. Repeat this after every Dia restart.

Check the whole chain any time:

```bash
~/.agents/skills/dia-browser/scripts/doctor.sh
```

Besides "is it running", doctor checks that the watcher can read Dia's windows through
Accessibility (the watcher writes its state to
`~/Library/Application Support/dia-browser-skill/watcher.status`) and that a real CDP connection
to Dia completes within 10 s (`DIA_CDP_TIMEOUT` changes the limit). That check opens one
throwaway connection, so Dia shows the consent sheet for about a second.

**Where the watcher logs.** `osascript` logs to stderr, so under pm2 every line is in
`~/.pm2/logs/dia-auto-allow-error.log` (`pm2 logs dia-auto-allow` shows it); the `-out.log` file
stays empty. That is normal, not a sign of errors: lines are prefixed `info:`, `warn:` or
`error:`. A state is logged once when it changes (Dia not running, Accessibility denied, an
unrecognised sheet), not once per second, and an allowed connection logs `info: allowed N
debugging connection(s)`.

**If a command hangs with no output**, see the Troubleshooting table in `SKILL.md`: kill stale
daemons with `pkill -9 -f agent-browser`, re-run doctor, and run agent-browser commands with a
timeout instead of retrying in a loop.

Uninstall with `scripts/uninstall.sh`. With the app runner, also remove DiaAutoAllow from the
Accessibility list.

## Other Dia profiles

Plain `agent-browser` drives Dia's main profile. For any other profile, `dia-profile.mjs` starts
a separate agent-browser session (`dia-<profile>`, headless unless `--headed`) and gives it that
profile's cookies, read live from Dia over CDP. Dia's windows are never touched, and several
profiles can run at once.

```bash
P=~/.agents/skills/dia-browser/scripts/dia-profile.mjs
$P list                               # profiles, loaded in Dia or not, running sessions
$P open cuong-dev https://github.com  # start or refresh a session; --headed to watch it
$P ab cuong-dev snapshot -i           # run any agent-browser command against the session
$P close cuong-dev
```

The profile must have an open window in Dia (CDP only sees loaded profiles). Only cookies are
copied, as a snapshot: sites that keep their login in localStorage may ask to log in, and a
login made in Dia later needs `open` again.

## How it got here

The goal: let a coding agent control the browser where I am already logged in, without logging
in again.

1. **Claude in Chrome did not work with Dia.** The Claude extension runs inside Dia, but
   `claude --chrome` registers its native messaging host
   (`com.anthropic.claude_code_browser_extension`) for Google Chrome only. Copying the manifest
   into `Dia/User Data/NativeMessagingHosts` did not make Dia pick it up, so Claude Code kept
   attaching to Chrome.
2. **`--remote-debugging-port` is not an option.** Dia is Chromium-based (Chromium 158), and since
   Chrome 136 that flag is ignored for the default profile, which is the one holding the logins.
3. **The supported path is in-browser remote debugging.** `chrome://inspect/#remote-debugging`
   makes Dia listen on `127.0.0.1:9222` with its real profile. `agent-browser --cdp 9222` then sees
   every open tab.
4. **Each new connection triggers a consent dialog.** Chromium asks "Allow debugging connection?"
   for every new CDP connection, and offers no setting or policy to always allow. The
   agent-browser daemon reuses its connection, but every new `--session` or daemon restart asks
   again.
5. **DiaAutoAllow answers it.** An AppleScript checks Dia once a second for a sheet whose
   heading is exactly "Allow debugging connection?" and clicks its Allow button. Fresh sessions
   now connect in 2–4 seconds instead of timing out after 90.
6. **The applet kept losing its Accessibility grant.** macOS ties the grant to the app's
   signature, so every rebuild of `DiaAutoAllow.app` silently revoked it, and adding the app
   back means a manual trip through System Settings. Running the same script as a pm2 process
   reuses the grant already on pm2's daemon `node` binary, so pm2 became the default runner.
7. **Other profiles cannot be reached through Dia's own windows safely.** CDP's
   `Target.createTarget` only accepts browser contexts CDP created, so it cannot open a tab in
   an existing profile, and Dia ignores `--profile-directory` (it starts a second instance on
   the same data folder instead). Switching profiles through Dia's Window menu works, but menu
   commands act on whatever window is in front, which changes while the user browses, and a
   switched window also pulls in that profile's saved tabs. A first version did this and twice
   switched the user's own window.
8. **Headless Dia cannot use a copied profile.** Dia runs headless, but a copy of the profile
   folder loses every login: its cookies are encrypted with the "Dia Safe Storage" Keychain key,
   which headless mode does not use, so 2919 of 2919 cookies failed to decrypt.
9. **Live cookies over CDP do work.** `Network.getAllCookies`, called in one of the profile's own
   tabs, returns that profile's cookies already decrypted. Setting them into a separate
   agent-browser browser with `Storage.setCookies` gives a session that is logged in as the
   profile, and nothing in Dia changes. The profile is found by matching those cookies against
   the profile's own `Cookies` database (host, name and path only, read-only).

## Layout

```
skills/dia-browser/
  SKILL.md                       # what the agent reads: rules, connection model, troubleshooting
  scripts/install.sh             # machine setup (idempotent)
  scripts/uninstall.sh           # reverses install.sh
  scripts/doctor.sh              # checks every link, prints the fix
  scripts/dia-profile.mjs        # per-profile agent-browser sessions with the profile's cookies
  scripts/DiaAutoAllow.applescript
```

## License

MIT
