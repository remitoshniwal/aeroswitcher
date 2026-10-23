import Cocoa
import SwiftUI

// MARK: - SwiftUI view

// Purely presentational: it just draws whatever rows it's handed for the
// CURRENT page. All the "how many rows fit, which page is that" math lives
// in SwitcherWindowController below, so there's exactly one place that
// logic can go wrong instead of two.
struct SwitcherView: View {
    let visibleRealRows: [[ThumbnailItem]]
    let visibleLauncherRows: [[LauncherTile]]
    let selectedItemID: String?
    let selectedLauncherID: String?
    let referenceWidth: CGFloat  // every row centers under this same width
    let maxWidth: CGFloat
    let panelHeight: CGFloat
    let pageIndex: Int
    let totalPages: Int
    let onPick: (ThumbnailItem) -> Void
    let onLaunch: (LauncherApp) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 16) {
                ForEach(Array(visibleRealRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 16) {
                        ForEach(row) { item in
                            ThumbnailCard(item: item, isSelected: item.id == selectedItemID) { onPick(item) }
                        }
                    }
                    .frame(width: referenceWidth, alignment: .center)
                }

                if !visibleLauncherRows.isEmpty {
                    // A thin divider so the "not running yet" row never
                    // looks like just another row of open windows — but
                    // only when there's actually a real-window row above it
                    // to divide from. With zero windows open (everything's
                    // greyed out), there's nothing to separate the launcher
                    // row from, so the line would just be floating there
                    // for no reason.
                    if !visibleRealRows.isEmpty {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: referenceWidth, height: 1)
                    }

                    ForEach(Array(visibleLauncherRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 16) {
                            ForEach(row) { tile in
                                LauncherCard(app: tile.app, isRunning: tile.isRunning, isSelected: tile.app.id == selectedLauncherID) {
                                    onLaunch(tile.app)
                                }
                            }
                        }
                        .frame(width: referenceWidth, alignment: .center)
                    }
                }

                // Little dots showing which page you're on, only shown once
                // there's more than one — most of the time this never
                // appears at all.
                if totalPages > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<totalPages, id: \.self) { i in
                            Circle()
                                .fill(i == pageIndex ? Color.white.opacity(0.9) : Color.white.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(width: maxWidth, height: panelHeight)
        .background(.ultraThinMaterial)                       // native frosted-glass blur, like the real Cmd+Tab
        .clipShape(RoundedRectangle(cornerRadius: 20))         // rounds the WHOLE panel, not just the cards
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)  // faint edge so it doesn't disappear on light backgrounds
        )
    }
}

private struct ThumbnailCard: View {
    let item: ThumbnailItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: cardSize.width, height: cardSize.height)
                .background(Color(white: 0.15))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                )
            Text(item.appName)
                .foregroundColor(.white)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardSize.width)  // never let a long title stretch the column
        }
        .frame(width: cardSize.width)  // pin the whole card's width too
        .onTapGesture(perform: onTap)
    }
}

// A grayed-out placeholder for an app that belongs to this workspace but
// doesn't have a window here right now. That covers two different
// situations that look identical otherwise: the app is fully quit, or it's
// running fine just with no window in THIS workspace (another workspace,
// or none anywhere). isRunning tells them apart, shown as a small dot
// under the icon (the same convention as the Dock) plus a text label,
// since the dot alone is easy to miss at this size.
//
// A THIRD situation looks identical to those two without extra help:
// app.isOrphaned tiles (from orphanedRunningApps) aren't configured for
// this workspace at all, they're just an app with no window anywhere,
// shown on whichever workspace you happened to be viewing. The "No window"
// caption is the main way you tell them apart from a real "belongs here"
// tile, plus a deliberately opposite dimming choice below: isOrphaned
// tiles get the LIGHTER treatment (they're not really supposed to be
// here, but they're at least genuinely running), while actually-configured
// tiles get dimmed HARDER — running or quit, either way it's the
// workspace's own roster doing the not-currently-open-here waiting, so
// that's the one that should visually recede, not the app that showed up
// uninvited. That dimming (see `dim` below) applies to the box, the
// running-dot, the selection ring, and both text labels — NOT the icon
// itself, which always renders at full brightness regardless of any of
// this, so it stays recognizable even on a greyed tile.
private struct LauncherCard: View {
    let app: LauncherApp
    let isRunning: Bool
    let isSelected: Bool
    let onTap: () -> Void

    // Everything on a greyed tile dims by this amount EXCEPT the icon
    // itself, which stays at full, undimmed brightness — an icon at 15-30%
    // opacity is hard to actually recognize at a glance, defeating the
    // point of showing a real one at all. Kept as one named value so the
    // box, running-dot, selection ring, and both text labels all still
    // dim by the exact same amount they always did, just no longer
    // multiplied into the icon too.
    private var dim: Double { app.isOrphaned ? 0.6 : 0.4 }

    var body: some View {
        VStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.15))
                .frame(width: cardSize.width, height: cardSize.height)
                // Applied here, BEFORE the icon's .overlay() below, on
                // purpose — SwiftUI's .opacity() only affects the view
                // it's directly attached to, not content added via a
                // LATER .overlay() call. That's exactly what keeps this
                // dimming scoped to just the box itself and lets the icon
                // (added next) render at full brightness on top of it.
                .opacity(dim)
                .overlay(
                    Group {
                        // Three-way fallback, in order:
                        //   1. app.customIcon — this SPECIFIC entry's own
                        //      per-workspace "icon" field. Since an app
                        //      configured in several workspaces (Finder
                        //      being the obvious one) is actually several
                        //      separate LauncherAppConfig entries, one per
                        //      workspace, this only ever covers the exact
                        //      entry that set it — a workspace whose copy
                        //      of that entry didn't set "icon" falls
                        //      through, even if some OTHER workspace's
                        //      copy did.
                        //   2. customIcon(forAppName:) — config.json's
                        //      standalone top-level "icons" dict, checked
                        //      by name rather than by entry, so it applies
                        //      the same everywhere regardless of which
                        //      workspace's copy of an app this tile is.
                        //      This used to be missing here entirely (only
                        //      the overview checked it), which meant a
                        //      standalone "icons" entry silently never
                        //      showed up on the greyed launcher row at
                        //      all — fixed now, both sources are checked
                        //      wherever AeroSwitcher shows an icon.
                        //   3. resolvedAppIcon — this app's own real macOS
                        //      icon, so every tile shows something
                        //      recognizable even with no config at all.
                        if let shown = app.customIcon ?? customIcon(forAppName: app.matchKey) ?? resolvedAppIcon(matchKey: app.matchKey, openName: app.openName) {
                            // No opacity on the icon itself, deliberately
                            // — see `dim` above. Full brightness, same as
                            // any other icon in the app.
                            Image(nsImage: shown)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 44, height: 44)
                        } else {
                            // Same reasoning — full white, not dimmed,
                            // even though this is the rarer placeholder
                            // case (only shown if resolvedAppIcon couldn't
                            // find anything at all, e.g. a typo in "open").
                            Image(systemName: "app.dashed")
                                .font(.system(size: 36))
                                .foregroundColor(.white)
                        }
                    }
                )
                .overlay(alignment: .bottom) {
                    if isRunning {
                        Circle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 5, height: 5)
                            .padding(.bottom, 6)
                            .opacity(dim)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                        .opacity(dim)
                )
            Text(app.displayName)
                .foregroundColor(.white.opacity(app.isOrphaned ? 0.5 : 0.35))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardSize.width)
                .opacity(dim)
            // Off by default's the other way around — this line only draws
            // at all if config.json's showTileStatusText is true (the
            // built-in default). Set it to false for quieter tiles that
            // just rely on the running-dot above instead.
            if shouldShowTileStatusText(appConfig) {
                Text(app.isOrphaned ? "No window" : (isRunning ? "Running" : "Quit"))
                    .foregroundColor(.white.opacity(0.3))
                    .font(.system(size: 10))
                    .opacity(dim)
            }
        }
        .frame(width: cardSize.width)
        .onTapGesture(perform: onTap)
    }
}

// The Cmd+` overview: every workspace, purely to look at, a few at a time.
// No selection, no clicking, no arrow keys — just app icons and how many
// windows each has open, per workspace, so you can see everything without
// hunting through the normal switcher one workspace at a time. Escape or
// letting go of Cmd just closes it. `workspaces` is already just the
// slice for the CURRENT page, already sized to fit — same "controller does
// the math, this just draws it" split as SwitcherView. width/height match
// the normal switcher's own maximum panel size exactly (see
// currentPanelViewAndSize()), so the two panels feel like one app.
// Paging with Tab/Shift+Tab or A/D keeps the whole thing keyboard-driven
// with your left hand, same as the normal switcher, rather than needing
// the mouse/trackpad to scroll. Even the one page that does scroll
// (`scrollable` below) scrolls with W/S, with two-finger scrolling as an
// extra on top.
struct WorkspacesOverviewView: View {
    let workspaces: [WorkspaceSummary]
    let pageIndex: Int
    let totalPages: Int
    let width: CGFloat
    let height: CGFloat
    // Last resort for when one workspace has so many apps open that its
    // card alone is taller than the whole panel. Paging can't help there,
    // a page can't hold less than one workspace, so the controller puts
    // every busy workspace on one page instead (see computeOverviewPages
    // and overviewPageNeedsScroll) and that page scrolls with W/S or two
    // fingers instead of having its bottom rows cut off. False for every
    // normal page, which then draws exactly the same as it did before
    // this existed.
    let scrollable: Bool
    // The latest W/S press, passed along from the controller (the keys
    // arrive through its event tap, not through this view), and a number
    // that changes whenever the scroll position should go back to the top.
    let scrollRequest: OverviewScrollRequest
    let scrollResetKey: Int
    // The rows W/S step through on that page, with where each one starts
    // and ends, worked out by the controller (see overviewScrollRows).
    // Empty on every normal page.
    let scrollRows: [OverviewScrollRow]

    private let iconSize: CGFloat = 48

    // Shared sizing constants — computeOverviewPages (on the controller)
    // uses these exact same numbers to estimate section heights, so a
    // card's real size and its estimated size never drift apart from each
    // other. Keeping them in one place here, rather than copied as magic
    // numbers in two spots, is what keeps that guaranteed.
    static let cardPadding: CGFloat = 12          // inside each card, every side
    static let cardGap: CGFloat = 14              // between one workspace's card and the next
    static let headerHeight: CGFloat = 24         // workspace name + spacing before its content
    static let iconRowHeight: CGFloat = 48 + 4 + 14  // icon + inner spacing + name label
    static let iconColumnWidth: CGFloat = 48 + 20    // iconSize + the grid's minimum column width
    static let iconSpacing: CGFloat = 16             // the grid's row AND column spacing
    // Every card is at least this tall — one header plus one icon row's
    // worth of space — even a workspace with nothing open at all. That's
    // what keeps every card the same height in the common case (nothing,
    // or few enough apps to fit one row), rather than empty ones looking
    // noticeably shorter than busy ones. A workspace with enough apps to
    // wrap onto a second icon row still grows taller than this, real
    // content is never clipped to force a uniform height.
    static let minCardContentHeight: CGFloat = headerHeight + iconRowHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Self.cardGap) {
            if scrollable {
                // layoutPriority(1) makes the scroll area take ALL the
                // leftover height before the Spacer below gets any, so the
                // page dots stay pinned at the bottom of the panel like on
                // every other page, and only the cards move. .id() throws
                // away the scroll position whenever the controller bumps
                // scrollResetKey (new session or new page), so every page
                // opens scrolled to the top.
                OverviewScrollArea(request: scrollRequest, rows: scrollRows) {
                    VStack(alignment: .leading, spacing: Self.cardGap) {
                        ForEach(workspaces) { workspace in
                            workspaceCard(workspace)
                        }
                    }
                }
                .id(scrollResetKey)
                .layoutPriority(1)
            } else {
                ForEach(workspaces) { workspace in
                    workspaceCard(workspace)
                }
            }

            Spacer(minLength: 0)

            // Same page-dots convention as the normal switcher, only shown
            // once there's more than one page.
            if totalPages > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == pageIndex ? Color.white.opacity(0.9) : Color.white.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(24)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // One workspace's card. Pulled out of body only so the normal path and
    // the scrolling path above draw the exact same card, rather than two
    // copies of it that could slowly drift apart.
    private func workspaceCard(_ workspace: WorkspaceSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.name)
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 13, weight: .semibold))

            // No "Nothing open" label — an empty card is just the
            // name and blank space below it, at the same height a
            // one-row card would be.
            if !workspace.apps.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.iconColumnWidth), spacing: Self.iconSpacing)], alignment: .leading, spacing: Self.iconSpacing) {
                    ForEach(workspace.apps) { app in
                        WorkspaceAppIcon(app: app, iconSize: iconSize)
                    }
                }
            }
        }
        .frame(minHeight: Self.minCardContentHeight, alignment: .topLeading)
        .padding(Self.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A card per workspace, not just spacing between blocks of
        // text — makes it obvious at a glance where one workspace
        // ends and the next begins, especially once there are
        // several in a row.
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// One W/S key going down or coming back up in the overview, handed from
// the controller to OverviewScrollArea. `id` goes up by one on every
// change, so two presses in a row in the same direction still count as
// two separate changes (SwiftUI's onChange only fires when the value
// actually differs). direction is +1 for down (S) and -1 for up (W).
struct OverviewScrollRequest: Equatable {
    var id = 0
    var direction: CGFloat = 0
    var isPressed = false
}

// One row W/S can step through on a scrolling overview page: where it
// starts and ends, in points down from the top of the page. Built by the
// controller (overviewScrollRows), which knows the layout numbers. A
// workspace's first row includes its name, so it's taller than the rest.
struct OverviewScrollRow {
    let top: CGFloat
    let bottom: CGFloat
}

// The scroll area for the one overview page that's taller than the
// panel. A real ScrollView, so two-finger scrolling works, that W/S can
// ALSO move. Moving a ScrollView to an exact spot from code needs
// ScrollPosition, which only exists on macOS 15 and newer. This app
// still supports macOS 14, so on 14 it falls back to a plain ScrollView:
// two-finger scrolling only, W/S do nothing there.
private struct OverviewScrollArea<Content: View>: View {
    let request: OverviewScrollRequest
    let rows: [OverviewScrollRow]
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 15, *) {
            KeyboardScrollView(request: request, rows: rows, content: content)
        } else {
            ScrollView(.vertical) { content }
        }
    }
}

// The ScrollView for the scrolling overview page, with W/S driving it
// through OverviewGlide below. Two-finger scrolling works as normal: it's
// a real ScrollView, and the glide engine picks up from wherever you
// scrolled to.
@available(macOS 15, *)
private struct KeyboardScrollView<Content: View>: View {
    let request: OverviewScrollRequest
    let rows: [OverviewScrollRow]
    let content: Content

    @State private var position = ScrollPosition(edge: .top)
    @State private var glide = OverviewGlide()

    var body: some View {
        ScrollView(.vertical) { content }
            .scrollPosition($position)
            // Where the scroll view really is, how tall its visible area
            // is, and how far it can go, all MEASURED by the scroll view
            // itself rather than estimated, so the glide always stops
            // exactly at the real top and bottom.
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    visibleHeight: geometry.containerSize.height,
                    maxOffset: max(0, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
                )
            } action: { _, metrics in
                glide.measured(metrics)
            }
            .onChange(of: request) { _, request in
                // Handed over fresh on every key change, so the engine
                // always moves THIS view's scroll position with this
                // page's rows.
                let binding = $position
                glide.moveTo = { y in binding.wrappedValue.scrollTo(y: y) }
                glide.rows = rows
                if request.isPressed {
                    glide.press(direction: request.direction)
                } else {
                    glide.release()
                }
            }
    }
}

// The engine behind W/S scrolling. Instead of jumping or running one
// fixed animation per press, it moves the page a tiny bit on every frame
// the screen draws (a display link), always chasing a "target" position
// with a soft spring. The spring keeps whatever speed the page already
// has, which is what makes it glide:
//   Tap S/W: the target moves one row. The page speeds up, then eases in
//     and settles on it. Tapping again before it settles moves the target
//     one row further from where it was heading, so quick taps build up
//     speed (momentum) instead of restarting from zero each time.
//   Hold S/W: after holdDelay, the target starts moving at a steady
//     holdSpeed, and the page glides along behind it. On release, the
//     target snaps forward to the next row edge, and the page eases into
//     it, so it never stops halfway through a row.
// Row edges here mean "bottom-aligned": every place the page can settle
// has some row's bottom lined up exactly with the bottom of the visible
// area (S reveals one more whole row at the bottom, W is the exact
// reverse). The very top and very bottom of the page are edges too.
@MainActor
private final class OverviewGlide: NSObject {
    // The three feel knobs. Change these to tune how scrolling feels.
    // springStrength: how quickly the page catches up with its target.
    //   Lower = floatier and slower to settle, higher = snappier. At 13 a
    //   one-row tap settles in about 0.35s (10 took about 0.45s, which
    //   felt a little slow).
    private let springStrength: CGFloat = 13
    // holdSpeed: how fast holding S/W glides, in points per second (one
    //   row of icons is 82 points).
    private let holdSpeed: CGFloat = 650
    // holdDelay: how long a key has to be held before it counts as a hold
    //   rather than a tap, in seconds.
    private let holdDelay: CFTimeInterval = 0.2

    var moveTo: (CGFloat) -> Void = { _ in }
    var rows: [OverviewScrollRow] = []

    private var measuredOffset: CGFloat = 0
    private var visibleHeight: CGFloat = 0
    private var maxOffset: CGFloat = 0

    private var y: CGFloat = 0          // where the engine has the page right now
    private var velocity: CGFloat = 0   // points per second, + is down
    private var target: CGFloat = 0     // where the spring is pulling it to
    private var direction: CGFloat = 0
    private var pressedAt: CFTimeInterval?  // when S/W went down, nil once released
    private var holding = false             // true once a press has lasted holdDelay
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0

    func measured(_ metrics: ScrollMetrics) {
        visibleHeight = metrics.visibleHeight
        maxOffset = metrics.maxOffset
        measuredOffset = metrics.offset
        // While nothing is gliding, the measured position is the truth
        // (two-finger scrolling may have moved it), so start from there.
        if link == nil {
            y = metrics.offset
            target = metrics.offset
        }
    }

    func press(direction: CGFloat) {
        if link == nil {
            y = measuredOffset
            target = measuredOffset
            velocity = 0
        }
        self.direction = direction
        pressedAt = CACurrentMediaTime()
        holding = false
        // Every press, tap or hold, starts by moving one row.
        target = nextEdge(after: target, direction: direction)
        start()
    }

    func release() {
        pressedAt = nil
        if holding {
            holding = false
            target = edge(atOrPast: target, direction: direction)
        }
    }

    // Every position the page is allowed to settle at, top to bottom.
    private var edges: [CGFloat] {
        let inside = rows.map { $0.bottom - visibleHeight }.filter { $0 > 0.5 && $0 < maxOffset - 0.5 }
        return [0] + inside.sorted() + [maxOffset]
    }

    // The next edge strictly past `position` (one row on from it).
    private func nextEdge(after position: CGFloat, direction: CGFloat) -> CGFloat {
        if direction > 0 { return edges.first { $0 > position + 1 } ?? maxOffset }
        return edges.last { $0 < position - 1 } ?? 0
    }

    // The nearest edge at or past `position` (for settling after a hold).
    private func edge(atOrPast position: CGFloat, direction: CGFloat) -> CGFloat {
        if direction > 0 { return edges.first { $0 >= position - 0.5 } ?? maxOffset }
        return edges.last { $0 <= position + 0.5 } ?? 0
    }

    private func start() {
        guard link == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = CACurrentMediaTime()
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        // Capped so a hiccup (a slow frame) can't make the page leap.
        let dt = CGFloat(min(max(now - lastFrame, 1.0 / 240), 1.0 / 30))
        lastFrame = now

        if let pressedAt, !holding, now - pressedAt >= holdDelay { holding = true }
        if holding {
            target = min(max(target + direction * holdSpeed * dt, 0), maxOffset)
        }

        // A "critically damped" spring: pulls toward the target as fast
        // as possible without ever overshooting it and bouncing back.
        let distance = y - target
        let acceleration = -springStrength * springStrength * distance - 2 * springStrength * velocity
        velocity += acceleration * dt
        y = min(max(y + velocity * dt, 0), maxOffset)
        moveTo(y)

        // Settled: close enough and slow enough, and no key held.
        if pressedAt == nil && abs(target - y) < 0.5 && abs(velocity) < 2 {
            y = target
            velocity = 0
            moveTo(y)
            stop()
        }
    }
}

struct ScrollMetrics: Equatable {
    let offset: CGFloat
    let visibleHeight: CGFloat
    let maxOffset: CGFloat
}

private struct WorkspaceAppIcon: View {
    let app: WorkspaceAppSummary
    let iconSize: CGFloat

    // windowCount is only ever 0 for homeless apps (homelessAppSummary) —
    // whether merged into their own remembered workspace's card, or
    // landing in the catch-all "Running, no window" section when
    // AeroSwitcher has no history for them at all. Every real
    // per-workspace app has at least one window by construction, so this
    // alone is enough to tell the two apart without a separate flag.
    private var isWindowless: Bool { app.windowCount == 0 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        // Dimmed, same convention the normal switcher's
                        // grayed-out launcher tiles already use for "not
                        // fully here" — here that means "running, but
                        // nothing to actually switch to."
                        .opacity(isWindowless ? 0.55 : 1)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.2))
                        .frame(width: iconSize, height: iconSize)
                }
                if isWindowless {
                    // A dashed ring around an otherwise-real icon reads as
                    // "present, but not solid" — distinct from both a
                    // normal icon (solid, full opacity) and the launcher
                    // row's fully-placeholder dashed-square icon (which
                    // means "not even running").
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: iconSize, height: iconSize)
                } else if app.windowCount > 1 {
                    Text("\(app.windowCount)")
                        .foregroundColor(.white)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .offset(x: 4, y: 4)
                }
            }
            Text(app.appName)
                .foregroundColor(.white.opacity(isWindowless ? 0.5 : 0.8))
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: iconSize + 20)
        }
    }
}


// MARK: - Config problems window
//
// The small window that lists what's wrong with config.json (and, after a
// "reload both" from `pkill -HUP AeroSwitcher`, with AeroSpace's config
// too). Same idea as the window AeroSpace itself opens when its config has
// errors. Before this, every problem was only print()ed, which nobody sees
// unless the app was started from Terminal.
//
// It's an ordinary window, but on purpose:
//   - It never takes the keyboard by itself (orderFrontRegardless, not
//     activate), so saving config.json in your editor doesn't yank you out
//     of the editor. Click it to use it.
//   - It can't be resized, which also means it has no working green full
//     screen button, so maximize.applescript leaves it alone when AeroSpace
//     notices it (see the dialog check in that script).
//   - It closes by itself after a reload with no problems left.

struct ConfigProblemSection: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let lines: [String]
}

struct ConfigProblemsView: View {
    let sections: [ConfigProblemSection]
    let openConfig: () -> Void
    let reload: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.headline)
                    Text(section.summary).font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        // Selectable, so an error can be copied into a
                        // search or a message to someone helping.
                        Text(section.lines.map { "• " + $0 }.joined(separator: "\n\n"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 220)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Button("Open config.json", action: openConfig)
                // Same as `pkill -HUP AeroSwitcher`: reloads both configs.
                Button("Reload", action: reload)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

@MainActor
final class ConfigProblemsWindow {
    static let shared = ConfigProblemsWindow()
    private var window: NSWindow?

    // Shows, refreshes or closes the window to match the latest reload.
    // `aerospace` is nil when AeroSpace wasn't reloaded this time (a plain
    // save of config.json, or app launch), so only AeroSwitcher's own
    // problems count then.
    func update(report: ConfigReport, aerospace: AeroSpaceReloadResult?) {
        var sections: [ConfigProblemSection] = []
        if !report.errors.isEmpty {
            sections.append(ConfigProblemSection(
                title: "config.json has errors",
                summary: report.keptPreviousSettings
                    ? "AeroSwitcher is still using your previous settings. Fix the problem and save, it reloads by itself."
                    : "AeroSwitcher is using its built-in default settings until this is fixed. Fix the problem and save, it reloads by itself.",
                lines: report.errors + report.warnings))
        } else if !report.warnings.isEmpty {
            sections.append(ConfigProblemSection(
                title: "config.json loaded with warnings",
                summary: "Everything else was applied. Each item below fell back to its default.",
                lines: report.warnings))
        }
        // The aerospace command says "Can't connect to AeroSpace server"
        // when AeroSpace isn't running at all. That's not a config problem,
        // so it gets its own title instead of a misleading one.
        if let aerospace, !aerospace.ok, aerospace.output.contains("Can't connect to AeroSpace server") {
            sections.append(ConfigProblemSection(
                title: "AeroSpace isn't running",
                summary: "AeroSwitcher couldn't reach AeroSpace to reload its config. Open AeroSpace, then reload again.",
                lines: [aerospace.output]))
        } else if let aerospace, !aerospace.ok {
            sections.append(ConfigProblemSection(
                title: "AeroSpace's config has problems",
                summary: "This is ~/.aerospace.toml, reloaded together with config.json. AeroSpace keeps its previous config while there are errors.",
                lines: [aerospace.output.isEmpty ? "aerospace reload-config failed without saying why." : aerospace.output]))
        }

        guard !sections.isEmpty else {
            window?.close()
            return
        }
        show(sections)
    }

    private func show(_ sections: [ConfigProblemSection]) {
        let view = ConfigProblemsView(
            sections: sections,
            openConfig: { NSWorkspace.shared.open(configFileURL()) },
            reload: { settings.reloadTogether() },
            close: { [weak self] in self?.window?.close() })
        if let window {
            window.contentView = NSHostingView(rootView: view)
            window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
            window.orderFrontRegardless()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "AeroSwitcher config"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
        window.orderFrontRegardless()
        self.window = window
    }
}
