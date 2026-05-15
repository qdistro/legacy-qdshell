pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Qdwin

// PodApps — per-container app registry for the qdshell launcher.
//
// Reads the JSON cache that tier2/podapps-scan.sh writes under
// /var/lib/qdistro/podapps/<container>/apps.json, exposes a flat
// list-model the Launcher and Taskbar merge alongside the host's
// XDG DesktopEntries, and tracks per-launch placeholders for the
// cold-start UX.
//
// See:
//   - qdistro/doc/containers.md      (the design)
//   - qdistro/doc/window-hierarchy.md (cold-start contract)
//   - qdistro/doc/ui.md               (silo-badge convention)
Singleton {
    id: root

    // ---- Configuration ----------------------------------------------------
    readonly property string cacheRoot: "/var/lib/qdistro/podapps"
    // Spawn helper path. Resolved at runtime; if the user runs from a
    // dev tree, qdistro/tier2/spawn-tier2.sh works too — we shell out.
    readonly property string spawnHelper: "qdistro-tier2-spawn"

    // ---- Public model -----------------------------------------------------
    // Each row: { appId, container, workload, name, iconName, comment,
    //             execArgv (string), silo, containerState }
    // containerState ∈ { "running", "off", "starting", "unknown" }
    property ListModel apps: ListModel {}

    // ---- Cold-start placeholders -----------------------------------------
    // Each entry: { launchToken, appId, name, iconName, silo, since }
    // Inserted on spawn, removed on matching toplevel_security_context
    // event or after the placeholderTimeoutMs cap.
    property ListModel placeholders: ListModel {}
    property int placeholderTimeoutMs: 15000

    signal placeholderAdded(string launchToken, string appId,
                            string name, string iconName, string silo)
    signal placeholderResolved(string launchToken, int handle)
    signal placeholderTimedOut(string launchToken, string appId)

    // ---- Container state cache ------------------------------------------
    // containerName → "running" | "off"
    property var _containerStates: ({})
    signal containerStateChanged(string container, string state)

    // ---- Implementation -------------------------------------------------

    // Re-scan the cache directory. Cheap — reads ~one JSON file per
    // container. Triggered periodically + on Container state change.
    function refresh() {
        apps.clear();
        _scanProcess.command = ["sh", "-c",
            "shopt -s nullglob; " +
            "for d in " + cacheRoot + "/*/; do " +
            "  name=$(basename \"$d\"); " +
            "  if [ -f \"$d/apps.json\" ]; then " +
            "    printf '=== %s\\n' \"$name\"; " +
            "    cat \"$d/apps.json\"; " +
            "  fi; " +
            "done"];
        _scanProcess.running = true;
    }

    Process {
        id: _scanProcess
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = this.text || "";
                if (!raw) return;
                // Sections: "=== <container>\n[<json>]\n"
                const sections = raw.split(/^=== /m).filter(s => s.length > 0);
                for (const sec of sections) {
                    const nl = sec.indexOf("\n");
                    if (nl < 0) continue;
                    const container = sec.slice(0, nl).trim();
                    const jsonBody  = sec.slice(nl + 1).trim();
                    let entries = [];
                    try { entries = JSON.parse(jsonBody); }
                    catch (e) {
                        Logger.w("PodApps", "parse failed for " + container + ": " + e);
                        continue;
                    }
                    const state = root._containerStates[container] || "off";
                    for (const e of entries) {
                        root.apps.append({
                            appId:          e.appId          || "",
                            container:      e.container      || container,
                            workload:       e.workload       || "",
                            name:           e.name           || "",
                            iconName:       e.iconName       || "",
                            comment:        e.comment        || "",
                            execArgv:       JSON.stringify(e.execArgv || []),
                            silo:           e.silo           || ("tier2/" + container),
                            containerState: state,
                        });
                    }
                }
            }
        }
    }

    // Poll podman for running containers, update containerStates,
    // re-stamp the apps model's containerState column.
    function refreshContainerStates() {
        _containerListProcess.running = false;
        _containerListProcess.command = ["sh", "-c",
            "command -v podman >/dev/null && " +
            "podman ps --format '{{.Names}}' 2>/dev/null || true"];
        _containerListProcess.running = true;
    }

    Process {
        id: _containerListProcess
        stdout: StdioCollector {
            onStreamFinished: {
                const running = new Set(
                    (this.text || "").split("\n")
                        .map(s => s.trim()).filter(s => s.length > 0));
                const next = {};
                for (const name of running) next[name] = "running";
                // Find off transitions.
                for (const name in root._containerStates) {
                    if (!(name in next)) next[name] = "off";
                }
                const changed = [];
                for (const name in next) {
                    if (root._containerStates[name] !== next[name])
                        changed.push(name);
                }
                root._containerStates = next;
                // Propagate to apps model.
                for (let i = 0; i < root.apps.count; i++) {
                    const row = root.apps.get(i);
                    const s = next[row.container] || "off";
                    if (row.containerState !== s)
                        root.apps.setProperty(i, "containerState", s);
                }
                for (const c of changed)
                    root.containerStateChanged(c, next[c]);
            }
        }
    }

    Timer {
        id: stateTimer
        interval: 3000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refreshContainerStates()
    }

    Timer {
        id: cacheRefreshTimer
        interval: 30000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ---- Launch -----------------------------------------------------------
    // Called from Launcher / Taskbar click handlers. Forks spawn-tier2.sh
    // with the right args; the helper emits LAUNCH_TOKEN= on its
    // stdout. We add a placeholder immediately keyed on that token, then
    // resolve it on toplevel_security_context.
    function launch(row) {
        if (!row || !row.appId) return;
        let argv = [];
        try { argv = JSON.parse(row.execArgv); } catch (e) { argv = []; }
        if (argv.length === 0) {
            Logger.w("PodApps", "launch: empty execArgv for " + row.appId);
            return;
        }
        // Build: spawn-tier2.sh <container> <workload> -- <argv...>
        const cmd = [root.spawnHelper, row.container,
                     row.workload || "weston-terminal", "--"].concat(argv);

        const tokenSlot = { value: "" };
        const proc = launchProcessComp.createObject(root, {
            "command": cmd,
            "_tokenSlot": tokenSlot,
            "_appId":    row.appId,
            "_name":     row.name,
            "_iconName": row.iconName || "",
            "_silo":     row.silo,
        });
        proc.running = true;
    }

    // Internal helper Process component. One per launch — Process is
    // a transient state holder, not a singleton.
    Component {
        id: launchProcessComp
        Process {
            property var _tokenSlot
            property string _appId
            property string _name
            property string _iconName
            property string _silo
            stdout: StdioCollector {
                onStreamFinished: {
                    // Parse LAUNCH_TOKEN=... from helper stdout.
                    const m = (this.text || "").match(/^LAUNCH_TOKEN=([0-9a-fA-F]+)/m);
                    if (m) {
                        const token = m[1];
                        root._registerPlaceholder(token, parent._appId,
                                                  parent._name, parent._iconName,
                                                  parent._silo);
                    } else {
                        Logger.w("PodApps", "launch: no LAUNCH_TOKEN in spawn stdout for " + parent._appId);
                    }
                    parent.destroy();
                }
            }
            stderr: StdioCollector {
                onStreamFinished: {
                    if (this.text && this.text.length > 0)
                        Logger.w("PodApps", "spawn stderr (" + parent._appId + "): " + this.text);
                }
            }
        }
    }

    function _registerPlaceholder(launchToken, appId, name, iconName, silo) {
        placeholders.append({
            launchToken: launchToken,
            appId:       appId,
            name:        name,
            iconName:    iconName,
            silo:        silo,
            since:       Date.now(),
        });
        placeholderAdded(launchToken, appId, name, iconName, silo);
    }

    Timer {
        id: placeholderGcTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            for (let i = root.placeholders.count - 1; i >= 0; i--) {
                const ph = root.placeholders.get(i);
                if (now - ph.since > root.placeholderTimeoutMs) {
                    root.placeholderTimedOut(ph.launchToken, ph.appId);
                    root.placeholders.remove(i);
                }
            }
        }
    }

    // Wire the secctx-resolved signal from the Qdwin singleton. When
    // a toplevel arrives with an instanceId matching one of our
    // pending placeholders, drop the placeholder.
    Connections {
        target: Qdwin
        function onWindowSecctxResolved(handle, sandboxEngine, secctxAppId, instanceId) {
            if (!instanceId) return;
            for (let i = 0; i < root.placeholders.count; i++) {
                if (root.placeholders.get(i).launchToken === instanceId) {
                    root.placeholders.remove(i);
                    root.placeholderResolved(instanceId, handle);
                    return;
                }
            }
        }
    }
}
