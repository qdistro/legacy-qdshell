pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "CaptureState.js" as CaptureState

// Live-capture observer feeding the non-suppressible lock-screen indicators
// (J28). Same shape as SiloEgressService: one poll process, one monitor
// process that coalesces into a refresh, one slow safety timer.
//
// The graph is read with `pw-dump` because PipeWire is the only place qdistro
// can see capture across silos today (silos get a bind-mounted view of admin's
// pipewire socket). Read Services/Qdistro/CaptureState.js before changing any
// of this — it documents exactly which negatives are trustworthy and which
// must stay "unverified".
Singleton {
  id: root

  // A scan older than this is not evidence of anything; every kind falls back
  // to "unverified" so a wedged observer can never read as a quiet machine.
  readonly property int staleAfterMs: 15000
  readonly property int pollIntervalMs: 5000

  property bool refreshInFlight: false
  property double lastOkMs: 0
  property double nowMs: Date.now()
  readonly property bool fresh: lastOkMs > 0 && (nowMs - lastOkMs) <= staleAfterMs

  // Last parse result, kept so a freshness expiry can re-derive without a scan.
  property var parsed: ({ ok: false, nodes: [] })

  // Derived state (see CaptureState.summarise).
  property bool observerOk: false
  property var kinds: ({})
  property var activeKinds: []
  property var unverifiedKinds: []
  property int activeCount: 0
  property string activeLabel: ""
  property string activeDetail: ""
  property string unverifiedLabel: ""
  property bool anyActive: false
  property bool anyUnverified: false
  property bool active: false
  property bool indicatorVisible: false

  Component.onCompleted: {
    Logger.i("CaptureStateService", "service started");
    _derive();
    refresh();
    _monitor.running = true;
  }

  // Drop the trust in the last scan. Callers that must not inherit pre-lock
  // state (the lock surface) call this before refresh() so the indicator reads
  // "unverified" until a scan taken AFTER the lock lands.
  function markStale() {
    lastOkMs = 0;
    _derive();
  }

  function refresh() {
    _scan.running = false;
    _scan.command = ["sh", "-c",
      "command -v pw-dump >/dev/null 2>&1 || exit 0; " +
      "pw-dump 2>/dev/null || true"];
    refreshInFlight = true;
    _scan.running = true;
  }

  function _derive() {
    const s = CaptureState.summarise(parsed, { fresh: fresh, limit: 2 });
    observerOk = s.observerOk;
    kinds = s.kinds;
    activeKinds = s.activeKinds;
    unverifiedKinds = s.unverifiedKinds;
    activeCount = s.activeCount;
    activeLabel = s.activeLabel;
    activeDetail = s.activeDetail;
    unverifiedLabel = s.unverifiedLabel;
    anyActive = s.anyActive;
    anyUnverified = s.anyUnverified;
    active = s.anyActive;
    indicatorVisible = s.visible;
  }

  // Freshness is time-dependent, so re-derive on every tick of the clock we
  // keep for it rather than only when a scan completes.
  onFreshChanged: _derive()

  Process {
    id: _scan
    stdout: StdioCollector {
      onStreamFinished: {
        const raw = (this.text || "").trim();
        root.refreshInFlight = false;
        const next = CaptureState.parsePwDump(raw);
        root.parsed = next;
        // Only a usable graph refreshes the freshness clock; a failed scan
        // leaves the old timestamp to expire into "unverified".
        if (next.ok)
          root.lastOkMs = Date.now();
        else
          Logger.w("CaptureStateService", "pw-dump produced no usable graph");
        root.nowMs = Date.now();
        root._derive();
      }
    }
    stderr: StdioCollector {}
    onExited: function () {
      root.refreshInFlight = false;
    }
  }

  // pw-mon prints a line per graph change (node added/removed/state change), so
  // a capture starting while locked is picked up in well under a second instead
  // of waiting for the poll. Output is chatty, hence the coalescing timer.
  Process {
    id: _monitor
    running: false
    command: ["sh", "-c",
      "command -v pw-mon >/dev/null 2>&1 || exit 1; exec pw-mon -N -o -a"]
    stdout: SplitParser {
      onRead: data => {
        if (String(data || "").trim() !== "")
          _coalesce.restart();
      }
    }
    stderr: StdioCollector {}
    onExited: function () {
      _restartMonitor.start();
    }
  }

  Timer {
    id: _coalesce
    interval: 300
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: _poll
    interval: root.pollIntervalMs
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // Drives the freshness computation between scans.
  Timer {
    id: _freshTick
    interval: 1000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: _restartMonitor
    interval: 5000
    repeat: false
    onTriggered: _monitor.running = true
  }
}
