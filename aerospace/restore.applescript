-- restore.applescript
-- The "un-maximize" half of alt-f: resizes the frontmost window to 70%
-- of the screen's usable area, centered. Change the 0.7 below if you
-- want it bigger/smaller — it's just a plain number, no special syntax.

tell application "Finder" to set screenBounds to bounds of window of desktop

set screenW to (item 3 of screenBounds) - (item 1 of screenBounds)
set screenH to (item 4 of screenBounds) - (item 2 of screenBounds)
set restoredW to screenW * 0.7
set restoredH to screenH * 0.7
set restoredX to (item 1 of screenBounds) + (screenW - restoredW) / 2
set restoredY to (item 2 of screenBounds) + (screenH - restoredH) / 2

tell application "System Events"
    tell (first application process whose frontmost is true)
        set position of window 1 to {restoredX, restoredY}
        set size of window 1 to {restoredW, restoredH}
    end tell
end tell
