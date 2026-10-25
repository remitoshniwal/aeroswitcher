import Foundation

// MARK: - Log file
//
// Everything the app used to print() now goes through one of four functions,
// and each one does two things:
//
//   1. It prints the text to stdout exactly like before, so running the app
//      from Terminal, or `open --stdout file AeroSwitcher.app`, shows the
//      same lines as always.
//   2. It adds a line with a time and a level to the log file, so a normally
//      opened app (a login item, a double click) leaves a trail too:
//
//        2026-10-25 14:03:22.123 WARN  Couldn't save /tmp/...
//
//   logInfo   normal things that happened (a menu item clicked, a reload)
//   logWarn   something failed but the app carries on
//   logError  a feature is down (no Cmd+Tab hook, can't reach AeroSpace)
//   logDebug  chatter, like every single AeroSpace event. Always printed, but
//             only written to the file when debug logging is switched on:
//               AEROSWITCHER_DEBUG=1 in the environment, or
//               defaults write com.aeroswitcher.app LogDebug -bool true
//             (switch it off with `defaults delete com.aeroswitcher.app LogDebug`)
//
// Where: ~/Library/Logs/AeroSwitcher/AeroSwitcher.log. A test copy started
// with AEROSWITCHER_CONFIG_DIR writes to <that folder>/Logs instead, so a
// test can never fill or confuse the real log.
//
// Size: when the file passes 1 MB it is renamed AeroSwitcher.log.1 (replacing
// the previous .1) and a new file starts, so the two files together never
// pass about 2 MB. To keep more or less, change `maxLogBytes`.
//
// Nothing here waits for the disk: lines are handed to a background queue,
// because logInfo is also called from the Cmd+Tab event tap, which must never
// be slowed down. The price is that if the app crashes, the last few lines
// may not have reached the file yet. `flushLog()` waits for the queue and is
// called before the app exits on purpose (menu Quit, pkill, a second copy
// quitting).
//
// Never put window titles or anything from inside a window in a log line.
// The file is meant to be pasted into a bug report.

func logInfo(_ message: String) { appLogger.write(message, level: .info) }
func logWarn(_ message: String) { appLogger.write(message, level: .warn) }
func logError(_ message: String) { appLogger.write(message, level: .error) }
func logDebug(_ message: String) { appLogger.write(message, level: .debug) }

// Waits until every line handed over so far is in the file.
func flushLog() { appLogger.flush() }

// The folder the log lives in (also what "Show log" opens).
func logDirectoryURL() -> URL {
    if let testDir = ProcessInfo.processInfo.environment["AEROSWITCHER_CONFIG_DIR"] {
        return URL(fileURLWithPath: testDir).appendingPathComponent("Logs")
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/AeroSwitcher")
}

func logFileURL() -> URL {
    logDirectoryURL().appendingPathComponent("AeroSwitcher.log")
}

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO "
    case warn = "WARN "
    case error = "ERROR"
}

// One shared logger. It's a global in this file, so Swift only creates it the
// first time something logs; main.swift's very first line logs, so that is
// right at launch (see "Start-up order" in main.swift).
let appLogger = AppLogger()

final class AppLogger {
    private let queue = DispatchQueue(label: "AeroSwitcher.log")
    // Only touched on `queue`.
    private var handle: FileHandle?
    private var linesSinceSizeCheck = 0
    private var fileFailed = false
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    // 1 MB. A test copy may set AEROSWITCHER_LOG_MAX_BYTES to try rotation
    // with a tiny limit (only honored together with AEROSWITCHER_CONFIG_DIR,
    // like the other test-only switches).
    private let maxLogBytes: Int = {
        let environment = ProcessInfo.processInfo.environment
        if environment["AEROSWITCHER_CONFIG_DIR"] != nil, let text = environment["AEROSWITCHER_LOG_MAX_BYTES"], let bytes = Int(text) {
            return bytes
        }
        return 1_000_000
    }()

    private let debugToFile: Bool = {
        ProcessInfo.processInfo.environment["AEROSWITCHER_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "LogDebug")
    }()

    func write(_ message: String, level: LogLevel) {
        // Same text as the old print(), so Terminal output is unchanged.
        print(message)
        if level == .debug && !debugToFile { return }
        let now = Date()
        queue.async { [self] in
            // A message with several lines (an error from another program)
            // keeps its extra lines indented so each entry starts at a time.
            let text = message.replacingOccurrences(of: "\n", with: "\n    ")
            let line = "\(formatter.string(from: now)) \(level.rawValue) \(text)\n"
            appendToFile(line)
        }
    }

    func flush() {
        queue.sync {}
    }

    // MARK: Writing (all on `queue`)

    private func appendToFile(_ line: String) {
        if handle == nil && !fileFailed { openFile() }
        guard let handle, let data = line.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fileFailed = true
            self.handle = nil
            print("Log file: couldn't write to \(logFileURL().path), logging to the screen only. \(error.localizedDescription)")
            return
        }
        linesSinceSizeCheck += 1
        if linesSinceSizeCheck >= 200 {
            linesSinceSizeCheck = 0
            rotateIfNeeded()
        }
    }

    private func openFile() {
        let fileManager = FileManager.default
        let url = logFileURL()
        do {
            try fileManager.createDirectory(at: logDirectoryURL(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: url.path) {
                // Only the owner can read it, it contains file paths.
                fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            handle = opened
            rotateIfNeeded()
        } catch {
            fileFailed = true
            print("Log file: couldn't open \(url.path), logging to the screen only. \(error.localizedDescription)")
        }
    }

    // Past the size limit: the current file becomes AeroSwitcher.log.1
    // (the old .1 is deleted) and a new one starts. That's all the cleaning
    // up there is, nothing else is ever deleted.
    private func rotateIfNeeded() {
        let url = logFileURL()
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxLogBytes else { return }
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        openFile()
    }
}
