pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Control
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
/// .qml files compile unchanged. Workspace / window data stays empty
/// for now — qdwin will wire real data via qdwin_shell_v1 when
/// Phase 5+ adds the binding. Session controls (lock/suspend/etc.)
/// shell out to `loginctl` / `systemctl` directly, no compositor IPC.
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

    // Workspace + window state (empty until qdwin_shell_v1 wiring).
    property ListModel workspaces: ListModel {}
    property ListModel windows: ListModel {}
    property int focusedWindowIndex: -1
    readonly property bool overviewActive: false
    readonly property bool globalWorkspaces: true

    // Display scales: persisted via ShellState. qdwin will publish
    // updates over qdwin_shell_v1.output_*; until then we just load
    // whatever the user persisted last.
    property var displayScales: ({})
    property bool displayScalesLoaded: false

    property var backend: null  // never assigned; consumers default-check

    signal workspaceChanged
    signal activeWindowChanged
    signal windowListChanged

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

    // -- workspace + window actions (no-op until qdwin wiring) -- //

    function switchToWorkspace(workspace) { /* qdwin: TODO */ }
    function focusWindow(window)         { /* qdwin: TODO */ }
    function closeWindow(window)         { /* qdwin: TODO */ }
    function cycleKeyboardLayout()       { /* qdwin: TODO */ }

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
