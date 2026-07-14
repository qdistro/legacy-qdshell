pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Qdwin
import "OutputLayout.js" as OutputLayout
import "RemoteDisplayLease.js" as Lease

// Shell-side executor for controller-verified remote-display slot mutations.
// ClaimLayout/AcknowledgeLayout authenticate this process (or its direct
// busctl child) at the controller service. No same-uid command target exists.
Singleton {
    id: root

    readonly property string bus: "org.qdistro.MultiMachineDisplay1"
    readonly property string path: "/org/qdistro/MultiMachineDisplay1"
    readonly property string iface: "org.qdistro.MultiMachineDisplay1"
    property var _pending: null
    property bool _claimBusy: false
    property bool _ackBusy: false

    function _claimCommand() {
        return ["busctl", "--user", "--timeout=2s", "call",
                bus, path, iface, "ClaimLayout"];
    }

    function _ack(result) {
        if (!_pending || _ackBusy) return;
        _ackBusy = true;
        _ackProc.command = [
            "busctl", "--user", "--timeout=2s", "call",
            bus, path, iface, "AcknowledgeLayout", "sts",
            _pending.request_id, String(_pending.generation), result
        ];
        _ackProc.running = true;
    }

    function _apply(request) {
        const live = OutputLayout.layoutFromSnapshots(Qdwin.outputs || []);
        const layout = Lease.buildSlotLayout(live, request);
        if (!layout) {
            Logger.w("RemoteDisplayLease", "invalid/unavailable slot request");
            _pending = request;
            _ack("failed");
            return;
        }
        const modes = {};
        for (let i = 0; i < (Qdwin.outputs || []).length; i++) {
            const output = Qdwin.outputs[i];
            modes[output.name] = output.modes || [];
        }
        const verdict = OutputLayout.validateLayout(layout, modes);
        _pending = request;
        if (!verdict.ok || !Qdwin.applyOutputLayoutTagged(
                layout, Qdwin.outputSerial, request.request_id)) {
            Logger.w("RemoteDisplayLease",
                "slot apply rejected before qdwin: " + verdict.errors.join(","));
            _ack("failed");
        }
    }

    Timer {
        interval: 500
        repeat: true
        running: true
        onTriggered: {
            if (root._claimBusy || root._pending || root._ackBusy) return;
            root._claimBusy = true;
            _claimProc.command = root._claimCommand();
            _claimProc.running = true;
        }
    }

    Process {
        id: _claimProc
        running: false
        stdout: StdioCollector { id: _claimStdout }
        stderr: StdioCollector { id: _claimStderr }
        onExited: (exitCode, exitStatus) => {
            root._claimBusy = false;
            if (exitCode !== 0) return; // service absent while undocked is normal
            const request = Lease.parseBusctlString(_claimStdout.text || "");
            if (request) root._apply(request);
        }
    }

    Process {
        id: _ackProc
        running: false
        stderr: StdioCollector { id: _ackStderr }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                Logger.w("RemoteDisplayLease",
                    "layout acknowledgement failed: "
                    + String(_ackStderr.text || "").trim());
            root._ackBusy = false;
            root._pending = null;
        }
    }

    Connections {
        target: Qdwin
        function onOutputLayoutTaggedResult(tag, ok, cancelled) {
            if (!root._pending || tag !== root._pending.request_id) return;
            root._ack(ok ? "applied" : (cancelled ? "cancelled" : "failed"));
        }
    }
}
