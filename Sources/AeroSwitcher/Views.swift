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
// currentPanelViewAndSize()), so the two panels feel like one app. No
// scrolling, ever: paging with Tab/Shift+Tab or A/D keeps the whole thing
// keyboard-driven with your left hand, same as the normal switcher,
// rather than needing the mouse/trackpad to scroll.
struct WorkspacesOverviewView: View {
    let workspaces: [WorkspaceSummary]
    let pageIndex: Int
    let totalPages: Int
    let width: CGFloat
    let height: CGFloat

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
            ForEach(workspaces) { workspace in
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

