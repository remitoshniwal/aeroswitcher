import Cocoa

// MARK: - Most-recently-used tracking

// AeroSpace itself already knows exactly when any window gets focus, down
// to the specific window ID (see the on-focus-changed line in
// ~/.aerospace.toml). Reading that is far more reliable than us trying to
// guess from app-level activation, it works correctly even for two windows
// of the exact same app.
//
// One small log file PER WORKSPACE, under /tmp/aerospace-mru/, rather than
// one shared file for the whole Mac. AeroSpace's hook only ever hands us
// the window ID directly, not which workspace it's in, so the hook itself
// asks `aerospace list-workspaces --focused` to figure out which file to
// append to. Splitting it this way isn't just about file size, it fixes a
// real correctness issue too: with one shared history, heavy switching in
// whatever workspace you're using right now could crowd out an older,
// less-visited workspace's own recency order entirely. Keeping each
// workspace's history separate means that can't happen, each one only
// ever competes with its own past, not everyone else's.
class MRUTracker {
    private let logDir = "/tmp/aerospace-mru"

    // Each workspace's own log file grows by one line every focus change
    // within it, forever, with nothing on the AeroSpace side to trim it.
    // We only ever care about the most recent handful of window IDs
    // anyway, so this is both how many we keep AND the cue for when it's
    // worth rewriting a file back down to size.
    private let maxRemembered = 300

    private func logPath(for workspace: String) -> String {
        "\(logDir)/\(workspace).log"
    }

    private func recentWindowIDs(workspace: String) -> [String] {
        let path = logPath(for: workspace)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var seen = Set<String>()
        var result: [String] = []
        for line in content.split(separator: "\n").reversed() {
            let id = line.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty && !seen.contains(id) {
                seen.insert(id)
                result.append(id)
                if result.count >= maxRemembered { break }  // no point reading further back than we'll ever use
            }
        }

        // Once a workspace's own file has grown enough to be worth the
        // trouble, rewrite it down to just the recent IDs we actually kept
        // above, so no single workspace's log can grow past a few hundred
        // short lines no matter how long the Mac's been on.
        if content.utf8.count > maxRemembered * 20 {
            let trimmed = result.reversed().joined(separator: "\n") + "\n"
            try? trimmed.write(toFile: path, atomically: true, encoding: .utf8)
        }

        return result
    }

    // Puts the most recently focused window(s) first, by actual window ID,
    // using just THIS workspace's own history. Anything we've never seen
    // focus falls back to AeroSpace's own order, at the end. If we don't
    // know the workspace (shouldn't normally happen), skip reordering
    // entirely rather than guessing.
    func sorted(_ windows: [AeroWindow], workspace: String?) -> [AeroWindow] {
        guard let workspace = workspace else { return windows }
        let recent = recentWindowIDs(workspace: workspace)
        func rank(_ id: String) -> Int {
            recent.firstIndex(of: id) ?? Int.max
        }
        return windows.enumerated().sorted { a, b in
            let ra = rank(a.element.id)
            let rb = rank(b.element.id)
            if ra != rb { return ra < rb }
            return a.offset < b.offset  // stable fallback
        }.map { $0.element }
    }
}

// Remembers which workspace each app was last actually seen with a window
// in — used only for "homeless" apps (running, no window anywhere, not
// configured for any workspace either; see homelessRunningApps below), so
// an app like Preview, closed while you were in Dev, keeps showing up
// specifically on Dev afterward instead of drifting to whichever workspace
// you simply happen to be browsing the next time you open the switcher.
//
// Updated opportunistically, not by a separate background hook: every
// time AeroSwitcher already fetches the full cross-workspace window list
// (both the normal switcher and the Cmd+` overview do this on every
// open), record() gets called with that snapshot. That's accurate as long
// as you're using AeroSwitcher normally — an app it's genuinely never seen
// with a window (freshly installed, or you haven't opened the switcher
// since launch) just has no entry yet, and callers fall back to something
// reasonable for that case themselves.
//
// Persisted as a small JSON file, same folder and same idea as
// config.json, so this survives quitting and relaunching AeroSwitcher,
// not just remembered for the current run.
class AppWorkspaceTracker {
    private let fileURL = appSupportDirectory().appendingPathComponent("app-workspaces.json")
    private var mapping: [String: String]  // app name (lowercased) -> workspace

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            mapping = decoded
        } else {
            mapping = [:]
        }
    }

    func workspace(for appName: String) -> String? {
        mapping[appName.lowercased()]
    }

    func record(_ windows: [AeroWindow]) {
        var changed = false
        for w in windows {
            let key = w.appName.lowercased()
            if mapping[key] != w.workspace {
                mapping[key] = w.workspace
                changed = true
            }
        }
        guard changed else { return }  // no point writing to disk when nothing actually moved
        do {
            try JSONEncoder().encode(mapping).write(to: fileURL)
        } catch {
            print("Couldn't save \(fileURL.path): \(error)")
        }
    }
}

