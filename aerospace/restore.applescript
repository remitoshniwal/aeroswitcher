-- restore.applescript
-- The "un-maximize" half of alt-f: resizes the focused window to 70%
-- of the screen's usable area, centered. Change the 0.7 below if you
-- want it bigger/smaller — it's just a plain number, no special syntax.
--
-- toggle-maximize.sh passes the focused window's AeroSpace ID, so the
-- right window is found even when it belongs to a helper process (Steam's
-- windows belong to "Steam Helper", not to the front app). See the
-- comment at the top of maximize.applescript. Without an ID it falls back
-- to the front app's front window, like before.
on run argv
    set winID to system attribute "AEROSPACE_WINDOW_ID"
    if (count of argv) > 0 then set winID to item 1 of argv as text

    tell application "Finder" to set screenBounds to bounds of window of desktop
    set screenW to (item 3 of screenBounds) - (item 1 of screenBounds)
    set screenH to (item 4 of screenBounds) - (item 2 of screenBounds)
    set restoredW to screenW * 0.7
    set restoredH to screenH * 0.7
    set restoredX to (item 1 of screenBounds) + (screenW - restoredW) / 2
    set restoredY to (item 2 of screenBounds) + (screenH - restoredH) / 2

    set {targetPID, targetTitle} to lookUpWindow(winID)
    if targetPID is missing value then
        tell application "System Events" to set targetPID to unix id of (first application process whose frontmost is true)
    end if
    set winIndex to focusedWindow(targetPID, targetTitle)
    if winIndex is not missing value then
        tell application "System Events"
            tell (first application process whose unix id is targetPID)
                set position of window winIndex to {restoredX, restoredY}
                set size of window winIndex to {restoredW, restoredH}
            end tell
        end tell
    end if
end run

-- Asks AeroSpace which process owns window <winID> and what its title is.
-- (Same handler as in maximize.applescript, keep the two in sync.)
on lookUpWindow(winID)
    if winID is "" then return {missing value, missing value}
    try
        set listing to do shell script "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; aerospace list-windows --all --format '%{window-id}|%{app-pid}|%{window-title}'"
    on error
        return {missing value, missing value}
    end try
    set oldDelims to AppleScript's text item delimiters
    set AppleScript's text item delimiters to "|"
    repeat with lineText in paragraphs of listing
        set parts to text items of lineText
        if (count of parts) is greater than or equal to 3 and item 1 of parts is winID then
            set thePID to (item 2 of parts) as integer
            set theTitle to (items 3 thru -1 of parts) as text
            set AppleScript's text item delimiters to oldDelims
            return {thePID, theTitle}
        end if
    end repeat
    set AppleScript's text item delimiters to oldDelims
    return {missing value, missing value}
end lookUpWindow

-- The number of the window with that title in that process's window
-- list. If several share the title, the app's main window (the one you're
-- on). Windows are referred to by process ID + number, never by title,
-- see pickWindow in maximize.applescript for why.
on focusedWindow(targetPID, targetTitle)
    set candidates to {}
    tell application "System Events"
        try
            tell (first application process whose unix id is targetPID)
                set winCount to count of windows
                if targetTitle is not missing value then
                    repeat with i from 1 to winCount
                        try
                            if name of window i is targetTitle then set end of candidates to i
                        end try
                    end repeat
                end if
                if candidates is {} and winCount > 0 then set candidates to {1}
                repeat with i in candidates
                    try
                        if (value of attribute "AXMain" of window (contents of i)) is true then return contents of i
                    end try
                end repeat
            end tell
        end try
    end tell
    if candidates is not {} then return item 1 of candidates
    return missing value
end focusedWindow
