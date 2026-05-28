pragma Singleton

import QtQuick
import Quickshell
import qs.Commons
import qs.Services.Qdwin
import qs.Services.UI

// WindowManagerService — surfaces window-manager policy (focus, placement,
// snapping, titlebar action, decoration theme, WM shortcuts) and gates live
// application behind a backend capability, exactly mirroring how
// PointerInputService / PowerService capability-gate against qdwin.
//
// Backend model (mirrors PointerInputService under qdwin):
//   * qdshell runs on exactly one compositor — qdwin (via libweston). qdwin's
//     qdwin_shell_v1 IPC has NO window-manager-policy mutation request yet, so
//     we are PERSIST-ONLY: settings are stored and the UI shows a clear
//     "not applied by this backend" banner. They will apply automatically once
//     a supporting qdwin_shell_v1 request lands.
//
// There is NO probing for or dispatch to sway / labwc / hyprctl / any other
// compositor tool — qdshell only ever supports qdwin. The capability flag is
// derived purely from the (compile-time-fixed) Qdwin compositor identity, not
// from detecting any other window manager.
//
// All policy normalisation lives in the pure WindowManagerPolicy.js module
// (dual QML/Node) so it is unit-testable headless. The decoration theme name
// and shortcut strings are treated as UNTRUSTED free text: they are validated /
// clamped there before they are ever persisted.
Singleton {
  id: root

  // ─── Capability ──────────────────────────────────────────────────
  // Whether the active backend can live-apply WM policy. qdwin has no
  // qdwin_shell_v1 WM-policy request yet, so this is currently false
  // (persist-only). Sourced from the unified CapabilityService, NOT from
  // probing for any non-qdwin window manager. Flips true automatically once a
  // qdwin_shell_v1 WM-policy request exists and CapabilityService reports it.
  readonly property bool canApplyWmPolicy: CapabilityService.wmPolicy

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
  // Nothing to initialise (persist-only; no backend probe). Kept so the
  // shell.qml startup sequence has a stable entry point and so a future
  // qdwin_shell_v1 WM-policy wiring has a home.
  function init() {
    Logger.i("WindowManagerService", "Service started (qdwin: persist-only, WM policy not yet applied by compositor)");
  }
}
