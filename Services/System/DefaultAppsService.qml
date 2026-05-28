pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Service to manage default application / MIME type associations.
// Reads from ~/.config/mimeapps.list and /usr/share/applications/mimeapps.list,
// discovers installed .desktop files, and writes user preferences back to
// ~/.config/mimeapps.list [Default Applications].
Singleton {
  id: root

  // ── Category definitions ──────────────────────────────────────────────
  // Each category maps to the MIME types / desktop-file fields used for
  // discovery and the representative MIME type written to mimeapps.list.

  readonly property var categories: [
    {
      "id": "browser",
      "mimeTypes": ["text/html", "x-scheme-handler/http", "x-scheme-handler/https"],
      "primaryMime": "x-scheme-handler/http",
      "allMimes": ["text/html", "x-scheme-handler/http", "x-scheme-handler/https"]
    },
    {
      "id": "mail",
      "mimeTypes": ["x-scheme-handler/mailto"],
      "primaryMime": "x-scheme-handler/mailto",
      "allMimes": ["x-scheme-handler/mailto"]
    },
    {
      "id": "fileManager",
      "mimeTypes": ["inode/directory"],
      "primaryMime": "inode/directory",
      "allMimes": ["inode/directory"]
    },
    {
      "id": "terminal",
      "mimeTypes": [],
      "categoryField": "TerminalEmulator",
      "primaryMime": "",
      "allMimes": []
    },
    {
      "id": "textEditor",
      "mimeTypes": ["text/plain"],
      "primaryMime": "text/plain",
      "allMimes": ["text/plain"]
    },
    {
      "id": "imageViewer",
      "mimeTypes": ["image/png", "image/jpeg", "image/gif", "image/bmp", "image/svg+xml", "image/webp"],
      "primaryMime": "image/png",
      "allMimes": ["image/png", "image/jpeg", "image/gif", "image/bmp", "image/svg+xml", "image/webp"]
    },
    {
      "id": "audioPlayer",
      "mimeTypes": ["audio/mpeg", "audio/ogg", "audio/flac", "audio/x-wav", "audio/mp4", "audio/aac"],
      "primaryMime": "audio/mpeg",
      "allMimes": ["audio/mpeg", "audio/ogg", "audio/flac", "audio/x-wav", "audio/mp4", "audio/aac"]
    },
    {
      "id": "videoPlayer",
      "mimeTypes": ["video/mp4", "video/x-matroska", "video/webm", "video/ogg", "video/x-msvideo", "video/mpeg"],
      "primaryMime": "video/mp4",
      "allMimes": ["video/mp4", "video/x-matroska", "video/webm", "video/ogg", "video/x-msvideo", "video/mpeg"]
    }
  ]

  // ── Public state ──────────────────────────────────────────────────────
  // Map from category id -> list of { desktopId, name, icon, exec }
  property var availableApps: ({})
  // Map from category id -> explicit user choice (or "" for system default)
  property var currentDefaults: ({})
  // Map from category id -> effective resolved handler (for informational display)
  property var resolvedDefaults: ({})

  // Whether the initial scan is finished
  property bool ready: false

  signal defaultsChanged

  // ── Internal ──────────────────────────────────────────────────────────
  property var _desktopEntries: ({})  // desktopId -> { name, icon, exec, mimeTypes, categories }
  property var _systemDefaults: ({})  // mime -> desktopId from system mimeapps.list
  property var _userDefaults: ({})    // mime -> desktopId from user mimeapps.list

  readonly property string _userMimeappsPath: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/mimeapps.list"

  Component.onCompleted: {
    _scanProcess.running = true;
  }

  // ── Single scan script ────────────────────────────────────────────────
  // Outputs JSON with { desktopEntries, systemDefaults, userDefaults }.
  // Uses StdioCollector (not SplitParser) so the full multi-kilobyte JSON
  // payload is buffered before parsing.
  Process {
    id: _scanProcess
    command: ["sh", "-c", _scanScript()]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const parsed = JSON.parse(text.trim());
          root._desktopEntries = parsed.desktopEntries || {};
          root._systemDefaults = parsed.systemDefaults || {};
          root._userDefaults = parsed.userDefaults || {};
          root._buildAvailableApps();
          root._buildCurrentDefaults();
          root.ready = true;
        } catch (e) {
          Logger.e("DefaultAppsService", "Failed to parse scan output: " + e);
        }
      }
    }
  }

  function _scanScript() {
    return `python3 -c '
import os, json, configparser, glob

def parse_desktop_file(path):
    """Parse a .desktop file and return relevant fields."""
    cp = configparser.RawConfigParser()
    cp.optionxform = str  # preserve case
    try:
        cp.read(path, encoding="utf-8")
    except Exception:
        return None
    if not cp.has_section("Desktop Entry"):
        return None
    entry = dict(cp.items("Desktop Entry"))
    if entry.get("Type", "") != "Application":
        return None
    if entry.get("NoDisplay", "").lower() == "true":
        # Allow NoDisplay apps that are still useful as default handlers
        pass
    name = entry.get("Name", "")
    icon = entry.get("Icon", "")
    exe = entry.get("Exec", "")
    mime_str = entry.get("MimeType", "")
    cat_str = entry.get("Categories", "")
    mimes = [m.strip() for m in mime_str.strip().rstrip(";").split(";") if m.strip()]
    cats = [c.strip() for c in cat_str.strip().rstrip(";").split(";") if c.strip()]
    return {"name": name, "icon": icon, "exec": exe, "mimeTypes": mimes, "categories": cats}

def parse_mimeapps(path):
    """Parse [Default Applications] from a mimeapps.list file."""
    defaults = {}
    cp = configparser.RawConfigParser()
    cp.optionxform = str
    try:
        cp.read(path, encoding="utf-8")
    except Exception:
        return defaults
    if cp.has_section("Default Applications"):
        for mime, val in cp.items("Default Applications"):
            # Value may be semicolon-separated; take the first
            ids = [v.strip() for v in val.strip().rstrip(";").split(";") if v.strip()]
            if ids:
                defaults[mime] = ids[0]
    return defaults

# Scan desktop files
entries = {}
dirs = set()
xdg_data = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
for d in xdg_data.split(":"):
    dirs.add(os.path.join(d.strip(), "applications"))
dirs.add(os.path.expanduser("~/.local/share/applications"))

for appdir in dirs:
    for path in glob.glob(os.path.join(appdir, "*.desktop")):
        desktop_id = os.path.basename(path)
        parsed = parse_desktop_file(path)
        if parsed and parsed["name"]:
            # Prefer the first occurrence (user local takes precedence)
            if desktop_id not in entries:
                entries[desktop_id] = parsed

# System mimeapps.list
sys_defaults = {}
for d in xdg_data.split(":"):
    p = os.path.join(d.strip(), "applications", "mimeapps.list")
    if os.path.isfile(p):
        sys_defaults.update(parse_mimeapps(p))

# User mimeapps.list
user_path = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "mimeapps.list"
)
user_defaults = parse_mimeapps(user_path) if os.path.isfile(user_path) else {}

print(json.dumps({"desktopEntries": entries, "systemDefaults": sys_defaults, "userDefaults": user_defaults}))
'`;
  }

  // ── Build the availableApps map ────────────────────────────────────────
  function _buildAvailableApps() {
    var result = {};
    for (var ci = 0; ci < categories.length; ci++) {
      var cat = categories[ci];
      var apps = [];
      var seen = {};

      var ids = Object.keys(_desktopEntries);
      for (var di = 0; di < ids.length; di++) {
        var desktopId = ids[di];
        var entry = _desktopEntries[desktopId];
        var matched = false;

        // Match by MIME types
        if (cat.mimeTypes.length > 0) {
          for (var mi = 0; mi < cat.mimeTypes.length; mi++) {
            if (entry.mimeTypes.indexOf(cat.mimeTypes[mi]) >= 0) {
              matched = true;
              break;
            }
          }
        }

        // Match by Categories field (for terminal)
        if (!matched && cat.categoryField) {
          if (entry.categories.indexOf(cat.categoryField) >= 0) {
            matched = true;
          }
        }

        if (matched && !seen[desktopId]) {
          seen[desktopId] = true;
          apps.push({
            "desktopId": desktopId,
            "name": entry.name,
            "icon": entry.icon,
            "exec": entry.exec
          });
        }
      }

      // Sort alphabetically by name
      apps.sort(function (a, b) {
        return a.name.localeCompare(b.name);
      });

      result[cat.id] = apps;
    }
    availableApps = result;
  }

  // ── Build the currentDefaults map ──────────────────────────────────────
  // currentDefaults holds the *explicit* user-level choice for each category
  // (qdshell setting or user mimeapps.list). An empty string means "no explicit
  // override" → the combo shows "System default" selected and the reset button
  // is hidden. resolvedDefaults holds the system-resolved handler purely for
  // informational display.
  function _buildCurrentDefaults() {
    var current = {};
    var resolved = {};
    for (var ci = 0; ci < categories.length; ci++) {
      var cat = categories[ci];

      // Explicit choice: qdshell settings first, then user mimeapps.list
      var explicit = _getSettingsDefault(cat.id);
      if (!explicit && cat.primaryMime && _userDefaults[cat.primaryMime]) {
        explicit = _userDefaults[cat.primaryMime];
      }
      current[cat.id] = explicit || "";

      // Resolved (effective) handler for display: explicit, else system default
      if (explicit) {
        resolved[cat.id] = explicit;
      } else if (cat.primaryMime && _systemDefaults[cat.primaryMime]) {
        resolved[cat.id] = _systemDefaults[cat.primaryMime];
      } else {
        resolved[cat.id] = "";
      }
    }
    currentDefaults = current;
    resolvedDefaults = resolved;
  }

  function _getSettingsDefault(categoryId) {
    var da = Settings.data.defaultApps;
    if (!da) return "";
    switch (categoryId) {
      case "browser": return da.browser || "";
      case "mail": return da.mail || "";
      case "fileManager": return da.fileManager || "";
      case "terminal": return da.terminal || "";
      case "textEditor": return da.textEditor || "";
      case "imageViewer": return da.imageViewer || "";
      case "audioPlayer": return da.audioPlayer || "";
      case "videoPlayer": return da.videoPlayer || "";
    }
    return "";
  }

  // ── Public: set default for a category ─────────────────────────────────
  function setDefault(categoryId, desktopId) {
    // Find the category definition
    var cat = null;
    for (var i = 0; i < categories.length; i++) {
      if (categories[i].id === categoryId) {
        cat = categories[i];
        break;
      }
    }

    // Update qdshell settings
    _setSettingsDefault(categoryId, desktopId);

    // Keep in-memory user defaults in sync so the UI reflects the change
    // immediately (the on-disk write below is asynchronous).
    if (cat) {
      var um = Object.assign({}, _userDefaults);
      for (var mi = 0; mi < cat.allMimes.length; mi++) {
        if (desktopId) {
          um[cat.allMimes[mi]] = desktopId;
        } else {
          delete um[cat.allMimes[mi]];
        }
      }
      _userDefaults = um;
    }

    // Write to mimeapps.list
    _writeMimeappsList(categoryId, desktopId);

    // Rebuild current defaults
    _buildCurrentDefaults();
    defaultsChanged();
  }

  function _setSettingsDefault(categoryId, desktopId) {
    switch (categoryId) {
      case "browser": Settings.data.defaultApps.browser = desktopId; break;
      case "mail": Settings.data.defaultApps.mail = desktopId; break;
      case "fileManager": Settings.data.defaultApps.fileManager = desktopId; break;
      case "terminal":
        Settings.data.defaultApps.terminal = desktopId;
        _syncTerminalCommand(desktopId);
        break;
      case "textEditor": Settings.data.defaultApps.textEditor = desktopId; break;
      case "imageViewer": Settings.data.defaultApps.imageViewer = desktopId; break;
      case "audioPlayer": Settings.data.defaultApps.audioPlayer = desktopId; break;
      case "videoPlayer": Settings.data.defaultApps.videoPlayer = desktopId; break;
    }
  }

  // Terminal has no standard XDG MIME type. Instead, derive the launcher's
  // terminal command from the chosen .desktop Exec line so the selection
  // actually takes effect for qdshell's app launcher.
  function _syncTerminalCommand(desktopId) {
    if (!desktopId) {
      // Reset to the schema default
      var def = Settings.getDefaultValue("appLauncher.terminalCommand");
      Settings.data.appLauncher.terminalCommand = (def !== undefined) ? def : "alacritty -e";
      return;
    }
    var entry = _desktopEntries[desktopId];
    if (!entry || !entry.exec)
      return;
    // Strip field codes (%f, %u, %U, etc.) from the Exec line, then append the
    // "execute command" flag commonly used by terminals (-e).
    var exec = entry.exec.replace(/%[a-zA-Z]/g, "").trim();
    if (exec) {
      Settings.data.appLauncher.terminalCommand = exec + " -e";
    }
  }

  // ── Public: reset a category to system default ─────────────────────────
  function resetDefault(categoryId) {
    setDefault(categoryId, "");
  }

  // ── Write user mimeapps.list ──────────────────────────────────────────
  function _writeMimeappsList(categoryId, desktopId) {
    // Find the category definition
    var cat = null;
    for (var i = 0; i < categories.length; i++) {
      if (categories[i].id === categoryId) {
        cat = categories[i];
        break;
      }
    }
    if (!cat || cat.allMimes.length === 0) return;

    if (desktopId) {
      // Use xdg-mime to set the default for each MIME type
      for (var mi = 0; mi < cat.allMimes.length; mi++) {
        Quickshell.execDetached(["xdg-mime", "default", desktopId, cat.allMimes[mi]]);
      }
    } else {
      // Remove only the [Default Applications] entries for these MIME types.
      // A naive sed/grep would also strip matching keys from [Added Associations]
      // and [Removed Associations]; use configparser to scope deletion safely.
      _removeProcess.mimes = cat.allMimes;
      _removeProcess.running = true;
    }
  }

  // Process that removes specific MIME keys from [Default Applications] only,
  // preserving every other section. Driven via the `mimes` property.
  Process {
    id: _removeProcess
    property var mimes: []
    command: ["python3", "-c", _removeScript(), JSON.stringify(mimes), _userMimeappsPath]
  }

  function _removeScript() {
    return `
import sys, json, os, configparser
mimes = json.loads(sys.argv[1])
path = sys.argv[2]
if not os.path.isfile(path):
    sys.exit(0)
cp = configparser.RawConfigParser()
cp.optionxform = str
cp.read(path, encoding="utf-8")
if cp.has_section("Default Applications"):
    for m in mimes:
        cp.remove_option("Default Applications", m)
with open(path, "w", encoding="utf-8") as f:
    cp.write(f, space_around_delimiters=False)
`;
  }

  // ── Public: re-scan from disk ──────────────────────────────────────────
  function rescan() {
    ready = false;
    _scanProcess.running = true;
  }

  // ── Public: get display name for a desktop ID ──────────────────────────
  function getAppName(desktopId) {
    if (!desktopId) return "";
    var entry = _desktopEntries[desktopId];
    return entry ? entry.name : desktopId;
  }

  // ── Public: get icon for a desktop ID ──────────────────────────────────
  function getAppIcon(desktopId) {
    if (!desktopId) return "";
    var entry = _desktopEntries[desktopId];
    return entry ? entry.icon : "";
  }
}
