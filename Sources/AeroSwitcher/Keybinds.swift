import Cocoa

// MARK: - Keybind resolution

// Translates the human-readable key names used in config.json
// (like "d" or "space") into the raw numeric codes macOS actually uses for
// keys. Only the keys that make sense to rebind are listed here — letters,
// digits, the arrows, and a handful of named keys. If you type a name
// that's not in this list, resolveKeybinds() below falls back to that
// key's own default and reports it as a warning in the problems window,
// rather than the app just quietly not responding to that key.
let keyCodesByName: [String: Int64] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
    "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "space": 49, "tab": 48, "return": 36, "enter": 36, "escape": 53, "delete": 51,
    "up": 126, "down": 125, "left": 123, "right": 124,
    "pageup": 116, "pagedown": 121,
]

func keyCode(forName name: String) -> Int64? {
    keyCodesByName[name.lowercased()]
}

// The other way round, for the settings window's key recorder: the name
// config.json uses for a key that was just pressed. nil = a key that isn't
// in the table above (F-keys, punctuation...), which AeroSwitcher can't use.
// "return" and "enter" are the same key, "return" is the one written.
func keyName(forCode code: Int64) -> String? {
    if code == 36 { return "return" }
    return keyCodesByName.first { $0.value == code }?.key
}

// How a key name is shown in the settings window: "d" as "D",
// "pagedown" as "Page Down".
func keyDisplayName(_ name: String) -> String {
    let words: [String: String] = [
        "space": "Space", "tab": "Tab", "return": "Return", "enter": "Return", "escape": "Escape",
        "delete": "Delete", "up": "↑", "down": "↓", "left": "←", "right": "→",
        "pageup": "Page Up", "pagedown": "Page Down",
    ]
    return words[name.lowercased()] ?? name.uppercased()
}

// Every keybind, in the order the settings window lists them, with where
// it lives in KeybindConfig (so its default can be looked up).
let keybindActions: [(name: String, keyPath: WritableKeyPath<KeybindConfig, String>)] = [
    ("cycleNext", \.cycleNext), ("cyclePrevious", \.cyclePrevious),
    ("enterGreyedRow", \.enterGreyedRow), ("exitGreyedRow", \.exitGreyedRow),
    ("pageUp", \.pageUp), ("pageDown", \.pageDown),
    ("confirm", \.confirm), ("cancel", \.cancel),
]

struct ResolvedKeybinds {
    let cycleNext: Int64
    let cyclePrevious: Int64
    let enterGreyedRow: Int64
    let exitGreyedRow: Int64
    let pageUp: Int64
    let pageDown: Int64
    let confirm: Int64
    let cancel: Int64
}

func resolveKeybinds(_ config: KeybindConfig, report: ConfigReport) -> ResolvedKeybinds {
    let defaults = KeybindConfig()
    func resolve(_ label: String, _ configured: String, fallback: String) -> Int64 {
        if let code = keyCode(forName: configured) { return code }
        report.warning("keybinds.\(label) is \"\(configured)\", which isn't a key AeroSwitcher recognizes, so the default (\"\(fallback)\") is used instead.")
        return keyCode(forName: fallback)!  // the built-in defaults are always valid names
    }
    let resolved = ResolvedKeybinds(
        cycleNext: resolve("cycleNext", config.cycleNext, fallback: defaults.cycleNext),
        cyclePrevious: resolve("cyclePrevious", config.cyclePrevious, fallback: defaults.cyclePrevious),
        enterGreyedRow: resolve("enterGreyedRow", config.enterGreyedRow, fallback: defaults.enterGreyedRow),
        exitGreyedRow: resolve("exitGreyedRow", config.exitGreyedRow, fallback: defaults.exitGreyedRow),
        pageUp: resolve("pageUp", config.pageUp, fallback: defaults.pageUp),
        pageDown: resolve("pageDown", config.pageDown, fallback: defaults.pageDown),
        confirm: resolve("confirm", config.confirm, fallback: defaults.confirm),
        cancel: resolve("cancel", config.cancel, fallback: defaults.cancel)
    )

    // Two actions silently sharing one key means only the first one in the
    // switch below ever fires — easy to do by accident when hand-editing
    // the file, so call it out instead of leaving the other key looking
    // "broken" for no obvious reason.
    let named: [(String, Int64)] = [
        ("cycleNext", resolved.cycleNext), ("cyclePrevious", resolved.cyclePrevious),
        ("enterGreyedRow", resolved.enterGreyedRow), ("exitGreyedRow", resolved.exitGreyedRow),
        ("pageUp", resolved.pageUp), ("pageDown", resolved.pageDown),
        ("confirm", resolved.confirm), ("cancel", resolved.cancel),
    ]
    for i in 0..<named.count {
        for j in (i + 1)..<named.count where named[i].1 == named[j].1 {
            report.warning("keybinds.\(named[i].0) and keybinds.\(named[j].0) are both set to the same key, so \(named[j].0) will never fire.")
        }
        // Tab (keyCode 48) is permanently what opens the switcher in the
        // first place — it's handled separately, before any of these, so
        // binding another action to it here would just never be reachable.
        if named[i].1 == 48 {
            report.warning("keybinds.\(named[i].0) is set to Tab, which is always reserved for opening the switcher, so it can never fire. Pick a different key.")
        }
    }

    return resolved
}

