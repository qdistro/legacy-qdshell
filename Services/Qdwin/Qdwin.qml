pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Qdistro.Qdwin 1.0
import qs.Commons
import qs.Services.Control
import qs.Services.Qdshell
import qs.Services.UI
import "../Qdshell/BrokerGate.js" as BrokerGate
import "../Qdshell/ClipboardSilo.js" as ClipboardSilo

/// qdshell Qdwin — qdwin-only.
///
/// In upstream Noctalia this service detects the host compositor
/// (Hyprland / Niri / Sway / Mango / Labwc) at startup and loads a
/// matching backend adapter to provide workspace + window data via
/// per-compositor IPC. qdshell drops the adapters because we run on
/// exactly one compositor (qdwin via libweston). The foreign-compositor
/// identity flags are gone too — `isQdwin` is the only backend identity.
///
/// The QML interface (workspaces ListModel, focus helpers, session
/// controls, spawn) is preserved so the consumer .qml files compile
/// unchanged. As of 2026-05-14 the `windows`
/// ListModel + focus driving are populated via `Qdistro.Qdwin`
/// (libqdistro-qdwin.so QML plugin) which binds qdwin_shell_v1 at v14
/// and exposes toplevel events + imperative requests to QML. Workspace
/// data stays empty (qdwin doesn't expose workspaces yet). Session
/// controls (lock/suspend/etc.) still shell out to `loginctl`/
/// `systemctl` — those don't need compositor IPC.
Singleton {
    id: root

    // qdwin is the only supported compositor; this is the sole backend
    // identity flag. (Kept readonly to make accidental writes fail loudly.)
    readonly property bool isQdwin: true

    // Workspace state — qdwin has no workspace concept yet, so we
    // populate from the user's settings (workspaces.count / .names)
    // to give the bar widget something to display.
    property ListModel workspaces: ListModel {}
    property int _settingsWorkspaceCount: Settings.isLoaded ? Settings.data.workspaces.count : 4
    property var _settingsWorkspaceNames: Settings.isLoaded ? Settings.data.workspaces.names : []

    on_SettingsWorkspaceCountChanged: _rebuildSettingsWorkspaces()
    on_SettingsWorkspaceNamesChanged: _rebuildSettingsWorkspaces()

    function _rebuildSettingsWorkspaces() {
        if (!Settings.isLoaded) return;
        var count = Math.max(1, Math.min(_settingsWorkspaceCount, 32));
        var names = _settingsWorkspaceNames || [];
        workspaces.clear();
        for (var i = 0; i < count; i++) {
            var label = (i < names.length && names[i] !== "") ? names[i] : String(i + 1);
            workspaces.append({
                id: i,
                idx: i + 1,
                name: label,
                output: "",
                isFocused: i === 0,
                isActive: i === 0,
                isUrgent: false,
                isOccupied: false,
            });
        }
        root.workspaceChanged();
    }

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
    // P05a Phase A: per-toplevel chrome colour. Tier4Apps / Tier3Apps
    // call this after resolving a toplevel's silo so qdwin stores the
    // rgba per-handle (qdwin_toplevel_border_rgba in qdwin.c). Pre-P05a
    // the rgba arg was logged + dropped on the qdwin side; now the SSD
    // paint helper reads it back via the per-toplevel state. Returns
    // nothing — fire-and-forget. Logs on no-binding so a race during
    // shell startup leaves a journal trace.
    function setBorderColor(handle, rgba) {
        if (!qdwinBinding) {
            Logger.w("Qdwin", "setBorderColor handle=" + handle
                              + " rgba=" + rgba + " — no binding");
            return;
        }
        qdwinBinding.setBorderColor(handle, rgba >>> 0);
    }

    function _windowByHandle(handle) {
        for (let i = 0; i < root.windows.count; i++) {
            const row = root.windows.get(i);
            if (row.handle === handle)
                return row;
        }
        return null;
    }

    function _siloForWindow(row) {
        if (!row)
            return "unknown";
        const secctxSilo = ClipboardSilo.fromSecctx(
            row.sandboxEngine || "",
            row.secctxAppId || "",
            row.instanceId || "");
        if (secctxSilo.length > 0)
            return secctxSilo;
        if (typeof row.ownerUid === "number")
            return "uid:" + row.ownerUid;
        return "unknown";
    }

    function _verifyWindowIdentity(row) {
        if (!row || !qdwinBinding || qdwinBinding.verifyClientIdentity === undefined)
            return false;
        if (!row.peerPid || row.peerPid <= 0)
            return false;
        return qdwinBinding.verifyClientIdentity(
            row.peerPid >>> 0,
            row.peerStarttime || 0,
            row.peerUid >>> 0,
            row.peerExe || "",
            row.peerSelinuxLabel || "",
            row.sandboxEngine || "",
            row.secctxAppId || "",
            row.instanceId || "");
    }

    function _verifyActivationIdentity(sourceRow, targetRow, sourceSilo, targetSilo) {
        if (sourceSilo === targetSilo && sourceSilo.indexOf("uid:") === 0
                && sourceRow && targetRow
                && sourceRow.ownerUid === targetRow.ownerUid)
            return true;
        return root._verifyWindowIdentity(sourceRow)
            && root._verifyWindowIdentity(targetRow);
    }

    function _decideNestedProxy(handle, appId, originUid) {
        const action = BrokerGate.nestedProxyAction(appId);
        let decision = { verdict: "deny", reason: "broker-unavailable" };
        if (qdwinBinding && qdwinBinding.checkPermission !== undefined) {
            const result = qdwinBinding.checkPermission(
                action, BrokerGate.nestedProxyDetails(appId, originUid));
            decision = BrokerGate.parseStringVerdict(
                result.exitCode, result.stdout || "", "broker-unavailable");
        }
        Logger.i("Qdwin", "NESTED_PROXY_GATE",
                 "handle=" + handle,
                 "app_id=" + (appId || ""),
                 "origin_uid=" + originUid,
                 "verdict=" + decision.verdict,
                 "reason=" + decision.reason);
        qdwinBinding.nestedProxyDecision(
            handle, BrokerGate.qdwinDecision(decision.verdict),
            decision.reason);
    }

    function _decideActivation(handle, sourceHandle, targetHandle, sourceAppId) {
        const sourceRow = sourceHandle !== 4294967295
            ? root._windowByHandle(sourceHandle) : null;
        const targetRow = root._windowByHandle(targetHandle);
        const sourceSilo = root._siloForWindow(sourceRow);
        const targetSilo = root._siloForWindow(targetRow);
        let decision = { verdict: "deny", reason: "unknown-identity" };

        if (BrokerGate.knownSilo(sourceSilo) && BrokerGate.knownSilo(targetSilo)
                && qdwinBinding
                && qdwinBinding.checkHandoffActivation !== undefined) {
            const srcApp = sourceAppId || (sourceRow ? (sourceRow.secctxAppId || sourceRow.appId || "") : "");
            const dstApp = targetRow ? (targetRow.secctxAppId || targetRow.appId || "") : "";
            const srcEngine = sourceRow ? (sourceRow.sandboxEngine || "") : "";
            const identityVerified = root._verifyActivationIdentity(
                sourceRow, targetRow, sourceSilo, targetSilo);
            // Relay the source app's authenticated (pid, starttime) so the
            // broker attests the source silo via its launch-record store
            // (P1-1). 0/0 when the source row has no peer identity → broker
            // enforce denies cross-silo rather than trusting the claim.
            const result = qdwinBinding.checkHandoffActivation(
                sourceSilo, targetSilo, srcApp, dstApp, srcEngine,
                identityVerified,
                sourceRow ? (sourceRow.peerPid >>> 0) : 0,
                sourceRow ? (sourceRow.peerStarttime || 0) : 0);
            decision = BrokerGate.parseStringVerdict(
                result.exitCode, result.stdout || "", "broker-unavailable");
        }

        Logger.i("Qdwin", "ACTIVATION_GATE",
                 "handle=" + handle,
                 "src_handle=" + sourceHandle,
                 "target_handle=" + targetHandle,
                 "src_silo=" + sourceSilo,
                 "dst_silo=" + targetSilo,
                 "src_app=" + (sourceAppId || ""),
                 "verdict=" + decision.verdict,
                 "reason=" + decision.reason);
        qdwinBinding.activationDecision(
            handle, BrokerGate.qdwinDecision(decision.verdict),
            decision.reason);
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
                // P05a: a tier-4 toplevel that appeared *before* the
                // binding landed had its setBorderColor() call dropped
                // (no binding → logged + returned), so it sits with
                // neutral chrome. Now that we are bound, notify peers so
                // Tier4Apps can replay the per-toplevel border paint for
                // any pre-bind windows. Fires only on the false→true
                // transition (QdwinBinding.bound flips false→true once
                // per bind), so no replay spam.
                root.shellBound();
            } else if (lastError.length > 0) {
                Logger.w("Qdwin", "qdwin_shell_v1 unbound: " + lastError);
            }
        }
        onLastErrorChanged: {
            if (lastError.length > 0)
                Logger.w("Qdwin", "binding error: " + lastError);
        }
        onLauncherRequested: {
            const screen = PanelService.findScreenForPanels();
            if (screen)
                PanelService.toggleLauncher(screen);
            else
                Logger.w("Qdwin", "launcher_requested with no available screen");
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
                peerPid: 0,
                peerStarttime: 0,
                peerUid: 0,
                peerExe: "",
                peerSelinuxLabel: "",
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
        onToplevelPeerIdentity: (handle, peerPid, peerStarttime, peerUid, peerExe, peerSelinuxLabel) => {
            for (let i = 0; i < root.windows.count; i++) {
                if (root.windows.get(i).handle === handle) {
                    root.windows.setProperty(i, "peerPid", peerPid >>> 0);
                    root.windows.setProperty(i, "peerStarttime", peerStarttime);
                    root.windows.setProperty(i, "peerUid", peerUid >>> 0);
                    root.windows.setProperty(i, "peerExe", peerExe || "");
                    root.windows.setProperty(i, "peerSelinuxLabel", peerSelinuxLabel || "");
                    return;
                }
            }
        }
        onNestedProxyPending: (handle, appId, originUid) => {
            root._decideNestedProxy(handle, appId, originUid);
        }
        onActivationPending: (handle, sourceHandle, targetHandle, sourceAppId) => {
            root._decideActivation(handle, sourceHandle, targetHandle, sourceAppId);
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
    // Fires when qdwin_shell_v1 transitions to bound (false→true). Tier
    // chrome services (Tier4Apps) listen here to replay per-toplevel
    // border paint for windows that appeared before the binding landed
    // — their setBorderColor() calls were dropped while unbound.
    signal shellBound

    Component.onCompleted: {
        Qt.callLater(() => {
            if (typeof ShellState !== 'undefined' && ShellState.isLoaded) {
                loadDisplayScalesFromState();
            }
            // Populate workspaces from settings on startup
            if (Settings.isLoaded) {
                _rebuildSettingsWorkspaces();
            }
        });
    }

    Connections {
        target: Settings
        function onSettingsLoaded() {
            root._rebuildSettingsWorkspaces();
        }
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
            if (ws.isActive) result.push(ws);
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
        // P05a: if this is a tier-4 VM toplevel, route the close button
        // through the per-VM Tier4VM.Control.Close() RPC FIRST so the
        // ACPI→destroy lifecycle (with virsh timeout + orphan reap) runs
        // before xdg_toplevel.close goes to virt-viewer. The RPC handler
        // tears down virt-viewer and the libvirt domain; we still call
        // xdg_toplevel.close afterward as a belt-and-braces so the
        // window disappears even when the control process is missing
        // (degraded image without dbus-python).
        if (typeof window === "object" && window !== null
                && typeof window.secctxAppId === "string"
                && window.secctxAppId.startsWith("qdistro.tier4.")
                && typeof window.ownerUid === "number") {
            const vm = window.secctxAppId.slice("qdistro.tier4.".length);
            if (vm.length > 0) {
                _dispatchTier4Close(vm, window.ownerUid);
            }
        } else if (h >= 0) {
            // Lookup the row from windows by handle so a bare-handle
            // caller (Taskbar / Workspace pass numeric handles) also
            // benefits from the tier-4 close hook.
            for (let i = 0; i < root.windows.count; i++) {
                const w = root.windows.get(i);
                if (w.handle === h
                        && typeof w.secctxAppId === "string"
                        && w.secctxAppId.startsWith("qdistro.tier4.")) {
                    const vm2 = w.secctxAppId.slice("qdistro.tier4.".length);
                    if (vm2.length > 0) _dispatchTier4Close(vm2, w.ownerUid);
                    break;
                }
            }
        }
        qdwinBinding.closeWindow(h);
    }

    // Fire-and-forget Close() RPC on org.qdistro.Tier4VM.Control.uid<N>.
    // The control process owns this name (see qdistro/tier4-vm/
    // tier4_control.py); the same-uid bus + same-uid attestation in the
    // handler defends against cross-uid abuse. We use busctl rather
    // than DBusBinding because the result is a fire-and-forget side
    // effect — the user-visible close is achieved by virt-viewer's
    // exit, the RPC just guarantees the qemu domain doesn't survive.
    function _dispatchTier4Close(vmName, ownerUid) {
        if (!vmName || typeof ownerUid !== "number" || ownerUid < 0) return;
        const busName = "org.qdistro.Tier4VM.Control.uid" + ownerUid;
        Logger.i("Qdwin", "tier4 close vm=" + vmName
                          + " uid=" + ownerUid + " bus=" + busName);
        // The RPC takes no args, returns (bsui). Discard the reply —
        // even denial / failure should fall through to xdg_toplevel.close
        // so the user gets a window dismissal regardless.
        Quickshell.execDetached([
            "busctl", "--user", "--no-pager",
            "call", busName, "/org/qdistro/Tier4VM",
            "org.qdistro.Tier4VM.Control", "Close"
        ]);
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
