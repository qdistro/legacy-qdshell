pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Qdwin
import qs.Services.UI
import "WindowManagerPolicy.js" as WMPolicy

// WindowManagerService — surfaces window-manager policy (focus, placement,
// snapping, titlebar action, decoration theme, WM shortcuts) and gates live
// application behind a backend capability, exactly mirroring how
// PointerInputService / PowerService capability-gate against qdwin.
//
// Backend model (mirrors PointerInputService):
//   * Under qdwin (our default compositor) qdwin_shell_v1 has NO WM-policy
//     mutation request yet, so we are PERSIST-ONLY: settings are stored and
//     the UI shows a clear "not applied by this backend" banner. They will
//     apply automatically once a supporting request lands.
//   * Under a sway-like compositor (`swaymsg -t get_tree` succeeds) we
//     reconfigure live via `swaymsg`; under labwc (`labwc --version`
//     available) we trigger `labwc --reconfigure`.
//
// Backend detection is active (a probe at startup), not derived solely from
// the compile-time-fixed Qdwin compositor flags, so the sway/labwc branches
// are reachable when qdshell actually runs under those compositors. On qdwin
// the probe yields "none" and canApplyWmPolicy stays false.
//
// All policy normalisation + command building lives in the pure
// WindowManagerPolicy.js module (dual QML/Node) so it is unit-testable
// headless. The decoration theme name and shortcut strings are treated as
// UNTRUSTED: they are never interpolated into a shell string — every backend
// command is dispatched as a fully-tokenised argv via Quickshell.execDetached.
Singleton {
  id: root

  // ─── Capability ──────────────────────────────────────────────────
  // Which backend can live-apply WM policy.
  //   "sway"  — swaymsg reachable.
  //   "labwc" — labwc reachable.
  //   "none"  — no live-apply backend (e.g. qdwin); persist-only.
  property string applyBackend: "detecting"
  // qdwin can never live-apply (no qdwin_shell_v1 WM request yet); guard on it
  // explicitly so a stray probe success can't flip us on under qdwin.
  readonly property bool canApplyWmPolicy: !Qdwin.isQdwin && (applyBackend === "sway" || applyBackend === "labwc")

  // ─── Settings convenience aliases ────────────────────────────────
  readonly property string focusPolicy: Settings.data.windowManager.focusPolicy
  readonly property int focusFollowsMouseDelay: Settings.data.windowManager.focusFollowsMouseDelay
  readonly property bool raiseOnClick: Settings.data.windowManager.raiseOnClick
  readonly property bool raiseOnHover: Settings.data.windowManager.raiseOnHover
  readonly property string placement: Settings.data.windowManager.placement
  readonly property bool snapEnabled: Settings.data.windowManager.snapEnabled
  readonly property int snapDistance: Settings.data.windowManager.snapDistance
  readonly property string titlebarDoubleClick: Settings.data.windowManager.titlebarDoubleClick
  readonly property string decorationTheme: Settings.data.windowManager.decorationTheme
  readonly property string shortcutClose: Settings.data.windowManager.shortcutClose
  readonly property string shortcutToggleMaximize: Settings.data.windowManager.shortcutToggleMaximize
  readonly property string shortcutToggleFullscreen: Settings.data.windowManager.shortcutToggleFullscreen
  readonly property string shortcutTileLeft: Settings.data.windowManager.shortcutTileLeft
  readonly property string shortcutTileRight: Settings.data.windowManager.shortcutTileRight

  // ─── Init ────────────────────────────────────────────────────────
  function init() {
    Logger.i("WindowManagerService", "Service started");
    detectApplyBackend();
  }

  // ─── Backend detection ───────────────────────────────────────────
  // sway is detected by a live `swaymsg -t get_tree` (proves a sway IPC socket
  // is actually present, not merely that the binary is installed). labwc has
  // no live config IPC, so we confirm the *running* session is labwc via the
  // session-desktop env var rather than merely `command -v labwc` (which would
  // false-positive on any host that has labwc installed but is running another
  // compositor).
  Process {
    id: backendDetectProc
    command: ["sh", "-c", "if command -v swaymsg >/dev/null 2>&1 && swaymsg -t get_tree >/dev/null 2>&1; then echo sway; elif command -v labwc >/dev/null 2>&1 && printf '%s\\n%s\\n' \"$XDG_SESSION_DESKTOP\" \"$XDG_CURRENT_DESKTOP\" | grep -qi labwc; then echo labwc; else echo none; fi"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var v = String(text || "").trim();
        root.applyBackend = (v === "sway" || v === "labwc") ? v : "none";
        Logger.i("WindowManagerService", "applyBackend:", root.applyBackend);
      }
    }
    stderr: StdioCollector {}
  }

  function detectApplyBackend() {
    backendDetectProc.running = true;
  }

  // ─── Apply ───────────────────────────────────────────────────────
  // Translate the stored policy into backend reconfigure invocations. Only
  // runs when canApplyWmPolicy. Each command is a fully-tokenised argv (no
  // `sh -c`); untrusted theme/shortcut strings are passed as single literal
  // argv elements and never built into a shell string.
  function _policyObject() {
    return {
      "focusPolicy": focusPolicy,
      "focusFollowsMouseDelay": focusFollowsMouseDelay,
      "raiseOnClick": raiseOnClick,
      "raiseOnHover": raiseOnHover,
      "placement": placement,
      "snapEnabled": snapEnabled,
      "snapDistance": snapDistance,
      "titlebarDoubleClick": titlebarDoubleClick,
      "decorationTheme": decorationTheme,
      "shortcutClose": shortcutClose,
      "shortcutToggleMaximize": shortcutToggleMaximize,
      "shortcutToggleFullscreen": shortcutToggleFullscreen,
      "shortcutTileLeft": shortcutTileLeft,
      "shortcutTileRight": shortcutTileRight
    };
  }

  function applyAll() {
    if (!canApplyWmPolicy) {
      Logger.d("WindowManagerService", "applyAll skipped — backend cannot apply");
      return;
    }

    var policy = _policyObject();

    if (applyBackend === "sway") {
      var cmds = WMPolicy.buildSwayReconfigureCommands(policy);
      for (var i = 0; i < cmds.length; i++)
        Quickshell.execDetached(cmds[i]);
      var binds = WMPolicy.buildSwayKeybindCommands(policy);
      for (var j = 0; j < binds.length; j++)
        Quickshell.execDetached(binds[j]);
      Logger.i("WindowManagerService", "applied WM policy via swaymsg");
    } else if (applyBackend === "labwc") {
      // The theme name + shortcuts are written to labwc config by the
      // appearance/theme pipeline; here we only ask labwc to re-read it
      // (argument-free argv — no untrusted data on the command line).
      Quickshell.execDetached(WMPolicy.buildLabwcReconfigureCommand());
      Logger.i("WindowManagerService", "requested labwc reconfigure");
    }
  }

  // Re-apply whenever any relevant policy setting changes (live backends only).
  onFocusPolicyChanged: applyAll()
  onFocusFollowsMouseDelayChanged: applyAll()
  onRaiseOnClickChanged: applyAll()
  onRaiseOnHoverChanged: applyAll()
  onPlacementChanged: applyAll()
  onSnapEnabledChanged: applyAll()
  onSnapDistanceChanged: applyAll()
  onTitlebarDoubleClickChanged: applyAll()
  onDecorationThemeChanged: applyAll()
  onShortcutCloseChanged: applyAll()
  onShortcutToggleMaximizeChanged: applyAll()
  onShortcutToggleFullscreenChanged: applyAll()
  onShortcutTileLeftChanged: applyAll()
  onShortcutTileRightChanged: applyAll()

  // Re-apply once the backend is confirmed (covers settings loaded before
  // detection finished).
  onCanApplyWmPolicyChanged: {
    if (canApplyWmPolicy)
      applyAll();
  }
}
