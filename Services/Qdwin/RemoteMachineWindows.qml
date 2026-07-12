pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Qdwin
import "RemoteMachine.js" as RM

// RemoteMachineWindows — the viewer-side shell authority for multi-machine
// remote (RDP-backed) managed windows. Phase-2 rung-1 FOLD; codex impl-34
// (Q1 mirror / Q3 close / Q5 chrome) + impl-30 (Q5 chrome / Q6 attribution).
// Sibling of Tier4Apps.qml (tier-4 = whole-VM-as-a-window): both render a
// remote/VM surface as a single chromed, secctx-identified managed window.
//
// Remote windows arrive on the VIEWER compositor as ordinary xdg_toplevels from
// a windowed FreeRDP client that qdistro-mm-rdp-client-wrapper launched under
// qdistro-secctx-exec, planting wp_security_context_v1:
//   engine      = qdistro.mm
//   app_id      = qdistro.mm.<origin_machine_id>.<stream_id>
//   instance_id = <origin>-<stream>-<nonce>
//
// The durable remote_managed_toplevel REGISTRY lives in the in-VM
// qdistro-mm-broker (org.qdistro.MultiMachine1), NOT here (impl-34 Q1): the
// upstream control plane crosses the VM-A trust boundary. This service MIRRORS
// the broker for presentation/policy and owns the SHELL-side authority:
//   1. Filter Qdwin.windows for the qdistro.mm.* secctx subset (identity from
//      secctx app_id, NEVER window title — impl-30 Q6) → remoteWindows.
//   2. A neutral border until the broker vouches the paired origin; then a
//      per-(trust-domain, origin) colour via Qdwin.setBorderColor — compositor-owned,
//      non-spoofable trust chrome. qdwin stores it per-toplevel so an SSD
//      re-attach doesn't drop it.
//   3. Bind each handle to its stream in the broker (BindHandleIdentity) so the
//      broker's handle↔stream map matches what the viewer compositor mapped and
//      the shell receives only broker-vouched presentation identity.
//   4. SOURCE-MEDIATED close (impl-34 Q3): when Qdwin.closeWindow sees a
//      qdistro.mm.* handle it does NOT call request_close (that would xdg-close
//      FreeRDP = the forbidden client-tree kill — and qdwin itself now refuses it
//      as a compositor backstop); it emits Qdwin.remoteCloseRequested(handle),
//      which we route to the broker's RequestClose. The window stays visible with
//      a dimmed "close-pending" border until the source emits Closed and the
//      broker tears down the backend.
//
// Test contract: tests/test_remote_machine.js exercises the pure logic in
// RemoteMachine.js (imported here as RM). Bind is serialized and response-checked;
// close stays fire-and-forget because source Closed is authoritative.
Singleton {
    id: root

    Component.onCompleted: {
        Logger.i("RemoteMachineWindows", "service started");
        // Pick up toplevels that mapped before this singleton instantiated —
        // shell.qml forces instantiation at startup, but that can land after
        // Qdwin.shellBound already fired.
        rebuild(true);
    }

    readonly property string mmEngine: "qdistro.mm"
    readonly property string brokerBus: "org.qdistro.MultiMachine1"
    readonly property string brokerPath: "/org/qdistro/MultiMachine1"
    readonly property string brokerIface: "org.qdistro.MultiMachine1"

    // The viewer-side mirror of the broker's remote_managed_toplevel records.
    property ListModel remoteWindows: ListModel {}
    // Only broker-confirmed handles enter these maps. Merely observing a
    // qdistro.mm.* secctx string earns neutral chrome and no close authority.
    property var _originByHandle: ({})
    property var _trustDomainByHandle: ({})
    property var _allowInputByHandle: ({})
    property var _secctxByHandle: ({})
    property var _bindAttemptByHandle: ({})
    property var _bindQueue: []
    property var _bindCurrent: null

    signal remoteWindowAdded(int handle, string origin, string streamId, string colour)
    signal remoteWindowRemoved(int handle, string origin)

    function isRemote(secctxAppId) {
        return RM.isRemoteMachine(secctxAppId);
    }

    // ---- chrome paint ---------------------------------------------------
    function _paintBorder(handle, origin, trustDomainId, pending) {
        const bright = RM.colourForTrustedOrigin(origin, trustDomainId);
        const hex = pending ? RM.dim(bright, 0.5) : bright;
        const rgba = RM.hexToRgba(hex);
        if (rgba !== 0 && Qdwin && Qdwin.setBorderColor)
            Qdwin.setBorderColor(handle, rgba);
    }

    // ---- broker mirror (serialized authenticated bind; R2 authority) ------
    function _brokerBindHandle(origin, secctxAppId, handle) {
        // org.qdistro.MultiMachine1.BindHandleIdentity(origin, stream, generation,
        // secctx_app_id, handle). The broker validates any NON-empty redundant
        // field against the peer it resolves from secctx_app_id — and its
        // peer.stream_id is the SOURCE-MINTED id, a separate namespace from the
        // <stream_label> segment of the app_id (which is all qdshell knows).
        // Passing the label there would be rejected whenever it differs from the
        // minted id, black-holing close (codex mm-merge review HIGH-2), so
        // stream and generation are sent empty (skip-check); origin IS
        // validated. The broker is the registry authority; this is the viewer's
        // confirmation of what it mapped, used only for the handle↔stream map.
        root._bindQueue = root._bindQueue.concat([{
            origin: origin, secctxAppId: secctxAppId, handle: handle
        }]);
        root._bindAttemptByHandle[handle] = secctxAppId;
        root._startNextBind();
    }

    function _startNextBind() {
        if (_bindProc.running || root._bindCurrent !== null
                || root._bindQueue.length === 0)
            return;
        const queue = root._bindQueue.slice();
        root._bindCurrent = queue.shift();
        root._bindQueue = queue;
        const req = root._bindCurrent;
        _bindProc.command = [
            "/usr/bin/busctl", "--user", "--no-pager", "--json=short", "call",
            root.brokerBus, root.brokerPath, root.brokerIface,
            "BindHandleIdentity", "sssst",
            req.origin, "", "", req.secctxAppId, String(req.handle)
        ];
        _bindProc.running = true;
    }

    function _acceptBoundIdentity(req, identity) {
        if (!identity || identity.handle !== req.handle
                || identity.origin !== req.origin)
            return false;
        for (let i = 0; i < root.remoteWindows.count; i++) {
            const row = root.remoteWindows.get(i);
            if (row.handle !== req.handle || row.secctxAppId !== req.secctxAppId)
                continue;
            root.remoteWindows.setProperty(i, "authorized", true);
            root.remoteWindows.setProperty(i, "trustDomainId",
                                           identity.trust_domain_id);
            root.remoteWindows.setProperty(i, "allowInput", identity.allow_input);
            root.remoteWindows.setProperty(i, "colour",
                RM.colourForTrustedOrigin(identity.origin,
                                          identity.trust_domain_id));
            root._originByHandle[req.handle] = identity.origin;
            root._trustDomainByHandle[req.handle] = identity.trust_domain_id;
            root._allowInputByHandle[req.handle] = identity.allow_input;
            root._secctxByHandle[req.handle] = req.secctxAppId;
            root._paintBorder(req.handle, identity.origin,
                              identity.trust_domain_id, false);
            Logger.i("RemoteMachineWindows",
                "[mm] broker-vouched origin=" + identity.origin
                + " trust_domain=" + identity.trust_domain_id
                + " generation=" + identity.generation
                + " allow_input=" + identity.allow_input
                + " handle=" + identity.handle);
            root.remoteWindowAdded(req.handle, identity.origin,
                                   identity.stream_id,
                                   RM.colourForTrustedOrigin(
                                       identity.origin,
                                       identity.trust_domain_id));
            return true;
        }
        return false;
    }

    function _brokerRequestClose(handle) {
        // org.qdistro.MultiMachine1.RequestClose(handle): the broker sends
        // CloseRequest upstream and tears the backend down only after source
        // Closed. Fire-and-forget — the user-visible teardown is driven by the
        // source Closed, not this call's reply (same shape as Tier4VM close).
        Quickshell.execDetached([
            "/usr/bin/busctl", "--user", "--no-pager", "call",
            root.brokerBus, root.brokerPath, root.brokerIface,
            "RequestClose", "t", String(handle)
        ]);
    }

    // ---- rebuild from Qdwin.windows ------------------------------------
    function rebuild(repaintAll) {
        const wm = Qdwin.windows;
        if (!wm) return;
        const fresh = [];
        const seen = new Set();
        for (let i = 0; i < wm.count; i++) {
            const w = wm.get(i);
            const origin = RM.originFromSecctx(w.secctxAppId);
            const streamId = RM.streamFromSecctx(w.secctxAppId);
            if (!origin || !streamId) continue;   // fail closed — unattributable
            const authorized = root._originByHandle[w.handle] !== undefined
                && root._secctxByHandle[w.handle] === w.secctxAppId;
            fresh.push({
                handle: w.handle, ownerUid: w.ownerUid, appId: w.appId,
                title: w.title, secctxAppId: w.secctxAppId,
                instanceId: w.instanceId, origin: origin, streamId: streamId,
                authorized: authorized,
                trustDomainId: authorized
                    ? (root._trustDomainByHandle[w.handle] || "") : "",
                allowInput: authorized
                    ? (root._allowInputByHandle[w.handle] || 0) : 0,
                colour: authorized
                    ? RM.colourForTrustedOrigin(
                        origin, root._trustDomainByHandle[w.handle] || "")
                    : RM.UNVERIFIED_COLOUR
            });
            seen.add(w.handle);
        }
        const prev = new Set();
        for (let i = 0; i < root.remoteWindows.count; i++)
            prev.add(root.remoteWindows.get(i).handle);

        root.remoteWindows.clear();
        for (const row of fresh) {
            root.remoteWindows.append(row);
            const isNew = !prev.has(row.handle);
            const needsBind = !row.authorized
                && root._bindAttemptByHandle[row.handle] !== row.secctxAppId;
            if (isNew || needsBind) {
                if (isNew) {
                    Logger.i("RemoteMachineWindows",
                        "[mm] toplevel observed origin=" + row.origin
                        + " stream=" + row.streamId + " secctx=" + row.secctxAppId
                        + " handle=" + row.handle);
                }
                // Neutral chrome until the broker joins this secctx observation
                // to a paired origin grant and source-minted stream record.
                root._paintBorder(row.handle, "", "", false);
                if (needsBind)
                    root._brokerBindHandle(row.origin, row.secctxAppId,
                                           row.handle);
            }
            if (!isNew && repaintAll)
                root._paintBorder(row.handle, row.authorized ? row.origin : "",
                                  row.trustDomainId, false);
        }
        for (const h of prev)
            if (!seen.has(h)) {
                root.remoteWindowRemoved(h, root._originByHandle[h] || "");
                delete root._originByHandle[h];
                delete root._trustDomainByHandle[h];
                delete root._allowInputByHandle[h];
                delete root._secctxByHandle[h];
                delete root._bindAttemptByHandle[h];
            }
    }

    // ---- wire-up --------------------------------------------------------
    Connections {
        target: Qdwin
        function onWindowListChanged() { root.rebuild(false); }
        function onWindowSecctxResolved(handle, engine, appId, instanceId) {
            if (root.isRemote(appId) || root._originByHandle[handle])
                root.rebuild(false);
        }
        function onShellBound() { root.rebuild(true); }
        // SOURCE-mediated close (impl-34 Q3): Qdwin.closeWindow emits this for
        // qdistro.mm.* handles INSTEAD of request_close. Route it upstream via the
        // broker and dim the border to "close-pending" — the window stays visible
        // until the source Closed drives teardown.
        function onRemoteCloseRequested(handle) {
            const origin = root._originByHandle[handle];
            if (origin === undefined) return;
            Logger.i("RemoteMachineWindows",
                "[mm] close-requested handle=" + handle + " origin=" + origin
                + " -> broker RequestClose (source-mediated)");
            root._paintBorder(handle, origin,
                              root._trustDomainByHandle[handle] || "", true);
            root._brokerRequestClose(handle);
        }
    }

    Process {
        id: _bindProc
        running: false
        stdout: StdioCollector { id: _bindStdout }
        stderr: StdioCollector { id: _bindStderr }
        onExited: (exitCode, exitStatus) => {
            const req = root._bindCurrent;
            const identity = exitCode === 0
                ? RM.parseBindIdentity(String(_bindStdout.text || "")) : null;
            if (!req || !root._acceptBoundIdentity(req, identity)) {
                Logger.w("RemoteMachineWindows",
                    "[mm] broker bind denied/unparseable; leaving neutral chrome"
                    + " handle=" + (req ? req.handle : 0)
                    + " exit=" + exitCode
                    + " stderr=" + String(_bindStderr.text || "").trim());
            }
            root._bindCurrent = null;
            root._startNextBind();
        }
    }
}
