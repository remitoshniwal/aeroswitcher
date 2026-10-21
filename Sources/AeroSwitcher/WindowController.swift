import Cocoa
import SwiftUI
import ScreenCaptureKit

// MARK: - Window management

// Bundles everything needed to render one page of the switcher: which real
// rows and launcher rows fall on it, plus the page number itself.
private struct PageData {
    let realRows: [[ThumbnailItem]]
    let launcherRows: [[LauncherTile]]
    let totalRowCount: Int
    let page: Int
    let totalPages: Int
}

@MainActor
class SwitcherWindowController: NSObject {
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    var items: [ThumbnailItem] = []
    var selectedIndex = 0
    var launcherItems: [LauncherApp] = []
    // nil while Tab-cycling real windows normally. Set to an index into
    // launcherItems the moment you press the down arrow to "enter" the
    // grayed-out row. Cmd+Tab / arrow-cycling real windows always resets
    // this back to nil first, so Tab can never land selection on a grayed
    // tile — that's what keeps them out of the normal cycling order.
    var launcherSelectedIndex: Int? = nil
    // Which page you're LOOKING at, when it's different from wherever your
    // selection currently is. nil means "just show whatever page contains
    // the current selection" (the normal, default behavior). Set only by
    // Page Up / Page Down, and cleared the instant selection moves again,
    // so browsing and picking never fight each other.
    var manualPageOverride: Int? = nil
    var isLoading = false
    var mru: MRUTracker?
    // Self-contained (unlike mru, nothing outside the controller needs
    // it), so it's just created here directly rather than wired in from
    // the app-entry Task.
    let appWorkspaceTracker = AppWorkspaceTracker()

    // True only for a session opened with Cmd+` (see handleOverviewKey) —
    // shows a read-only overview of every workspace at once (app icons +
    // window counts, no thumbnails, no selection) instead of the normal
    // interactive single-workspace switcher. Reset back to false at the
    // start of every normal Cmd+Tab session too, so it can never leak from
    // one session into the next.
    private(set) var showingAllWorkspaces = false
    // What the overview panel shows — rebuilt fresh every time it opens,
    // sorted alphabetically by workspace name.
    var workspaceSummaries: [WorkspaceSummary] = []
    // Workspace sections, already split into pages — each page packed with
    // as many sections as actually fit within the panel's height (same
    // budget as the normal switcher: windowMaxHeight()), computed fresh
    // every time the overview opens by computeOverviewPages(). Sections
    // vary in height (an app-heavy workspace needs more icon rows than an
    // empty one), so this is a greedy fit rather than a fixed count per
    // page — first page gets as many as fit, then the next page starts
    // fresh, same idea as the normal switcher packing rows into pages.
    private var overviewPages: [[WorkspaceSummary]] = []
    // Which page of workspaces the overview is currently showing. Reset to
    // 0 at the start of every overview session.
    private var overviewPageIndex = 0
    // W/S scrolling for the rare overview page that's taller than the
    // panel (see overviewPageNeedsScroll). The keys arrive here, through
    // HotkeyManager's event tap, but only the SwiftUI scroll view knows
    // how tall its content really is and where it's currently scrolled
    // to (two-finger scrolling moves it too). So the controller doesn't
    // track a position at all, it just passes each W/S press along as a
    // request, and the view does the actual scrolling (see
    // OverviewScrollArea in Views.swift).
    private var overviewScrollRequest = OverviewScrollRequest()
    // Bumped at the start of every overview session and on every page
    // change. The view throws away its scroll position whenever this
    // changes, so every page always opens scrolled to the top.
    private var overviewScrollResetKey = 0
    // Whatever window was actually focused right before the overview panel
    // took over, so Escape/Cmd-release can hand focus back to it. Only used
    // in overview mode — the normal switcher uses items.first for this
    // instead, since it already has the full window list.
    private var originalFocusedWindow: AeroWindow?

    private var isVisible = false
    var isOpen: Bool { isVisible }

    // True from the moment Cmd+Tab is first pressed until the session ends,
    // even while the window is still loading. isOpen alone isn't enough to
    // gate on: it only flips true once thumbnails finish loading and the
    // window actually appears, which is asynchronous. If Cmd got released
    // before that finished, checking isOpen would see "not open yet" and
    // silently ignore the release — that's the bug where the panel got
    // stuck on screen.
    private var sessionActive = false
    // If Cmd was released before we finished loading, act on it the instant
    // loading completes instead of leaving the panel open with nothing left
    // to close it.
    private var confirmPending = false
    // Set right before show() when a fresh normal-switcher session starts
    // with Shift held (Cmd+Shift+Tab from cold) — tells show() to land the
    // initial selection on the LAST window (least-recently-used) instead
    // of the second one, matching native macOS's own Cmd+Shift+Tab.
    private var pendingStartReversed = false

    // Single entry point for every Cmd+Tab / Cmd+Shift+Tab keydown — this
    // is back to matching native macOS Cmd+Tab exactly, now that Cmd+`
    // (see handleOverviewKey, below) is its own separate key for opening
    // the overview instead of sharing Tab with Shift:
    //   - Nothing open: Shift decides where you land — plain Cmd+Tab lands
    //     one window forward (the normal, most common case), Cmd+Shift+Tab
    //     lands on your least-recently-used window instead.
    //   - Already open: Shift always just means "go backward". In the
    //     normal switcher that's the previous window; in the overview
    //     (which has no window selection) Tab/Shift+Tab instead page
    //     through workspaces, same physical key as everything else that
    //     cycles through something.
    func handleTabPress(reverse: Bool) {
        guard sessionActive else {
            beginSession(startReversed: reverse)
            return
        }
        if showingAllWorkspaces {
            if reverse { overviewPageUp() } else { overviewPageDown() }
            return
        }
        if reverse { movePrevious() } else { moveNext() }
    }

    private func beginSession(startReversed: Bool) {
        guard !sessionActive else { moveNext(); return }  // shouldn't happen via handleTabPress, kept as a safe fallback
        sessionActive = true
        confirmPending = false
        showingAllWorkspaces = false
        pendingStartReversed = startReversed
        show()
    }

    // Cmd+` (backtick, no Shift) — the all-workspaces overview's own key,
    // completely separate from Cmd+Tab. Only does anything from cold;
    // pressed while a session (either switcher) is already open, it's
    // ignored rather than trying to switch modes mid-session.
    func handleOverviewKey() {
        guard !sessionActive else { return }
        sessionActive = true
        confirmPending = false
        showingAllWorkspaces = true
        overviewPageIndex = 0
        overviewScrollResetKey += 1
        show()
    }

    // Called when Cmd is released. If the panel's already up, confirm and
    // close normally. If it's still loading, remember to act the moment it
    // finishes rather than leaving things stuck.
    func endSession() {
        guard sessionActive else { return }
        if isOpen {
            confirmSelection()
        } else {
            confirmPending = true
        }
    }

    private func show() {
        guard !isLoading else { return }
        isLoading = true

        if showingAllWorkspaces {
            showOverview()
            return
        }

        Task { @MainActor in
            defer { isLoading = false }
            guard #available(macOS 14.0, *) else { sessionActive = false; return }

            // Asking AeroSpace for the window list (a subprocess), asking
            // ScreenCaptureKit for its shareable-content snapshot, and
            // asking AeroSpace which workspace is focused don't depend on
            // each other, so kick off all three at once instead of waiting
            // for one to finish before starting the next. The AeroSpace
            // calls also run off the main actor so the subprocess wait
            // can't stall the UI.
            async let windowListTask = Task.detached { getWindows(scope: "focused") }.value
            // excludingDesktopWindows skips the wallpaper/desktop-icon layer
            // from the enumeration, never something you'd want in the
            // switcher anyway, so this is a free speedup. onScreenWindowsOnly
            // was tried too, but it silently drops any window you've
            // manually minimized (yellow button) since a minimized window
            // isn't technically "on screen" — since you do minimize things
            // sometimes, that trade wasn't worth it, so it's back to false.
            async let contentTask: SCShareableContent? = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            async let workspaceNameTask = Task.detached { getCurrentWorkspaceName() }.value
            // Needed for orphanedRunningApps below — has to be the FULL
            // cross-workspace list, not just this workspace's, since "zero
            // windows on the entire Mac" is what actually makes an app
            // unreachable, not just "zero windows here."
            async let allWindowsTask = Task.detached { getWindows(scope: "all") }.value

            // Used to bail out here the moment the workspace had zero real
            // windows open — but an empty workspace can still have greyed
            // launcher tiles worth showing (apps that belong there but
            // just aren't running yet), so keep going even when this is
            // empty and only actually give up once launcher tiles turn out
            // to be empty too, below.
            let rawWindows = await windowListTask
            // Awaited here (rather than later) so the MRU sort below knows
            // which workspace's own history to use. Costs nothing extra:
            // this task started concurrently with the others above, so by
            // now it's essentially always already finished.
            let workspaceName = await workspaceNameTask
            let windows = mru?.sorted(rawWindows, workspace: workspaceName) ?? rawWindows

            let content = await contentTask
            let loaded = await captureAll(windows, content: content)
            let configuredLauncherItems = missingLauncherApps(workspace: workspaceName, runningItems: loaded)
            let allWindows = await allWindowsTask
            // Keep the tracker current with today's real cross-workspace
            // snapshot before asking it anything, so orphanedRunningApps
            // below always sees the freshest "last known workspace" data.
            self.appWorkspaceTracker.record(allWindows)
            // Apps running with no window anywhere AND no config entry in
            // any workspace — added on top of your configured tiles rather
            // than replacing them, so a genuinely homeless running app is
            // never just invisible. Only shown here if this IS its
            // tracked workspace (or it has no tracked workspace yet); an
            // app configured for, or last seen in, a DIFFERENT workspace
            // is deliberately excluded — it already has (or will have) a
            // proper place to show up, it shouldn't also show up here.
            // sortedLauncherItems puts everything actually alive (Running
            // + orphaned "No window" tiles) ahead of fully Quit apps, so
            // the row reads left-to-right as "stuff you could jump
            // straight to" before "stuff that needs a fresh launch."
            self.launcherItems = sortedLauncherItems(configuredLauncherItems + orphanedRunningApps(allWindows: allWindows, workspace: workspaceName, tracker: self.appWorkspaceTracker))

            // Truly nothing to show at all — no real windows, no launcher
            // tiles either. Only now is there actually nothing to open for.
            guard !loaded.isEmpty || !self.launcherItems.isEmpty else { sessionActive = false; return }
            self.items = loaded

            self.manualPageOverride = nil  // fresh session always starts on the page your selection is on

            if loaded.isEmpty {
                // No real windows at all — land straight on the greyed
                // launcher row instead of trying to select a real window
                // that doesn't exist.
                self.selectedIndex = 0
                self.launcherSelectedIndex = 0
            } else {
                self.launcherSelectedIndex = nil
                // A single tap should already move OFF the window you're
                // on, same as native Cmd+Tab — the current window stays
                // first in the (unchanged) MRU order, but the highlight
                // starts one over. Cmd+Shift+Tab from cold instead lands on
                // the LAST window (least-recently-used), same as native
                // macOS's own Cmd+Shift+Tab.
                if self.pendingStartReversed {
                    self.selectedIndex = loaded.count - 1
                } else {
                    self.selectedIndex = loaded.count > 1 ? 1 : 0
                }
            }

            if confirmPending {
                // Cmd was already released while this was loading — jump
                // straight to confirming the selected tile (focusing a
                // window, or launching an app if it landed on the greyed
                // row), no need to ever flash the panel open for a press
                // this quick. confirmSelection() already resets
                // sessionActive/confirmPending via hide().
                confirmPending = false
                confirmSelection()
                return
            }

            self.present()
        }
    }

    // The Cmd+` overview: much lighter than the normal switcher since
    // there's no ScreenCaptureKit thumbnail capture involved at all, just
    // two AeroSpace CLI calls (the window list and the workspace list)
    // plus each app's own icon, which is instant.
    private func showOverview() {
        Task { @MainActor in
            defer { isLoading = false }

            // Captured BEFORE the panel takes over keyboard focus, so
            // Escape/Cmd-release can hand focus back to whatever you were
            // actually using — the overview itself never focuses anything.
            async let focusedTask = Task.detached { getFocusedWindow() }.value
            async let windowsTask = Task.detached { getWindows(scope: "all") }.value
            async let namesTask = Task.detached { getAllWorkspaceNames() }.value

            self.originalFocusedWindow = await focusedTask
            let windows = await windowsTask
            // Alphabetical rather than whatever order AeroSpace happens to
            // list workspaces in — so the overview's layout is always the
            // same and predictable, not dependent on definition order in
            // ~/.aerospace.toml or which ones you've visited recently.
            let names = await namesTask.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            // Keep the tracker current with today's real snapshot first,
            // same as the normal switcher does.
            self.appWorkspaceTracker.record(windows)
            let homeless = homelessRunningApps(allWindows: windows, tracker: self.appWorkspaceTracker)
            // Homeless apps with a remembered workspace merge straight
            // into that workspace's own card (as a dimmed, windowCount-0
            // entry — see WorkspaceAppIcon) instead of a separate section,
            // so Preview closed while you were on Dev shows up ON Dev,
            // same "stays where it came from" behavior as the switcher.
            let tracked = homeless.filter { $0.lastWorkspace != nil }
            let extraByWorkspace = Dictionary(grouping: tracked, by: { $0.lastWorkspace! })
                .mapValues { $0.map(homelessAppSummary) }
            var summaries = buildWorkspaceSummaries(allWorkspaceNames: names, windows: windows, extraApps: extraByWorkspace)

            // Only apps AeroSwitcher has genuinely never seen with a
            // window at all get the separate "Running, no window" section
            // — there's no workspace to credibly put those on. Only added
            // when there's actually at least one, so a Mac with nothing
            // truly homeless never shows an empty section for it.
            let untracked = homeless.filter { $0.lastWorkspace == nil }
            if !untracked.isEmpty {
                summaries.append(WorkspaceSummary(name: "Running, no window", apps: untracked.map(homelessAppSummary)))
            }
            self.workspaceSummaries = summaries
            self.overviewPages = computeOverviewPages(self.workspaceSummaries)

            guard !self.workspaceSummaries.isEmpty else { sessionActive = false; return }

            if confirmPending {
                // Nothing to "confirm" in a read-only panel — Cmd was
                // released before loading even finished, so just close
                // straight back up without ever flashing it open.
                confirmPending = false
                closeOverview()
                return
            }

            self.present()
        }
    }

    func moveNext() {
        guard !items.isEmpty else { return }
        launcherSelectedIndex = nil  // Tab always snaps back to the real windows
        manualPageOverride = nil     // ...and to whatever page that selection is actually on
        selectedIndex = (selectedIndex + 1) % items.count
        refresh()
    }

    func movePrevious() {
        guard !items.isEmpty else { return }
        launcherSelectedIndex = nil
        manualPageOverride = nil
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        refresh()
    }

    // Left/right arrow while focus is already on the grayed-out row —
    // moves between launcher tiles instead of real windows.
    func moveLauncherNext() {
        guard !launcherItems.isEmpty else { return }
        manualPageOverride = nil
        let current = launcherSelectedIndex ?? 0
        launcherSelectedIndex = (current + 1) % launcherItems.count
        refresh()
    }

    func moveLauncherPrevious() {
        guard !launcherItems.isEmpty else { return }
        manualPageOverride = nil
        let current = launcherSelectedIndex ?? 0
        launcherSelectedIndex = (current - 1 + launcherItems.count) % launcherItems.count
        refresh()
    }

    // Page Up / Page Down: jump to another page AND select its first tile
    // (real window or greyed launcher app, whichever the page starts with).
    // Earlier this only changed what was drawn without touching selection,
    // but that left pages you could land on with nothing highlighted at
    // all, no way to tell what Return would even do. Selecting the first
    // tile as you land fixes that, and it's just as fast to keep arrowing
    // from there if the one you want isn't first.
    func jumpPage(by delta: Int) {
        let data = pageData()
        guard data.totalPages > 1 else { return }
        let base = manualPageOverride ?? data.page
        let newPage = min(max(base + delta, 0), data.totalPages - 1)
        selectFirstItem(onPage: newPage)
        manualPageOverride = nil  // selection now lives on newPage, so normal auto-follow already shows it
        refresh()
    }

    private func selectFirstItem(onPage page: Int) {
        let realRows = chunk(items)
        let launcherRows = chunk(launcherItems)
        let startRow = page * maxRows
        if startRow < realRows.count {
            launcherSelectedIndex = nil
            selectedIndex = min(startRow * capacity, max(items.count - 1, 0))
        } else {
            let launcherRowIndex = startRow - realRows.count
            guard launcherRowIndex < launcherRows.count else { return }
            launcherSelectedIndex = min(launcherRowIndex * capacity, max(launcherItems.count - 1, 0))
        }
    }

    // Confirms whatever is currently selected, whether that's a real window
    // or a launcher tile. Used by both the Return key and by releasing Cmd,
    // so the two can never disagree about what "confirm" means. The
    // overview panel is read-only, so there's nothing to "confirm" there —
    // Cmd-release/Return/F just close it, same as Escape.
    func confirmSelection() {
        if showingAllWorkspaces { closeOverview(); return }
        if let idx = launcherSelectedIndex, launcherItems.indices.contains(idx) {
            launchApp(launcherItems[idx])
            hide()
            return
        }
        // Even with nothing to focus, still close the panel — leaving it
        // open here would strand it in a state where the session never
        // properly ends, and Cmd+Tab afterward would think a session was
        // already running instead of starting a fresh one.
        guard !items.isEmpty else { hide(); return }
        focusWindow(id: items[selectedIndex].id, pid: items[selectedIndex].appPID)
        hide()
    }

    // Shared by Escape and by confirmSelection() while the overview is
    // open — both mean the same thing in a read-only panel, just hand
    // focus back to whatever was actually focused before it opened.
    private func closeOverview() {
        if let original = originalFocusedWindow {
            focusWindow(id: original.id, pid: original.appPID)
        }
        hide()
    }

    private var overviewTotalPages: Int { max(1, overviewPages.count) }

    // Just the workspaces that belong on the CURRENT overview page —
    // WorkspacesOverviewView only ever draws whatever it's handed, all the
    // "which page has what" math (computeOverviewPages, below) already ran
    // once when the overview opened.
    private func overviewPageSlice() -> [WorkspaceSummary] {
        guard overviewPageIndex < overviewPages.count else { return [] }
        return overviewPages[overviewPageIndex]
    }

    // Tab/Shift+Tab and A/D (your configured cycleNext/cyclePrevious) page
    // through the overview — same physical keys as everything else that
    // cycles through something in this app, rather than a separate set
    // just for this one panel.
    func overviewPageUp() {
        guard overviewTotalPages > 1 else { return }
        overviewPageIndex = max(overviewPageIndex - 1, 0)
        overviewScrollResetKey += 1
        refresh()
    }

    func overviewPageDown() {
        guard overviewTotalPages > 1 else { return }
        overviewPageIndex = min(overviewPageIndex + 1, overviewTotalPages - 1)
        overviewScrollResetKey += 1
        refresh()
    }

    // S (your configured enterGreyedRow) and W (exitGreyedRow) scroll the
    // overview, but only on a page that's actually taller than the panel.
    // The overview has no greyed launcher row, so these keys were doing
    // nothing there, and they sit right next to A/D, so scrolling stays
    // left-handed like everything else. On a normal page they still do
    // nothing. HotkeyManager calls the first one when S/W goes DOWN (only
    // the real press, not macOS's key repeats) and the second when it
    // comes back UP. The view's glide engine turns that into "tap = one
    // row, hold = keep gliding" (see OverviewGlide in Views.swift).
    func overviewScrollPressed(direction: CGFloat) {
        guard overviewPageNeedsScroll() else { return }
        overviewScrollRequest = OverviewScrollRequest(id: overviewScrollRequest.id + 1, direction: direction, isPressed: true)
        refresh()
    }

    func overviewScrollReleased() {
        guard overviewPageNeedsScroll(), overviewScrollRequest.isPressed else { return }
        overviewScrollRequest = OverviewScrollRequest(id: overviewScrollRequest.id + 1, direction: overviewScrollRequest.direction, isPressed: false)
        refresh()
    }

    // Estimates roughly how tall one workspace section will render at, so
    // computeOverviewPages can decide how many fit per page — same idea as
    // rowHeight for the normal switcher, just for a section whose height
    // actually varies (more apps wrap onto more icon rows), rather than a
    // single fixed constant. These numbers mirror WorkspacesOverviewView's
    // own layout (icon size, fonts, spacing) closely enough to be a good
    // estimate without needing SwiftUI to actually measure anything ahead
    // of time.
    private func estimatedOverviewSectionHeight(_ workspace: WorkspaceSummary, availableWidth: CGFloat) -> CGFloat {
        // Each workspace renders inside its own card (see
        // WorkspacesOverviewView) with cardPadding on every side, so that
        // padding counts toward the section's real height, and the inner
        // content (the icon grid) has cardPadding less width to work with
        // on the left AND right than the full available width. Every card
        // also has a shared minimum height (minCardContentHeight) so an
        // empty workspace's card isn't visibly shorter than a busy one's.
        let cardPadding = WorkspacesOverviewView.cardPadding
        if workspace.apps.isEmpty {
            return WorkspacesOverviewView.minCardContentHeight + cardPadding * 2
        }
        let spacing = WorkspacesOverviewView.iconSpacing
        let iconRows = estimatedOverviewIconRows(workspace, availableWidth: availableWidth)
        let gridHeight = CGFloat(iconRows) * WorkspacesOverviewView.iconRowHeight + CGFloat(max(iconRows - 1, 0)) * spacing
        let contentHeight = max(WorkspacesOverviewView.minCardContentHeight, WorkspacesOverviewView.headerHeight + gridHeight)
        return contentHeight + cardPadding * 2
    }

    // How many rows of icons a workspace's card wraps onto: as many
    // columns as fit across the card's inside width (the same sum the
    // view's LazyVGrid does), then however many rows the apps need. Its
    // own function because both the height estimate above and the W/S
    // scroll rows (overviewScrollRows) need it.
    private func estimatedOverviewIconRows(_ workspace: WorkspaceSummary, availableWidth: CGFloat) -> Int {
        let innerWidth = availableWidth - WorkspacesOverviewView.cardPadding * 2
        let columnWidth = WorkspacesOverviewView.iconColumnWidth
        let spacing = WorkspacesOverviewView.iconSpacing
        let columns = max(1, Int((innerWidth + spacing) / (columnWidth + spacing)))
        return Int(ceil(Double(workspace.apps.count) / Double(columns)))
    }

    // Panel height for the rare overview page that scrolls. At full height
    // the bottom edge of the scroll area would land wherever it happens to,
    // usually halfway through a row of icons. Instead this picks the
    // tallest height that still fits on screen AND ends exactly on a row's
    // bottom edge, so the page looks like it ends cleanly. Every W/S press
    // then keeps that bottom edge on a row edge too (S and W line rows up
    // with the bottom, see OverviewGlide in Views.swift), so it stays clean
    // while scrolling. Only that page gets this shorter panel. Every other
    // page keeps the usual full height.
    private func overviewScrollPanelHeight(rows: [OverviewScrollRow]) -> CGFloat {
        let panelPadding: CGFloat = 48  // 24pt top + bottom
        let gap = WorkspacesOverviewView.cardGap
        // What the view stacks under the scroll area: a cardGap down to the
        // (zero height) Spacer, and when there are page dots, another
        // cardGap plus the 6pt dots themselves. Counting these exactly is
        // the point here: the old budget's flat 22pt for the dots missed
        // one of those gaps, which is why rows used to get cut off.
        let below: CGFloat = overviewTotalPages > 1 ? gap + gap + 6 : gap
        let available = windowMaxHeight() - panelPadding - below
        let fitted = rows.map(\.bottom).filter { $0 <= available }.max() ?? available
        return fitted + panelPadding + below
    }

    // The rows W/S step through on a scrolling overview page, top to
    // bottom, each with where it starts and ends (measured down from the
    // top of the page). A workspace's FIRST row counts together with its
    // name as one taller row, since the name belongs with it. Every row's
    // edges sit halfway into the empty gap around it, so lining a row up
    // with the edge of the scroll area never cuts through app names or a
    // card's border. The scroll view uses these to move by exactly the
    // height of the next row each press, whatever that height is (see
    // OverviewGlide in Views.swift).
    //
    // These positions use the same layout numbers as the height estimate
    // (cardPadding, headerHeight, iconRowHeight...), which matched the
    // real panel to within a point when checked against a screenshot. The
    // very bottom is NOT taken from here: the scroll view measures that
    // itself, so the last press always lands exactly on the real bottom.
    private func overviewScrollRows() -> [OverviewScrollRow] {
        let budget = overviewContentBudget()
        let halfGap = WorkspacesOverviewView.cardGap / 2
        let halfSpacing = WorkspacesOverviewView.iconSpacing / 2
        let rowPitch = WorkspacesOverviewView.iconRowHeight + WorkspacesOverviewView.iconSpacing
        var rows: [OverviewScrollRow] = []
        var cardTop: CGFloat = 0
        for workspace in overviewPageSlice() {
            let cardBottom = cardTop + estimatedOverviewSectionHeight(workspace, availableWidth: budget.width)
            let firstRowTop = cardTop + WorkspacesOverviewView.cardPadding + WorkspacesOverviewView.headerHeight
            let iconRows = max(1, estimatedOverviewIconRows(workspace, availableWidth: budget.width))
            for row in 0..<iconRows {
                let rowTop = firstRowTop + CGFloat(row) * rowPitch
                let isFirst = row == 0
                let isLast = row == iconRows - 1
                rows.append(OverviewScrollRow(
                    // The first row starts at the card's top edge, so the
                    // workspace name comes along with it.
                    top: isFirst ? max(0, cardTop - halfGap) : rowTop - halfSpacing,
                    // The last row ends at the card's bottom edge, so the
                    // card's border and padding come along with it.
                    bottom: isLast ? cardBottom + halfGap : rowTop + WorkspacesOverviewView.iconRowHeight + halfSpacing
                ))
            }
            cardTop = cardBottom + WorkspacesOverviewView.cardGap
        }
        return rows
    }

    // Packs workspace sections into pages, greedily filling each page with
    // as many as actually fit within the panel's height budget before
    // starting the next — matches the normal switcher's own row-packing
    // philosophy (pageData()), just generalized to sections of unequal
    // height instead of uniform rows.
    //
    // Non-empty workspaces are packed first, empty ones are packed
    // separately afterward and always start on a fresh page — so a
    // "Nothing open" card never sits in the middle of a page next to
    // workspaces that actually matter, and once you've scrolled past the
    // busy ones, that's it, everything after is empty. `workspaces` is
    // already alphabetical coming in (see showOverview), and that order is
    // preserved within each of the two groups.
    private func computeOverviewPages(_ workspaces: [WorkspaceSummary]) -> [[WorkspaceSummary]] {
        let sectionSpacing = WorkspacesOverviewView.cardGap  // must match the view's own VStack spacing
        let (availableWidth, availableHeight) = overviewContentBudget()

        func pack(_ list: [WorkspaceSummary]) -> [[WorkspaceSummary]] {
            var pages: [[WorkspaceSummary]] = []
            var currentPage: [WorkspaceSummary] = []
            var currentHeight: CGFloat = 0

            for workspace in list {
                let sectionHeight = estimatedOverviewSectionHeight(workspace, availableWidth: availableWidth)
                let neededHeight = currentPage.isEmpty ? sectionHeight : currentHeight + sectionSpacing + sectionHeight
                if !currentPage.isEmpty && neededHeight > availableHeight {
                    pages.append(currentPage)
                    currentPage = [workspace]
                    currentHeight = sectionHeight
                } else {
                    currentPage.append(workspace)
                    currentHeight = neededHeight
                }
            }
            if !currentPage.isEmpty { pages.append(currentPage) }
            return pages
        }

        let nonEmpty = workspaces.filter { !$0.apps.isEmpty }
        let empty = workspaces.filter { $0.apps.isEmpty }

        // The one exception to normal packing: a workspace with so many apps
        // open (roughly 100 on a 14" MacBook screen) that its card ALONE is
        // taller than the panel. Packing as usual would give it a page to
        // itself and push every other busy workspace onto the next page,
        // just because one of them got huge. Instead, every workspace that
        // has something open goes on ONE page, still in alphabetical order,
        // and that page scrolls (see overviewPageNeedsScroll). Empty
        // workspaces still get their own normal page(s) after it, same rule
        // as always: nothing empty mixed in with the ones that matter.
        let anyOversized = nonEmpty.contains { estimatedOverviewSectionHeight($0, availableWidth: availableWidth) > availableHeight }
        if anyOversized {
            return [nonEmpty] + pack(empty)
        }
        return pack(nonEmpty) + pack(empty)
    }

    // The width and height the overview's workspace cards actually get to
    // use, once the panel's own padding and the page dots are taken out of
    // windowMaxWidth()/windowMaxHeight(). Its own function rather than
    // local constants inside computeOverviewPages, because
    // overviewPageNeedsScroll (below) has to measure against the exact
    // same budget. If the two ever used different numbers, a page could be
    // packed as "fits" but drawn as "scrolls", or the other way round.
    private func overviewContentBudget() -> (width: CGFloat, height: CGFloat) {
        let panelPadding: CGFloat = 48     // 24pt top + bottom
        let dotsReserve: CGFloat = 22      // room for the page dots, reserved whether or not they end up shown
        return (windowMaxWidth() - panelPadding, windowMaxHeight() - panelPadding - dotsReserve)
    }

    // True only when the current overview page's cards, stacked with their
    // gaps, are taller than the panel. Normal packing never builds a page
    // like that (pack() starts a new page before going over), so in
    // practice this is only ever the "one workspace is oversized, so every
    // busy workspace shares one page" case from computeOverviewPages.
    // WorkspacesOverviewView uses this to put just that page in a scroll
    // view. Every normal page gets false and is drawn exactly as before.
    // This only decides WHETHER a page scrolls, from the same estimate the
    // packing uses. How FAR it can scroll is measured by the scroll view
    // itself, never estimated here, so the last W/S press always lands
    // exactly on the real bottom of the page.
    private func overviewPageNeedsScroll() -> Bool {
        let page = overviewPageSlice()
        guard !page.isEmpty else { return false }
        let budget = overviewContentBudget()
        let cardsHeight = page.reduce(0) { $0 + estimatedOverviewSectionHeight($1, availableWidth: budget.width) }
        let gapsHeight = CGFloat(page.count - 1) * WorkspacesOverviewView.cardGap
        return cardsHeight + gapsHeight > budget.height
    }

    var rowHeight: CGFloat {
        cardSize.height + 40  // thumbnail + label + spacing
    }

    private func windowMaxWidth() -> CGFloat {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1200
        return screenWidth * 0.85
    }

    private func windowMaxHeight() -> CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return screenHeight * 0.8
    }

    private let columnSpacing: CGFloat = 16
    private var columnStride: CGFloat { cardSize.width + columnSpacing }

    // How many columns comfortably fit without scrolling, computed fresh
    // from the current screen size every time.
    private var capacity: Int {
        max(1, Int(windowMaxWidth() / columnStride))
    }

    // How many rows comfortably fit vertically, same idea as capacity but
    // for height. Once there are more rows than this, they spill onto
    // additional pages instead of making the panel taller than the screen.
    private var maxRows: Int {
        max(1, Int(windowMaxHeight() / rowHeight))
    }

    private func chunk<T>(_ array: [T]) -> [[T]] {
        guard capacity > 0, !array.isEmpty else { return [] }
        return stride(from: 0, to: array.count, by: capacity).map {
            Array(array[$0..<min($0 + capacity, array.count)])
        }
    }

    // The single source of truth for "what does the panel look like right
    // now": every real-window row, then the launcher row(s) right after
    // them, split into pages of maxRows rows each, then sliced down to
    // whichever page should currently be visible. That page defaults to
    // wherever the current selection lives, unless manualPageOverride says
    // otherwise.
    private func pageData() -> PageData {
        let realRows = chunk(items)
        let launcherRows = chunk(launcherItems)
        let totalRowCount = realRows.count + launcherRows.count
        let totalPages = max(1, Int(ceil(Double(max(totalRowCount, 1)) / Double(maxRows))))

        let selectedRealRow = items.isEmpty ? 0 : selectedIndex / max(1, capacity)
        let selectedLauncherRow: Int? = {
            guard let idx = launcherSelectedIndex, !launcherRows.isEmpty else { return nil }
            return realRows.count + (idx / max(1, capacity))
        }()
        let derivedRow = selectedLauncherRow ?? selectedRealRow
        let derivedPage = derivedRow / maxRows

        let page = min(manualPageOverride ?? derivedPage, totalPages - 1)
        let startRow = page * maxRows
        let endRow = min(startRow + maxRows, totalRowCount)

        var visibleReal: [[ThumbnailItem]] = []
        var visibleLauncher: [[LauncherTile]] = []
        if startRow < endRow {
            for rowIdx in startRow..<endRow {
                if rowIdx < realRows.count {
                    visibleReal.append(realRows[rowIdx])
                } else {
                    // Only worth checking isAppRunning for tiles actually
                    // shown on this page, not the whole roster every time.
                    let appsRow = launcherRows[rowIdx - realRows.count]
                    visibleLauncher.append(appsRow.map { LauncherTile(app: $0, isRunning: isAppRunning($0)) })
                }
            }
        }

        return PageData(realRows: visibleReal, launcherRows: visibleLauncher,
                         totalRowCount: totalRowCount, page: page, totalPages: totalPages)
    }

    private func rowWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return CGFloat(columnStride) }
        return CGFloat(count) * cardSize.width + CGFloat(count - 1) * columnSpacing
    }

    // Window is exactly as wide as it needs to be for however many columns
    // your current item count actually uses, capped at windowMaxWidth().
    // Beyond the cap, each row scrolls horizontally instead of growing.
    private func windowWidth() -> CGFloat {
        let columnsUsed = min(max(items.count, launcherItems.count, 1), capacity)
        return min(rowWidth(columnsUsed) + 48, windowMaxWidth())
    }

    private func currentView() -> SwitcherView {
        let data = pageData()
        let selectedItemID = items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
        let selectedLauncherID = launcherSelectedIndex.flatMap {
            launcherItems.indices.contains($0) ? launcherItems[$0].id : nil
        }
        let referenceColumns = min(max(items.count, launcherItems.count, 1), capacity)

        // Sized to what's actually on THIS page, not the tallest possible
        // page. A trailing page that's just the launcher row would otherwise
        // get stretched to full maxRows height, leaving a big empty gap
        // under one lone row of tiles.
        let effectiveRows = max(data.realRows.count + data.launcherRows.count, 1)
        // The divider itself only renders when there's a real row AND a
        // launcher row on this page — matches SwitcherView's own condition
        // exactly, so the reserved space and the actual drawn line never
        // disagree.
        let dividerAllowance: CGFloat = (!data.realRows.isEmpty && !data.launcherRows.isEmpty) ? 17 : 0
        let dotsAllowance: CGFloat = data.totalPages > 1 ? 22 : 0
        let height = rowHeight * CGFloat(effectiveRows) + dividerAllowance + dotsAllowance + 48

        return SwitcherView(
            visibleRealRows: data.realRows,
            visibleLauncherRows: data.launcherRows,
            selectedItemID: selectedItemID,
            selectedLauncherID: selectedLauncherID,
            referenceWidth: rowWidth(referenceColumns),
            maxWidth: windowWidth(),
            panelHeight: height,
            pageIndex: data.page,
            totalPages: data.totalPages,
            onPick: { [weak self] item in
                focusWindow(id: item.id, pid: item.appPID)
                self?.hide()
            },
            onLaunch: { [weak self] app in
                launchApp(app)
                self?.hide()
            }
        )
    }

    // Whichever panel is actually showing right now, type-erased to AnyView
    // since the two are completely different view trees (SwitcherView for
    // the normal switcher, WorkspacesOverviewView for the read-only
    // overview) hosted in the same NSHostingView. Also hands back the size
    // that view wants, computed alongside it so both stay in sync.
    private func currentPanelViewAndSize() -> (AnyView, NSSize) {
        if showingAllWorkspaces {
            // Same maximum footprint as the normal switcher, not a size of
            // its own — so the two panels feel like the same app, and
            // computeOverviewPages() (which already budgeted against these
            // same two numbers) and this stay in agreement.
            //
            // The one exception is the rare page that scrolls: its panel is
            // made a little shorter (see overviewScrollPanelHeight) so the
            // visible rows end cleanly instead of cutting one in half.
            let scrollable = overviewPageNeedsScroll()
            let scrollRows = scrollable ? overviewScrollRows() : []
            let height = scrollable ? overviewScrollPanelHeight(rows: scrollRows) : windowMaxHeight()
            let size = NSSize(width: windowMaxWidth(), height: height)
            let view = WorkspacesOverviewView(
                workspaces: overviewPageSlice(),
                pageIndex: overviewPageIndex,
                totalPages: overviewTotalPages,
                width: size.width,
                height: size.height,
                scrollable: scrollable,
                scrollRequest: overviewScrollRequest,
                scrollResetKey: overviewScrollResetKey,
                scrollRows: scrollRows
            )
            return (AnyView(view), size)
        }
        let view = currentView()
        return (AnyView(view), NSSize(width: windowWidth(), height: view.panelHeight))
    }

    // Creates the NSWindow and its SwiftUI host ONCE, the very first time
    // the switcher is opened, and reuses both on every later open. Tearing
    // down and rebuilding a whole window and view hierarchy on every single
    // Cmd+Tab press is allocation work that just isn't necessary, updating
    // an existing window's size and content is far cheaper.
    // A plain, borderless NSWindow can never become the "key" window (the
    // one that actually receives keyboard events) — that's an AppKit
    // default, not a bug. It's why the panel could show thumbnails and
    // react to clicks the whole time, but every arrow key, Return, and
    // Escape press was silently going nowhere. This tiny subclass just
    // says "yes, I can become key" so keyboard input actually reaches it.
    class SwitcherPanel: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private func ensureWindow() -> (NSWindow, NSHostingView<AnyView>) {
        if let window = window, let hostingView = hostingView {
            return (window, hostingView)
        }
        let (panelView, _) = currentPanelViewAndSize()
        let hosting = NSHostingView(rootView: panelView)
        let win = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.contentView = hosting
        self.window = win
        self.hostingView = hosting
        return (win, hosting)
    }

    private func present() {
        let (win, hosting) = ensureWindow()
        let (panelView, size) = currentPanelViewAndSize()

        // .rootView (rather than swapping in a new NSHostingView) lets
        // SwiftUI diff against what's already on screen instead of building
        // the whole view tree from nothing.
        hosting.rootView = panelView
        hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        win.setContentSize(size)
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    // Navigation used to live in a local NSEvent keyDown monitor here,
    // which needs this window to be the genuine OS-level key window to
    // ever fire. For a background/accessory app (no Dock icon) that's
    // surprisingly unreliable — the app can report itself as active and
    // key internally while the WindowServer doesn't actually agree, and
    // when that happens a local monitor just silently never fires, even
    // though everything looks focused from the inside. HotkeyManager's
    // global tap doesn't have that problem: it already reliably sees every
    // key regardless of focus state (that's how Tab and Cmd-release always
    // worked), so these are called from there instead, directly, while a
    // session is open — named after what each key DOES rather than which
    // physical key triggers it, since that's fully configurable now (see
    // config.json).
    func cycleForward() {
        if launcherSelectedIndex != nil { moveLauncherNext() } else { moveNext() }
    }

    func cycleBackward() {
        if launcherSelectedIndex != nil { moveLauncherPrevious() } else { movePrevious() }
    }

    // Jump onto the grayed-out row, if there's anything there
    func enterGreyedRow() {
        guard !launcherItems.isEmpty else { return }
        launcherSelectedIndex = 0
        manualPageOverride = nil
        refresh()
    }

    // Jump back off the grayed-out row. Only if there's an actual
    // real-window row to land on — with none open at all (an empty
    // workspace), there'd be nothing left selected at all otherwise.
    func exitGreyedRow() {
        guard launcherSelectedIndex != nil, !items.isEmpty else { return }
        launcherSelectedIndex = nil
        manualPageOverride = nil
        refresh()
    }

    // Escape — cancel, and hand focus back to whatever you were on.
    // items.first is always the window you were originally on (MRU-sorted,
    // never reordered by Tab-cycling). The overview panel has no items
    // (it never captures thumbnails), so it uses originalFocusedWindow
    // instead, via the same closeOverview() confirmSelection() also uses.
    func cancelSession() {
        if showingAllWorkspaces { closeOverview(); return }
        if let original = items.first {
            focusWindow(id: original.id, pid: original.appPID)
        }
        hide()
    }

    // Called by the normal switcher's own navigation (cycleForward,
    // enterGreyedRow, jumpPage, ...) and by the overview's own paging
    // (overviewPageUp/Down) — currentPanelViewAndSize() already knows
    // which of those is relevant based on showingAllWorkspaces.
    func refresh() {
        let (panelView, size) = currentPanelViewAndSize()
        hostingView?.rootView = panelView
        // Height can change page to page (a launcher row's divider only
        // shows up on the page it's actually on) and width can change with
        // item count, so keep the real window frame in sync too, not just
        // the SwiftUI content.
        if window?.frame.size != size {
            window?.setContentSize(size)
            window?.center()
        }
    }

    func hide() {
        window?.orderOut(nil)  // hidden, not destroyed — ensureWindow() reuses it next time
        isVisible = false
        sessionActive = false
        confirmPending = false
    }
}

