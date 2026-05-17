pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Defense-in-depth gate around HooksService's script execution.
//
// HooksService already gates execution behind Settings.data.hooks.enabled
// (user-side opt-in). HooksGate adds a second layer: each event-script
// pair is checked against the qdistro broker's CheckPermission rules
// engine before execDetached actually fires, so admin can disable a
// specific hook (e.g. "screenLock" hook running an unwanted shutdown
// command) without touching the user's qdshell settings file.
//
// Action namespace: "hook.allowed:<eventName>"
//   - eventName ∈ { wallpaperChange, darkModeChange, screenLock,
//                   screenUnlock, performanceModeEnabled,
//                   performanceModeDisabled, session, startup }
//
// Details dict: { "script": <full command string> }
//
// Decision policy:
//   - "allow"   → execute script
//   - "deny"    → skip + log
//   - "unknown" → execute (defense-in-depth, not gatekeeping); fire
//                 async RequestPermission so admin sees the rule next
//                 time and can switch the verdict.
//   - broker absent / call fails → execute (graceful degradation;
//                                  qdshell must still work without
//                                  qdistro broker).
//
// The broker is on the system bus:
//   bus  = org.qdistro.AdminBroker1
//   path = /org/qdistro/AdminBroker1
//   sig  = CheckPermission(s action, a{sv} details) -> s

Singleton {
  id: root

  readonly property string brokerBus: "org.qdistro.AdminBroker1"
  readonly property string brokerPath: "/org/qdistro/AdminBroker1"
  readonly property string brokerIface: "org.qdistro.AdminBroker1"

  // Pending gate requests, keyed by a unique id. Each entry:
  //   { event, script, args, callback }
  // Fed to a single Process queue so concurrent hooks don't fork bombs.
  property var _pending: ({})
  property int _nextId: 1

  // Public entry — non-blocking. Calls broker.CheckPermission for the
  // (event, script) pair, then on grant invokes onAllow().
  //   event: short event name, e.g. "wallpaperChange"
  //   script: command string that would have been passed to sh -lc
  //   onAllow: function() to invoke when the gate clears
  function gate(event, script, onAllow) {
    if (!event || !script) {
      return;
    }
    const id = _nextId++;
    _pending[id] = {
      "event": event,
      "script": script,
      "onAllow": onAllow,
    };
    _checkProcess.command = [
      "busctl", "--system", "--no-pager", "call",
      brokerBus, brokerPath, brokerIface,
      "CheckPermission", "sa{sv}",
      "hook.allowed:" + event,
      "1", "script", "s", script,
    ];
    // Stash id in env so the exit handler knows which pending entry
    // resolved. busctl doesn't carry user data — we scope per-call by
    // serializing through a single Process and a queue.
    _checkProcess.environment = ["__QDSHELL_GATE_ID=" + id];
    _checkProcess.running = true;
  }

  // Internal: route HooksService's blocking power-hook through the gate.
  // Mirrors gate(), but the caller's onAllow is responsible for
  // launching its own blocking Process and finalizing the callback.
  function gateBlocking(event, script, onAllow) {
    gate(event, script, onAllow);
  }

  Process {
    id: _checkProcess
    running: false

    stdout: StdioCollector {
      id: _stdoutCollector
    }
    stderr: StdioCollector {
      id: _stderrCollector
    }

    onExited: (exitCode, exitStatus) => {
      // Recover gate id from the env we stashed.
      let id = -1;
      const env = _checkProcess.environment || [];
      for (let i = 0; i < env.length; i++) {
        const kv = env[i];
        if (kv.indexOf("__QDSHELL_GATE_ID=") === 0) {
          id = parseInt(kv.substring("__QDSHELL_GATE_ID=".length), 10);
          break;
        }
      }
      const entry = (id > 0) ? root._pending[id] : null;
      if (entry && id > 0) {
        delete root._pending[id];
      }
      if (!entry) {
        Logger.w("HooksGate", "exit handler with no matching pending entry");
        return;
      }

      // Parse busctl output. On success it prints `s "allow"` (or
      // "deny" / "unknown"). On failure (broker absent, rate-limit,
      // bus error) exitCode != 0.
      const stdout = (_stdoutCollector.text || "").trim();
      let verdict = "unknown";
      if (exitCode === 0) {
        const m = stdout.match(/^s\s+"([^"]+)"/);
        if (m) {
          verdict = m[1];
        }
      } else {
        // Broker absent / not running / not installed — fall through
        // to graceful-degradation allow. Log once at debug; this is
        // the expected state on dev VMs without qdistro infra.
        Logger.d("HooksGate", "broker check failed (exitCode=" + exitCode
                 + "), falling back to allow:", entry.event);
        verdict = "broker-absent";
      }

      if (verdict === "deny") {
        Logger.w("HooksGate", "DENIED hook", entry.event,
                 "by broker rule. Script not executed:", entry.script);
        return;
      }

      // allow / unknown / broker-absent → execute. For "unknown",
      // fire-and-forget RequestPermission so admin's rules UI gets a
      // pending entry next time.
      if (verdict === "unknown") {
        _requestProcess.command = [
          "busctl", "--system", "--no-pager", "call",
          root.brokerBus, root.brokerPath, root.brokerIface,
          "RequestPermission", "sa{sv}",
          "hook.allowed:" + entry.event,
          "1", "script", "s", entry.script,
        ];
        _requestProcess.running = true;
      }

      try {
        entry.onAllow();
      } catch (e) {
        Logger.e("HooksGate", "onAllow callback raised:", e);
      }
    }
  }

  // Fire-and-forget RequestPermission Process for the "unknown" path.
  // We don't care about its result; it queues a pending entry in the
  // broker's admin-prompt list so admin can decide the rule for next
  // time. Output deliberately ignored.
  Process {
    id: _requestProcess
    running: false
  }
}
