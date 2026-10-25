import Cocoa
import ScreenCaptureKit

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

@available(macOS 14.0, *)
func captureThumbnail(scWindow: SCWindow) async -> NSImage? {
    do {
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

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    } catch {
        logWarn("Capture failed: \(error)")
        return nil
    }
}

// Captures every window fresh, every time, concurrently rather than one at
// a time. No cache — every card you see is a real screenshot from the
// instant you pressed Cmd+Tab, nothing stale. What keeps this fast is
// captureThumbnail's small capture resolution above plus doing every
// window's capture in parallel here via withTaskGroup, not a cache trading
// correctness for speed.
@available(macOS 14.0, *)
func captureAll(_ windows: [AeroWindow], content: SCShareableContent?) async -> [ThumbnailItem] {
    guard let content = content else { return [] }

    var scByID: [CGWindowID: SCWindow] = [:]
    for w in content.windows {
        scByID[w.windowID] = w
    }

    let captured: [(AeroWindow, NSImage)] = await withTaskGroup(of: (AeroWindow, NSImage?).self) { group in
        for w in windows {
            group.addTask {
                guard let cgID = CGWindowID(w.id), let scWindow = scByID[cgID] else { return (w, nil) }
                // `?? nil`: withTimeout gives nil for "no answer", and the
                // capture itself gives nil for "failed", both mean no card.
                let image = await withTimeout(seconds: screenshotServiceTimeout, label: "Screenshot of a window") {
                    await captureThumbnail(scWindow: scWindow)
                } ?? nil
                return (w, image)
            }
        }
        var collected: [(AeroWindow, NSImage)] = []
        for await (w, img) in group where img != nil {
            collected.append((w, img!))
        }
        return collected
    }

    var resultByID: [String: ThumbnailItem] = [:]
    for (w, img) in captured {
        resultByID[w.id] = ThumbnailItem(id: w.id, appPID: w.appPID, appName: w.displayName, image: img)
    }

    // Original (already MRU-sorted) order, dropping any window whose capture
    // failed outright rather than showing a broken card.
    return windows.compactMap { resultByID[$0.id] }
}

