// check-drift.js: compares your two lists of "which app belongs in which
// workspace" and reports where they disagree. It never changes either file,
// it only prints.
//
// Why there are two lists at all:
//   ~/.aerospace.toml     decides where an app's window GOES when it opens
//                         (the on-window-detected rules).
//   AeroSwitcher's        decides which grey "not open yet" launcher tiles
//   config.json           show up in each workspace's Cmd+Tab panel.
// They're edited by hand, separately, so it's easy to add an app to one and
// forget the other. That's "drift".
//
// It's written in JavaScript for Automation (JXA), which is built into every
// Mac, so nothing needs installing. Run it from the repo folder with:
//
//   osascript -l JavaScript check-drift.js
//
// sync-aerospace.sh also runs it automatically at the end.

ObjC.import('Foundation')

// Apps that are SUPPOSED to differ between the two lists, so they're never
// reported. Finder is here because it's a launcher tile in several
// workspaces on purpose but has no AeroSpace rule (it opens wherever you
// are). Add a name here when the checker flags something you meant to do.
// Matched the same loose way as everything else below.
const EXCEPTIONS = ['Finder']

const home = $.NSHomeDirectory().js
const TOML_PATH = home + '/.aerospace.toml'
const CONFIG_PATH = home + '/Library/Application Support/AeroSwitcher/config.json'

function readFile(path) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
    return text.isNil() ? null : text.js
}

// Lowercase and drop ".app", so "Whatsapp.app" and "WhatsApp" compare equal.
function norm(s) {
    return s.toLowerCase().replace(/\.app$/, '').trim()
}

// The "fuzzy" part. The two files never spell an app quite the same way:
// the toml says "Ableton Live", config.json says match "Ableton" and open
// "Ableton Live 12 Suite". So two names count as the same app if either one
// contains the other. This is a guess, and the most likely source of a false
// alarm. A very short name (like "Code") could in theory match an app it
// shouldn't.
function sameApp(a, b) {
    a = norm(a)
    b = norm(b)
    return a.length > 0 && b.length > 0 && (a.includes(b) || b.includes(a))
}

// A config.json entry has three names for one app (name, match, open).
// Any of them counting as a match is enough.
function entryMatches(entry, name) {
    return [entry.name, entry.match, entry.open].some(n => n && sameApp(n, name))
}

function isException(names) {
    return EXCEPTIONS.some(ex => names.some(n => n && sameApp(n, ex)))
}

// Normally reads your live files. Passing two paths instead
// (osascript -l JavaScript check-drift.js some.toml some-config.json)
// checks those, which is handy for testing on throwaway copies.
function run(argv) {
    const out = []
    const tomlPath = argv[0] || TOML_PATH
    const configPath = argv[1] || CONFIG_PATH

    const tomlText = readFile(tomlPath)
    if (tomlText === null) return 'Could not read ' + tomlPath + ', drift check skipped.'
    const configText = readFile(configPath)
    if (configText === null) return 'Could not read ' + configPath + ', drift check skipped.'

    let config
    try {
        config = JSON.parse(configText)
    } catch (e) {
        return 'config.json is not valid JSON (' + e.message + '), drift check skipped.'
    }

    // Pull every "this app goes to that workspace" rule out of the toml.
    // Looks for lines like:
    //   { if = 'test %{app-bundle-path} ~= "Steam.app"', run = ['move-node-to-workspace Gaming', ...
    // Commented out lines (starting with #) are ignored, and so is the
    // catch-all rule at the bottom, since it doesn't move windows anywhere.
    const rules = []
    for (const line of tomlText.split('\n')) {
        if (line.trim().startsWith('#')) continue
        const m = line.match(/app-bundle-path\}\s*~=\s*"([^"]+)".*move-node-to-workspace\s+([A-Za-z0-9_-]+)/)
        if (m) rules.push({ app: m[1], workspace: m[2] })
    }

    // Flatten config.json's workspaces into one list of tiles.
    const tiles = []
    const workspaces = config.workspaces || {}
    for (const ws of Object.keys(workspaces)) {
        for (const entry of workspaces[ws]) tiles.push({ entry: entry, workspace: ws })
    }

    // Workspace names that exist in config.json but not in the toml's
    // persistent-workspaces list. Usually a typo, and those tiles would
    // never show up anywhere.
    const persistent = tomlText.match(/^\s*persistent-workspaces\s*=\s*\[([^\]]*)\]/m)
    if (persistent) {
        const known = persistent[1].split(',').map(s => s.replace(/["'\s]/g, '')).filter(Boolean)
        for (const ws of Object.keys(workspaces)) {
            if (!known.includes(ws)) {
                out.push('- Workspace "' + ws + '" is in config.json but not in the toml\'s persistent-workspaces. Typo?')
            }
        }
    }

    for (const rule of rules) {
        if (isException([rule.app])) continue
        const matching = tiles.filter(t => entryMatches(t.entry, rule.app))
        const label = rule.app.replace(/\.app$/, '')
        if (matching.length === 0) {
            out.push('- ' + label + ': AeroSpace sends it to ' + rule.workspace + ', but it has no launcher tile in config.json.')
        } else if (!matching.some(t => t.workspace === rule.workspace)) {
            const where = [...new Set(matching.map(t => t.workspace))].join(', ')
            out.push('- ' + label + ': AeroSpace sends it to ' + rule.workspace + ', but its launcher tile is in ' + where + '.')
        }
    }

    for (const t of tiles) {
        const e = t.entry
        if (isException([e.name, e.match, e.open])) continue
        const hasRule = rules.some(r => entryMatches(e, r.app))
        if (!hasRule) {
            out.push('- ' + e.name + ': launcher tile in ' + t.workspace + ', but no AeroSpace rule, so its windows open wherever you are instead of moving to ' + t.workspace + '.')
        }
    }

    if (out.length === 0) return 'Drift check: .aerospace.toml and config.json agree.'
    return 'Drift check found ' + out.length + ' difference(s) between .aerospace.toml and config.json:\n' +
        out.join('\n') +
        '\nIf one of these is on purpose, add the app to EXCEPTIONS at the top of check-drift.js.'
}
