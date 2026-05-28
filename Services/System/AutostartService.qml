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
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
  }

  // Refresh the full list by scanning both directories
  function refresh() {
    _pendingEntries = [];
    scanProcess.command = ["sh", "-c", "ls -1 " + _q(userDir) + "/*.desktop 2>/dev/null; echo '---SEPARATOR---'; ls -1 " + _q(systemDir) + "/*.desktop 2>/dev/null"];
    scanProcess.running = true;
  }

  // Enable or disable an entry by toggling the appropriate desktop file key.
  // 'entry' is one of the objects from the entries list.
  function setEnabled(entry, enabled) {
    if (entry.isSystem) {
      // System entry (possibly with an existing user override). The override
      // lives at userDir/<fileName> with Hidden=true.
      const userPath = userDir + "/" + entry.fileName;
      if (!enabled) {
        // Create a minimal user override that hides the system entry.
        // We do not copy the full system file (that would shadow future
        // upstream changes); a small Hidden=true stub is sufficient per spec.
        var stub = "[Desktop Entry]\nType=Application\nHidden=true\n";
        writeProcess.command = ["sh", "-c",
          "mkdir -p " + _q(userDir) + " && cat > " + _q(userPath) + " << 'QDSHELL_EOF'\n" + stub + "QDSHELL_EOF"];
      } else {
        // Re-enable by removing the user override so the system entry applies.
        writeProcess.command = ["sh", "-c", "rm -f " + _q(userPath)];
      }
    } else {
      // Plain user entry: toggle X-GNOME-Autostart-enabled / clear Hidden.
      const filePath = entry.filePath;
      if (enabled) {
        writeProcess.command = ["sh", "-c",
          "sed -i '/^Hidden=/d' " + _q(filePath) + " && " +
          "if grep -q '^X-GNOME-Autostart-enabled=' " + _q(filePath) + "; then " +
          "sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=true/' " + _q(filePath) + "; fi"];
      } else {
        writeProcess.command = ["sh", "-c",
          "if grep -q '^X-GNOME-Autostart-enabled=' " + _q(filePath) + "; then " +
          "sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=false/' " + _q(filePath) + "; " +
          "else echo 'X-GNOME-Autostart-enabled=false' >> " + _q(filePath) + "; fi"];
      }
    }
    writeProcess.running = true;
  }

  // Add a new autostart entry. Picks a non-colliding filename.
  function addEntry(name, comment, exec, workingDir) {
    const base = (name.replace(/[^a-zA-Z0-9_-]/g, "_") || "autostart");
    var content = "[Desktop Entry]\n";
    content += "Type=Application\n";
    content += "Name=" + name + "\n";
    if (comment)
      content += "Comment=" + comment + "\n";
    content += "Exec=" + exec + "\n";
    if (workingDir)
      content += "Path=" + workingDir + "\n";
    content += "X-GNOME-Autostart-enabled=true\n";

    // Use a shell loop to find a free filename so we never clobber an
    // existing user or override .desktop file.
    const dir = _q(userDir);
    const heredoc = "cat << 'QDSHELL_EOF'\n" + content + "QDSHELL_EOF";
    writeProcess.command = ["sh", "-c",
      "mkdir -p " + dir + "; " +
      "base=" + _q(base) + "; f=\"" + userDir + "/$base.desktop\"; i=1; " +
      "while [ -e \"$f\" ]; do f=\"" + userDir + "/$base-$i.desktop\"; i=$((i+1)); done; " +
      heredoc + " > \"$f\""];
    writeProcess.running = true;
  }

  // Edit an existing user entry. Updates only Name/Comment/Exec/Path in place,
  // preserving all other keys (Icon, Terminal, OnlyShowIn, enabled state, ...).
  function editEntry(filePath, name, comment, exec, workingDir) {
    if (filePath.startsWith(systemDir))
      return; // Cannot edit system entries

    // Build an upsert command for one key. The replacement value is passed
    // through an environment variable (QD_KEY / QD_VAL) so awk/sh never
    // reinterpret backslashes or shell metacharacters in the value.
    function upsert(idx, key, value) {
      const fp = _q(filePath);
      if (value === "" || value === undefined || value === null) {
        // Remove the key entirely (key is a fixed literal, safe in regex).
        return "sed -i " + _q("/^" + key + "=/d") + " " + fp + "; ";
      }
      const keyVar = "QD_K" + idx;
      const valVar = "QD_V" + idx;
      const assigns = keyVar + "=" + _q(key) + " " + valVar + "=" + _q(value) + " ";
      const awkProg =
        "BEGIN{done=0; k=ENVIRON[\"" + keyVar + "\"]; v=ENVIRON[\"" + valVar + "\"]} " +
        "$0 ~ (\"^\" k \"=\") { if(!done){print k\"=\"v; done=1} next } {print} " +
        "END{ if(!done) print k\"=\"v }";
      // Apply the env assignment directly to the awk command so the variables
      // are in awk's environment (env prefixes only affect one simple command).
      return "tmp=\"$(mktemp)\"; " + assigns + "awk " + _q(awkProg) + " " + fp +
             " > \"$tmp\" && mv \"$tmp\" " + fp + "; ";
    }

    var cmd = upsert(1, "Name", name) + upsert(2, "Comment", comment) + upsert(3, "Exec", exec) + upsert(4, "Path", workingDir);
    writeProcess.command = ["sh", "-c", cmd];
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
  // Map of fileName -> true for files that exist in systemDir (so we can
  // detect that a user file is actually a system-entry override).
  property var _systemFileNames: ({})

  function _parseScanOutput(output) {
    _filesToRead = [];
    _pendingEntries = [];
    _systemFileNames = {};

    const lines = output.trim().split("\n");
    let inSystem = false;
    let userFiles = [];
    let systemFiles = [];

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line === "---SEPARATOR---") {
        inSystem = true;
        continue;
      }
      if (line === "" || !line.endsWith(".desktop"))
        continue;

      const fileName = line.substring(line.lastIndexOf("/") + 1);
      if (inSystem) {
        _systemFileNames[fileName] = true;
        systemFiles.push({ "path": line, "isSystem": true });
      } else {
        userFiles.push({ "path": line, "isSystem": false });
      }
    }

    // Read user files first, then system files. This ordering lets system
    // entries detect a pre-existing user override.
    _filesToRead = userFiles.concat(systemFiles);
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
    let inDesktopEntry = false;
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
      if (line.startsWith("[")) {
        // Only parse keys inside the [Desktop Entry] group.
        inDesktopEntry = (line === "[Desktop Entry]");
        continue;
      }
      if (!inDesktopEntry)
        continue;

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

    const fileName = filePath.substring(filePath.lastIndexOf("/") + 1);

    if (isSystem) {
      // If a user override already exists for this filename, the user entry
      // has already been pushed; we just need to update its display data and
      // mark it as a system entry so the UI treats it as read-only.
      for (let i = 0; i < _pendingEntries.length; i++) {
        if (_pendingEntries[i].fileName === fileName) {
          const e = _pendingEntries[i];
          e.isSystem = true;
          // System metadata fills in display fields the stub override lacks.
          if (!e._rawName)
            e.name = name || fileName.replace(".desktop", "");
          if (!e._rawComment)
            e.comment = comment;
          if (!e._rawExec)
            e.exec = exec;
          // Effective enabled state is whatever the override declared.
          return;
        }
      }
    }

    // Skip non-application entries (only relevant for fresh entries).
    if (type !== "" && type !== "Application")
      return;

    // Determine effective enabled state
    const enabled = !hidden && autostartEnabled;

    _pendingEntries.push({
      "filePath": filePath,
      "fileName": fileName,
      // A user file whose name matches a system entry is really a system override.
      "isSystem": isSystem || (_systemFileNames[fileName] === true),
      "name": name || fileName.replace(".desktop", ""),
      "comment": comment,
      "exec": exec,
      "icon": icon,
      "enabled": enabled,
      "workingDir": workingDir,
      // Raw (unfilled) values so a later system pass can detect a stub override
      "_rawName": name,
      "_rawComment": comment,
      "_rawExec": exec
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
