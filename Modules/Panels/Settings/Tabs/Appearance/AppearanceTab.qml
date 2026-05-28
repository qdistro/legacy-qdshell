import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginL
  Layout.fillWidth: true

  // --- Workspace settings section ---

  NText {
    text: I18n.tr("panels.appearance.workspaces-header")
    pointSize: Style.fontSizeL
    font.weight: Style.fontWeightBold
    color: Color.mOnSurface
  }

  NSpinBox {
    label: I18n.tr("panels.appearance.workspace-count-label")
    description: I18n.tr("panels.appearance.workspace-count-description")
    from: 1
    to: 32
    value: Settings.data.workspaces.count
    defaultValue: Settings.getDefaultValue("workspaces.count")
    onValueChanged: {
      if (value !== Settings.data.workspaces.count) {
        Settings.data.workspaces.count = value;
        // Resize workspace names array to match new count
        var names = (Settings.data.workspaces.names || []).slice();
        while (names.length < value) {
          names.push(String(names.length + 1));
        }
        if (names.length > value) {
          names = names.slice(0, value);
        }
        Settings.data.workspaces.names = names;
      }
    }
  }

  // Workspace name editors
  Repeater {
    model: Settings.data.workspaces.count

    delegate: NTextInput {
      Layout.fillWidth: true
      label: I18n.tr("panels.appearance.workspace-name-label") + " " + (index + 1)
      text: {
        var names = Settings.data.workspaces.names || [];
        return (index < names.length) ? names[index] : String(index + 1);
      }
      onEditingFinished: {
        var names = (Settings.data.workspaces.names || []).slice();
        while (names.length <= index) {
          names.push(String(names.length + 1));
        }
        names[index] = text || String(index + 1);
        Settings.data.workspaces.names = names;
      }
    }
  }

  NDivider {
    Layout.fillWidth: true
  }

  // --- Icon theme section ---

  NText {
    text: I18n.tr("panels.appearance.themes-header")
    pointSize: Style.fontSizeL
    font.weight: Style.fontWeightBold
    color: Color.mOnSurface
  }

  // Discover installed icon themes
  property var iconThemes: []

  Process {
    id: iconThemeDiscovery
    command: ["sh", "-c", "for d in /usr/share/icons/*/index.theme; do dirname \"$d\" | xargs basename; done 2>/dev/null | sort -u"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var themes = this.text.trim().split("\n").filter(function(t) { return t.length > 0; });
        root.iconThemes = themes;
      }
    }
    stderr: StdioCollector {}
  }

  Component.onCompleted: {
    iconThemeDiscovery.running = true;
    cursorThemeDiscovery.running = true;
  }

  NComboBox {
    id: iconThemeCombo
    label: I18n.tr("panels.appearance.icon-theme-label")
    description: I18n.tr("panels.appearance.icon-theme-description")
    Layout.fillWidth: true
    minimumWidth: 250

    model: {
      var items = [{ "key": "", "name": I18n.tr("panels.appearance.system-default") }];
      for (var i = 0; i < root.iconThemes.length; i++) {
        items.push({ "key": root.iconThemes[i], "name": root.iconThemes[i] });
      }
      return items;
    }

    currentKey: Settings.data.appearance.iconTheme
    defaultValue: Settings.getDefaultValue("appearance.iconTheme")

    onSelected: function(key) {
      Settings.data.appearance.iconTheme = key;
      root.applyIconTheme(key);
    }
  }

  NDivider {
    Layout.fillWidth: true
  }

  // --- Cursor theme section ---

  property var cursorThemes: []

  Process {
    id: cursorThemeDiscovery
    command: ["sh", "-c", "for d in /usr/share/icons/*/cursors; do dirname \"$d\" | xargs basename; done 2>/dev/null | sort -u"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var themes = this.text.trim().split("\n").filter(function(t) { return t.length > 0; });
        root.cursorThemes = themes;
      }
    }
    stderr: StdioCollector {}
  }

  NComboBox {
    id: cursorThemeCombo
    label: I18n.tr("panels.appearance.cursor-theme-label")
    description: I18n.tr("panels.appearance.cursor-theme-description")
    Layout.fillWidth: true
    minimumWidth: 250

    model: {
      var items = [{ "key": "", "name": I18n.tr("panels.appearance.system-default") }];
      for (var i = 0; i < root.cursorThemes.length; i++) {
        items.push({ "key": root.cursorThemes[i], "name": root.cursorThemes[i] });
      }
      return items;
    }

    currentKey: Settings.data.appearance.cursorTheme
    defaultValue: Settings.getDefaultValue("appearance.cursorTheme")

    onSelected: function(key) {
      Settings.data.appearance.cursorTheme = key;
      root.applyCursorTheme(key, Settings.data.appearance.cursorSize);
    }
  }

  NSpinBox {
    label: I18n.tr("panels.appearance.cursor-size-label")
    description: I18n.tr("panels.appearance.cursor-size-description")
    from: 16
    to: 64
    stepSize: 8
    value: Settings.data.appearance.cursorSize
    defaultValue: Settings.getDefaultValue("appearance.cursorSize")
    onValueChanged: {
      if (value !== Settings.data.appearance.cursorSize) {
        Settings.data.appearance.cursorSize = value;
        root.applyCursorTheme(Settings.data.appearance.cursorTheme, value);
      }
    }
  }

  // Spacer
  Item {
    Layout.fillHeight: true
  }

  // --- Apply helpers ---

  // Reject theme names with shell-unsafe characters
  function isSafeThemeName(name) {
    return (/^[A-Za-z0-9._-]+$/).test(name);
  }

  // Helper: ensure a GTK settings.ini key exists with the given value.
  // Works on both fresh files (creates [Settings] section) and existing ones.
  function _gtkSetKey(key, value) {
    Quickshell.execDetached(["sh", "-c",
      "for dir in ~/.config/gtk-3.0 ~/.config/gtk-4.0; do " +
        "mkdir -p \"$dir\"; " +
        "f=\"$dir/settings.ini\"; " +
        "if grep -q '^" + key + "=' \"$f\" 2>/dev/null; then " +
          "sed -i 's/^" + key + "=.*/" + key + "=" + value + "/' \"$f\"; " +
        "elif [ -s \"$f\" ]; then " +
          "printf '" + key + "=" + value + "\\n' >> \"$f\"; " +
        "else " +
          "printf '[Settings]\\n" + key + "=" + value + "\\n' > \"$f\"; " +
        "fi; " +
      "done"
    ]);
  }

  // Helper: remove a GTK settings.ini key (revert to system default).
  function _gtkRemoveKey(key) {
    Quickshell.execDetached(["sh", "-c",
      "for dir in ~/.config/gtk-3.0 ~/.config/gtk-4.0; do " +
        "sed -i '/^" + key + "=/d' \"$dir/settings.ini\" 2>/dev/null; " +
      "done"
    ]);
  }

  function applyIconTheme(theme) {
    if (!theme || theme === "") {
      // Revert to system default: remove our overrides
      _gtkRemoveKey("gtk-icon-theme-name");
      return;
    }
    if (!isSafeThemeName(theme)) return;
    _gtkSetKey("gtk-icon-theme-name", theme);
  }

  function applyCursorTheme(theme, size) {
    var sizeStr = String(Math.max(16, Math.min(64, size || 24)));
    if (!theme || theme === "") {
      // Revert to system default: remove our overrides and default cursor index
      _gtkRemoveKey("gtk-cursor-theme-name");
      _gtkRemoveKey("gtk-cursor-theme-size");
      Quickshell.execDetached(["rm", "-f", Quickshell.env("HOME") + "/.icons/default/index.theme"]);
      return;
    }
    if (!isSafeThemeName(theme)) return;
    // Persist to ~/.icons/default/index.theme so X11/XWayland apps also pick it up
    Quickshell.execDetached(["sh", "-c",
      "mkdir -p ~/.icons/default; " +
      "printf '[Icon Theme]\\nInherits=" + theme + "\\n' > ~/.icons/default/index.theme"
    ]);
    _gtkSetKey("gtk-cursor-theme-name", theme);
    _gtkSetKey("gtk-cursor-theme-size", sizeStr);
  }
}
