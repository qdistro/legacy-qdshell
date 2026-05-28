pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI
import "PointerInputParse.js" as PointerInputParse

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

  // Parsing/classification lives in the pure PointerInputParse.js module
  // (dual QML/Node), so it is unit-testable headless. This wrapper only wires
  // the parsed result into the singleton's reactive state.
  function _parseEnum(out) {
    var res = PointerInputParse.parseEnum(out);
    root.enumSource = res.source;
    root.devices = res.devices;
    root.ready = true;
    Logger.i("PointerInputService", "enumerated", res.devices.length, "pointer device(s) via", root.enumSource || "none");
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
  function _swayInput(argv) {
    Quickshell.execDetached(argv);
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

    // Build the exact ordered argv list in the pure module (no shell, every
    // token separate) and dispatch each as a fully-tokenised argv.
    var cmds = PointerInputParse.buildSwayInputCommands({
      "accelProfile": accelProfile,
      "pointerSpeed": pointerSpeed,
      "naturalScroll": naturalScroll,
      "scrollMethod": scrollMethod,
      "tapToClick": tapToClick,
      "disableWhileTyping": disableWhileTyping,
      "leftHanded": leftHanded
    });
    for (var i = 0; i < cmds.length; i++)
      _swayInput(cmds[i]);

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
