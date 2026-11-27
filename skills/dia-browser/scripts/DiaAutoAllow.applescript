-- Clicks "Allow" on Dia's "Allow debugging connection?" sheet, and on nothing else.
--
-- The process that runs it needs macOS Accessibility. Two runners:
--   osascript DiaAutoAllow.applescript watch   loops forever (install.sh runs this under pm2)
--   compiled as a stay-open applet             the idle handler polls every second
--
-- Observability. The script never fails silently:
--   * `log` writes to stderr, so under pm2 every line lands in dia-auto-allow-error.log
--     (dia-auto-allow-out.log stays empty). Lines are prefixed info:/warn:/error:.
--   * A state is logged once, when it changes, never once per second.
--   * Every state is also written to a status file (one line: epoch, state, detail), refreshed
--     every 10 s, which doctor.sh reads. It proves what a shell cannot: that the process that
--     really runs the watcher has Accessibility access to Dia. Override the path with the
--     DIA_AUTO_ALLOW_STATUS environment variable.
-- States: ok (Dia's windows are readable), no-dia (Dia not running), denied (no Accessibility
-- grant), error (anything else).

property lastKey : ""
property lastWrite : 0
property lastWriteFailure : ""
property heartbeatSeconds : 10

on statusPath()
	set override to system attribute "DIA_AUTO_ALLOW_STATUS"
	if override is not "" then return override
	return (system attribute "HOME") & "/Library/Application Support/dia-browser-skill/watcher.status"
end statusPath

on epochText()
	return do shell script "date +%s"
end epochText

on writeStatus(theState, theDetail)
	try
		set p to statusPath()
		set theLine to epochText() & tab & theState & tab & theDetail
		do shell script "mkdir -p " & quoted form of (do shell script "dirname " & quoted form of p) & " && printf '%s\\n' " & quoted form of theLine & " > " & quoted form of p
		set lastWrite to epochText() as integer
		set lastWriteFailure to ""
	on error errMsg
		-- Retried every tick, logged once per distinct failure.
		if errMsg is not lastWriteFailure then log "warn: cannot write the status file: " & errMsg
		set lastWriteFailure to errMsg
	end try
end writeStatus

-- Scans Dia once and returns {state, detail, notes, clicked}. Clicks only a sheet whose heading
-- is exactly "Allow debugging connection?"; any other sheet is reported in notes, never clicked.
on scan()
	set clicked to 0
	set notes to {}
	set windowCount to 0
	set sheetCount to 0
	tell application "System Events"
		if not (exists process "Dia") then return {"no-dia", "Dia is not running", {}, 0}
		try
			tell process "Dia"
				set ws to windows
				set windowCount to count of ws
				repeat with w in ws
					set ss to sheets of w
					repeat with s in ss
						set sheetCount to sheetCount + 1
						set heading to missing value
						try
							set heading to value of text area 1 of scroll area 1 of s
						on error errMsg
							set end of notes to "a sheet is open but its heading cannot be read (" & errMsg & ")"
						end try
						if heading is "Allow debugging connection?" then
							try
								click button "Allow" of s
								set clicked to clicked + 1
							on error errMsg
								set end of notes to "found the consent sheet but clicking Allow failed (" & errMsg & ")"
							end try
						else if heading is not missing value then
							set end of notes to "ignored a sheet titled \"" & heading & "\""
						end if
					end repeat
				end repeat
			end tell
		on error errMsg number errNum
			if errNum is -25211 or errMsg contains "assistive access" then
				return {"denied", errMsg, {}, 0}
			end if
			return {"error", errMsg, {}, 0}
		end try
	end tell
	return {"ok", "windows=" & windowCount & " sheets=" & sheetCount, notes, clicked}
end scan

-- One poll: scan, click, and log only when the state changed.
on tick()
	set r to scan()
	set theState to item 1 of r
	set theDetail to item 2 of r
	set theNotes to item 3 of r
	set n to item 4 of r
	if n > 0 then log "info: allowed " & n & " debugging connection(s)"

	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "; "
	set noteText to theNotes as text
	set AppleScript's text item delimiters to oldDelims
	set theKey to theState & "|" & noteText
	if theKey is not lastKey then
		set lastKey to theKey
		if theState is "ok" then
			log "info: watching Dia through Accessibility"
			if noteText is not "" then log "warn: " & noteText
		else if theState is "no-dia" then
			log "info: Dia is not running, waiting for it"
		else if theState is "denied" then
			log "error: macOS Accessibility denied (" & theDetail & "). Enable the process that runs this script in System Settings > Privacy & Security > Accessibility."
		else
			log "error: cannot read Dia's windows (" & theDetail & ")"
		end if
		writeStatus(theState, theDetail)
	else if ((epochText() as integer) - lastWrite) >= heartbeatSeconds then
		writeStatus(theState, theDetail)
	end if
end tick

on run argv
	set watching to false
	try
		set watching to (argv is {"watch"})
	end try
	if watching then
		repeat
			try
				tick()
			on error errMsg
				log "error: " & errMsg
			end try
			delay 1
		end repeat
	else
		tick()
	end if
end run

on idle
	try
		tick()
	on error errMsg
		log "error: " & errMsg
	end try
	return 1
end idle
