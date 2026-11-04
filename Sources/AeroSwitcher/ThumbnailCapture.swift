import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Thumbnail capture

// Card size on screen, in points. The capture resolution is derived from
// this, not a hardcoded pixel guess.
let cardSize = NSSize(width: 220, height: 140)

// How many real pixels one point is on this Mac's display (2.0 on Retina,
// 1.0 on older non-Retina screens). This is a `let` at file scope, so Swift
// only evaluates it once when the app launches, not on every Cmd+Tab press.
let displayScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0

// Capture at the display's real native resolution. We tried capping this
// below displayScale (first 1.5x, then 1x) to save time, but testing showed
// that made thumbnails blurrier WITHOUT making captures any faster — the
// real cost per window is ScreenCaptureKit's fixed overhead for compositing
// a window at all, not the pixel count. So there's no actual tradeoff being
// made here: capping resolution was a corner we didn't need to cut.
let captureScale: CGFloat = displayScale

// Target capture resolution: the card's point size converted to actual
// pixels for this display. Capturing a window at its full native size (a
// maximized Retina Chrome window can be 3000+ pixels wide) is the single
// biggest cost in this whole app, even though we only ever display it at
// cardSize. Rendering directly at this reduced size is both way less for
// ScreenCaptureKit to composite and less data to hand back to us.
let captureTargetSize = NSSize(width: cardSize.width * captureScale,
                                height: cardSize.height * captureScale)

// MARK: Time limit for macOS's screenshot service
//
// ScreenCaptureKit can simply stop answering: it did on 2026-10-26, after a
// second login session was left running on the Mac, and the plain
// `screencapture` command failed too. Neither SCShareableContent nor
// captureImage has a time limit of its own, so one unanswered call kept the
// switcher "loading" forever and every later Cmd+Tab was ignored until the
// app was restarted, with nothing in the log.
//
// How long to wait for one answer from macOS before giving up. A normal
// Cmd+Tab finishes in well under 1.5 seconds, so 3 seconds only ever matters
// when something is really wrong. Raise it if a very busy Mac gives up too
// early (the log then says "did not answer").
let screenshotServiceTimeout: Double = 3

// Hands the answer back exactly once, from whichever side gets there first
// (the real work or the timer). The lock is what makes "first one wins" safe
// when both happen at nearly the same moment.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
    // True if THIS call was the one that delivered the answer.
    @discardableResult
    func resume(_ value: T?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}

// Runs `operation` and returns its answer, or nil if it hasn't answered after
// `seconds` (and says so in the log). Not a Task group on purpose: a group
// waits for ALL its tasks before it finishes, so one call that never returns
// would still hang us. Here the stuck call is simply left behind (it costs a
// little memory and is cleaned up if macOS ever answers it).
func withTimeout<T>(seconds: Double, label: String, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce<T>(continuation)
        Task { once.resume(await operation()) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Only logs if the timer won, which is what we want to know.
            if once.resume(nil) {
                logWarn("\(label) did not answer within \(Int(seconds)) s, giving up on it")
            }
        }
    }
}

// MARK: Not waiting for slow screenshots
//
// How long Cmd+Tab waits for the screenshots before it opens the panel
// anyway, in seconds, counted from when the screenshots start. Any window
// still not captured by then gets its icon card at first, and its picture
// replaces the icon the moment it arrives (see captureAll below).
//
// Why: the panel used to wait for the SLOWEST screenshot. Measured
// 2026-11-04: a normal screenshot takes 40 to 200 ms, but a window in
// macOS's own full screen on another desktop (the Minecraft game) took
// 1.2 to 2.5 s just to FAIL, and Cmd+Tab took that long to open. A busy
// Mac (a game running) also makes some normal screenshots slow.
//
// Lower = the panel opens faster, but more cards start as an icon and
// "pop" into a picture a moment later. Higher = fewer pops, slower worst
// case. The log line "Switcher: ..." says how many were late, use that to
// tune it.
let screenshotWaitLimit: Double = 0.25

// Collects the screenshots as they finish, and lets captureAll wait for
// either all of them or the wait limit, whichever comes first. The lock
// makes it safe for many screenshots to finish at the same moment.
private final class CaptureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: NSImage?] = [:]   // window id -> picture (nil = failed)
    private var remaining: Int
    private var waiting: CheckedContinuation<Void, Never>?
    private var stoppedWaiting = false

    init(count: Int) { remaining = count }

    // Called once per window when its screenshot is done (or failed).
    // Returns true if captureAll already stopped waiting, so the picture is
    // LATE and has to be handed to the panel separately.
    func finished(_ id: String, _ image: NSImage?) -> Bool {
        lock.lock()
        if stoppedWaiting { lock.unlock(); return true }
        images[id] = image
        remaining -= 1
        let wake = remaining == 0 ? waiting : nil
        if wake != nil { waiting = nil }
        lock.unlock()
        wake?.resume()
        return false
    }

    // Waits for all screenshots or `seconds`, then returns what arrived and
    // how many were still missing. Everything finishing after this is late.
    func waitForAll(atMost seconds: Double) async -> (images: [String: NSImage?], late: Int) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard park(continuation) else { continuation.resume(); return }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self.unpark()?.resume()
            }
        }
        return stop()
    }

    // The three small steps below each hold the lock briefly. They are plain
    // (not async) functions because Swift doesn't allow NSLock inside async
    // code directly.

    // Remembers who to wake. False if everything is already done.
    private func park(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if remaining == 0 { return false }
        waiting = continuation
        return true
    }

    // The wait limit passed: hands back whoever is still waiting (nil if the
    // last screenshot already woke them).
    private func unpark() -> CheckedContinuation<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        let wake = waiting
        waiting = nil
        return wake
    }

    // Stops waiting for good and hands back what arrived in time.
    private func stop() -> (images: [String: NSImage?], late: Int) {
        lock.lock(); defer { lock.unlock() }
        stoppedWaiting = true
        return (images, remaining)
    }
}

@available(macOS 14.0, *)
func captureThumbnail(scWindow: SCWindow) async -> NSImage? {
    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let config = SCStreamConfiguration()

    // Fit the window's real aspect ratio inside captureTargetSize so
    // nothing gets stretched.
    let srcW = max(scWindow.frame.width, 1)
    let srcH = max(scWindow.frame.height, 1)
    let aspect = srcW / srcH
    var outW = captureTargetSize.width
    var outH = captureTargetSize.width / aspect
    if outH > captureTargetSize.height {
        outH = captureTargetSize.height
        outW = captureTargetSize.height * aspect
    }
    config.width = max(1, Int(outW))
    config.height = max(1, Int(outH))
    config.showsCursor = false

    // Names the app (never the window title) so a failure can be tied to
    // an app, for example a DRM protected one. Look for "Capture failed for".
    let appName = scWindow.owningApplication?.applicationName ?? "unknown app"
    let bundleID = scWindow.owningApplication?.bundleIdentifier ?? "unknown"

    do {
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    } catch {
        // Which app macOS had in front, and macOS's own "on screen" and
        // "active" flags for this window, to show WHEN a capture fails. The
        // panel is not shown yet at this point, so the front app is still the
        // one you were using. Seen 2026-11-01: Ableton Live's window was
        // "on screen false" whenever another app was in front, so every
        // capture failed with -3811, and a second try 150 ms later failed
        // every time too (tried and removed). Most likely because the owner
        // keeps Ableton on a separate macOS desktop (reached with a 3 finger
        // swipe), and macOS has nothing to capture for a window on a desktop
        // you are not looking at. Covered windows on the same desktop, like
        // Spotify behind Claude, stay "on screen" and capture fine.
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        logWarn("Capture failed for \(appName) (\(bundleID)), window \(scWindow.windowID), front app \(front), window on screen \(scWindow.isOnScreen), window active \(scWindow.isActive), showing its icon card: \(error)")
        return nil
    }
}

// What a card shows when there is no screenshot of its window: the app's own
// icon, centred, on a transparent card-sized canvas (the card draws its dark
// background behind it). Instant, no screen capture involved. Used when macOS
// failed or timed out on this window's screenshot, so the window stays
// reachable with Cmd+Tab instead of silently vanishing from the list.
func iconPlaceholder(forAppPID pid: Int32) -> NSImage {
    // A KnownApps app's icon first (Minecraft's "java" gets Minecraft's icon,
    // not the generic program icon), see KnownAppsTable.icon(forPID:).
    let icon = knownApps.icon(forPID: pid)
        ?? NSRunningApplication(processIdentifier: pid)?.icon
        ?? NSWorkspace.shared.icon(for: .applicationBundle)
    // A bit under half the card's height, so it reads as "the app" rather
    // than a huge blurry thumbnail. Change the 0.5 to make it bigger or smaller.
    let side = captureTargetSize.height * 0.5
    return NSImage(size: captureTargetSize, flipped: false) { rect in
        icon.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
}

// Captures every window fresh, every time, concurrently rather than one at
// a time. No cache — every card you see is a real screenshot from the
// instant you pressed Cmd+Tab, nothing stale. What keeps this fast is
// captureThumbnail's small capture resolution above plus doing every
// window's capture in parallel here, not a cache trading correctness for
// speed.
//
// Windows that macOS lists but whose screenshot fails or times out get an
// icon card (iconPlaceholder) rather than disappearing. A window macOS's
// list doesn't contain at all is still left out, as before. If the whole
// window list is unavailable (content == nil, for example macOS's screenshot
// service is stuck), every window gets an icon card, so Cmd+Tab still opens.
//
// Waits at most screenshotWaitLimit for the screenshots (see above). A
// window whose screenshot isn't back by then starts as an icon card, and
// when its picture does arrive, `lateImage` is called with the window id and
// the picture (on the main thread), so the panel can swap it in. A late
// screenshot that fails is simply never reported, the icon card stays.
// Also returns how many screenshots were late, for the log.
@available(macOS 14.0, *)
func captureAll(_ windows: [AeroWindow], content: SCShareableContent?,
                lateImage: @escaping @MainActor (String, NSImage) -> Void) async -> (items: [ThumbnailItem], late: Int) {
    guard let content = content else {
        if !windows.isEmpty {
            logWarn("No screenshots available, showing app icons for \(windows.count) window(s)")
        }
        return (windows.map {
            ThumbnailItem(id: $0.id, appPID: $0.appPID, appName: $0.displayName, image: iconPlaceholder(forAppPID: $0.appPID))
        }, 0)
    }

    var scByID: [CGWindowID: SCWindow] = [:]
    for w in content.windows {
        scByID[w.windowID] = w
    }

    // Only windows macOS knows get a card at all, as before.
    let known: [(AeroWindow, SCWindow)] = windows.compactMap { w in
        guard let cgID = CGWindowID(w.id), let scWindow = scByID[cgID] else { return nil }
        return (w, scWindow)
    }

    // Every screenshot runs in parallel as its own task. Not a Task group on
    // purpose: a group can't finish before ALL its tasks do, and the whole
    // point here is to stop waiting for the slow ones.
    let collector = CaptureCollector(count: known.count)
    for (w, scWindow) in known {
        Task {
            // `?? nil`: withTimeout gives nil for "no answer", and the
            // capture itself gives nil for "failed", both mean no screenshot.
            let image = await withTimeout(seconds: screenshotServiceTimeout, label: "Screenshot of a window") {
                await captureThumbnail(scWindow: scWindow)
            } ?? nil
            if collector.finished(w.id, image), let image {
                await lateImage(w.id, image)
            }
        }
    }
    let (images, late) = await collector.waitForAll(atMost: screenshotWaitLimit)

    // Original (already MRU-sorted) order. A missing entry (late) and a nil
    // one (failed) both start as the app's icon.
    let items = known.map { w, _ in
        ThumbnailItem(id: w.id, appPID: w.appPID, appName: w.displayName,
                      image: (images[w.id] ?? nil) ?? iconPlaceholder(forAppPID: w.appPID))
    }
    return (items, late)
}

