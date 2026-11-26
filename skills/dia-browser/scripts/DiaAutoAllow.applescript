-- Clicks "Allow" on Dia's "Allow debugging connection?" sheet, and on nothing else.
-- The process that runs it needs macOS Accessibility. Two runners:
--   osascript DiaAutoAllow.applescript watch   loops forever (install.sh runs this under pm2)
--   compiled as a stay-open applet             the idle handler polls every second
on clickDebugConsent()
	tell application "System Events"
		if not (exists process "Dia") then return 0
		set clicked to 0
		tell process "Dia"
			repeat with w in windows
				try
					repeat with s in (sheets of w)
						try
							set heading to value of text area 1 of scroll area 1 of s
							if heading is "Allow debugging connection?" then
								click button "Allow" of s
								set clicked to clicked + 1
							end if
						end try
					end repeat
				end try
			end repeat
		end tell
		return clicked
	end tell
end clickDebugConsent

on run argv
	set watching to false
	try
		set watching to (argv is {"watch"})
	end try
	if watching then
		repeat
			try
				set n to clickDebugConsent()
				if n > 0 then log "allowed " & n & " debugging connection(s)"
			on error errMsg
				log "error: " & errMsg
			end try
			delay 1
		end repeat
	else
		clickDebugConsent()
	end if
end run

on idle
	try
		clickDebugConsent()
	end try
	return 1
end idle
