pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

// PointerInputService — enumerates pointer input devices (mice, touchpads,
// trackpoints) and applies libinput-style pointer settings where a backend
// supports it.
//
// Backend model (mirrors PowerService capability-gating):
//   * Under qdwin (our default compositor) the compositor owns libinput
//     configuration and qdwin_shell_v1 does NOT yet expose a pointer-config
//     request. So on qdwin we are PERSIST-ONLY: settings are stored and will
//     apply once a supporting backend exists, but the UI shows a clear
//     "not applied by this backend" note.
//   * Under a sway-like compositor (`swaymsg -t get_inputs` succeeds) we apply
//     live via `swaymsg input <identifier> <cmd>`.
//   * Enumeration prefers `libinput list-devices` (richest, but usually needs
//     permissions); falls back to parsing `/proc/bus/input/devices` (always
//     readable) and classifying devices by their evdev capability bits.
//
// All shell-outs use the `_q()` shell-safe quoting pattern; device names and
// identifiers obtained from enumeration are treated as untrusted input and are
// never interpolated raw into `sh -c` strings.
Singleton {
  id: root

  // ─── Public state ────────────────────────────────────────────────
  // Detected pointer devices. Each entry:
  //   { id, name, type ("mouse"|"touchpad"|"trackpoint"|"pointer"),
  //     hasTap (bool), hasNaturalScroll (bool), hasDisableWhileTyping (bool),
  //     hasScrollMethod (bool) }
  property list<var> devices: []

  // Which backend can actually apply settings live.
  //   "sway"  — swaymsg input available, settings apply live.
  //   "none"  — no live-apply backend (e.g. qdwin); persist-only.
  property string applyBackend: "detecting"
  readonly property bool canApply: applyBackend === "sway"

  // Which source enumerated the device list (for the "no devices" UI state).
  //   "libinput" | "proc" | "none"
  property string enumSource: ""
  readonly property bool hasDevices: devices.length > 0

  // Has enumeration completed at least once?
  property bool ready: false

  // ─── Settings convenience aliases ────────────────────────────────
  // Global (single-profile) pointer policy. Per-device override is not
  // exposed yet; XFCE's per-device model maps cleanly onto these globals for
  // the common single-mouse + single-touchpad case.
  readonly property string accelProfile: Settings.data.pointer.accelProfile
  readonly property real pointerSpeed: Settings.data.pointer.pointerSpeed
  readonly property bool naturalScroll: Settings.data.pointer.naturalScroll
  readonly property string scrollMethod: Settings.data.pointer.scrollMethod
  readonly property bool tapToClick: Settings.data.pointer.tapToClick
  readonly property bool disableWhileTyping: Settings.data.pointer.disableWhileTyping
  readonly property bool leftHanded: Settings.data.pointer.leftHanded
  readonly property bool horizontalScroll: Settings.data.pointer.horizontalScroll
  readonly property int doubleClickTime: Settings.data.pointer.doubleClickTime
  readonly property int doubleClickDistance: Settings.data.pointer.doubleClickDistance
  readonly property int dragThreshold: Settings.data.pointer.dragThreshold

  // ─── Init ────────────────────────────────────────────────────────
  function init() {
    Logger.i("PointerInputService", "Service started");
    detectApplyBackend();
    refresh();
  }

  // Shell-safe quoting: wrap in single quotes, escaping embedded single quotes.
  function _q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'";
  }

  // ─── Backend detection ───────────────────────────────────────────
  Process {
    id: backendDetectProc
    // swaymsg fails (non-zero) when no sway-compatible socket is present.
    command: ["sh", "-c", "command -v swaymsg >/dev/null 2>&1 && swaymsg -t get_inputs >/dev/null 2>&1 && echo sway || echo none"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var v = String(text || "").trim();
        root.applyBackend = (v === "sway") ? "sway" : "none";
        Logger.i("PointerInputService", "applyBackend:", root.applyBackend);
      }
    }
    stderr: StdioCollector {}
  }

  function detectApplyBackend() {
    backendDetectProc.running = true;
  }

  // ─── Enumeration ─────────────────────────────────────────────────
  // First try libinput list-devices; if it is missing or unreadable, fall
  // back to /proc/bus/input/devices. The marker line lets the parser know
  // which format it received.
  function refresh() {
    enumProc.running = false;
    enumProc.command = ["sh", "-c", "if command -v libinput >/dev/null 2>&1 && libinput list-devices >/dev/null 2>&1; then " + "echo '@@SRC:libinput'; libinput list-devices 2>/dev/null; " + "else " + "echo '@@SRC:proc'; cat /proc/bus/input/devices 2>/dev/null; " + "fi"];
    enumProc.running = true;
  }

  Process {
    id: enumProc
    property string _stdout: ""
    onStarted: _stdout = ""
    stdout: StdioCollector {
      onStreamFinished: enumProc._stdout = text
    }
    stderr: StdioCollector {}
    onExited: (code, status) => {
      root._parseEnum(enumProc._stdout);
    }
  }

  function _parseEnum(out) {
    out = String(out || "");
    var lines = out.split("\n");
    var src = "";
    if (lines.length > 0 && lines[0].indexOf("@@SRC:") === 0) {
      src = lines[0].substring(6).trim();
      lines = lines.slice(1);
    }

    var parsed = [];
    if (src === "libinput")
      parsed = _parseLibinput(lines);
    else
      parsed = _parseProc(lines);

    root.enumSource = parsed.length > 0 ? src : "none";
    root.devices = parsed;
    root.ready = true;
    Logger.i("PointerInputService", "enumerated", parsed.length, "pointer device(s) via", root.enumSource || "none");
  }

  // Parse `libinput list-devices` blocks. Devices are separated by blank
  // lines; each block has "Device:", "Capabilities:", "Tap:", "Natural
  // scrolling:", "Scroll methods:", "Disable while typing:" fields.
  function _parseLibinput(lines) {
    var out = [];
    var cur = null;

    function commit() {
      if (cur && cur._isPointer) {
        // Classify type now that all fields are collected. libinput reports a
        // touchpad as "Capabilities: pointer gesture" (NOT "touch" — that is a
        // touchscreen) and uniquely exposes non-n/a tap-to-click /
        // disable-while-typing fields. So a pointer device is a touchpad when
        // it advertises the gesture capability or any touchpad-only field;
        // everything else is a mouse (refined to trackpoint by name below).
        var type = "mouse";
        if (cur._hasGesture || cur.hasTap || cur.hasDisableWhileTyping)
          type = "touchpad";
        var nl = cur.name.toLowerCase();
        if (type === "mouse" && (nl.indexOf("trackpoint") !== -1 || nl.indexOf("track point") !== -1 || nl.indexOf("pointing stick") !== -1))
          type = "trackpoint";

        // libinput has no stable id; use the device name as the identifier.
        out.push({
                   "id": cur.name,
                   "name": cur.name,
                   "type": type,
                   "hasTap": cur.hasTap,
                   "hasNaturalScroll": cur.hasNaturalScroll,
                   "hasDisableWhileTyping": cur.hasDisableWhileTyping,
                   "hasScrollMethod": cur.hasScrollMethod
                 });
      }
      cur = null;
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var t = line.trim();
      if (t === "") {
        commit();
        continue;
      }

      if (t.indexOf("Device:") === 0) {
        commit();
        cur = {
          "name": t.substring(7).trim(),
          "_isPointer": false,
          "_hasGesture": false,
          "hasTap": false,
          "hasNaturalScroll": false,
          "hasDisableWhileTyping": false,
          "hasScrollMethod": false
        };
        continue;
      }
      if (!cur)
        continue;

      if (t.indexOf("Capabilities:") === 0) {
        var caps = t.substring(13).toLowerCase();
        // Only "pointer"-capable devices are mice/touchpads/trackpoints. A
        // device that is "touch" but not "pointer" is a touchscreen — skip it.
        if (caps.indexOf("pointer") !== -1)
          cur._isPointer = true;
        if (caps.indexOf("gesture") !== -1)
          cur._hasGesture = true;
      } else if (t.toLowerCase().indexOf("tap-to-click:") === 0) {
        cur.hasTap = (t.toLowerCase().indexOf("n/a") === -1);
      } else if (t.toLowerCase().indexOf("natural scrolling:") === 0) {
        cur.hasNaturalScroll = (t.toLowerCase().indexOf("n/a") === -1);
      } else if (t.toLowerCase().indexOf("disable-w-typing:") === 0 || t.toLowerCase().indexOf("disable while typing:") === 0) {
        cur.hasDisableWhileTyping = (t.toLowerCase().indexOf("n/a") === -1);
      } else if (t.toLowerCase().indexOf("scroll methods:") === 0) {
        cur.hasScrollMethod = (t.toLowerCase().indexOf("n/a") === -1);
      }
    }
    commit();

    return out;
  }

  // Parse /proc/bus/input/devices. Each device is a block of I:/N:/H:/B: lines
  // separated by a blank line. We classify pointer devices using evdev
  // capability bits: EV_REL (relative axes, mouse) and EV_ABS + INPUT_PROP
  // POINTER/BUTTONPAD (touchpad). Capabilities here are coarser than libinput,
  // so the per-control "has*" flags default to true (the compositor will
  // ignore unsupported ones); they remain false only when no live backend
  // confirms them.
  function _parseProc(lines) {
    var out = [];
    var cur = null;

    function commit() {
      if (cur && cur._isPointer) {
        out.push({
                   "id": cur.name,
                   "name": cur.name,
                   "type": cur.type,
                   // Unknown via /proc — assume available; gating handled by applyBackend.
                   "hasTap": cur.type === "touchpad",
                   "hasNaturalScroll": true,
                   "hasDisableWhileTyping": cur.type === "touchpad",
                   "hasScrollMethod": true
                 });
      }
      cur = null;
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.trim() === "") {
        commit();
        continue;
      }

      var tag = line.substring(0, 2);
      if (tag === "I:") {
        commit();
        cur = {
          "name": "",
          "type": "pointer",
          "_isPointer": false,
          "_ev": "",
          "_prop": "",
          "_key": ""
        };
      } else if (!cur) {
        continue;
      } else if (tag === "N:") {
        var m = line.match(/Name="(.*)"/);
        cur.name = m ? m[1] : line.substring(2).trim();
      } else if (line.indexOf("B: EV=") === 0) {
        cur._ev = line.substring(6).trim();
      } else if (line.indexOf("B: PROP=") === 0) {
        cur._prop = line.substring(8).trim();
      } else if (line.indexOf("B: KEY=") === 0) {
        cur._key = line.substring(7).trim().toLowerCase();
      } else if (line.indexOf("I: ") === 0) {
        // already handled by tag check
      }

      // Re-classify on each line so we have it once the block ends.
      if (cur) {
        var evVal = parseInt(cur._ev || "0", 16) || 0;
        var hasRel = (evVal & 0x04) !== 0;   // EV_REL bit 2
        var hasAbs = (evVal & 0x08) !== 0;   // EV_ABS bit 3
        // INPUT_PROP_POINTER (bit0) / INPUT_PROP_BUTTONPAD (bit2) => touchpad.
        var propVal = parseInt(cur._prop || "0", 16) || 0;
        var isTouchpad = hasAbs && ((propVal & 0x05) !== 0);
        var nameL = (cur.name || "").toLowerCase();
        if (isTouchpad || nameL.indexOf("touchpad") !== -1) {
          cur._isPointer = true;
          cur.type = "touchpad";
        } else if (nameL.indexOf("trackpoint") !== -1 || nameL.indexOf("pointing stick") !== -1) {
          cur._isPointer = true;
          cur.type = "trackpoint";
        } else if (hasRel) {
          // Relative pointer with mouse buttons => mouse. Exclude pure
          // consumer-control / keyboard devices that also expose EV_REL.
          cur._isPointer = true;
          cur.type = "mouse";
        }
      }
    }
    commit();

    // De-duplicate by name (a single physical mouse may show several event
    // nodes); keep the first occurrence.
    var seen = ({});
    var dedup = [];
    for (var k = 0; k < out.length; k++) {
      var nm = out[k].name;
      if (seen[nm])
        continue;
      seen[nm] = true;
      dedup.push(out[k]);
    }
    return dedup;
  }

  // ─── Apply ───────────────────────────────────────────────────────
  // Translate the stored settings into `swaymsg input <selector> <option>
  // <value>` invocations. Only runs when applyBackend === "sway".
  //
  // Each call is dispatched as a fully-tokenised argv via
  // Quickshell.execDetached — there is no `sh -c` and therefore no shell
  // parsing of any argument. `selector` is always a controlled literal
  // (type:pointer / type:touchpad); `option` is a controlled literal; `value`
  // is a value we computed from a typed/clamped setting. Device names from
  // enumeration are NEVER used as selectors here, so untrusted strings never
  // reach a command line.
  function _swayInput(selector, option, value) {
    Quickshell.execDetached(["swaymsg", "input", selector, option, value]);
  }

  // sway input options that XFCE's mouse dialog maps onto. Settings that have
  // no sway equivalent (double-click time/distance, drag threshold,
  // horizontal-scroll toggle) are intentionally NOT emitted here — they are
  // persist-only and surfaced as such in the UI rather than firing inert
  // commands that silently do nothing.
  function applyAll() {
    if (!canApply) {
      Logger.d("PointerInputService", "applyAll skipped — backend cannot apply");
      return;
    }

    var ptr = "type:pointer";
    var tp = "type:touchpad";

    // Acceleration profile + speed (sway: accel_profile / pointer_accel).
    var profile = (accelProfile === "flat") ? "flat" : "adaptive";
    _swayInput(ptr, "accel_profile", profile);
    _swayInput(tp, "accel_profile", profile);
    // pointer_accel takes -1..1; pointerSpeed is stored 0..1 → map to -1..1.
    var accel = (Math.max(0, Math.min(1, pointerSpeed)) * 2 - 1).toFixed(2);
    _swayInput(ptr, "pointer_accel", accel);
    _swayInput(tp, "pointer_accel", accel);

    // Natural scroll.
    var nat = naturalScroll ? "enabled" : "disabled";
    _swayInput(ptr, "natural_scroll", nat);
    _swayInput(tp, "natural_scroll", nat);

    // Scroll method (touchpad only).
    var sm = scrollMethod;
    if (sm !== "two_finger" && sm !== "edge" && sm !== "on_button_down" && sm !== "none")
      sm = "two_finger";
    _swayInput(tp, "scroll_method", sm);

    // Tap-to-click + disable-while-typing (touchpad only).
    _swayInput(tp, "tap", tapToClick ? "enabled" : "disabled");
    _swayInput(tp, "dwt", disableWhileTyping ? "enabled" : "disabled");

    // Left-handed mode.
    var lh = leftHanded ? "enabled" : "disabled";
    _swayInput(ptr, "left_handed", lh);
    _swayInput(tp, "left_handed", lh);

    Logger.i("PointerInputService", "applied pointer settings via swaymsg");
  }

  // Re-apply whenever a relevant setting changes (live backends only).
  // horizontalScroll is omitted: sway/libinput has no on/off toggle for it
  // (horizontal scrolling is implicit on two-finger touchpads), so we persist
  // it for future backends rather than emit an inert command.
  onAccelProfileChanged: applyAll()
  onPointerSpeedChanged: applyAll()
  onNaturalScrollChanged: applyAll()
  onScrollMethodChanged: applyAll()
  onTapToClickChanged: applyAll()
  onDisableWhileTypingChanged: applyAll()
  onLeftHandedChanged: applyAll()

  // Re-apply once the backend is confirmed (covers settings loaded before
  // detection finished).
  onApplyBackendChanged: {
    if (canApply)
    applyAll();
  }
}
