# AeroSwitcher Documentation

## What it is

AeroSwitcher is a custom replacement for macOS's Cmd+Tab, built as a small Swift/SwiftUI app. The default Cmd+Tab cycles through every open app on the whole Mac. AeroSwitcher instead only shows windows in whatever AeroSpace workspace you're currently on, since AeroSpace already organizes your apps into groups (Core, School, Personal, Creative, Dev, Gaming) and jumping between windows in a totally different group rarely makes sense.

It's a Swift Package Manager project, wrapped into a real `.app` bundle so macOS treats it as a proper application (needed for it to be grantable in System Settings for the permissions it needs, and to run quietly in the background without a Dock icon).

## How it's put together

The whole app lives in one file, `main.swift`. There's no separate UI framework project, no storyboard, just:

- Cocoa and AppKit for the low level system hooks (intercepting Cmd+Tab, creating a floating window)
- SwiftUI for drawing the actual panel of thumbnails
- ScreenCaptureKit for taking window screenshots
- The `aerospace` command line tool, called as a subprocess, for everything workspace-related (listing windows, focusing a window, checking which workspace is active)

Nothing about this app modifies AeroSpace itself. It just asks AeroSpace questions ("what windows are open right now") and tells it what to do ("focus this window"), the same way you could from Terminal.

## The pieces, one at a time

### Intercepting Cmd+Tab

`HotkeyManager` uses a `CGEventTap`, a low level hook that sees every keystroke on the Mac before any app does. When it sees Tab pressed while Cmd is held, it swallows that keystroke (so the real system switcher never sees it and never opens) and tells `SwitcherWindowController` to open instead. When Cmd is released, it tells the controller the session is over.

This requires the **Input Monitoring** permission (System Settings > Privacy & Security > Input Monitoring). Without it, the event tap silently fails to see anything.

### Getting the window list

`getWindowsInCurrentWorkspace()` runs `aerospace list-windows --workspace focused` and parses the output into a list of windows (id, app name, title). `focusWindow(id:)` runs `aerospace focus --window-id <id>` to actually switch to a window once you pick one. `getCurrentWorkspaceName()` runs `aerospace list-workspaces --focused` to find out which workspace (Core, Gaming, etc.) you're currently on, which the launcher tiles feature (below) needs.

### Taking the screenshots

Each window's thumbnail is a real screenshot, taken fresh every single time you open the switcher. There's no cache and no live video feed, `captureThumbnail` calls `SCScreenshotManager.captureImage`, a one shot snapshot, once per window, and all the windows are captured in parallel (not one after another) to keep things fast.

A live, constantly updating preview was tried and removed. Some apps, most notably Spotify, are protected by DRM at the hardware/GPU level on macOS, below every screen capture API that exists (ScreenCaptureKit, QuickTime, the old CGWindowListCreateImage). There's no workaround for this, confirmed through research into how other developers have hit the exact same wall. Since a live view couldn't work for every app, static screenshots for every app was the more honest, consistent choice.

Screenshots are captured directly at the small size they'll actually be shown at (220 x 140 points, scaled up for Retina displays), not at the window's full native resolution and then shrunk down. That's the main reason captures are fast even though the app never caches anything.

### Remembering which window you used last

`MRUTracker` reads from `/tmp/aerospace-mru/`, one small log file per workspace (`Core.log`, `Gaming.log`, and so on), that AeroSpace itself appends a window ID to every time focus changes within that workspace (set up via the `on-focus-changed` line in `~/.aerospace.toml`). This is how the switcher knows to put your most recently used windows first, in the same order the real Cmd+Tab does, instead of some arbitrary order.

It's split per workspace rather than one shared log for the whole Mac for two reasons. First, each file grows by one line every focus change forever with nothing to trim it, so `MRUTracker` only ever keeps the most recent 300 window IDs per workspace and rewrites a file back down to size once it's grown enough to be worth the trouble, the same fix as before, just scoped per file now. Second, and more importantly, it fixes a real accuracy problem: with one shared history, heavily switching windows in whatever workspace you're using right now could push an older, less-visited workspace's own window IDs out of the remembered set entirely, so by the time you switched back to it, its recency order would already be forgotten. Separate files mean each workspace only ever competes with its own past, not everyone else's.

Since AeroSpace's hook only hands the callback the window ID directly, not which workspace it's in, the `on-focus-changed` command makes one extra `aerospace list-workspaces --focused` call to figure out which file to append to. That's a small bit of extra background work on every ordinary window click (not just when the switcher opens), but it runs fire-and-forget and never blocks anything you're doing, so it isn't something you'd notice.

### Launcher tiles for apps that aren't open yet

Alongside your real open windows, the switcher can show a row of grayed out tiles for apps that belong to your current workspace but don't have a window here. For example, if you're on the Creative workspace and only Affinity is open, Ableton Live still gets a tile there so you can jump straight to launching it.

A grayed out tile actually covers two different situations: the app might be fully quit, or it might already be running fine, just with no window in this particular workspace (it could have one open elsewhere, or none at all). Those lead to different outcomes when you click the tile, so each one shows a small dot under its icon (the same convention as the Dock) plus a "Running" or "Quit" label, computed by `isAppRunning()` checking `NSWorkspace.shared.runningApplications` for a process matching that app.

This is driven by the `"workspaces"` section of `~/Library/Application Support/AeroSwitcher/config.json` (see **Config file**, below), which lists which apps belong to each workspace. It loosely mirrors the same grouping in `~/.aerospace.toml`'s `on-window-detected` rules, but **the two lists aren't linked, and don't have to match.** `aerospace.toml` controls where an app gets auto-routed when it opens, this list controls what shows up greyed out. Finder is a deliberate example of them diverging: it's intentionally left out of `aerospace.toml` (so it isn't pinned to one workspace, since it's used across several), but it's listed here as a launcher tile in Core, School, Personal, Creative, and Dev, so there's always a quick way to pop open a fresh Finder window wherever you currently are. For every other app, if you add or move one in `aerospace.toml`, update the matching entry in `~/Library/Application Support/AeroSwitcher/config.json` too, or the launcher row will drift out of sync.

`missingLauncherApps` compares that roster against your real open windows and returns whichever configured apps aren't currently running. `launchApp` normally runs `open -a <app name>` to start one when you pick it.

### Apps running with no window anywhere, and nowhere configured either

Native macOS Cmd+Tab still shows an app that's running with zero windows open (picking it just brings the app forward with nothing on screen). AeroSwitcher fully replaces Cmd+Tab, so without something explicit for this case, that same app would become completely unreachable the moment you close its last window without quitting it: no real window to switch to.

Most of the time this isn't actually a problem: an app that's configured for a workspace in `config.json` already shows up there correctly as a "Running" tile via the normal `missingLauncherApps` + `isAppRunning` path (see above) the instant you're actually on that workspace, whether or not it currently has a window. The real gap is only apps that are windowless **and never configured for any workspace at all** — those had genuinely nowhere to show up.

`homelessRunningApps` finds exactly that case: every "normal" running app (`.regular` activation policy, the same set native Cmd+Tab shows, which is also why AeroSwitcher itself never shows up as one of its own tiles) that has no window open in ANY workspace (checked against the full cross-workspace window list, not just the one you're currently on) AND isn't listed in ANY workspace's `config.json` roster, not just the current one. That second condition matters as much as the first — an app that's simply configured for a *different* workspace than the one you're looking at (WhatsApp under Core, say) is deliberately excluded here; it isn't homeless, it's just elsewhere, and scattering it across whatever workspace you happen to be browsing would be actively misleading, not helpful.

**Remembering where a homeless app came from.** A homeless app isn't just dropped wherever you happen to be looking, it's put back where it was last actually seen with an open window. Every time AeroSwitcher already fetches the full cross-workspace window list (which it does on every normal switcher open and every overview open, since both need it anyway), it also feeds that list to a small `AppWorkspaceTracker`, which records, per app name, the last workspace that app had a real window on. That mapping is saved to its own file, `~/Library/Application Support/AeroSwitcher/app-workspaces.json`, separate from `config.json` and not meant to be hand-edited. So if you open Preview while on Dev, then close its window without quitting, Preview shows up as a homeless tile specifically on Dev, not on whatever workspace you're currently browsing. Only if AeroSwitcher has never seen a given app with a window before (a fresh install, or an app opened for the first time in some other way) does it fall back to showing that app with no known workspace at all.

- **In the normal switcher**, `orphanedRunningApps` turns these into extra greyed tiles, but only on the one workspace they're actually remembered as belonging to (or, if untracked, on whatever workspace you're currently viewing, same fallback as before). Confirming one just activates it, same as clicking any other already-running launcher tile. Since it doesn't actually belong to whatever workspace you see it on, `LauncherApp.isOrphaned` marks it, and `LauncherCard` renders it dimmer than a normal tile with a "No window" caption instead of "Running", so it doesn't look like it was ever configured for that workspace.
- **In the Cmd+\` overview**, tracked homeless apps are folded directly into their remembered workspace's card as extra tiles, right alongside that workspace's real windows and configured launcher tiles, so a homeless Preview genuinely reads as "belongs to Dev," not as some separate miscellaneous bucket. Only apps AeroSwitcher has never seen with a window (no tracked workspace at all) land in a dedicated section, titled "Running, no window", tacked on after the real per-workspace sections. That section only appears when there's actually at least one such app. Either way, these tiles are rendered with a dashed ring and dimmed opacity around the (real, live) icon, and a dimmer name label, so they read as clearly different from an app with an actual open window, at a glance, not just by which section or card they're in.

Finder and Terminal are exceptions. Both are single shared processes, so if a window already exists ANYWHERE (even in a different workspace), `open -a` just brings that existing window forward instead of making a new one where you actually are. For those two, `LauncherApp` carries a small AppleScript (`newWindowScript`) that explicitly asks for a brand new window instead, the same trick your `aerospace.toml`'s alt-enter binding already uses for Terminal.

Finder's script opens the new window at whatever you've actually set as "New Finder windows show" in Finder > Settings > General, resolved by `finderDefaultNewWindowPath()`. Finder writes that preference to its own preferences file under the key `NewWindowTarget` (a short code like `PfHm` for home or `PfDe` for Desktop) and, for anything beyond those few named presets (Downloads, iCloud Drive, a custom folder), `NewWindowTargetPath` holds the actual folder as a `file://` URL. Reading that file directly turned out to be far more reliable than an earlier attempt that tried asking Finder for this through AppleScript itself (`target of Finder preferences`), that property doesn't really exist in Finder's scripting dictionary, which is why it silently failed. This resolved path is computed once when AeroSwitcher starts, so changing the Finder preference while AeroSwitcher is already running won't be picked up until it restarts.

That silent failure is also why `launchApp` now waits for these AppleScript launches to finish and prints an error if one fails (still nothing written to disk, just a `print()` like the rest of the app already uses elsewhere). AppleScript errors don't throw in Swift, `osascript` just exits with a non-zero status and writes the reason to stderr, so without checking that, a broken script just looks like nothing happened when you click the tile.

### Fitting everything on screen

Two numbers control the grid: `capacity` (how many columns fit across the screen) and `maxRows` (how many rows fit down the screen), both recomputed from your actual screen size every time the switcher opens rather than being fixed numbers.

Real windows fill rows top to bottom, using as many rows as they need, no artificial cap. The launcher row (grayed out apps) always comes right after the real windows, never mixed in with them, separated by a thin divider line.

If everything together needs more rows than `maxRows` allows, it splits into pages instead of making the window taller than the screen. Small dots at the bottom of the panel show which page you're on, but only appear once there's more than one page.

## Keybindings

All of these only apply while the switcher panel is open (you're holding Cmd after pressing Tab). Everything except Cmd+Tab itself is configurable, see **Config file**, below, for how to change any of them.

| Key (default) | Config name | What it does |
|---|---|---|
| Cmd+Tab, nothing open | *(fixed, not configurable)* | Opens the normal switcher (current workspace only) |
| Cmd+Shift+Tab, nothing open | *(fixed, not configurable)* | Opens the normal switcher, landing on your least-recently-used window (same as native macOS) |
| Cmd+\`, nothing open | *(fixed, not configurable)* | Opens the **all-workspaces overview** instead — see below |
| Cmd+Tab, already open | *(fixed, not configurable)* | Normal switcher: advances to the next window (or tile). Overview: pages forward. |
| Cmd+Shift+Tab, already open | *(fixed, not configurable)* | Normal switcher: goes back to the previous window (or tile). Overview: pages backward. |
| D | `cycleNext` | Normal switcher: next window (or next launcher tile). Overview: pages forward. |
| A | `cyclePrevious` | Normal switcher: previous window (or previous launcher tile). Overview: pages backward. |
| S | `enterGreyedRow` | Normal switcher only: step onto the grayed out launcher row, if there's anything there |
| W | `exitGreyedRow` | Normal switcher only: step back off the launcher row, to your real windows |
| Q | `pageUp` | Normal switcher only: jump to the previous page |
| E | `pageDown` | Normal switcher only: jump to the next page |
| F | `confirm` | Switch to the selected window, or launch the selected grayed out app. Does nothing in the overview (there's nothing to confirm). |
| Escape | `cancel` | Cancel, closing the switcher and returning keyboard focus to whatever you were on before opening it |
| Releasing Cmd | *(fixed)* | Switch to (or launch) whatever's currently selected, same as `confirm` |
| Clicking a tile | *(fixed)* | Switch to that window, or launch that app, immediately |

While the all-workspaces overview is open, only Tab/Shift+Tab, D/A, Escape, and releasing Cmd do anything — Tab and D both page forward, Shift+Tab and A both page backward (same physical keys the normal switcher already uses to cycle, repurposed here since the overview has no window selection to cycle through). S/W/Q/E/F are all inert there.

The defaults above (Q/W/E/A/S/D/F) sit under your left hand, the same physical cluster your `~/.aerospace.toml` workspace-switching keys already use, so the whole thing, opening the switcher, navigating it, and confirming, works with Cmd held by your left pinky and everything else reachable without moving that hand. `confirm` deliberately isn't Space: Cmd+Space is macOS's own reserved Spotlight shortcut, and the system wins that one no matter what a regular app tries to do about it, so anything bound here needs to be a combination nothing else already claims.

Page Up/Down always select the first tile of the page they land on (real window or grayed launcher app, whichever comes first), so it's always obvious what confirming would act on. An earlier version only changed what was drawn without moving the selection, which meant you could land on a page with nothing highlighted at all, no way to tell what confirming would even do.

## All-workspaces overview (Cmd+\`)

The normal switcher is deliberately scoped to just your current workspace, that's the whole point of this app over stock Cmd+Tab. But sometimes you just want to glance at everything that's open, across every workspace, without hunting through them one at a time, so Cmd+\` (the backtick key, top-left of the keyboard, no Shift needed — the same physical key macOS's own "cycle this app's windows" shortcut uses) opens a second, completely different panel for exactly that.

Cmd+\` only does anything from cold. Pressed while a switcher (either one) is already open, it's ignored rather than trying to switch modes mid-session.

(An earlier version had Cmd+Shift+Tab-from-cold open this overview instead, repurposing Shift's native meaning. That's gone now — Cmd+Shift+Tab is back to matching stock macOS exactly, landing on your least-recently-used window, and the overview has its own dedicated key instead of borrowing Tab's. An even earlier version paged the overview with Q/E, but those don't match anything else in the app — paging now reuses Tab/Shift+Tab and A/D instead, the same keys that already cycle everywhere else.)

Unlike the normal switcher, the overview is **read-only — purely a way to look, not to act**:

- **The panel is exactly the same maximum size as the normal switcher** (85% of your screen's width, 80% of its height), not a fixed size of its own, so the two feel like one app.
- **Every workspace gets its own section**, stacked vertically, alphabetically within two groups: workspaces with something open come first, empty ones are pushed to the end — always in that order, every time. An empty workspace still gets its own card (just its name, no extra text), so you can see at a glance which ones are free, but they never crowd out the busy ones.
- **Empty workspaces always start on their own fresh page**, never sharing a page with a workspace that has something open — so once you've paged past the ones that actually matter, everything after that point is empty, nothing empty is ever mixed in earlier.
- **Each page is packed with as many workspace sections as actually fit** in that space before spilling onto the next page, the same "fill the first page, then the next" logic the normal switcher uses for window rows, just applied to sections that can each be a different height (a workspace with a lot of apps needs more icon rows than an empty one). Every card is at least as tall as one icon row, even an empty one, so cards read as consistent sizes rather than empty ones looking noticeably shorter.
- **Each app that has a window open in a workspace shows as its own icon**, with a small number badge if it has more than one window there. These are the app's real, *live* icon (instant, straight from the running process, refetched every time the panel opens) — not window thumbnails, no screenshots are captured for this panel at all, which is what keeps it fast even with a lot of windows open. If you use something like LiveIcon or Silicon to give an app a custom icon, the overview picks that up automatically too, even after the app updates, since it's never hardcoded to any specific image.
- **Apps that are fully quit don't show up.** Only apps that are actually running appear — either with a real window (in their workspace's section) or, if running with no window anywhere, in the separate "Running, no window" section (see "Apps running with no window anywhere," above). No greyed-out "not running yet" tiles here either way, that's only ever the normal switcher's thing.
- **Nothing is clickable, and there's no selection.** Arrow keys, S/W/Q/E/F, Return, and clicking all do nothing while this panel is open. Escape or releasing Cmd just closes it and returns you to whatever you were doing, exactly as if you'd never pressed the key at all.
- **Tab/Shift+Tab or A/D page through workspaces**, with the same small dots at the bottom the normal switcher uses to show which page you're on. The panel never scrolls, on purpose, so browsing it stays fully left-handed with the keyboard instead of needing the mouse/trackpad.

Cmd+\` isn't in the config file's `keybinds` section, unlike everything else, it's a completely separate way to open the panel (same category as Cmd+Tab itself), not a navigation action within an already-open one.

## Config file (`~/Library/Application Support/AeroSwitcher/config.json`)

A plain JSON file, created automatically the first time AeroSwitcher runs, with the keybind defaults already filled in — `workspaces` starts empty on purpose (the app is built without any one person's setup baked into it, so it works cleanly if someone else runs it too), so the switcher itself and the all-workspaces overview work right away, you just won't see any greyed-out "not running yet" tiles until you add some, following the example below. Edit the file any time and relaunch AeroSwitcher (quit and reopen, or just restart your Mac if it's in Login Items) to pick up changes, nothing needs to be rebuilt.

It lives under `~/Library/Application Support/`, the standard place a Mac app is supposed to keep its own settings, same folder structure apps like Chrome or Slack use for theirs, rather than a loose dotfile sitting directly in your home folder. `~/Library` is hidden by default in Finder (Cmd+Shift+. in a Finder window toggles hidden files if you ever want to look at it directly), or just open it by path.

It has four sections:

```json
{
  "keybinds" : {
    "cycleNext" : "d",
    "cyclePrevious" : "a",
    "enterGreyedRow" : "s",
    "exitGreyedRow" : "w",
    "pageUp" : "q",
    "pageDown" : "e",
    "confirm" : "f",
    "cancel" : "escape"
  },
  "workspaces" : {
    "Core" : [
      { "name" : "WhatsApp", "match" : "Whatsapp", "open" : "Whatsapp" },
      { "name" : "Finder", "match" : "Finder", "open" : "Finder", "newWindowStyle" : "finder" },
      { "name" : "Calendar", "match" : "Calendar", "open" : "Calendar", "icon" : "~/Pictures/AppIcons/calendar.png" }
    ]
  },
  "showTileStatusText" : true,
  "icons" : {
    "Notes" : "~/Pictures/AppIcons/notes.png"
  }
}
```

**`keybinds`**: each value is the name of a key, lowercase. Letters (`"a"`–`"z"`), digits, and a few named keys (`"space"`, `"escape"`, `"return"`, `"tab"`, `"delete"`, `"up"`, `"down"`, `"left"`, `"right"`) are recognized, that list lives in `keyCode(forName:)` in `main.swift` if you ever want to see or extend it. Tab itself can't be reassigned, it's permanently what opens the switcher. Careful with combinations macOS itself already reserves system-wide (Space for Spotlight is the one that bit the original default here) — those will keep doing their system behavior no matter what this file says, since AeroSwitcher can't override the OS's own reserved shortcuts.

**`workspaces`**: one array per AeroSpace workspace name, each entry a launcher tile:
- `name` — what's shown under the grayed tile
- `match` — checked against already-open windows to decide whether to hide this tile (should match how the app's name normally appears)
- `open` — passed to `open -a` to actually launch it
- `newWindowStyle` — optional, only `"finder"` or `"terminal"` are accepted. Leave it out for every other app. This is intentionally the only kind of "custom launch behavior" the config file can express, arbitrary AppleScript isn't accepted here, so a typo or mistake in this file can never make the app run something unexpected.
- `icon` — optional, only needed to override an app's icon. Greyed tiles show each app's own real macOS icon automatically (running instance if it's open anywhere, otherwise a Launch Services lookup by name), no config needed for that. Set `icon` only when you specifically want something different, a path to an image file (PNG, JPG, ICNS, whatever). `~` is expanded, so `"~/Pictures/AppIcons/calendar.png"` works. This is mainly for apps like Calendar whose real macOS icon can't be replaced system-wide without disabling System Integrity Protection (not something worth doing for a cosmetic icon) — set it here instead and AeroSwitcher shows it everywhere it displays that app's icon: the greyed launcher row AND the Cmd+\` overview, both the real-window entries and any homeless "No window" ones. A bad or missing path just falls back to the app's real icon (or the dashed placeholder if that can't be found either) and prints which app it was for, it never crashes the app.

Greyed tiles are ordered in three groups, not one alphabetical list: orphaned "No window" tiles first, then this workspace's own "Running" tiles (configured here, just open somewhere else), then fully "Quit" tiles last. Alphabetical within each group.

**`icons`**: optional, a flat `"App Name": "path"` map for a custom icon by name, checked everywhere AeroSwitcher shows an icon for that app: real open windows and homeless "No window" tiles in the Cmd+\` overview, AND greyed launcher tiles, if that app also happens to be in `workspaces` somewhere. It does NOT make an app show up as a greyed launcher tile on its own though, that still only happens for apps actually listed in `workspaces` — this only changes what icon shows once a tile already exists some other way.

Mainly useful for two cases: an app that isn't in `workspaces` at all (workspaces' own per-entry `icon` only works on entries already inside there, so there's nothing else that can reach it), or an app configured in SEVERAL workspaces, since each workspace's copy is a separate entry with its own separate `icon` field — set it here once instead and it's consistent everywhere that app's tile shows up, rather than needing to repeat the same `icon` path in every workspace's copy of it (and easy to accidentally miss one, which looks like the icon "randomly" not working in just that one workspace). Same rules as the per-entry version: `~` expanded, any common image format, a bad path just gets ignored with a print.

**Don't set custom icons by editing the app itself.** It's possible to change an app's icon system-wide with `NSWorkspace.setIconForFileOptions` (this is what the Finder "paste icon in Get Info" trick does under the hood), and it's tempting to script that instead of using `icons` above. Don't, for two reasons: it writes a hidden `Icon` file and a "has custom icon" flag directly into the app's own bundle on disk, so it affects Dock, real Cmd+Tab, Finder, everywhere, not just AeroSwitcher, and a bad or half-finished image applied that way can leave the app showing the generic blue folder icon system-wide until it's manually undone (delete the hidden `Icon` file, `xattr -d com.apple.FinderInfo` on the app, then `killall Finder Dock`). A LaunchAgent that reapplies this automatically on a `WatchPaths` trigger makes it worse, since it can silently reapply a broken icon every time the app launches. The `icons` config above gets the same visual result inside AeroSwitcher without ever touching the real app bundle, so there's nothing to undo if a path or image turns out to be wrong.

**`showTileStatusText`**: optional, defaults to `true`. Controls the small "Running" / "Quit" / "No window" line under each greyed-out launcher tile in the normal switcher (not the overview, which never had this text). Set it to `false` for quieter tiles — the small running-dot above the icon (same convention as the Dock) still shows whether an app is alive somewhere, you just lose the word underneath it.

Two safety nets if something's off in the file:
- **A key name that isn't recognized** falls back to that one action's own default and prints exactly which one, instead of silently doing nothing.
- **Two actions bound to the same key**, or a key colliding with the reserved Tab, gets called out too (only the first one in line would ever actually fire otherwise).
- **If the whole file fails to parse** (a missing comma, an extra brace, anything that isn't valid JSON), AeroSwitcher falls back to its built-in defaults entirely for that run and prints the JSON error, rather than crashing or refusing to open.

All of these show up as `print()` output if you're running AeroSwitcher from Terminal. If it's running quietly via Login Items instead, quit it, run `/Applications/AeroSwitcher.app/Contents/MacOS/AeroSwitcher` from Terminal once after editing the config, and check what it prints on launch.

## `~/.aerospace.toml`

This is AeroSpace's own config file, separate from AeroSwitcher, but AeroSwitcher depends on parts of it.

**Workspaces**: Core, School, Personal, Creative, Dev, Gaming, laid out on a 3x3 key grid under your left hand (Alt+Q/W/E/A/S/D switches workspaces, Alt+Shift+Q/W/E/A/S/D sends the focused window to one).

**Auto-sorting apps into workspaces** (the `on-window-detected` block): every time an app opens, a rule checks its `.app` bundle path and moves it to the right workspace automatically. Matching is done on bundle *path* rather than bundle *ID*, for two reasons. First, some apps (like Steam) have their actual on-screen window owned by a separate helper process with a different bundle ID than the main app, so an ID based rule can silently never match. Second, some apps (like Safari-installed web apps) get a random bundle ID assigned that can change, but the file name on disk stays stable. Every rule was checked against the real `/Applications` folder to make sure no two rules could ever accidentally match the same app.

Finder is deliberately left out of this block, since it's used across every workspace and forcing it into one would just fight you.

**The MRU logs**: `on-focus-changed` appends the newly focused window's ID to that workspace's own file under `/tmp/aerospace-mru/` every time focus changes. This is the only reason AeroSwitcher can show your most-recently-used windows first.

`auto-reload-config = true` means saving this file applies changes immediately, no need to restart AeroSpace.

## Fullscreen / maximize toggle (alt-f)

This part isn't AeroSwitcher code at all, it's entirely `~/.aerospace.toml` plus three small script files, but it's worth documenting here since it directly affects how every window behaves.

**The goal**: every window fills the screen automatically when it opens, stays that way no matter how you switch between windows (Cmd+Tab, AeroSpace's own alt-tab, the Dock, anything), and only changes size when you personally press Alt+F. No flicker, ever.

**Why this doesn't use AeroSpace's own `fullscreen` command.** That was the first thing tried, and it doesn't work for this: AeroSpace automatically un-applies fullscreen the moment you switch away from a window, every time, with no config flag to stop it (this is confirmed behavior, tracked as a feature request on AeroSpace's own GitHub, issues #1475 and #1480). Reacting to that after the fact (re-apply fullscreen a moment after every switch) technically works but causes a visible flicker, since there's always a brief real gap between AeroSpace un-fullscreening a window and a script telling it to fullscreen again.

**Why this works instead**: every window is set to `layout floating` the moment it opens, in the `on-window-detected` block. Floating is a different management mode from AeroSpace's normal tiling. Confirmed straight from AeroSpace's maintainer (GitHub issue #1519): a **tiled** window has its position and size continuously re-enforced by AeroSpace, so anything else that tries to move or resize it (including a plain macOS resize) just gets snapped back. A **floating** window is the opposite, AeroSpace sets it up once and then leaves it alone completely. Switching focus, in any way, never touches a floating window's size or position again. That's what makes "always maximized until I say otherwise, zero flicker" actually possible, there's nothing to react to and nothing fighting the size you set.

**The three script files**, all living in `~/Library/Application Support/AeroSpace/` (this exact folder, not AeroSpace's own app folder, just a convenient place created for these scripts):

- **`maximize.applescript`** — resizes the frontmost window to fill the screen's usable area (below the menu bar, above the Dock). This is a real macOS window resize via System Events, nothing AeroSpace-specific. Runs automatically on every new window (via `on-window-detected`) and on one half of the `alt-f` toggle.- **`restore.applescript`** — resizes the frontmost window down to 70% of the screen, centered. The number `0.7` near the top of the file controls this, edit it directly if you want windows to restore to a different size, it's just a plain number.
- **`toggle-maximize.sh`** — what `alt-f` actually runs. It keeps a small empty marker file per window (under `/tmp/aerospace-restored/`, named by window ID) to remember which windows are currently in the smaller "restored" state. No marker means the window is currently maximized, so pressing `alt-f` runs `restore.applescript` and creates the marker; a marker present means it's currently restored, so `alt-f` runs `maximize.applescript` and deletes the marker. This only ever runs when you actually press `alt-f`, it's not hooked into switching at all.

**In `~/.aerospace.toml`**: every rule in `on-window-detected` (the auto-sort-into-workspaces block) now does `layout floating` followed by `exec-and-forget osascript ".../maximize.applescript"`, right after the workspace move. The `alt-f` binding runs `toggle-maximize.sh` instead of AeroSpace's own `fullscreen` command.

**Permission needed**: since `maximize.applescript` and `restore.applescript` control another app's window through System Events, macOS requires **Accessibility** permission the first time this runs (System Settings > Privacy & Security > Accessibility). macOS should prompt for this automatically the first time a window opens after setting this up. If windows stop resizing and nothing else looks broken, that permission is the first thing to check, see whatever process is asking (likely `osascript` or AeroSpace itself) is listed and enabled there.

## Known limitations

- **Popups and dialogs get maximized too.** AeroSpace treats every window the same, so a save dialog or alert that appears in a workspace app is floated and maximized along with real windows. Press `alt-f` to shrink it. Two fixes were explored and deliberately not adopted (see ROADMAP.md).
- **Spotify (and similar DRM-protected apps)** will always show a static screenshot, never a live thumbnail. This is a macOS/hardware limitation, not something fixable in this app.
- **The `"workspaces"` list in `~/Library/Application Support/AeroSwitcher/config.json` is a manual copy** of the workspace groupings in `aerospace.toml`. The two can drift apart if only one gets updated.
- **No vertical scrolling within a page.** If a single page somehow still ends up too tall (extremely unlikely at normal window counts, since `maxRows` already caps it), there's currently no vertical scroll as a fallback, only pagination.
- **A deprecation warning on every build, and that's expected.** `build.sh` will print a warning about `fullPath(forApplication:)` being deprecated, pointing at `resolvedAppIcon` in `main.swift` (the function that finds a QUIT app's real icon by name, for the greyed launcher row's automatic icons). This is intentional, not a mistake left behind: Apple's suggested replacement needs a bundle identifier, but config.json only ever has app names/paths (`match`/`open`), never bundle identifiers, so there's no non-deprecated API that does the same name-based lookup. The build still succeeds and the app works normally, this warning is cosmetic. The only way to avoid it entirely would be replacing this one lookup with a manual scan of `/Applications`, `/System/Applications`, and `~/Applications` instead of asking macOS directly, which trades a clean build log for missing apps installed in less common locations, judged not worth it.

## Permissions this app needs

- **Input Monitoring**: required for the Cmd+Tab interception (`CGEventTap`) to see keystrokes at all.
- **Screen Recording**: required for `ScreenCaptureKit` to take window screenshots.

Both are granted per-app in System Settings > Privacy & Security, to AeroSwitcher.app specifically. If thumbnails stop appearing or Cmd+Tab stops responding after a rebuild, check that AeroSwitcher is still listed and enabled under both.

There's a third permission the setup as a whole needs, **Accessibility**, but it isn't AeroSwitcher's own, it belongs to the maximize/floating toggle system described above (see **Fullscreen / maximize toggle**), which is entirely AeroSpace config and separate script files, not this app's code. Worth knowing about here since without it, windows will stop resizing even though AeroSwitcher itself is working fine.

## Packaging it as your daily-use app

A few things worth doing once, when you're ready to stop rebuilding and just leave a final version running:

1. **Move the built `.app` to `/Applications`.** It'll run from anywhere, but `/Applications` is the standard, expected location, and it's where Login Items and Spotlight expect to find things.
2. **Re-grant permissions on that final copy.** Since it's ad-hoc signed (not a paid Developer ID), macOS ties Input Monitoring and Screen Recording to the exact signed binary. Moving or rebuilding it can make macOS treat it as "new" and ask again, so do one full test (open the switcher, confirm thumbnails and Cmd+Tab both work) after moving it, before you rely on it daily.
3. **Add it to Login Items.** System Settings > General > Login Items & Extensions > click "+" under "Open at Login" > select AeroSwitcher.app. That's genuinely all you need, no separate LaunchAgent required, since it's a normal `.app` bundle (just hidden from the Dock by its own activation policy).
4. **Stop rebuilding it after that.** Every rebuild changes its code signature, which is exactly the kind of thing that resets the permissions above. Once you've got the version you're happy with, treat it as done rather than a work in progress you keep touching.
5. **Optional sanity check**: log out and back in once (or restart) after setting up Login Items, just to confirm it actually launches on its own before you stop thinking about it.
