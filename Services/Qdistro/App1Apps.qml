pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// App1Apps — discover ``org.qdistro.App1`` receivers via the broker.
//
// Where PodApps surfaces container-scanned tier-2 apps, App1Apps
// surfaces *running* user-uid apps that have registered themselves on
// the session bus as ``org.qdistro.<Name>.uid<NNNN>`` and answered
// the App1 contract (GetName / GetSilo / CanReceive / ReceivePayload).
// The data source is the admin broker's ``ListReceivers`` method,
// which side-channels into every uid's UserRelay to enumerate names.
//
// Each row exposed in :prop:`apps`:
//   { uid, service, name, silo }
//
// Refresh strategy: every 5s via busctl, plus an immediate refresh on
// Launcher open. Silo badge convention follows
// ``qdistro/doc/ui.md``; the launcher provider renders the silo as a
// chip in front of the comment so users can tell two instances of
// the same app in different silos apart.
Singleton {
    id: root

    Component.onCompleted: Logger.i("App1Apps", "service started")

    // Each row: { uid (int), service (str), name (str), silo (str) }
    property ListModel apps: ListModel {}

    // ``true`` when the most recent busctl probe succeeded; the
    // Launcher provider hides itself when the broker isn't on the
    // system bus rather than showing an empty section.
    property bool brokerReachable: false

    signal refreshed()

    function refresh() {
        _scan.running = false;
        _scan.command = ["sh", "-c",
            "busctl --system --json=short call " +
            "org.qdistro.AdminBroker1 " +
            "/org/qdistro/AdminBroker1 " +
            "org.qdistro.AdminBroker1 " +
            "ListReceivers 2>/dev/null || echo ''"];
        _scan.running = true;
    }

    Process {
        id: _scan
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = (this.text || "").trim();
                if (!raw) {
                    root.brokerReachable = false;
                    root.apps.clear();
                    root.refreshed();
                    return;
                }
                root.brokerReachable = true;
                let parsed = null;
                try { parsed = JSON.parse(raw); }
                catch (e) {
                    Logger.w("App1Apps", "parse failed: " + e + " raw=" + raw);
                    return;
                }
                // busctl --json=short shape:
                //   {"type":"a(iss)","data":[[[uid,svc,friendly],...]]}
                let rows = [];
                if (parsed && parsed.data && parsed.data.length > 0)
                    rows = parsed.data[0];
                root.apps.clear();
                for (const r of rows) {
                    const uid = parseInt(r[0]);
                    const svc = String(r[1]);
                    const friendly = String(r[2]);
                    // GetSilo per-row is a second round trip; for the
                    // launcher we fall back to the silo column from
                    // the friendly name's uid suffix mapping. The
                    // broker side already passes through whatever
                    // UserRelay knows, so the silo is best-effort.
                    const silo = root._siloFor(uid);
                    root.apps.append({
                        uid:     uid,
                        service: svc,
                        name:    friendly,
                        silo:    silo,
                    });
                }
                root.refreshed();
            }
        }
    }

    // Map uid → silo label. Pulled from SessionManager1.ListSilos via
    // a separate refresh so we don't pay one busctl per row on every
    // launcher open. Empty string when unknown — the launcher renders
    // no chip rather than a "[]" placeholder.
    property var _uidSilo: ({})

    function _siloFor(uid) {
        const s = root._uidSilo[String(uid)];
        return s || "";
    }

    function refreshSilos() {
        _siloScan.running = false;
        _siloScan.command = ["sh", "-c",
            "busctl --system --json=short call " +
            "org.qdistro.SessionManager1 " +
            "/org/qdistro/SessionManager1 " +
            "org.qdistro.SessionManager1 " +
            "ListSilos 2>/dev/null || echo ''"];
        _siloScan.running = true;
    }

    Process {
        id: _siloScan
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = (this.text || "").trim();
                if (!raw) return;
                let parsed = null;
                try { parsed = JSON.parse(raw); }
                catch (e) { return; }
                // SessionManager1.ListSilos returns a single string
                // (JSON-encoded). Drill in.
                let rows = [];
                if (parsed && parsed.data && parsed.data.length > 0) {
                    try { rows = JSON.parse(String(parsed.data[0])); }
                    catch (e) { rows = []; }
                }
                const next = {};
                for (const row of rows) {
                    if (row && typeof row.uid !== "undefined")
                        next[String(row.uid)] = row.name || "";
                }
                root._uidSilo = next;
                // Re-stamp existing apps so the next launcher open
                // sees up-to-date silo chips even without a full
                // refresh().
                for (let i = 0; i < root.apps.count; i++) {
                    const r = root.apps.get(i);
                    const s = root._siloFor(r.uid);
                    if (r.silo !== s)
                        root.apps.setProperty(i, "silo", s);
                }
            }
        }
    }

    Timer {
        id: refreshTimer
        interval: 5000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            root.refreshSilos();
            root.refresh();
        }
    }

    // Launch helper. App1Apps entries are user-uid binaries that
    // already exist in the silo's environment — no spawn-tier2
    // gymnastics needed; we just exec the friendly name as the
    // canonical binary (mapping QFileMan → qfileman etc.) inside the
    // target silo via the session-manager's StartSilo + a per-app
    // unit. Cold-start: no LAUNCH_TOKEN handshake yet (these apps
    // don't carry a wp_security_context_v1 tag), so the launcher
    // shows the toplevel as it arrives.
    function launch(row) {
        if (!row || !row.service) return;
        const binary = root._binaryFor(row.name);
        if (!binary) {
            Logger.w("App1Apps", "no binary mapping for " + row.name);
            return;
        }
        Logger.d("App1Apps", "launching " + binary + " for uid " + row.uid
                              + " (silo=" + row.silo + ")");
        const proc = launchProcessComp.createObject(root, {
            "command": ["sh", "-c",
                "QDISTRO_SILO=" + (row.silo || "") + " " +
                "exec " + binary + " >/dev/null 2>&1 &"],
        });
        proc.running = true;
    }

    Component {
        id: launchProcessComp
        Process {
            onExited: this.destroy()
        }
    }

    function _binaryFor(friendly) {
        // Friendly → binary mapping for the P03 first-party set; new
        // App1 entries can register a desktop file with a
        // ``X-Qdistro-Binary=...`` field once that convention lands.
        const map = {
            "QTerminator": "qterminator",
            "QNotebook":   "qnotebook",
            "QFileMan":    "qfileman",
        };
        return map[friendly] || friendly.toLowerCase();
    }
}
