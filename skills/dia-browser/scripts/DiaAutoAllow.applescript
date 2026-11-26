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

on run
	clickDebugConsent()
end run

on idle
	try
		clickDebugConsent()
	end try
	return 1
end idle
