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
                return (w, await captureThumbnail(scWindow: scWindow))
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

