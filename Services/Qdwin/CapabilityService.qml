pragma Singleton

import QtQuick
import Quickshell
import qs.Commons

/// CapabilityService — single source of truth for what the qdwin compositor's
/// `qdwin_shell_v1` IPC can currently *apply live*.
///
/// qdshell supports exactly one compositor (qdwin via libweston). Several
/// settings areas (pointer/touchpad, keyboard xkb+repeat, window-manager
/// policy, display/output management, workspace mutation, idle/DPMS, global
/// keybind registration) describe state that only the compositor can enact.
/// Until `qdwin_shell_v1` grows the matching request, those controls are
/// PERSIST-ONLY: the value is stored and surfaced in the UI behind a
/// capability note, and applies automatically once the backend supports it.
///
/// This replaces the ad-hoc per-page capability detection that used to probe
/// for foreign compositors (swaymsg/hyprctl/…). There is NO probing for or
/// dispatch to any non-qdwin compositor — every flag is derived purely from the
/// (compile-time-fixed) qdwin backend identity, and flips to true in exactly
/// one place here when the corresponding qdwin_shell_v1 request lands.
///
/// NOTE: pages that ALSO have a legitimate non-compositor apply path keep it.
/// Keyboard and Accessibility apply via X11/XWayland tooling (setxkbmap, xset,
/// xkbset, numlockx) when an X server is reachable — that is the X server, not
/// a foreign Wayland compositor, so it is allowed and unaffected by these
/// flags. Those services OR their X capability together with the relevant flag
/// below.
Singleton {
  id: root

  // ─── qdwin_shell_v1 live-apply capabilities ──────────────────────
  // All currently false: qdwin_shell_v1 exposes none of these requests yet.
  // When qdwin gains one, flip the corresponding flag here (or derive it from
  // a future qdwin capability advertisement) and every consumer follows.

  // libinput pointer/touchpad configuration (accel, scroll, tap, …).
  readonly property bool pointerConfig: false
  // xkb layout/options/model + key-repeat delay & rate.
  readonly property bool xkbRepeat: false
  // Window-manager policy mutation (focus, placement, snapping, decorations).
  readonly property bool wmPolicy: false
  // Output management (resolution, scale, rotation, position, enable/disable).
  // qdwin implements wlr-output-management-v1; unlike the other flags this is
  // LIVE. It is gated on the binding actually advertising the manager global
  // (not merely compiled in): Qdwin.qml calls setOutputManagement() once
  // QdwinBinding.outputManagementAvailable goes true (and back to false on a
  // disconnect). Writable (not readonly / not a binding on Qdwin) to keep the
  // import direction Qdwin → CapabilityService, avoiding a singleton import
  // cycle (CapabilityService imports only Commons).
  property bool outputManagement: false
  function setOutputManagement(available) {
    if (outputManagement !== available) {
      outputManagement = available;
      Logger.i("CapabilityService", "outputManagement -> " + available);
    }
  }
  // Workspace creation/switching/mutation.
  readonly property bool workspaceMutation: false
  // Idle timeout + display DPMS control.
  readonly property bool idleDpms: false
  // Global keyboard-shortcut (keybind) registration.
  readonly property bool keybindRegistration: false

  // ─── Shared messaging ────────────────────────────────────────────
  // Generic note for a control whose backend cannot apply yet. Pages with a
  // more specific string (e.g. mentioning the X server fallback) keep theirs.
  readonly property string persistOnlyNote: I18n.tr("capabilities.persist-only-note")

  function init() {
    Logger.i("CapabilityService", "qdwin live-apply capabilities: "
             + "pointer=" + pointerConfig + " xkb=" + xkbRepeat
             + " wm=" + wmPolicy + " output=" + outputManagement
             + " workspace=" + workspaceMutation + " idleDpms=" + idleDpms
             + " keybind=" + keybindRegistration);
  }
}
