// Pure desktop-icon logic, extracted from the DesktopIcons QML module so it
// can be unit-tested under Node (see tests/test_desktop_icons.js) while still
// being imported from QML (`import "DesktopIconModel.js" as DesktopIconModel`).
//
// This module operates ONLY on plain arrays/strings/objects. It has NO access
// to Quickshell / FolderListModel / Settings singletons — the QML layer reads
// those, hands the resulting primitives in, and performs the final exec. This
// keeps the functions deterministic and testable.
//
// SECURITY — the load-bearing part (xfdesktop launch parity):
//
//  * `.desktop` launchers are run EXCLUSIVELY via `gtk-launch <desktop-id>`,
//    and ONLY when the id passes `isDesktopId()` (a strict freedesktop-id
//    charset). The id is a DISTINCT argv element — never concatenated into a
//    shell string — so embedded metacharacters cannot inject. A crafted id
//    like `"evil; rm -rf ~"` fails the charset test and yields null (skipped).
//    There is deliberately NO "treat the value as a raw path/exec" fallback.
//
//  * Regular files are opened via `xdg-open <path>` with the path as a single
//    argv token. No shell is ever spawned (`sh -c` is never used here), so a
//    filename containing shell metacharacters cannot break out.

// Strict freedesktop application-id charset: a leading alphanumeric followed
// by id-safe characters only. No whitespace, slash, dot-dot, or shell
// metacharacters — so it can never be an absolute/relative path nor a shell
// fragment. (Same rule as Services/System/SessionModel.js isDesktopId.)
function isDesktopId(id) {
    return typeof id === "string"
        && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(id);
}

// Derive the freedesktop desktop-id from a .desktop file name, e.g.
// "org.gnome.Calculator.desktop" -> "org.gnome.Calculator". Returns "" if the
// name does not end in ".desktop" or the resulting id is not a clean id.
function desktopIdFromFileName(fileName) {
    if (typeof fileName !== "string")
        return "";
    if (!/\.desktop$/.test(fileName))
        return "";
    var id = fileName.slice(0, -(".desktop".length));
    return isDesktopId(id) ? id : "";
}

// True iff the file name should be hidden when "show hidden files" is off.
// Matches the Unix dotfile convention.
function isHiddenName(name) {
    return typeof name === "string" && name.length > 0 && name.charAt(0) === ".";
}

// Filter a raw list of file entries by the show-hidden toggle.
// Each entry is a plain object: { name, isDir, fileName?, ... }.
function filterHidden(entries, showHidden) {
    if (!Array.isArray(entries))
        return [];
    if (showHidden)
        return entries.slice();
    return entries.filter(function (e) {
        return e && !isHiddenName(e.name);
    });
}

// Case-insensitive name comparison, stable on ties via the raw name.
function _compareName(a, b) {
    var an = String(a.name || "").toLowerCase();
    var bn = String(b.name || "").toLowerCase();
    if (an < bn) return -1;
    if (an > bn) return 1;
    // Tie-break on the exact (case-sensitive) name for determinism.
    var ar = String(a.name || "");
    var br = String(b.name || "");
    if (ar < br) return -1;
    if (ar > br) return 1;
    return 0;
}

// "type" here means a coarse category used for grouping: directories first
// (when arrangeFoldersFirst), then a kind string (".desktop" launchers, then
// by file extension), then by name.
function _typeKey(e) {
    if (e && e.isDir)
        return "0-dir";
    var name = String((e && e.name) || "");
    if (/\.desktop$/.test(name))
        return "1-desktop";
    var dot = name.lastIndexOf(".");
    var ext = (dot > 0) ? name.slice(dot + 1).toLowerCase() : "";
    return "2-" + ext;
}

// Sort entries. `sortMode` is "name" or "type". `arrangeFoldersFirst` forces
// directories to the top regardless of sort mode (xfdesktop default behavior).
// Returns a NEW array; never mutates the input.
function sortEntries(entries, sortMode, arrangeFoldersFirst) {
    if (!Array.isArray(entries))
        return [];
    var list = entries.slice();
    list.sort(function (a, b) {
        if (arrangeFoldersFirst) {
            var ad = a && a.isDir ? 0 : 1;
            var bd = b && b.isDir ? 0 : 1;
            if (ad !== bd)
                return ad - bd;
        }
        if (sortMode === "type") {
            var ak = _typeKey(a);
            var bk = _typeKey(b);
            if (ak < bk) return -1;
            if (ak > bk) return 1;
        }
        return _compareName(a, b);
    });
    return list;
}

// Apply hidden-filter then sort in one call — the order the QML layer wants.
function arrangeEntries(entries, opts) {
    opts = opts || {};
    var showHidden = !!opts.showHidden;
    var sortMode = (opts.sortMode === "type") ? "type" : "name";
    var foldersFirst = (opts.arrangeFoldersFirst === undefined) ? true : !!opts.arrangeFoldersFirst;
    var filtered = filterHidden(entries, showHidden);
    return sortEntries(filtered, sortMode, foldersFirst);
}

// Build a SAFE launch argv for a desktop icon entry.
//
// Entry shapes:
//   { isDesktop: true,  desktopId: "org.gnome.Calculator" }  -> gtk-launch
//   { isDesktop: false, path: "/home/u/Desktop/notes.txt" }  -> xdg-open
//
// Returns a plain string[] argv, or null when the entry cannot be launched
// safely (e.g. a malformed desktop id, or an empty/non-string path). The
// caller passes the argv straight to execDetached — NEVER through a shell.
function buildLaunchArgv(entry) {
    if (!entry || typeof entry !== "object")
        return null;

    if (entry.isDesktop) {
        var id = (entry.desktopId === undefined || entry.desktopId === null)
            ? "" : String(entry.desktopId).trim();
        if (!isDesktopId(id))
            return null;
        return ["gtk-launch", id];
    }

    var path = (entry.path === undefined || entry.path === null)
        ? "" : String(entry.path);
    // A path must be a non-empty absolute path. We do not trim — a legitimate
    // file name may contain leading/trailing spaces — but a blank path is
    // rejected. The path is passed as ONE argv element, so metacharacters are
    // inert (no shell parses it).
    if (path.length === 0)
        return null;
    if (path.charAt(0) !== "/")
        return null;
    return ["xdg-open", path];
}

// Returns true iff the given argv is shell-safe: a non-empty array whose
// every element is a plain string. (No shell is interpreting an argv array.)
function isSafeArgv(argv) {
    // Must be a real array — a bare string also has a numeric .length and
    // string-indexed chars, so guard with Array.isArray to avoid blessing it.
    if (!Array.isArray(argv) || argv.length === 0)
        return false;
    for (var i = 0; i < argv.length; i++) {
        if (typeof argv[i] !== "string")
            return false;
    }
    return true;
}

// Pick a best-effort icon name for an entry. `.desktop` launchers carry their
// own Icon= (resolved by the QML layer and passed in as entry.icon). Folders
// get "folder"; everything else maps from a small extension table to a
// freedesktop-ish generic icon, falling back to "text-x-generic". The QML
// layer feeds these names to Quickshell.iconPath() with its own fallback.
var EXT_ICON = {
    "txt": "text-x-generic",
    "md": "text-x-generic",
    "pdf": "application-pdf",
    "png": "image-x-generic",
    "jpg": "image-x-generic",
    "jpeg": "image-x-generic",
    "gif": "image-x-generic",
    "svg": "image-x-generic",
    "webp": "image-x-generic",
    "mp3": "audio-x-generic",
    "flac": "audio-x-generic",
    "ogg": "audio-x-generic",
    "wav": "audio-x-generic",
    "mp4": "video-x-generic",
    "mkv": "video-x-generic",
    "webm": "video-x-generic",
    "zip": "package-x-generic",
    "tar": "package-x-generic",
    "gz": "package-x-generic",
    "xz": "package-x-generic",
    "7z": "package-x-generic",
    "sh": "text-x-script",
    "py": "text-x-script",
    // A standalone .desktop file that did not resolve to an installed app
    // (so isDesktop is false and it opens via xdg-open) still looks like a
    // launcher to the user.
    "desktop": "application-x-executable"
};
var GENERIC_FILE_ICON = "text-x-generic";

function iconNameForEntry(entry) {
    if (!entry || typeof entry !== "object")
        return GENERIC_FILE_ICON;
    if (entry.isDir)
        return "folder";
    if (entry.isDesktop) {
        // The QML layer resolves the .desktop Icon= and passes it in; if it
        // failed to resolve, fall back to a generic application icon.
        var ic = entry.icon;
        if (typeof ic === "string" && ic.length > 0)
            return ic;
        return "application-x-executable";
    }
    var name = String(entry.name || "");
    var dot = name.lastIndexOf(".");
    if (dot > 0) {
        var ext = name.slice(dot + 1).toLowerCase();
        if (Object.prototype.hasOwnProperty.call(EXT_ICON, ext))
            return EXT_ICON[ext];
    }
    return GENERIC_FILE_ICON;
}

// Parse the minimal fields of a .desktop file body we care about: Name and
// Icon from the [Desktop Entry] group. Returns { name, icon, noDisplay,
// hidden }. Resilient to garbage — never throws. (The desktop-id itself is
// derived from the file name, not trusted from the body.)
function parseDesktopEntry(text) {
    var result = { name: "", icon: "", noDisplay: false, hidden: false };
    if (typeof text !== "string")
        return result;
    var inGroup = false;
    var lines = text.split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line.length === 0 || line.charAt(0) === "#")
            continue;
        if (line.charAt(0) === "[") {
            inGroup = (line === "[Desktop Entry]");
            continue;
        }
        if (!inGroup)
            continue;
        var eq = line.indexOf("=");
        if (eq <= 0)
            continue;
        var key = line.slice(0, eq).trim();
        var val = line.slice(eq + 1).trim();
        // Only take the un-localized (base) key; ignore Name[xx] localizations
        // for this minimal parse.
        if (key === "Name" && !result.name)
            result.name = val;
        else if (key === "Icon" && !result.icon)
            result.icon = val;
        else if (key === "NoDisplay")
            result.noDisplay = (val.toLowerCase() === "true");
        else if (key === "Hidden")
            result.hidden = (val.toLowerCase() === "true");
    }
    return result;
}

// Decide whether a single click should activate (vs. double click). Pure
// passthrough kept here so the policy lives next to the rest of the logic and
// is unit-testable.
function activatesOnSingleClick(singleClickSetting) {
    return !!singleClickSetting;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        isDesktopId: isDesktopId,
        desktopIdFromFileName: desktopIdFromFileName,
        isHiddenName: isHiddenName,
        filterHidden: filterHidden,
        sortEntries: sortEntries,
        arrangeEntries: arrangeEntries,
        buildLaunchArgv: buildLaunchArgv,
        isSafeArgv: isSafeArgv,
        iconNameForEntry: iconNameForEntry,
        parseDesktopEntry: parseDesktopEntry,
        activatesOnSingleClick: activatesOnSingleClick,
        GENERIC_FILE_ICON: GENERIC_FILE_ICON
    };
}
