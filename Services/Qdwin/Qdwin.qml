pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Qdistro.Qdwin 1.0
import qs.Commons
import qs.Services.Control
import qs.Services.Qdshell
import qs.Services.UI

/// qdshell Qdwin — qdwin-only.
///
/// In upstream Noctalia this service detects the host compositor
/// (Hyprland / Niri / Sway / Mango / Labwc) at startup and loads a
/// matching backend adapter to provide workspace + window data via
/// per-compositor IPC. qdshell drops the adapters because we run on
/// exactly one compositor (qdwin via libweston).
///
/// The QML interface (workspaces ListModel, isHyprland flag, focus
/// helpers, session controls, spawn) is preserved so the ~50 consumer
/// .qml files compile unchanged. As of 2026-05-14 the `windows`
/// ListModel + focus driving are populated via `Qdistro.Qdwin`
/// (libqdistro-qdwin.so QML plugin) which binds qdwin_shell_v1 at v14
/// and exposes toplevel events + imperative requests to QML. Workspace
/// data stays empty (qdwin doesn't expose workspaces yet). Session
/// controls (lock/suspend/etc.) still shell out to `loginctl`/
/// `systemctl` — those don't need compositor IPC.
Singleton {
    id: root

    // Compositor detection — we are always qdwin, so all flags false.
    // (Kept readonly to make accidental writes fail loudly.)
    readonly property bool isHyprland: false
    readonly property bool isNiri: false
    readonly property bool isSway: false
    readonly property bool isMango: false
    readonly property bool isLabwc: false
    readonly property bool isScroll: false
    readonly property bool isQdwin: true

    // Workspace state stays empty — qdwin has no workspace concept yet.
    property ListModel workspaces: ListModel {}
    // Window state is populated from qdwin_shell_v1 events via the
    // Qdistro.Qdwin plugin (see QdwinBinding below).
    //
    // Each row carries: handle, ownerUid, appId, title, isXwayland,
    // workspaceId, sandboxEngine, secctxAppId, instanceId.
    // The latter three default to "" and are filled in when the
    // wp_security_context_v1 tag arrives (toplevel_security_context
    // event fires after toplevel_added). PodApps / VMApps services
    // use secctxAppId + instanceId for placeholder correlation.
    property ListModel windows: ListModel {}
    property int focusedWindowIndex: -1
    readonly property bool overviewActive: false
    readonly property bool globalWorkspaces: true

    // Alt+Tab switcher state. Once we bind qdwin_shell_v1 at v14+,
    // qdwin stops driving alt+tab focus itself — it emits
    // `switcher_next(dir)` to the bound shell on each Tab press while
    // Alt is held, then `switcher_commit` on Alt release. The shell
    // is expected to walk a candidate list and call set_keyboard_focus
    // on the commit. We keep a tiny ring-buffer position; nothing
    // fancier than wrap-around is required for parity with the v0
    // qdwin-internal switcher.
    property int _switcherIndex: -1

    // qdwin_shell_v1 binding. Constructed eagerly so the v14 bind
    // happens at qdshell startup — needed for the qdwin focus-emit /
    // keybinding branches to fire (their fallback "unbound" log path
    // runs while no shell is bound). The binding takes no QML
    // properties; we drive it via signal handlers + Q_INVOKABLE
    // methods.
    // External-facing wrappers for the native binding's Q_INVOKABLE
    // methods. Exposed so peer singletons (e.g. Tier3FocusIPC) and
    // IPC handlers can drive qdwin without needing direct access to
    // the internal qdwinBinding id.
    function injectFocus(handle, seat) {
        if (!qdwinBinding) return;
        qdwinBinding.focusWindow(handle, seat || "default");
        Logger.i("Qdwin", "ipc injectFocus handle=" + handle
                 + " seat=" + (seat || "default"));
    }
    function clearSeatSelection(seat, isPrimary) {
        if (!qdwinBinding) return;
        qdwinBinding.clearSelection(seat || "default", isPrimary ? 1 : 0);
        Logger.i("Qdwin", "ipc clearSelection seat=" + (seat || "default")
                 + " primary=" + (isPrimary ? 1 : 0));
    }

    QdwinBinding {
        id: qdwinBinding

        onBoundChanged: {
            if (bound) {
                Logger.i("Qdwin", "qdwin_shell_v1 bound v" + shellVersion);
                // spec/10 Phase-1 — wire the clipboard gate now that
                // we have a live binding. ClipboardGate.init is
                // idempotent so re-binds after a teardown are safe.
                ClipboardGate.init(qdwinBinding);
            } else if (lastError.length > 0) {
                Logger.w("Qdwin", "qdwin_shell_v1 unbound: " + lastError);
            }
        }
        onLastErrorChanged: {
            if (lastError.length > 0)
                Logger.w("Qdwin", "binding error: " + lastError);
        }

        onToplevelAdded: (handle, ownerUid, appId, title, isXwayland) => {
            root.windows.append({
                handle: handle,
                ownerUid: ownerUid,
                appId: appId || "",
                title: title || "",
                isXwayland: isXwayland,
                workspaceId: 0,
                sandboxEngine: "",
                secctxAppId: "",
                instanceId: "",
            });
            root.windowListChanged();
        }
        onToplevelSecurityContext: (handle, sandboxEngine, secctxAppId, instanceId) => {
            // Receive-side log line. Mirrors qdwin's send-side line at
            // qdwin/qdwin.c:814 ("qdwin: toplevel_security_context …")
            // so the wire path is greppable from both ends — the
            // load-bearing assertion in
            // tests/integration/vm/s41-secctx-toplevel-event.sh.
            Logger.i("Qdwin", "toplevel_security_context handle=" + handle
                + " engine=" + (sandboxEngine || "")
                + " app_id=" + (secctxAppId || "")
                + " instance=" + (instanceId || ""));
            for (let i = 0; i < root.windows.count; i++) {
                if (root.windows.get(i).handle === handle) {
                    root.windows.setProperty(i, "sandboxEngine", sandboxEngine || "");
                    root.windows.setProperty(i, "secctxAppId",   secctxAppId   || "");
                    root.windows.setProperty(i, "instanceId",    instanceId    || "");
                    root.windowSecctxResolved(handle, sandboxEngine || "",
                                              secctxAppId || "", instanceId || "");
                    return;
                }
            }
        }
        onNestedProxyPixelSource: (handle, pwNode, inputSink) => {
            // qdwin is asking for a pixel-consumer process. Spawn
            // qdistro-nested-pixelfeed; it connects back to the outer
            // wayland, creates a wl_surface, and calls bind_proxy_pixels.
            // Until it does, the proxy view stays on the placeholder
            // curtain (see qdwin-shell-v1.xml nested_proxy_pixel_source).
            // The consumer process self-detaches; we don't track it.
            if (!pwNode || pwNode.length === 0) {
                Logger.w("Qdwin", "nested_proxy_pixel_source: empty pw_node for handle " + handle);
                return;
            }
            const argv = ["qdistro-nested-pixelfeed", String(handle), pwNode];
            if (inputSink && inputSink.length > 0) argv.push(inputSink);
            Logger.i("Qdwin", "spawning pixelfeed for handle " + handle
                              + " pw_node=" + pwNode);
            Quickshell.execDetached(argv);
        }
        onToplevelRemoved: (handle) => {
            for (let i = 0; i < root.windows.count; i++) {
                if (root.windows.get(i).handle === handle) {
                    root.windows.remove(i);
                    if (root.focusedWindowIndex === i) {
                        root.focusedWindowIndex = -1;
                        root.activeWindowChanged();
                    } else if (root.focusedWindowIndex > i) {
                        root.focusedWindowIndex -= 1;
                    }
                    root.windowListChanged();
                    return;
                }
            }
        }
        onToplevelTitle: (handle, title) => {
            for (let i = 0; i < root.windows.count; i++) {
                if (root.windows.get(i).handle === handle) {
                    root.windows.setProperty(i, "title", title || "");
                    if (i === root.focusedWindowIndex)
                        root.activeWindowChanged();
                    return;
                }
            }
        }
        onSeatFocusChanged: (seat, handle) => {
            // Match on handle; UINT32_MAX (=4294967295) means "no focus".
            let next = -1;
            if (handle !== 4294967295) {
                for (let i = 0; i < root.windows.count; i++) {
                    if (root.windows.get(i).handle === handle) { next = i; break; }
                }
            }
            if (next !== root.focusedWindowIndex) {
                root.focusedWindowIndex = next;
                root.activeWindowChanged();
            }
        }

        onSwitcherNext: (dir) => {
            if (root.windows.count === 0) return;
            if (root._switcherIndex < 0)
                root._switcherIndex = root.focusedWindowIndex;
            const n = root.windows.count;
            root._switcherIndex =
                ((root._switcherIndex + dir) % n + n) % n;
        }
        onSwitcherCommit: () => {
            if (root._switcherIndex >= 0
                && root._switcherIndex < root.windows.count) {
                qdwinBinding.focusWindow(
                    root.windows.get(root._switcherIndex).handle);
            }
            root._switcherIndex = -1;
        }
    }

    // Display scales: persisted via ShellState. qdwin will publish
    // updates over qdwin_shell_v1.output_*; until then we just load
    // whatever the user persisted last.
    property var displayScales: ({})
    property bool displayScalesLoaded: false

    property var backend: null  // never assigned; consumers default-check

    signal workspaceChanged
    signal activeWindowChanged
    signal windowListChanged
    // Fires when wp_security_context_v1 fields arrive for a known
    // toplevel. PodApps / VMApps services listen here to resolve
    // their cold-start placeholders by instanceId match.
    signal windowSecctxResolved(int handle, string sandboxEngine,
                                string secctxAppId, string instanceId)

    Component.onCompleted: {
        Qt.callLater(() => {
            if (typeof ShellState !== 'undefined' && ShellState.isLoaded) {
                loadDisplayScalesFromState();
            }
        });
    }

    Connections {
        target: typeof ShellState !== 'undefined' ? ShellState : null
        function onIsLoadedChanged() {
            if (ShellState.isLoaded)
                loadDisplayScalesFromState();
        }
    }

    function loadDisplayScalesFromState() {
        try {
            const cached = ShellState.getDisplay();
            if (cached && Object.keys(cached).length > 0) {
                displayScales = cached;
            }
            displayScalesLoaded = true;
        } catch (error) {
            Logger.e("Qdwin", "Failed to load display scales:", error);
            displayScalesLoaded = true;
        }
    }

    function getDisplayScale(outputName) {
        return displayScales[outputName] || 1.0;
    }

    // -- workspace + window queries -- //

    function getActiveWorkspaces() {
        const result = [];
        for (let i = 0; i < workspaces.count; i++) {
            const ws = workspaces.get(i);
            if (ws.active) result.push(ws);
        }
        return result;
    }

    function getWindowsForWorkspace(workspaceId) {
        const result = [];
        for (let i = 0; i < windows.count; i++) {
            const w = windows.get(i);
            if (w.workspaceId === workspaceId) result.push(w);
        }
        return result;
    }

    function getFocusedWindow() {
        return focusedWindowIndex >= 0 && focusedWindowIndex < windows.count
            ? windows.get(focusedWindowIndex)
            : null;
    }

    function getFocusedWindowTitle() {
        const w = getFocusedWindow();
        return w ? (w.title || "") : "";
    }

    function getFocusedScreen() {
        // Fall back to first connected screen — qdwin doesn't yet
        // publish "focused output". Consumers that need precise
        // focus should query qdwin_shell_v1 directly.
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }

    // -- workspace + window actions -- //
    // Wired through Qdistro.Qdwin → qdwin_shell_v1. `window` is either
    // a row from the `windows` ListModel (has .handle) or a bare
    // numeric handle; we accept both so callers don't have to wrap.

    function switchToWorkspace(workspace) { /* qdwin: no workspaces yet */ }

    function _handleOf(w) {
        if (w === null || w === undefined) return -1;
        if (typeof w === "number") return w;
        if (typeof w === "object" && "handle" in w) return w.handle;
        return -1;
    }

    function focusWindow(window) {
        const h = _handleOf(window);
        if (h < 0) return;
        qdwinBinding.focusWindow(h);
    }

    function closeWindow(window) {
        const h = _handleOf(window);
        if (h < 0) return;
        qdwinBinding.closeWindow(h);
    }

    function requestMaximize(window, maximized) {
        const h = _handleOf(window);
        if (h < 0) return;
        qdwinBinding.requestMaximize(h, !!maximized);
    }

    function requestMinimize(window) {
        const h = _handleOf(window);
        if (h < 0) return;
        qdwinBinding.requestMinimize(h);
    }

    function cycleKeyboardLayout() { /* qdwin: not in qdwin_shell_v1 */ }

    // -- spawning + session control (compositor-agnostic) -- //

    function spawn(command) {
        Quickshell.execDetached(["sh", "-lc", command]);
    }

    function lock() {
        Quickshell.execDetached(["loginctl", "lock-session"]);
    }

    function logout() {
        Quickshell.execDetached(["loginctl", "terminate-session", "self"]);
    }

    function suspend() {
        Quickshell.execDetached(["systemctl", "suspend"]);
    }

    function hibernate() {
        Quickshell.execDetached(["systemctl", "hibernate"]);
    }

    function lockAndSuspend() {
        lock();
        Qt.callLater(suspend);
    }

    function reboot() {
        Quickshell.execDetached(["systemctl", "reboot"]);
    }

    function rebootToUefi() {
        Quickshell.execDetached(["systemctl", "reboot", "--firmware-setup"]);
    }

    function shutdown() {
        Quickshell.execDetached(["systemctl", "poweroff"]);
    }
}
