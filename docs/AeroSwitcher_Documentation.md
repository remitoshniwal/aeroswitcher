# AeroSwitcher Documentation

## What it is

AeroSwitcher is a custom replacement for macOS's Cmd+Tab, built as a small Swift/SwiftUI app. The default Cmd+Tab cycles through every open app on the whole Mac. AeroSwitcher instead only shows windows in whatever AeroSpace workspace you're currently on, since AeroSpace already organizes your apps into groups (Core, School, Personal, Creative, Dev, Gaming) and jumping between windows in a totally different group rarely makes sense.

It's a Swift Package Manager project, wrapped into a real `.app` bundle so macOS treats it as a proper application (needed for it to be grantable in System Settings for the permissions it needs, and to run quietly in the background without a Dock icon).

## How it's put together

The app's code lives in `Sources/AeroSwitcher/`, one file per part of the app:

| File | What's in it |
|---|---|
| `main.swift` | Start-up: the order things load in at launch, and starting the app |
| `AeroSpaceBridge.swift` | Every call out to the `aerospace` command line tool (list windows, focus a window, current workspace), and the live event connection the menu bar icon uses |
| `ThumbnailCapture.swift` | Taking the window screenshots |
| `DataModel.swift` | The basic types (a thumbnail, a launcher app) and the Finder/Terminal "new window" scripts |
| `Config.swift` | Reading `config.json`, launcher tiles, custom icons, homeless apps, launching apps, and the safe way the settings window edits `config.json` |
| `Views.swift` | Everything you see: the switcher panel, its cards, and the Cmd+\` overview |
| `MRUTracking.swift` | Recently-used order, and remembering which workspace each app was last in |
| `WindowController.swift` | The panel's brain: paging, selection, showing and hiding it, switching windows |
| `Keybinds.swift` | Turning key names from `config.json` into real key codes, and back (for recording keys) |
| `HotkeyInterception.swift` | Catching Cmd+Tab before macOS sees it |
| `MenuBar.swift` | The menu bar icon: workspace name, and its menu |
| `SettingsWindow.swift` | The settings window (General, Launcher tiles, Keys, Icons) |
| `SetupHelp.swift` | The setup checks (AeroSpace, Input Monitoring, Screen Recording, recent order) and the Setup window |

They all build into one app together, so code in one file can use things from another without any extra setup. There's no separate UI framework project, no storyboard, just:

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

`getWindows(scope:)` runs `aerospace list-windows --workspace focused` (or `--all` for the Cmd+\` overview) and parses the output into a list of windows (id, app, workspace, title). AeroSwitcher's own windows (the config problems window, About, the "Hide AeroSpace's icon" dialog) are left out, so they never show up as an "AeroSwitcher" card. `focusWindow(id:)` runs `aerospace focus --window-id <id>` to actually switch to a window once you pick one. `getCurrentWorkspaceName()` runs `aerospace list-workspaces --focused` to find out which workspace (Core, Gaming, etc.) you're currently on, which the launcher tiles feature (below) needs.

### Taking the screenshots

Each window's thumbnail is a real screenshot, taken fresh every single time you open the switcher. There's no cache and no live video feed, `captureThumbnail` calls `SCScreenshotManager.captureImage`, a one shot snapshot, once per window, and all the windows are captured in parallel (not one after another) to keep things fast.

A live, constantly updating preview was tried and removed. Some apps, most notably Spotify, are protected by DRM at the hardware/GPU level on macOS, below every screen capture API that exists (ScreenCaptureKit, QuickTime, the old CGWindowListCreateImage). There's no workaround for this, confirmed through research into how other developers have hit the exact same wall. Since a live view couldn't work for every app, static screenshots for every app was the more honest, consistent choice.

Screenshots are captured directly at the small size they'll actually be shown at (220 x 140 points, scaled up for Retina displays), not at the window's full native resolution and then shrunk down. That's the main reason captures are fast even though the app never caches anything.

### Remembering which window you used last

`MRUTracker` keeps one small log file per workspace (`Core.log`, `Gaming.log`, and so on), one window ID per line, newest last. This is how the switcher puts your most recently used windows first, in the same order the real Cmd+Tab does, instead of some arbitrary order.

**Where the IDs come from.** AeroSwitcher already keeps one `aerospace subscribe` connection open for the menu bar icon. It now also asks for AeroSpace's `focus-changed` events, which carry the window ID and the workspace (`{"_event":"focus-changed","windowId":69892,"workspace":"Core"}`), and appends each one to `/tmp/aeroswitcher-recent/<Workspace>.log` (written on a background queue, so the Cmd+Tab hook never waits for a file). Nothing has to be added to `.aerospace.toml`, which is the point: nobody else has to edit their config. AeroSpace also sends the current focus once on every new connection.

**The old hook still works.** The `on-focus-changed` line in `~/.aerospace.toml` writes the same kind of log to `/tmp/aerospace-mru/<Workspace>.log`. If both logs exist for a workspace, the one written to most recently is read, because both record the same events: if you remove the hook line, its log stops growing and AeroSwitcher's own takes over; if AeroSwitcher wasn't running for a while, the hook's log is the one that kept going. An AeroSpace without the `subscribe` command can only use the hook (the Setup window then shows a Recent order row with the line to add).

Both folders are in `/tmp` on purpose: window IDs mean nothing after a restart, and macOS empties `/tmp` then.

Each log is trimmed the same way: `MRUTracker` only keeps the most recent 300 window IDs per workspace and rewrites a file back down to size once it's grown enough to be worth the trouble. It's split per workspace rather than one shared log for two reasons. First, each file grows by one line every focus change, so the trimming has to be cheap. Second, and more importantly: with one shared history, heavily switching windows in whatever workspace you're using right now could push an older, less-visited workspace's own window IDs out of the remembered set entirely. Separate files mean each workspace only ever competes with its own past.

Checked on 2026-10-25: after a series of focus changes from the command line, AeroSwitcher's log was identical to the last lines of the hook's log, for every workspace that had entries.

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
- **In the Cmd+\` overview**, tracked homeless apps are folded directly into their remembered workspace's card as extra tiles, right alongside that workspace's real windows (the overview never shows the grey launcher tiles, those are only in the normal switcher), so a homeless Preview genuinely reads as "belongs to Dev," not as some separate miscellaneous bucket. Only apps AeroSwitcher has never seen with a window (no tracked workspace at all) land in a dedicated section, titled "Running, no window", tacked on after the real per-workspace sections. That section only appears when there's actually at least one such app. Either way, these tiles are rendered with a dashed ring and dimmed opacity around the (real, live) icon, and a dimmer name label, so they read as clearly different from an app with an actual open window, at a glance, not just by which section or card they're in.

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
| S | `enterGreyedRow` | Normal switcher: step onto the grayed out launcher row, if there's anything there. Overview: scrolls down, only on a page too tall for the panel. |
| W | `exitGreyedRow` | Normal switcher: step back off the launcher row, to your real windows. Overview: scrolls up, only on a page too tall for the panel. |
| Q | `pageUp` | Normal switcher only: jump to the previous page |
| E | `pageDown` | Normal switcher only: jump to the next page |
| F | `confirm` | Switch to the selected window, or launch the selected grayed out app. Does nothing in the overview (there's nothing to confirm). |
| Escape | `cancel` | Cancel, closing the switcher and returning keyboard focus to whatever you were on before opening it |
| Releasing Cmd | *(fixed)* | Switch to (or launch) whatever's currently selected, same as `confirm` |
| Clicking a tile | *(fixed)* | Switch to that window, or launch that app, immediately |

While the all-workspaces overview is open, only Tab/Shift+Tab, D/A, S/W, Escape, and releasing Cmd do anything — Tab and D both page forward, Shift+Tab and A both page backward (same physical keys the normal switcher already uses to cycle, repurposed here since the overview has no window selection to cycle through). S and W scroll down and up, but only on the rare page that's taller than the panel (see the overview section below), and do nothing on a normal page. Q/E/F are inert there.

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
- **Nothing is clickable, and there's no selection.** Arrow keys, Q/E/F, Return, and clicking all do nothing while this panel is open (S/W only scroll, and only on a page too tall for the panel, see below). Escape or releasing Cmd just closes it and returns you to whatever you were doing, exactly as if you'd never pressed the key at all.
- **Tab/Shift+Tab or A/D page through workspaces**, with the same small dots at the bottom the normal switcher uses to show which page you're on. Normal pages never scroll, on purpose, so browsing stays fully left-handed with the keyboard instead of needing the mouse/trackpad.
- **One exception: if one workspace is too big for the whole panel, the busy workspaces share one scrolling page.** A page always holds at least one workspace, so if one workspace has so many apps open that its card alone is taller than the panel (around 100 different apps on a 14" MacBook screen), paging can't help. Instead of giving that workspace a page to itself and pushing every other busy workspace onto the next page, every workspace with something open goes on the first page, still in alphabetical order, and that page scrolls with S (down) and W (up), so it stays left-handed like everything else. That page's panel is made a little shorter than usual, so its bottom edge lands exactly between two rows instead of cutting one in half (`overviewScrollPanelHeight` in `WindowController.swift`). Every place the page can come to rest keeps it that way: some row's bottom lined up with the bottom of the panel, or the very top or bottom of the page. Rows aren't all the same height, because a workspace's first row comes with its name, so how far one row is depends on the row (`overviewScrollRows` works out where each row starts and ends).
  - **Tap S or W** to move one row, with a soft glide that speeds up and then eases into place. Tapping again before it settles carries on from where it was heading, so quick taps build up speed.
  - **Hold S or W** to glide continuously at a steady speed. When you let go, it eases into the next row edge instead of stopping halfway through a row. This doesn't use macOS's own key repeat (which waits, then jerks row by row). AeroSwitcher watches for the key being released instead.
  - The motion comes from a small engine (`OverviewGlide` in `Views.swift`) that moves the page a little on every screen frame, following a target with a spring that never overshoots. Its three settings at the top (`springStrength`, `holdSpeed`, `holdDelay`) are what to change to make it feel floatier, faster, or slower to count as a hold.
  - Two-finger trackpad scrolling works too, and W/S carry on from wherever you scrolled to. The scroll view measures its own real height, so scrolling always stops exactly at the top and bottom.
  - W/S scrolling needs macOS 15 or newer. On macOS 14 that page still scrolls with two fingers, but W/S do nothing.

  Empty workspaces still get their own page after it, as always. The page dots stay at the bottom, Tab/A/D still page as usual, and every page opens scrolled to the top. `computeOverviewPages` in `WindowController.swift` makes this decision, and `overviewPageNeedsScroll` checks whether a page's cards are taller than the panel, both using the same height estimate and the same space budget (`overviewContentBudget`), so a page is never packed as "fits" and then drawn as "scrolls". Every other page has no scroll area at all and looks exactly the same as before.

Cmd+\` isn't in the config file's `keybinds` section, unlike everything else, it's a completely separate way to open the panel (same category as Cmd+Tab itself), not a navigation action within an already-open one.

## Menu bar icon

AeroSwitcher puts one item in the menu bar: the name of the workspace you're in (for example `Core`). It does everything AeroSpace's own icon is used for day to day, and **Hide AeroSpace's icon** in its menu gets rid of AeroSpace's, so only one is left (see below).

What the bar shows:
- The focused workspace name. If a binding mode other than `main` is active, its name comes first, like `(SERVICE) Core`.
- A pause symbol while AeroSpace is disabled.
- A warning triangle when AeroSwitcher can't reach AeroSpace (AeroSpace not running).

The menu, top to bottom:
- **Workspaces**: every workspace, with the apps open in it in grey. A tick marks the one you're in. Click one to switch to it (`aerospace workspace <name>`).
- **Disable AeroSpace / Enable AeroSpace**: `aerospace enable off` / `on`. While AeroSpace is disabled it refuses every other command, so the workspace list is replaced by "AeroSpace is disabled".
- **Reload config**: reloads config.json and AeroSpace's config together, exactly like `pkill -HUP AeroSwitcher` (see **Reloading**).
- **Open AeroSpace config**: opens the file AeroSpace says it's using (`aerospace config --config-path`) in its default app.
- **Settings...**: opens the settings window (see **Settings window**, below). Hold Option while the menu is open and it turns into **Open config.json**, which opens the file itself.
- **Permissions**: a tick, a cross or a `!` for Input Monitoring, Screen Recording, AeroSpace installed, AeroSpace running and Recent order, from the same check as the Setup window. Clicking a cross opens the right page in System Settings (or the Setup window). **Setup...** at the bottom opens the Setup window. These checks only look, they never pop up a permission request.
- **Launch at login**: see **Packaging it as your daily-use app**, below.
- **Hide AeroSpace's icon**: see below.
- **About AeroSwitcher**: the standard macOS About panel with the version and build number, the commit, AeroSpace's version, a link to the source code and the MIT license, and the copyright line. AeroSpace is asked for its version in the background first, so the panel can take up to 2 seconds to appear when AeroSpace is slow, but nothing freezes while it waits.
- **Quit AeroSwitcher**. (Before this menu existed, quitting needed `pkill AeroSwitcher` in Terminal.)

**How the name stays up to date.** AeroSwitcher keeps one `aerospace subscribe focused-workspace-changed mode-changed` running in the background (`AeroSpaceEventStream` in `AeroSpaceBridge.swift`). AeroSpace prints a line the moment you switch, so the name changes instantly, nothing is checked over and over, and nothing needs adding to `.aerospace.toml`. If AeroSpace quits or restarts, that connection ends; AeroSwitcher tries again every 2 seconds and gets the current workspace again on reconnect. An AeroSpace too old to have `subscribe` gets a check once a second instead. The menu itself asks AeroSpace fresh every time it opens, with a time limit on each question, so a hung AeroSpace can't freeze Cmd+Tab.

**How it knows AeroSpace is disabled.** There's no command to ask. But AeroSpace announces it on the same event connection: disabling sends a `mode-changed` event with no mode at all, enabling sends mode `main` again (found by testing, AeroSpace 0.21.3). So the pause symbol is right even if something else disables AeroSpace.

**Hiding AeroSpace's icon.** AeroSpace's icon can't simply be switched off. Tested on macOS 26.5 with AeroSpace 0.21.3: switching AeroSpace off in **System Settings > Menu Bar > Allow in the Menu Bar**, or Cmd-dragging its icon out of the menu bar, makes AeroSpace quit on the spot (macOS tells it its icon was removed and it reacts by quitting, it's not a crash), and when it's opened again its icon is back and the switch is on again. So don't use either of those.

Instead, **Hide AeroSpace's icon** pushes it off the screen, the same trick menu bar tidying apps like Ice and Bartender use. AeroSwitcher adds a second, invisible item of its own right next to its workspace name, 3000 points wide. Menu bar items are laid out from the right, so everything to the left of that divider ends up far past the left edge of the screen. AeroSpace still has its icon and is never told anything, so it keeps running normally.

- Turning it on first shows the divider as a thin **│** with a short explanation. AeroSpace's workspace name must be on the left of the │ (it usually already is). If it isn't, hold Cmd and drag it there, staying inside the menu bar. Then click **Hide**. macOS remembers where icons are, so this is a one-time step.
- **Everything to the left of AeroSwitcher's name is hidden, not just AeroSpace's icon.** To keep another app's icon visible, Cmd-drag it to the right of AeroSwitcher's name (turn the option off and on again to see the │ while you do).
- Turning it off removes the divider and AeroSpace's icon is back at once. If AeroSwitcher quits, the divider goes with it, so AeroSpace's icon shows again and you're never left without one.
- The choice is stored in AeroSwitcher's own preferences (`HideAeroSpaceIcon` in `com.aeroswitcher.app`), not in config.json, because it belongs with the divider's saved position (also stored there) and turning it on needs the arranging step above. The settings window has the same toggle, running the same code.
- The divider stretches over the empty part of the menu bar, but app menus (File, Edit, ...) still open normally. Clicking the empty part does nothing.

**The menu never waits for AeroSpace.** It opens instantly with the last known workspaces and refreshes them in the background (an open menu updates itself). Asking AeroSpace while the menu was opening sometimes took over 2 seconds in testing.

**Only one copy at a time.** A second AeroSwitcher that starts while one is running quits right away, so two can never both catch Cmd+Tab or show two icons. It waits up to 3 seconds first, so `pkill AeroSwitcher; open AeroSwitcher.app` still works. A copy started with `AEROSWITCHER_CONFIG_DIR` (for testing) skips this check.

## Setup window

A small window that says what AeroSwitcher is missing, in plain words, with a button that goes to the right place. **Setup...** in the menu (under Permissions) and **Open Setup...** on the Settings window's General tab open it any time.

It opens by itself:
- On a first launch (when `config.json` didn't exist yet and was just created), with a short welcome that says where the menu is.
- On any launch where something required is missing: AeroSpace not installed or not running, Input Monitoring, or Screen Recording. If only AeroSpace isn't running yet, it waits up to 15 seconds first, because at login AeroSwitcher can start a few seconds before AeroSpace.
- **Don't show at launch** (stored as `SetupHelpHideAtLaunch` in AeroSwitcher's preferences) stops only this automatic popup. The menu still says "(needs attention)".

The rows:
- **AeroSpace installed**: whether the `aerospace` command exists in `/opt/homebrew/bin` or `/usr/local/bin`. Buttons: Get AeroSpace (opens the AeroSpace website), Copy install command. An AeroSpace installed somewhere unusual may be reported as missing.
- **AeroSpace running**: asks `aerospace list-workspaces --focused`. Not running, or turned off (with an Enable AeroSpace button). It can't tell whether AeroSpace has its own Accessibility permission.
- **Input Monitoring**: macOS's answer, and whether the Cmd+Tab hook (the event tap) really started. Button: Open Input Monitoring.
- **Screen Recording**: macOS's answer. Button: Open Screen Recording. If AeroSwitcher is already in the list and switched on but still marked, the hint says to remove it with the minus button and add it again (this can happen after the app's signature changes).
- **Recent order**: with a current AeroSpace (it has `aerospace subscribe`) this is a tick, AeroSwitcher keeps the history itself and nothing needs adding to AeroSpace's config. Only for an old AeroSpace without `subscribe` is it an optional yellow row (never triggers the popup) that looks for an `on-focus-changed` line containing `aerospace-mru` in AeroSpace's config file. Buttons: Copy line, Open config. If the config already has its own `on-focus-changed` line, the row says to add the command inside that line's brackets instead, because two lines with the same key make AeroSpace refuse the file. AeroSwitcher can read the file but not whether AeroSpace has loaded it.
- **Accessibility** is not checked. It belongs to AeroSpace, and one app can't read another's permissions. The window only has a button for that page in System Settings.

While the window is open it checks again every 2 seconds and whenever you come back to it, so a cross turns into a tick by itself. If Input Monitoring is granted while the app is running, AeroSwitcher tries to start the Cmd+Tab hook again itself. After you open a System Settings page from a row and come back, a still-red row shows a hint and a **Restart AeroSwitcher** button: macOS often applies Screen Recording only after a restart. Restart waits for the old copy to exit and starts the app again.

None of this ever uses the macOS calls that pop up a permission dialog (`CGRequest...`, the prompting form of `AXIsProcessTrusted`, or a screen capture).

## Settings window

**Settings...** in the menu bar menu opens a window that can change everything config.json can, so the file never has to be edited by hand (it still can be). Four tabs:

- **General**: the Running / Quit / No window text under launcher tiles (`showTileStatusText`), auto reload (`autoReloadConfig`), **Launch at login** and **Hide AeroSpace's icon** (the same code as the menu items), and buttons to open config.json, show it in Finder, or reload both configs.
- **Launcher tiles**: AeroSpace's workspaces on the left, that workspace's tiles on the right. **Add app...** lists the apps that are running and installed (with a search field, and **Other...** for an app somewhere else). The minus button removes a tile. The arrow next to a tile shows its fields (name, match, open, new window style) to fix by hand. A workspace that config.json has but AeroSpace doesn't is marked, with a button to remove it. There's no reordering on purpose: tiles are always shown alphabetically, Running before Quit, whatever order the file has.
- **Keys**: each key used while the switcher is open, with **Record**: click it, press the key. Cmd may be held. Tab is refused (it's always Cmd+Tab), keys AeroSwitcher doesn't know (F-keys, punctuation) are refused, Space gets a warning (Spotlight wins Cmd+Space). A key another action already uses asks whether to swap the two. **Reset to defaults** puts D A S W Q E F Escape back. Cmd+Tab, Cmd+Shift+Tab and Cmd+\` are shown but fixed.
- **Icons**: every launcher-tile app, every app with a custom icon, and every running app. **Choose image...** picks a picture, **Remove** goes back to the app's own icon. The image file is not copied, so leave it where it is. A path that can't be loaded is shown in red.
  - **Use icons from a folder...** sets many icons at once. Pick a folder of images named after your apps (`calendar.png`, `vs code.png`, `ableton.png`). Each image is matched to an app by its file name, ignoring capitals, spaces and punctuation: the file name has to be one of the app's names (its tile name, match or open name, or its name while running), or, for names of 4 letters or more, part of one ("settings" finds a running "System Settings", marked as a close match). A list shows every app with its current and new icon, all ticked, plus the images that matched nothing. Untick what's wrong and click **Use**: everything is saved in one change. It's a one-time import, so an image added to the folder later needs another import (or **Choose image...**). Only the folder itself is searched, not folders inside it, and an app that isn't a launcher tile has to be running to be matched.

**How it saves.** Every change is saved the moment you make it (text fields when you press Return or click elsewhere) and applies at once, even with `autoReloadConfig` off. Each change reads config.json fresh, changes only the one part it's about, and writes it back (`editConfigFile` in `Config.swift`). So:

- **Hand edits are kept.** Something you saved in your editor is never thrown away by a later click in the window. The window also shows hand edits within about a second (it re-reads the file after every reload).
- **Unknown keys are kept**, at the top level, inside `keybinds`, and inside each app entry.
- **Same part changed in both places:** if you changed by hand the same part a window change is about (say a keybind, then Reset in the window before the window caught up), nothing is saved and the window says "config.json was changed meanwhile". It then shows the new version, and doing the change again works.
- **A broken config.json is never overwritten.** While the file can't be read (a missing comma, say), the window shows only the error (with line and column) and an Open config.json button, until the file is fixed.
- **It never writes a file that wouldn't load.** The result is test-read before saving.
- **Backup:** the first time the window saves in each run of AeroSwitcher, the file as it was is copied to `config.json.backup` next to it.
- **Formatting:** the window writes config.json in one fixed layout (one line per app, keys in a fixed order, the same shape as the example below). The first save from the window tidies the whole file into that layout once; values are never changed. After that, a save only changes the lines it's about.
- **What it can't protect:** unsaved changes in an editor that has config.json open. Save in the editor before using the window.

**Good to know.**
- Opening the window makes AeroSwitcher the active app, so it can be typed into. While it's active, the menu bar shows a small **AeroSwitcher** and **Edit** menu; the Edit menu is what makes copy, paste, select all and undo work in the text fields. There's no Quit in it on purpose (quitting AeroSwitcher also turns off its Cmd+Tab).
- The window can't be resized, so the maximize script leaves it alone. Like all of AeroSwitcher's own windows it doesn't show up as a Cmd+Tab card; reopen it with **Settings...**.
- Recording a key only listens to keys typed into this window, and only for one key. It can't see keys typed in other apps, and Cmd+Tab keeps working while it records.
- **Launch at login** only changes from the copy in `/Applications` (in both directions). A test build in the project folder sees the installed app's login item as its own, and turning it off there would remove the real one.

## Config file (`~/Library/Application Support/AeroSwitcher/config.json`)

A plain JSON file, created automatically the first time AeroSwitcher runs, with the keybind defaults already filled in. `workspaces` starts empty on purpose (the app is built without any one person's setup baked into it, so it works cleanly if someone else runs it too), so the switcher itself and the all-workspaces overview work right away, you just won't see any greyed-out "not running yet" tiles until you add some, following the example below. The **Settings** window (above) can change all of it; you can also edit the file any time and save it: AeroSwitcher reloads it by itself within a moment, the same way AeroSpace does with `auto-reload-config = true` (see **Reloading**, below). Nothing needs to be rebuilt or restarted.

It lives under `~/Library/Application Support/`, the standard place a Mac app is supposed to keep its own settings, same folder structure apps like Chrome or Slack use for theirs, rather than a loose dotfile sitting directly in your home folder. `~/Library` is hidden by default in Finder (Cmd+Shift+. in a Finder window toggles hidden files if you ever want to look at it directly), or just open it by path.

It has five sections (all but `keybinds` and `workspaces` optional):

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
  },
  "autoReloadConfig" : true
}
```

**`keybinds`**: each value is the name of a key, lowercase. Letters (`"a"`–`"z"`), digits, and a few named keys (`"space"`, `"escape"`, `"return"`, `"tab"`, `"delete"`, `"up"`, `"down"`, `"left"`, `"right"`, `"pageup"`, `"pagedown"`) are recognized, that list lives in `keyCode(forName:)` in `Keybinds.swift` if you ever want to see or extend it. Tab itself can't be reassigned, it's permanently what opens the switcher. Careful with combinations macOS itself already reserves system-wide (Space for Spotlight is the one that bit the original default here). Those will keep doing their system behavior no matter what this file says, since AeroSwitcher can't override the OS's own reserved shortcuts.

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

**`autoReloadConfig`**: optional, defaults to `true`. Reload config.json by itself whenever it's saved. Set it to `false` to only reload when you ask (see below).

### Reloading

Works the same way as AeroSpace's own config:

- **Save the file and it applies.** AeroSwitcher watches config.json and reloads it within about a second of a save (unless `autoReloadConfig` is `false`). It also notices editors that save by replacing the file with a new copy, like TextEdit.
- **Errors keep your previous settings.** If the file can't be used at all (invalid JSON such as a missing comma, or a value of the wrong kind such as `"showTileStatusText": "yes"`), AeroSwitcher keeps using the settings it had before and opens a small **AeroSwitcher config** window that says what's wrong and roughly where (line and column for JSON typos, or the exact setting, like `workspaces.Core[2].open is missing`). Only if this happens at launch, with nothing earlier to keep, does it use its built-in defaults until the file is fixed.
- **Warnings apply everything else.** Smaller mistakes only switch off the one thing that's wrong, and are listed in the same window: a key name that isn't recognized (that action uses its default key), two actions on the same key, an action on the reserved Tab key, an icon file that won't load, an unknown `newWindowStyle`, and any setting name AeroSwitcher doesn't know (usually a typo, which would otherwise silently do nothing).
- **The window closes by itself** after a save with no problems left. It never takes the keyboard away from your editor; click it to use it. **Open config.json** opens the file, **Reload** reloads both configs (below).
- **Reload config** in the menu bar menu does the same as `pkill -HUP AeroSwitcher`.

**Reloading AeroSwitcher and AeroSpace together.** `pkill -HUP AeroSwitcher` reloads config.json AND runs `aerospace reload-config --no-gui`, then shows any problems from both in the same window. To put that on a key, add a line like this to the `[mode.main.binding]` section of `~/.aerospace.toml` (the part after `||` reloads AeroSpace alone if AeroSwitcher isn't running):

```toml
alt-shift-r = 'exec-and-forget pkill -HUP -x AeroSwitcher || aerospace reload-config'
```

Saving `~/.aerospace.toml` still only reloads AeroSpace (its own `auto-reload-config`), since AeroSwitcher doesn't read that file. Everything is also `print`ed, so running `/Applications/AeroSwitcher.app/Contents/MacOS/AeroSwitcher` from Terminal shows the same messages there.

**Testing a config without touching your real one:** start a copy from Terminal with `AEROSWITCHER_CONFIG_DIR=/some/folder` set, and it reads (and creates) config.json in that folder instead. Quit the normal AeroSwitcher first, two copies would both catch Cmd+Tab (a test copy skips the one-copy check on purpose).

## `~/.aerospace.toml`

This is AeroSpace's own config file, separate from AeroSwitcher, but AeroSwitcher depends on parts of it.

**Workspaces**: Core, School, Personal, Creative, Dev, Gaming, laid out on a 3x3 key grid under your left hand (Alt+Q/W/E/A/S/D switches workspaces, Alt+Shift+Q/W/E/A/S/D sends the focused window to one).

**Auto-sorting apps into workspaces** (the `on-window-detected` block): every time an app opens, a rule checks its `.app` bundle path and moves it to the right workspace automatically. Matching is done on bundle *path* rather than bundle *ID*, for two reasons. First, some apps (like Steam) have their actual on-screen window owned by a separate helper process with a different bundle ID than the main app, so an ID based rule can silently never match. Second, some apps (like Safari-installed web apps) get a random bundle ID assigned that can change, but the file name on disk stays stable. Every rule was checked against the real `/Applications` folder to make sure no two rules could ever accidentally match the same app.

Finder is deliberately left out of this block, since it's used across every workspace and forcing it into one would just fight you.

**The MRU logs**: `on-focus-changed` appends the newly focused window's ID to that workspace's own file under `/tmp/aerospace-mru/` every time focus changes. AeroSwitcher no longer needs this line (it records focus itself from `aerospace subscribe`, see **Remembering which window you used last**), it is only needed with an AeroSpace that has no `subscribe`. Keeping it is harmless.

`auto-reload-config = true` means saving this file applies changes immediately, no need to restart AeroSpace.

## Fullscreen / maximize toggle (alt-f)

This part isn't AeroSwitcher code at all, it's entirely `~/.aerospace.toml` plus three small script files, but it's worth documenting here since it directly affects how every window behaves.

**The goal**: every window fills the screen automatically when it opens, stays that way no matter how you switch between windows (Cmd+Tab, AeroSpace's own alt-tab, the Dock, anything), and only changes size when you personally press Alt+F. No flicker, ever.

**Why this doesn't use AeroSpace's own `fullscreen` command.** That was the first thing tried, and it doesn't work for this: AeroSpace automatically un-applies fullscreen the moment you switch away from a window, every time, with no config flag to stop it (this is confirmed behavior, tracked as a feature request on AeroSpace's own GitHub, issues #1475 and #1480). Reacting to that after the fact (re-apply fullscreen a moment after every switch) technically works but causes a visible flicker, since there's always a brief real gap between AeroSpace un-fullscreening a window and a script telling it to fullscreen again.

**Why this works instead**: every window is set to `layout floating` the moment it opens, in the `on-window-detected` block. Floating is a different management mode from AeroSpace's normal tiling. Confirmed straight from AeroSpace's maintainer (GitHub issue #1519): a **tiled** window has its position and size continuously re-enforced by AeroSpace, so anything else that tries to move or resize it (including a plain macOS resize) just gets snapped back. A **floating** window is the opposite, AeroSpace sets it up once and then leaves it alone completely. Switching focus, in any way, never touches a floating window's size or position again. That's what makes "always maximized until I say otherwise, zero flicker" actually possible, there's nothing to react to and nothing fighting the size you set.

**The three script files**, all living in `~/Library/Application Support/AeroSpace/` (this exact folder, not AeroSpace's own app folder, just a convenient place created for these scripts):

- **`maximize.applescript`** — resizes a window to fill the screen's usable area (below the menu bar, above the Dock). This is a real macOS window resize via System Events, nothing AeroSpace-specific. Runs automatically on every new window (via `on-window-detected`) and on one half of the `alt-f` toggle.
  - **Which window:** the exact one AeroSpace detected. AeroSpace passes the window's ID to the script (the `AEROSPACE_WINDOW_ID` environment variable), the script asks `aerospace list-windows` which app process owns it and what it's called, and resizes that window. Earlier versions resized "window 1 of the front app", which missed apps whose windows belong to a helper process. Steam is one: its windows belong to "Steam Helper", and the front app's only window is invisible.
  - **Dialogs are skipped:** a new window is only maximized if it has a green full screen button, or macOS says it can go full screen at all (for apps like Steam that hide the button and draw their own title bar). Every real window tested passed (native apps, Electron apps like Notion, VS Code and Obsidian, Spotify, Steam, second windows of the same app), and no dialog did (Open dialogs, the Fonts panel, Connect to Server, Get Info, Settings and Print windows, Steam's sign in and Special Offers popups). The check is retried for up to about a second, in case an app adds its buttons a moment after the window appears, so a dialog takes about a second to be ignored, invisibly.
  - `alt-f` runs it as `maximize.applescript force <window id>`, which skips the dialog check, so `alt-f` always works.
- **`restore.applescript`** — resizes the focused window (found by the ID `toggle-maximize.sh` passes it, same way as above) down to 70% of the screen, centered. The number `0.7` near the top of the file controls this, edit it directly if you want windows to restore to a different size, it's just a plain number.
- **`toggle-maximize.sh`** — what `alt-f` actually runs. It keeps a small empty marker file per window (under `/tmp/aerospace-restored/`, named by window ID) to remember which windows are currently in the smaller "restored" state. No marker means the window is currently maximized, so pressing `alt-f` runs `restore.applescript` and creates the marker; a marker present means it's currently restored, so `alt-f` runs `maximize.applescript force` (skipping the dialog check, since pressing `alt-f` is your own choice) and deletes the marker. It passes the window ID to both scripts, so they resize exactly the window you're on. This only ever runs when you actually press `alt-f`, it's not hooked into switching at all.

**In `~/.aerospace.toml`**: every rule in `on-window-detected` (the auto-sort-into-workspaces block) now does `layout floating` followed by `exec-and-forget osascript ".../maximize.applescript"`, right after the workspace move. The `alt-f` binding runs `toggle-maximize.sh` instead of AeroSpace's own `fullscreen` command.

**Permission needed**: since `maximize.applescript` and `restore.applescript` control another app's window through System Events, macOS requires **Accessibility** permission the first time this runs (System Settings > Privacy & Security > Accessibility). macOS should prompt for this automatically the first time a window opens after setting this up. If windows stop resizing and nothing else looks broken, that permission is the first thing to check, see whatever process is asking (likely `osascript` or AeroSpace itself) is listed and enabled there.

## Known limitations

- **A real window that can't go full screen won't maximize on its own.** New windows are only maximized if they have a green full screen button or macOS says they can go full screen, which is how dialogs get skipped (see `maximize.applescript` above). Every real window tested passed, but not every app in the world was tested. If an app's windows open small, press `alt-f` twice (shrink, then grow) to maximize them. Dialogs that are actually sheets (the Save dialog that slides out of a window's title bar) were never a problem, AeroSpace doesn't treat them as windows at all.
- **Dialogs can remember the big size from before.** macOS remembers each dialog's last size, so a dialog that the old script stretched opens full size until you shrink it once by hand. After that it stays small.
- **Notion reopening several windows at once may leave some at their old size.** Notion puts its own saved window sizes back right after launch, undoing the resize. Press `alt-f` twice on any window that opens small.
- **Spotify (and similar DRM-protected apps)** will always show a static screenshot, never a live thumbnail. This is a macOS/hardware limitation, not something fixable in this app.
- **The `"workspaces"` list in `~/Library/Application Support/AeroSwitcher/config.json` is a manual copy** of the workspace groupings in `aerospace.toml`. The two can drift apart if only one gets updated.
- **No vertical scrolling within a normal switcher page.** If a single Cmd+Tab page somehow still ends up too tall (extremely unlikely at normal window counts, since `maxRows` already caps it), there's no vertical scroll as a fallback, only pagination. The Cmd+\` overview does have one, for when a single workspace is too big for the panel (see the overview section above), and it scrolls with S/W (macOS 15+) or two fingers.
- **A deprecation warning on every build, and that's expected.** `build.sh` will print a warning about `fullPath(forApplication:)` being deprecated, pointing at `resolvedAppIcon` in `Config.swift` (the function that finds a QUIT app's real icon by name, for the greyed launcher row's automatic icons). This is intentional, not a mistake left behind: Apple's suggested replacement needs a bundle identifier, but config.json only ever has app names/paths (`match`/`open`), never bundle identifiers, so there's no non-deprecated API that does the same name-based lookup. The build still succeeds and the app works normally, this warning is cosmetic. The only way to avoid it entirely would be replacing this one lookup with a manual scan of `/Applications`, `/System/Applications`, and `~/Applications` instead of asking macOS directly, which trades a clean build log for missing apps installed in less common locations, judged not worth it.

## Version numbers

Three numbers, shown in the About panel and printed on the first line when the app starts (`AeroSwitcher 0.9.0 (build 57, a1b2c3d)`):

- **Version** (`0.9.0`): the only one typed by hand, as `CFBundleShortVersionString` in `Info.plist`. Raise the middle number when a phase ships and the last one for fixes. 1.0.0 is for when strangers can install it (Phase 12).
- **Build** (`57`): the number of git commits so far (`git rev-list --count HEAD`). `build.sh` writes it into the copy of `Info.plist` inside the app (`CFBundleVersion`), so the file in the repo never changes because of a build. The build is made before its own commit, so a build made from a change shows the count from before that commit.
- **Commit** (`a1b2c3d`): the short git hash, with `-dirty` added when there were uncommitted changes, so a test build can be told apart from a committed one (`AeroSwitcherCommit` in the bundle's `Info.plist`).

Built without git (for example from a ZIP download), the build still works and says build 0, commit `unknown`. Run without an app bundle (`swift run`) it says "dev build". The code that reads them is `appVersion()` in `Config.swift`.

## Permissions this app needs

- **Input Monitoring**: required for the Cmd+Tab interception (`CGEventTap`) to see keystrokes at all.
- **Screen Recording**: required for `ScreenCaptureKit` to take window screenshots.

Both are granted per-app in System Settings > Privacy & Security, to AeroSwitcher.app specifically. If thumbnails stop appearing or Cmd+Tab stops responding after a rebuild, check that AeroSwitcher is still listed and enabled under both. The menu bar menu's **Permissions** item and the **Setup window** show both at a glance.

There's a third permission the setup as a whole needs, **Accessibility**, but it isn't AeroSwitcher's own, it belongs to the maximize/floating toggle system described above (see **Fullscreen / maximize toggle**), which is entirely AeroSpace config and separate script files, not this app's code. Worth knowing about here since without it, windows will stop resizing even though AeroSwitcher itself is working fine.

## Packaging it as your daily-use app

A few things worth doing once, when you're ready to stop rebuilding and just leave a final version running:

1. **Move the built `.app` to `/Applications`.** It'll run from anywhere, but `/Applications` is the standard, expected location, and it's where Login Items and Spotlight expect to find things.
2. **Re-grant permissions on that final copy.** Since it's ad-hoc signed (not a paid Developer ID), macOS ties Input Monitoring and Screen Recording to the exact signed binary. Moving or rebuilding it can make macOS treat it as "new" and ask again, so do one full test (open the switcher, confirm thumbnails and Cmd+Tab both work) after moving it, before you rely on it daily.
3. **Start it at login.** Open AeroSwitcher from `/Applications`, then tick **Launch at login** in its menu bar menu (or in the settings window). This uses Apple's own login item API (`SMAppService`) and shows up in System Settings > General > Login Items & Extensions. It refuses to change this from a copy outside an Applications folder, in either direction: macOS remembers the path, so a login item pointing at a build folder would break, and a test build turning it off would remove the installed app's login item (they count as the same app). Adding it by hand there (click "+" under "Open at Login") also still works, and macOS treats that hand-made entry as the same login item: the menu shows it ticked. Either way, no separate LaunchAgent is needed. If AeroSwitcher somehow gets started twice at login, the second copy quits by itself.
4. **Stop rebuilding it after that.** Every rebuild changes its code signature, which is exactly the kind of thing that resets the permissions above. Once you've got the version you're happy with, treat it as done rather than a work in progress you keep touching.
5. **Optional sanity check**: log out and back in once (or restart) after setting up Login Items, just to confirm it actually launches on its own before you stop thinking about it.
