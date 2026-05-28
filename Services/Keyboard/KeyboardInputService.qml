pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

/// KeyboardInputService — keyboard repeat, cursor blink, layout, NumLock,
/// Compose key and XKB option management for the Settings > Keyboard tab.
///
/// Apply mechanism + capability gating (mirrors PowerService): under a pure
/// Wayland compositor (qdwin) the compositor owns xkb + key repeat and exposes
/// no QML/IPC hook for it (Qdwin.cycleKeyboardLayout() is a stub and
/// qdwin_shell_v1 has no repeat/xkb requests). So we DETECT what is actually
/// applicable:
///   - X11 / Xwayland reachable (DISPLAY set, xset/setxkbmap present) ⇒ we can
///     apply repeat (xset r rate), blink, layout/variant/model/options/compose
///     (setxkbmap) and NumLock (numlockx) to the X server. Xwayland clients
///     pick these up; native Wayland clients honour the compositor's own xkb.
///   - Otherwise ⇒ persist only and surface a capability note. We never pretend
///     to apply when no supporting backend exists.
///
/// All settings persist regardless (Settings.data.keyboard.*) so they take
/// effect the moment a supporting backend (e.g. a future qdwin xkb request)
/// reads them. Apply runs at startup and on user changes.
Singleton {
  id: root

  // ─── Capability flags ────────────────────────────────────────────
  // Whether an X server (real X11 or Xwayland) is reachable for apply.
  property bool hasXServer: false
  // Individual tool availability.
  property bool hasSetxkbmap: false
  property bool hasXset: false
  property bool hasNumlockx: false
  property bool hasLocalectl: false
  // Whether the running session is Wayland (informational, for the note).
  readonly property bool isWayland: (Quickshell.env("WAYLAND_DISPLAY") || "") !== ""
  // True once capability detection has finished its first pass.
  property bool capabilitiesReady: false

  // Can we apply keyboard settings to *something* right now?
  readonly property bool canApply: hasXServer && (hasSetxkbmap || hasXset)
  // Are we limited to persisting (no live apply backend detected)?
  readonly property bool persistOnly: capabilitiesReady && !canApply

  // ─── Discovered XKB data (for the UI pickers) ────────────────────
  // models: [{ key, name }], layouts: [{ key, name }],
  // variants keyed by layout code: { "us": [{ key, name }], ... },
  // options grouped: [{ group, name, options: [{ key, name }] }]
  property var availableModels: []
  property var availableLayouts: []
  property var availableVariants: ({})
  property var availableOptions: []
  property bool xkbDataLoaded: false

  // Convenience settings aliases.
  readonly property int repeatDelay: Settings.data.keyboard.repeatDelay
  readonly property int repeatRate: Settings.data.keyboard.repeatRate
  readonly property bool cursorBlink: Settings.data.keyboard.cursorBlink
  readonly property int cursorBlinkRate: Settings.data.keyboard.cursorBlinkRate
  readonly property bool restoreNumLock: Settings.data.keyboard.restoreNumLock
  readonly property bool useSystemDefaults: Settings.data.keyboard.useSystemDefaults
  readonly property string keyboardModel: Settings.data.keyboard.model
  readonly property var layouts: Settings.data.keyboard.layouts
  readonly property var variants: Settings.data.keyboard.variants
  readonly property string switchShortcut: Settings.data.keyboard.switchShortcut
  readonly property string composeKey: Settings.data.keyboard.composeKey
  readonly property var xkbOptions: Settings.data.keyboard.xkbOptions

  // ─── Initialisation ──────────────────────────────────────────────
  function init() {
    Logger.i("KeyboardInput", "Service started");
    queryCapabilities();
  }

  Component.onCompleted: {
    // Self-init so the singleton works even if shell.qml does not call init().
    queryCapabilities();
  }

  // ─── Shell-safe quoting (AutostartService pattern) ────────────────
  function _q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
  }

  // ─── Capability detection ────────────────────────────────────────
  Process {
    id: capProc
    running: false
    // Emit one line per probe so we can parse a stable key=value set.
    command: ["sh", "-c",
      // Reachable X server: DISPLAY is set AND at least one X client tool can
      // talk to it. Probe with setxkbmap -query first (it is what we use to
      // apply), falling back to xset q, so a session missing one tool but
      // having the other is still detected as applyable.
      "x=no; if [ -n \"$DISPLAY\" ]; then " +
      "{ command -v setxkbmap >/dev/null 2>&1 && setxkbmap -query >/dev/null 2>&1 && x=yes; } || " +
      "{ command -v xset >/dev/null 2>&1 && xset q >/dev/null 2>&1 && x=yes; }; fi; echo \"xserver=$x\"; " +
      "command -v setxkbmap >/dev/null 2>&1 && echo setxkbmap=yes || echo setxkbmap=no; " +
      "command -v xset >/dev/null 2>&1 && echo xset=yes || echo xset=no; " +
      "command -v numlockx >/dev/null 2>&1 && echo numlockx=yes || echo numlockx=no; " +
      "command -v localectl >/dev/null 2>&1 && echo localectl=yes || echo localectl=no"]
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n");
        for (var i = 0; i < lines.length; i++) {
          var kv = lines[i].split("=");
          if (kv.length !== 2)
            continue;
          var v = kv[1].trim() === "yes";
          switch (kv[0].trim()) {
          case "xserver": root.hasXServer = v; break;
          case "setxkbmap": root.hasSetxkbmap = v; break;
          case "xset": root.hasXset = v; break;
          case "numlockx": root.hasNumlockx = v; break;
          case "localectl": root.hasLocalectl = v; break;
          }
        }
        root.capabilitiesReady = true;
        Logger.d("KeyboardInput", "caps: xServer=" + root.hasXServer
                 + " setxkbmap=" + root.hasSetxkbmap + " xset=" + root.hasXset
                 + " numlockx=" + root.hasNumlockx);
        // Now that caps are known, load the XKB tables and apply.
        root.loadXkbData();
        root.applyAll();
      }
    }
    stderr: StdioCollector {}
  }

  function queryCapabilities() {
    // Idempotent: shell.qml calls init() and the singleton also self-inits in
    // Component.onCompleted; only the first probe runs.
    if (capProc.running || capabilitiesReady)
      return;
    capProc.running = true;
  }

  // ─── XKB data loading ────────────────────────────────────────────
  // Parse /usr/share/X11/xkb/rules/evdev.lst, which lists models, layouts,
  // variants and options in `! section` blocks. This is the same table XFCE
  // and setxkbmap consult. We avoid localectl here because evdev.lst is the
  // richest source for variants grouped per layout.
  Process {
    id: xkbProc
    running: false
    command: ["sh", "-c",
      "f=/usr/share/X11/xkb/rules/evdev.lst; [ -f \"$f\" ] || f=/usr/share/X11/xkb/rules/base.lst; cat \"$f\" 2>/dev/null"]
    property string _buf: ""
    onStarted: _buf = ""
    stdout: SplitParser {
      onRead: data => xkbProc._buf += data + "\n"
    }
    onExited: (code, status) => {
      root._parseXkbList(xkbProc._buf);
    }
    stderr: StdioCollector {}
  }

  function loadXkbData() {
    xkbProc.running = true;
  }

  function _parseXkbList(text) {
    var models = [];
    var layouts = [];
    var variants = ({});
    var optionGroups = ({}); // groupKey -> { name, options: [] }
    var section = "";

    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var trimmed = line.trim();
      if (trimmed === "")
        continue;
      if (trimmed.charAt(0) === "!") {
        // e.g. "! model", "! layout", "! variant", "! option"
        section = trimmed.substring(1).trim();
        continue;
      }
      // Each entry: <key><whitespace><description...>
      var m = trimmed.match(/^(\S+)\s+(.*)$/);
      if (!m)
        continue;
      var key = m[1];
      var name = m[2].trim();

      if (section === "model") {
        models.push({ "key": key, "name": name });
      } else if (section === "layout") {
        layouts.push({ "key": key, "name": name });
      } else if (section === "variant") {
        // Variant key format: "<variant>" with description "<Lang>: <desc>";
        // the owning layout is the trailing token in the description's colon
        // group. evdev.lst variant lines look like:
        //   intl    us: English (US, intl., with dead keys)
        // The layout code is the token before the colon.
        var colon = name.indexOf(":");
        var layoutCode = colon > 0 ? name.substring(0, colon).trim() : "";
        if (layoutCode === "")
          continue;
        if (!variants[layoutCode])
          variants[layoutCode] = [];
        variants[layoutCode].push({ "key": key, "name": name });
      } else if (section === "option") {
        // Option keys are "group" or "group:option". Group headers have no
        // colon; member options are "group:something".
        if (key.indexOf(":") === -1) {
          if (!optionGroups[key])
            optionGroups[key] = { "name": name, "options": [] };
          else
            optionGroups[key].name = name;
        } else {
          var grp = key.substring(0, key.indexOf(":"));
          if (!optionGroups[grp])
            optionGroups[grp] = { "name": grp, "options": [] };
          optionGroups[grp].options.push({ "key": key, "name": name });
        }
      }
    }

    var optionsOut = [];
    for (var g in optionGroups) {
      optionsOut.push({ "group": g, "name": optionGroups[g].name, "options": optionGroups[g].options });
    }
    optionsOut.sort(function (a, b) { return a.name.localeCompare(b.name); });

    root.availableModels = models;
    root.availableLayouts = layouts;
    root.availableVariants = variants;
    root.availableOptions = optionsOut;
    root.xkbDataLoaded = true;
    Logger.d("KeyboardInput", "xkb data: " + models.length + " models, "
             + layouts.length + " layouts");
  }

  // Human-readable name for a layout code (falls back to the code itself).
  function layoutName(code) {
    for (var i = 0; i < availableLayouts.length; i++) {
      if (availableLayouts[i].key === code)
        return availableLayouts[i].name;
    }
    return code;
  }

  function variantsFor(code) {
    return availableVariants[code] || [];
  }

  // ─── Apply ───────────────────────────────────────────────────────
  Process {
    id: applyProc
    running: false
    stderr: StdioCollector {}
  }

  // Build the `setxkbmap` argument list from the persisted settings, using a
  // shell command string so we can chain with xset/numlockx. All user-provided
  // tokens go through _q() so a malicious layout/option string cannot inject.
  function _setxkbmapCmd() {
    if (!hasSetxkbmap)
      return "";
    var ls = (layouts && layouts.length > 0) ? layouts.slice() : ["us"];
    // Variants are positional and comma-joined to match the layout list.
    var vs = [];
    for (var i = 0; i < ls.length; i++) {
      var code = ls[i];
      vs.push((variants && variants[code]) ? variants[code] : "");
    }
    var cmd = "setxkbmap";
    if (keyboardModel && keyboardModel !== "")
      cmd += " -model " + _q(keyboardModel);
    cmd += " -layout " + _q(ls.join(","));
    // Only pass -variant if at least one variant is non-empty.
    var anyVariant = vs.some(function (v) { return v !== ""; });
    if (anyVariant)
      cmd += " -variant " + _q(vs.join(","));

    // Collect XKB options: explicit option list + switch shortcut + compose.
    var opts = [];
    if (xkbOptions) {
      for (var j = 0; j < xkbOptions.length; j++) {
        if (xkbOptions[j] && xkbOptions[j] !== "")
          opts.push(xkbOptions[j]);
      }
    }
    if (switchShortcut && switchShortcut !== "")
      opts.push(switchShortcut);
    if (composeKey && composeKey !== "")
      opts.push(composeKey);
    // Always pass an initial empty -option so previously-set options are
    // cleared from the X server even when the user removed the last option;
    // each desired option is then re-added. (setxkbmap accumulates options
    // otherwise, so a removal in the UI would never take effect live.)
    cmd += " -option " + _q("");
    for (var k = 0; k < opts.length; k++)
      cmd += " -option " + _q(opts[k]);
    return cmd;
  }

  function _xsetRepeatCmd() {
    if (!hasXset)
      return "";
    // xset r rate <delay-ms> <rate-hz>
    var d = Math.max(1, Math.round(repeatDelay));
    var r = Math.max(1, Math.round(repeatRate));
    return "xset r rate " + _q(String(d)) + " " + _q(String(r));
  }

  function _numlockCmd() {
    if (!restoreNumLock || !hasNumlockx)
      return "";
    return "numlockx on";
  }

  // Apply everything appropriate for the current capabilities.
  //
  // useSystemDefaults follows XFCE semantics: it scopes ONLY the layout block
  // (model/layout/variant/options/compose/switch). Key repeat, cursor blink
  // and NumLock are behavior settings that stay independently editable and
  // applied regardless of the layout-defaults toggle.
  function applyAll() {
    if (!capabilitiesReady)
      return;
    if (!canApply) {
      Logger.i("KeyboardInput", "No apply backend (persist-only); settings saved for a supporting compositor");
      return;
    }
    var parts = [];
    // Layout block — skipped when deferring to system layout defaults.
    if (!useSystemDefaults)
      parts.push(_setxkbmapCmd());
    // Behavior — always applied (not part of "use system defaults").
    parts.push(_xsetRepeatCmd());
    parts.push(_numlockCmd());
    _runChain(parts);
  }

  function _runChain(parts) {
    var nonEmpty = parts.filter(function (p) { return p && p !== ""; });
    if (nonEmpty.length === 0)
      return;
    // Each part is independent; do not abort the chain if one tool is missing.
    var cmd = nonEmpty.join("; ");
    applyProc.command = ["sh", "-c", cmd];
    applyProc.running = true;
    Logger.d("KeyboardInput", "apply: " + cmd);
  }

  // React to setting changes (debounced) so edits in the UI take effect.
  Timer {
    id: applyDebounce
    interval: 400
    repeat: false
    onTriggered: root.applyAll()
  }

  function requestApply() {
    if (capabilitiesReady)
      applyDebounce.restart();
  }

  onRepeatDelayChanged: requestApply()
  onRepeatRateChanged: requestApply()
  onRestoreNumLockChanged: requestApply()
  onUseSystemDefaultsChanged: requestApply()
  onKeyboardModelChanged: requestApply()
  onLayoutsChanged: requestApply()
  onVariantsChanged: requestApply()
  onSwitchShortcutChanged: requestApply()
  onComposeKeyChanged: requestApply()
  onXkbOptionsChanged: requestApply()

  // ─── Layout list helpers (used by the UI) ────────────────────────
  function addLayout(code, variant) {
    var ls = (layouts || []).slice();
    if (ls.indexOf(code) !== -1)
      return; // already present
    ls.push(code);
    Settings.data.keyboard.layouts = ls;
    if (variant && variant !== "") {
      var vmap = _cloneVariants();
      vmap[code] = variant;
      Settings.data.keyboard.variants = vmap;
    }
  }

  function removeLayout(code) {
    var ls = (layouts || []).slice();
    var idx = ls.indexOf(code);
    if (idx === -1)
      return;
    ls.splice(idx, 1);
    if (ls.length === 0)
      ls = ["us"]; // never leave an empty layout list
    Settings.data.keyboard.layouts = ls;
    var vmap = _cloneVariants();
    if (vmap[code] !== undefined) {
      delete vmap[code];
      Settings.data.keyboard.variants = vmap;
    }
  }

  function moveLayout(fromIdx, toIdx) {
    var ls = (layouts || []).slice();
    if (fromIdx < 0 || fromIdx >= ls.length || toIdx < 0 || toIdx >= ls.length)
      return;
    var item = ls.splice(fromIdx, 1)[0];
    ls.splice(toIdx, 0, item);
    Settings.data.keyboard.layouts = ls;
  }

  function setVariant(code, variant) {
    var vmap = _cloneVariants();
    if (!variant || variant === "")
      delete vmap[code];
    else
      vmap[code] = variant;
    Settings.data.keyboard.variants = vmap;
  }

  function variantOf(code) {
    return (variants && variants[code]) ? variants[code] : "";
  }

  function _cloneVariants() {
    var out = ({});
    if (variants) {
      for (var k in variants)
        out[k] = variants[k];
    }
    return out;
  }
}
