-- maximize.applescript
-- Resizes a new window (or, from alt-f, the focused one) to fill the screen's
-- usable area (below the menu bar, avoiding the Dock). Only works
-- sensibly on a FLOATING window (see ~/.aerospace.toml's on-window-detected
-- and alt-f) — a tiled window would just get snapped back to its tiled
-- size by AeroSpace immediately, since AeroSpace continuously enforces
-- tiled windows' geometry and ignores anything else that tries to move
-- them.
--
-- Requires Accessibility permission the first time it runs (System
-- Settings > Privacy & Security > Accessibility) — macOS will prompt for
-- this automatically. If windows aren't resizing and nothing else looks
-- wrong, check that permission got granted.
--
-- WHICH window: the one AeroSpace just detected, not simply "window 1 of
-- the front app". AeroSpace hands every script it runs the window's ID in
-- the AEROSPACE_WINDOW_ID environment variable (the same one the
-- on-focus-changed line in ~/.aerospace.toml uses). The ID is looked up
-- with `aerospace list-windows` to get the app's process and the window's
-- title, and the window is then found inside that process. This matters
-- for two cases that "window 1 of the front app" got wrong:
--   - Steam: its windows belong to a helper process ("Steam Helper"),
--     while the front app is the main Steam process, whose only window
--     is invisible and 1x1. The old way only ever resized that.
--   - two windows opening at once: both runs grabbed the same front
--     window, so one window never grew.
-- (The second case only partly: Notion puts its own saved window size
-- back right after launch, undoing the resize. Notion's doing, not ours.)
-- With no ID at all (run by hand) it falls back to the old way.
--
-- Dialogs are skipped. AeroSpace runs this for every new window, popups
-- included, so without a check an Open dialog or the Fonts panel got
-- stretched over the whole screen. A window counts as real if it has a
-- green full screen button, OR macOS says it can go full screen at all
-- (its AXFullScreen setting can be changed). The second half is for apps
-- that hide the button and draw their own title bar, like Steam. Every
-- real window tested passed (native apps, Electron apps like Notion/VS
-- Code/Obsidian, Spotify, Steam, second windows of the same app), and
-- every dialog tested failed both (Open, Fonts, Settings, Print, Get Info,
-- Connect to Server, Word's Font and Settings, Obsidian's vault switcher,
-- Affinity's Welcome screen, Steam's sign in and Special Offers popups).
-- The more obvious checks were tried first and fail:
--   - the window's "subrole" label: TextEdit's Open dialog calls itself a
--     standard window, and real Terminal windows were seen calling
--     themselves dialogs, so this would skip real windows
--   - "can it be resized": the Open dialog and the Fonts panel can be
--   - "is it modal": most dialogs that got maximized were not
-- Counting the app's windows was rejected earlier because it also skipped
-- second real windows opened on purpose (see ROADMAP.md).
--
-- The check is retried for up to about a second because this runs the
-- moment a window appears, and an app might add its buttons a moment
-- later. A real window gets maximized as soon as it passes, a dialog just
-- waits out the second and is left alone.
--
-- alt-f (toggle-maximize.sh) runs this as `osascript maximize.applescript
-- force <window id>`, which skips the check. Pressing alt-f is you
-- deciding, so it should always work. If an app's real windows ever stop
-- maximizing on their own, alt-f twice (shrink, then grow) still does it.

on run argv
    -- argv is the list of words after the file name on the osascript line:
    -- nothing when AeroSpace runs this for a new window, "force" plus the
    -- window ID when alt-f runs it.
    set forced to false
    set winID to system attribute "AEROSPACE_WINDOW_ID"
    repeat with arg in argv
        if (arg as text) is "force" then
            set forced to true
        else
            set winID to arg as text
        end if
    end repeat

    try
        maximizeWindow(winID, forced)
    end try
end run

on maximizeWindow(winID, forced)
    tell application "Finder" to set screenBounds to bounds of window of desktop
    -- The script can start before AeroSpace has finished registering the
    -- new window, so its ID isn't in `aerospace list-windows` yet. Ask again
    -- for up to about a second. If there is an ID but it never shows up,
    -- do nothing: falling back to "the front app" here was seen resizing a
    -- window of a different app (Obsidian) while Notion was opening.
    -- Only with no ID at all (run by hand) is the front app used.
    set {targetPID, targetTitle} to lookUpWindow(winID)
    if winID is not "" then
        repeat 10 times
            if targetPID is not missing value then exit repeat
            delay 0.1
            set {targetPID, targetTitle} to lookUpWindow(winID)
        end repeat
        if targetPID is missing value then return
    else
        tell application "System Events" to set targetPID to unix id of (first application process whose frontmost is true)
    end if

    set winIndex to missing value
    repeat 10 times
        set winIndex to pickWindow(targetPID, targetTitle, forced, screenBounds)
        if winIndex is not missing value or forced then exit repeat
        delay 0.1
    end repeat

    if winIndex is not missing value then
        tell application "System Events"
            tell (first application process whose unix id is targetPID)
                set position of window winIndex to {item 1 of screenBounds, item 2 of screenBounds}
                set size of window winIndex to {(item 3 of screenBounds) - (item 1 of screenBounds), (item 4 of screenBounds) - (item 2 of screenBounds)}
            end tell
        end tell
    end if
end maximizeWindow

-- Asks AeroSpace which process owns window <winID> and what its title is.
-- Returns {process id, title}, or {missing value, missing value} if there
-- is no ID or AeroSpace doesn't know it. GUI scripts don't get the
-- Terminal's PATH, so the two places Homebrew installs aerospace are added.
-- (Same handler as in restore.applescript, keep the two in sync.)
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
            -- a title can itself contain "|", so glue the rest back together
            set theTitle to (items 3 thru -1 of parts) as text
            set AppleScript's text item delimiters to oldDelims
            return {thePID, theTitle}
        end if
    end repeat
    set AppleScript's text item delimiters to oldDelims
    return {missing value, missing value}
end lookUpWindow

-- Finds the window to resize and returns its number in that process's
-- window list, or missing value to leave it alone. Windows are matched by
-- title inside the right process, because AppleScript has no way to look
-- a window up by AeroSpace's ID directly. Everything below refers to
-- windows by process ID + number, never by title: System Events likes to
-- hand back `window "<title>"`, which silently means "the FIRST window
-- with that title" and would resize the wrong one when titles repeat.
-- When several windows share the title (two Notion windows both called
-- "New page"), a new window is the first real one that is NOT already
-- maximized, so the second of two windows opening together still grows.
-- With alt-f (forced) it is the app's main window, the one you're on.
on pickWindow(targetPID, targetTitle, forced, screenBounds)
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
                -- title not found (it can change a moment after the window
                -- appears, Notion goes from "Notion" to the page name): fall
                -- back to the process's front window
                if candidates is {} and winCount > 0 then set candidates to {1}
            end tell
        end try
    end tell

    if forced then
        repeat with i in candidates
            if my isMain(targetPID, contents of i) then return contents of i
        end repeat
        if candidates is not {} then return item 1 of candidates
        return missing value
    end if

    repeat with i in candidates
        if my isRealWindow(targetPID, contents of i) and not my isMaximized(targetPID, contents of i, screenBounds) then return contents of i
    end repeat
    return missing value
end pickWindow

on isMain(targetPID, i)
    tell application "System Events"
        try
            return (value of attribute "AXMain" of window i of (first application process whose unix id is targetPID)) is true
        end try
    end tell
    return false
end isMain

-- The dialog check described at the top. The button is asked for as "is
-- there a button whose subrole is the full screen one" rather than by
-- reading the AXFullScreenButton attribute, because reading the attribute
-- makes System Events find the window again BY TITLE (see pickWindow).
on isRealWindow(targetPID, i)
    tell application "System Events"
        tell (first application process whose unix id is targetPID)
            try
                if exists (first button of window i whose subrole is "AXFullScreenButton") then return true
            end try
            try
                if settable of attribute "AXFullScreen" of window i then return true
            end try
        end tell
    end tell
    return false
end isRealWindow

-- Already filling the screen (within 2 pixels, Prism Launcher opens 2px
-- short)? Then there is nothing to do for this window.
on isMaximized(targetPID, i, screenBounds)
    try
        tell application "System Events"
            tell (first application process whose unix id is targetPID)
                set {x, y} to position of window i
                set {wide, high} to size of window i
            end tell
        end tell
    on error
        return false
    end try
    set fullW to (item 3 of screenBounds) - (item 1 of screenBounds)
    set fullH to (item 4 of screenBounds) - (item 2 of screenBounds)
    return (my near(x, item 1 of screenBounds) and my near(y, item 2 of screenBounds) and my near(wide, fullW) and my near(high, fullH))
end isMaximized

on near(a, b)
    return ((a - b) is less than or equal to 2 and (b - a) is less than or equal to 2)
end near
