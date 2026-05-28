pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Qdwin
import qs.Services.UI
import "PointerInputParse.js" as PointerInputParse

// PointerInputService — enumerates pointer input devices (mice, touchpads,
// trackpoints) for the Settings > Mouse tab.
//
// Backend model (qdwin-only, mirrors WindowManagerService / PowerService):
//   * qdshell runs on exactly one compositor — qdwin (via libweston). qdwin
//     owns libinput configuration and `qdwin_shell_v1` does NOT yet expose a
//     pointer-config request, so we are PERSIST-ONLY: settings are stored and
//     the UI shows a capability note. They apply automatically once qdwin
//     grows the request (CapabilityService.pointerConfig flips true).
//   * There is NO probing for or dispatch to any non-qdwin compositor
//     (swaymsg / hyprctl / …) — qdwin is the only supported compositor.
//
// Device enumeration is the only live operation: it prefers
// `libinput list-devices` (richest, usually needs permissions) and falls back
// to parsing `/proc/bus/input/devices` (always readable), classifying devices
// by their evdev capability bits. Both are read-only system queries, not
// compositor dispatch. Device names from enumeration are treated as untrusted
// input and are never interpolated raw into `sh -c` strings.
Singleton {
  id: root

  // ─── Public state ────────────────────────────────────────────────
  // Detected pointer devices. Each entry:
  //   { id, name, type ("mouse"|"touchpad"|"trackpoint"|"pointer"),
  //     hasTap (bool), hasNaturalScroll (bool), hasDisableWhileTyping (bool),
  //     hasScrollMethod (bool) }
  property list<var> devices: []

  // Whether the backend can apply pointer settings live. qdwin_shell_v1 has no
  // pointer-config request yet, so this is currently false (persist-only);
  // sourced from the unified CapabilityService, not from probing any compositor.
  readonly property bool canApply: CapabilityService.pointerConfig

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
    Logger.i("PointerInputService", "Service started (qdwin: persist-only, pointer config not yet applied by compositor)");
    refresh();
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
}
