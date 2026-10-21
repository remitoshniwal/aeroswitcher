-- maximize.applescript
-- Resizes the frontmost app's frontmost window to fill the screen's
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

tell application "Finder" to set screenBounds to bounds of window of desktop

tell application "System Events"
    tell (first application process whose frontmost is true)
        set position of window 1 to {item 1 of screenBounds, item 2 of screenBounds}
        set size of window 1 to {(item 3 of screenBounds) - (item 1 of screenBounds), (item 4 of screenBounds) - (item 2 of screenBounds)}
    end tell
end tell
