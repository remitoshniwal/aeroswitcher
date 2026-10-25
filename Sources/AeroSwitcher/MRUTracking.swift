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

    // AeroSwitcher's own history, written from the `focus-changed` events of
    // `aerospace subscribe` (see recordFocus). Same format as the hook's
    // logs: one window id per line, newest last. Also in /tmp on purpose:
    // window ids mean nothing after a restart, and /tmp is emptied then.
    private let ownLogDir = "/tmp/aeroswitcher-recent"
    private let writeQueue = DispatchQueue(label: "aeroswitcher.recent-history", qos: .utility)

    private func ownLogPath(for workspace: String) -> String {
        "\(ownLogDir)/\(workspace).log"
    }

    // Called for every focus event. The file write happens off the main
    // thread (that thread also runs the Cmd+Tab hook). A workspace name with
    // a slash in it can't be a file name, the hook has the same limit.
    func recordFocus(windowID: String, workspace: String) {
        guard !windowID.isEmpty, !workspace.isEmpty, !workspace.contains("/") else { return }
        let dir = ownLogDir
        let path = ownLogPath(for: workspace)
        writeQueue.async {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard let data = (windowID + "\n").data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // Which history to read. Both can exist: the hook's log (if the owner's
    // .aerospace.toml has the line) and AeroSwitcher's own. Both record the
    // same events, so the one written to most recently is the complete one:
    // if the hook line is removed, the hook log stops growing and the own
    // one takes over; if AeroSwitcher was not running for a while, the hook
    // log is the one that kept going. Neither exists: no history yet.
    private func historyPath(for workspace: String) -> String {
        let hook = logPath(for: workspace)
        let own = ownLogPath(for: workspace)
        switch (modificationDate(hook), modificationDate(own)) {
        case (nil, nil): return hook
        case (_, nil): return hook
        case (nil, _): return own
        case let (hookDate?, ownDate?): return ownDate > hookDate ? own : hook
        }
    }

    private func recentWindowIDs(workspace: String) -> [String] {
        recentWindowIDs(atPath: historyPath(for: workspace))
    }

    private func recentWindowIDs(atPath path: String) -> [String] {
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
        // A focus event just before this Cmd+Tab may still be waiting to be
        // written. Waiting for the (tiny) pending writes first means the
        // newest window is never missing from the history that's read.
        writeQueue.sync {}
        let recent = recentWindowIDs(workspace: workspace)
        // Which history was read, so it can be seen in the log. When both
        // exist they hold the same ids, the own file is just the hook's
        // file without the shell.
        logDebug("Recent order \(workspace): using \(historyPath(for: workspace) == ownLogPath(for: workspace) ? "AeroSwitcher's own" : "the hook's") history")
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
            logWarn("Couldn't save \(fileURL.path): \(error)")
        }
    }
}

