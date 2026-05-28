pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Singleton {
  id: root

  // Public list of autostart entries for UI binding
  property list<var> entries: []

  // Whether to include system (/etc/xdg/autostart) entries
  property bool showSystemEntries: true

  readonly property string userDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/autostart"
  readonly property string systemDir: "/etc/xdg/autostart"

  // Shell-safe quoting: wraps a string in single quotes, escaping embedded single quotes
  function _q(s) {
    return "'" + s.replace(/'/g, "'\\''") + "'";
  }

  // Refresh the full list by scanning both directories
  function refresh() {
    _pendingEntries = [];
    _scanPhase = "user";
    scanProcess.command = ["sh", "-c", "ls -1 " + _q(userDir) + "/*.desktop 2>/dev/null; echo '---SEPARATOR---'; ls -1 " + _q(systemDir) + "/*.desktop 2>/dev/null"];
    scanProcess.running = true;
  }

  // Enable or disable an entry by toggling the appropriate desktop file key
  function setEnabled(filePath, enabled) {
    // For system entries, create/update a user override
    const isSystem = filePath.startsWith(systemDir);
    if (isSystem) {
      const fileName = filePath.substring(filePath.lastIndexOf("/") + 1);
      const userPath = userDir + "/" + fileName;
      if (!enabled) {
        // Create user override with Hidden=true
        writeProcess.command = ["sh", "-c",
          "mkdir -p " + _q(userDir) + " && " +
          "cp " + _q(filePath) + " " + _q(userPath) + " && " +
          "sed -i 's/^Hidden=.*/Hidden=true/' " + _q(userPath) + " && " +
          "grep -q '^Hidden=' " + _q(userPath) + " || echo 'Hidden=true' >> " + _q(userPath)];
      } else {
        // Remove the user override to re-enable the system entry
        writeProcess.command = ["sh", "-c", "rm -f " + _q(userPath)];
      }
    } else {
      // User entry: toggle X-GNOME-Autostart-enabled
      if (enabled) {
        writeProcess.command = ["sh", "-c",
          "sed -i '/^Hidden=true/d' " + _q(filePath) + " && " +
          "sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=true/' " + _q(filePath) + " && " +
          "grep -q '^X-GNOME-Autostart-enabled=' " + _q(filePath) + " || true"];
      } else {
        writeProcess.command = ["sh", "-c",
          "sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' " + _q(filePath) + " && " +
          "grep -q '^X-GNOME-Autostart-enabled=' " + _q(filePath) + " || echo 'X-GNOME-Autostart-enabled=false' >> " + _q(filePath)];
      }
    }
    writeProcess.running = true;
  }

  // Add a new autostart entry
  function addEntry(name, comment, exec, workingDir) {
    const safeName = name.replace(/[^a-zA-Z0-9_-]/g, "_");
    const filePath = userDir + "/" + safeName + ".desktop";
    var content = "[Desktop Entry]\n";
    content += "Type=Application\n";
    content += "Name=" + name + "\n";
    if (comment)
      content += "Comment=" + comment + "\n";
    content += "Exec=" + exec + "\n";
    if (workingDir)
      content += "Path=" + workingDir + "\n";
    content += "X-GNOME-Autostart-enabled=true\n";

    writeProcess.command = ["sh", "-c",
      "mkdir -p " + _q(userDir) + " && cat > " + _q(filePath) + " << 'QDSHELL_EOF'\n" + content + "QDSHELL_EOF"];
    writeProcess.running = true;
  }

  // Edit an existing user entry
  function editEntry(filePath, name, comment, exec, workingDir) {
    if (filePath.startsWith(systemDir))
      return; // Cannot edit system entries

    var content = "[Desktop Entry]\n";
    content += "Type=Application\n";
    content += "Name=" + name + "\n";
    if (comment)
      content += "Comment=" + comment + "\n";
    content += "Exec=" + exec + "\n";
    if (workingDir)
      content += "Path=" + workingDir + "\n";
    content += "X-GNOME-Autostart-enabled=true\n";

    writeProcess.command = ["sh", "-c",
      "cat > " + _q(filePath) + " << 'QDSHELL_EOF'\n" + content + "QDSHELL_EOF"];
    writeProcess.running = true;
  }

  // Remove a user autostart entry
  function removeEntry(filePath) {
    if (filePath.startsWith(systemDir))
      return; // Cannot remove system entries
    writeProcess.command = ["sh", "-c", "rm -f " + _q(filePath)];
    writeProcess.running = true;
  }

  // --- Internal ---
  property var _pendingEntries: []
  property string _scanPhase: ""
  property string _scanOutput: ""

  Component.onCompleted: {
    refresh();
  }

  Connections {
    target: Settings
    function onDataChanged() {
      root.showSystemEntries = Settings.data.session ? Settings.data.session.showSystemAutostart : true;
    }
  }

  Process {
    id: scanProcess
    property string _stdout: ""

    onStarted: {
      _stdout = "";
    }

    stdout: SplitParser {
      onRead: data => scanProcess._stdout += data + "\n"
    }

    onExited: (exitCode, exitStatus) => {
      root._parseScanOutput(scanProcess._stdout);
    }
  }

  Process {
    id: readProcess
    property string _stdout: ""
    property string _filePath: ""
    property bool _isSystem: false

    onStarted: {
      _stdout = "";
    }

    stdout: SplitParser {
      onRead: data => readProcess._stdout += data + "\n"
    }

    onExited: (exitCode, exitStatus) => {
      root._parseDesktopFile(readProcess._filePath, readProcess._stdout, readProcess._isSystem);
      root._readNextFile();
    }
  }

  Process {
    id: writeProcess

    onExited: (exitCode, exitStatus) => {
      // Refresh entries after any write operation
      root.refresh();
    }
  }

  property var _filesToRead: []

  function _parseScanOutput(output) {
    _filesToRead = [];
    _pendingEntries = [];

    const lines = output.trim().split("\n");
    let inSystem = false;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line === "---SEPARATOR---") {
        inSystem = true;
        continue;
      }
      if (line === "" || !line.endsWith(".desktop"))
        continue;

      _filesToRead.push({
        "path": line,
        "isSystem": inSystem
      });
    }

    _readNextFile();
  }

  function _readNextFile() {
    if (_filesToRead.length === 0) {
      _finalize();
      return;
    }

    const next = _filesToRead.shift();
    readProcess._filePath = next.path;
    readProcess._isSystem = next.isSystem;
    readProcess.command = ["cat", next.path];
    readProcess.running = true;
  }

  function _parseDesktopFile(filePath, content, isSystem) {
    const lines = content.split("\n");
    let name = "";
    let comment = "";
    let exec = "";
    let icon = "";
    let hidden = false;
    let autostartEnabled = true;
    let type = "";
    let workingDir = "";

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.startsWith("[") && line !== "[Desktop Entry]" && name !== "")
        break; // Stop at next group

      if (line.startsWith("Name=") && !line.startsWith("Name["))
        name = line.substring(5);
      else if (line.startsWith("Comment=") && !line.startsWith("Comment["))
        comment = line.substring(8);
      else if (line.startsWith("Exec="))
        exec = line.substring(5);
      else if (line.startsWith("Icon="))
        icon = line.substring(5);
      else if (line.startsWith("Hidden="))
        hidden = line.substring(7).toLowerCase() === "true";
      else if (line.startsWith("X-GNOME-Autostart-enabled="))
        autostartEnabled = line.substring(26).toLowerCase() !== "false";
      else if (line.startsWith("Type="))
        type = line.substring(5);
      else if (line.startsWith("Path="))
        workingDir = line.substring(5);
    }

    // Skip non-application entries
    if (type !== "" && type !== "Application")
      return;

    // Determine effective enabled state
    const enabled = !hidden && autostartEnabled;

    // For system entries, check if a user override exists that hides it
    const fileName = filePath.substring(filePath.lastIndexOf("/") + 1);
    if (isSystem) {
      // Check if there is already a user entry with same filename
      for (let i = 0; i < _pendingEntries.length; i++) {
        if (_pendingEntries[i].fileName === fileName) {
          // User override exists; skip system entry
          return;
        }
      }
    }

    _pendingEntries.push({
      "filePath": filePath,
      "fileName": fileName,
      "name": name || fileName.replace(".desktop", ""),
      "comment": comment,
      "exec": exec,
      "icon": icon,
      "enabled": enabled,
      "isSystem": isSystem,
      "workingDir": workingDir
    });
  }

  function _finalize() {
    // Sort: user entries first, then system, alphabetical within each group
    let sorted = _pendingEntries.slice();
    sorted.sort(function(a, b) {
      if (a.isSystem !== b.isSystem)
        return a.isSystem ? 1 : -1;
      return a.name.localeCompare(b.name);
    });

    // Filter out system entries if showSystemEntries is false
    if (!showSystemEntries) {
      sorted = sorted.filter(function(e) { return !e.isSystem; });
    }

    entries = sorted;
  }
}
