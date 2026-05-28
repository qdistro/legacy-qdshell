pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Singleton {
  id: root

  // Capability flags — queried from logind at startup
  property bool canSuspend: false
  property bool canHibernate: false
  property bool canHybridSleep: false
  property bool canPowerOff: false

  // Whether a lid is physically present (laptop)
  property bool hasLid: false
  // Whether AC power is connected (best-effort; defaults true on desktops)
  property bool onAC: true

  // Settings-backed policy (convenience aliases)
  readonly property string powerButtonAction:        Settings.data.power.powerButtonAction
  readonly property string sleepButtonAction:         Settings.data.power.sleepButtonAction
  readonly property string lidCloseOnBattery:         Settings.data.power.lidCloseOnBattery
  readonly property string lidCloseOnAC:              Settings.data.power.lidCloseOnAC
  readonly property bool   lidIgnoreExternalDisplay:  Settings.data.power.lidIgnoreExternalDisplay
  readonly property int    inactivityTimeoutBattery:  Settings.data.power.inactivityTimeoutBattery
  readonly property int    inactivityTimeoutAC:       Settings.data.power.inactivityTimeoutAC
  readonly property string inactivityAction:          Settings.data.power.inactivityAction
  readonly property int    criticalBatteryLevel:      Settings.data.power.criticalBatteryLevel
  readonly property string criticalBatteryAction:     Settings.data.power.criticalBatteryAction
  readonly property int    displayOffBattery:         Settings.data.power.displayOffBattery
  readonly property int    displayOffAC:              Settings.data.power.displayOffAC

  // ─── Initialisation ──────────────────────────────────────────────
  function init() {
    Logger.i("PowerService", "Service started");
    queryCapabilities();
    detectLid();
    detectACState();
    startLidMonitor();
  }

  // ─── Capability detection (loginctl) ─────────────────────────────
  Process {
    id: canSuspendProc
    command: ["sh", "-c", "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend 2>/dev/null | sed 's/^s \"//' | sed 's/\"$//' || echo yes"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.canSuspend = String(text || "").trim() === "yes";
        Logger.d("PowerService", "CanSuspend:", root.canSuspend);
      }
    }
    stderr: StdioCollector {}
  }

  Process {
    id: canHibernateProc
    command: ["sh", "-c", "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null | sed 's/^s \"//' | sed 's/\"$//' || echo no"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.canHibernate = String(text || "").trim() === "yes";
        Logger.d("PowerService", "CanHibernate:", root.canHibernate);
      }
    }
    stderr: StdioCollector {}
  }

  Process {
    id: canHybridSleepProc
    command: ["sh", "-c", "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHybridSleep 2>/dev/null | sed 's/^s \"//' | sed 's/\"$//' || echo no"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.canHybridSleep = String(text || "").trim() === "yes";
        Logger.d("PowerService", "CanHybridSleep:", root.canHybridSleep);
      }
    }
    stderr: StdioCollector {}
  }

  Process {
    id: canPowerOffProc
    command: ["sh", "-c", "busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanPowerOff 2>/dev/null | sed 's/^s \"//' | sed 's/\"$//' || echo yes"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.canPowerOff = String(text || "").trim() === "yes";
        Logger.d("PowerService", "CanPowerOff:", root.canPowerOff);
      }
    }
    stderr: StdioCollector {}
  }

  function queryCapabilities() {
    canSuspendProc.running = true;
    canHibernateProc.running = true;
    canHybridSleepProc.running = true;
    canPowerOffProc.running = true;
  }

  // ─── Lid detection ───────────────────────────────────────────────
  Process {
    id: lidDetectProc
    command: ["sh", "-c", "{ test -e /proc/acpi/button/lid/LID0/state || test -e /proc/acpi/button/lid/LID/state; } && echo yes || echo no"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.hasLid = String(text || "").trim() === "yes";
        Logger.d("PowerService", "hasLid:", root.hasLid);
      }
    }
    stderr: StdioCollector {}
  }

  function detectLid() {
    lidDetectProc.running = true;
  }

  // ─── AC state detection ──────────────────────────────────────────
  Process {
    id: acDetectProc
    command: ["sh", "-c", "cat /sys/class/power_supply/AC*/online /sys/class/power_supply/ACAD*/online 2>/dev/null | head -1"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var val = String(text || "").trim();
        if (val === "1")
          root.onAC = true;
        else if (val === "0")
          root.onAC = false;
        // else keep default (true for desktops)
        Logger.d("PowerService", "onAC:", root.onAC);
      }
    }
    stderr: StdioCollector {}
  }

  Timer {
    id: acPollTimer
    interval: 30000 // 30 seconds
    repeat: true
    running: true
    onTriggered: detectACState()
  }

  function detectACState() {
    acDetectProc.running = true;
  }

  // ─── Lid-close monitor (logind PrepareForSleep) ──────────────────
  Process {
    id: lidMonitorProc
    running: false
    command: ["sh", "-c", "busctl monitor --json=short org.freedesktop.login1 --match \"type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'\" 2>/dev/null || gdbus monitor -y -d org.freedesktop.login1 -o /org/freedesktop/login1 2>/dev/null"]

    stdout: SplitParser {
      onRead: data => {
        if (data.includes("PrepareForSleep")) {
          Logger.d("PowerService", "PrepareForSleep signal received");
        }
      }
    }
    stderr: StdioCollector {}
  }

  function startLidMonitor() {
    lidMonitorProc.running = true;
  }

  // ─── Actions ─────────────────────────────────────────────────────
  function executeSuspend() {
    if (!canSuspend) {
      Logger.w("PowerService", "Suspend not available");
      return;
    }
    Logger.i("PowerService", "Executing suspend");
    Quickshell.execDetached(["sh", "-c", "systemctl suspend || loginctl suspend"]);
  }

  function executeHibernate() {
    if (!canHibernate) {
      Logger.w("PowerService", "Hibernate not available");
      return;
    }
    Logger.i("PowerService", "Executing hibernate");
    Quickshell.execDetached(["sh", "-c", "systemctl hibernate || loginctl hibernate"]);
  }

  function executeHybridSleep() {
    if (!canHybridSleep) {
      Logger.w("PowerService", "Hybrid sleep not available");
      return;
    }
    Logger.i("PowerService", "Executing hybrid sleep");
    Quickshell.execDetached(["sh", "-c", "systemctl hybrid-sleep || loginctl hybrid-sleep"]);
  }

  function executePowerOff() {
    Logger.i("PowerService", "Executing power off");
    Quickshell.execDetached(["sh", "-c", "systemctl poweroff || loginctl poweroff"]);
  }

  function executeAction(action) {
    switch (action) {
    case "suspend":
      executeSuspend();
      break;
    case "hibernate":
      executeHibernate();
      break;
    case "hybrid-sleep":
      executeHybridSleep();
      break;
    case "shutdown":
      executePowerOff();
      break;
    case "ask":
      // Open session menu to let user choose
      Logger.i("PowerService", "Opening session menu for user choice");
      break;
    case "nothing":
    default:
      break;
    }
  }

  // ─── DPMS / Display off ──────────────────────────────────────────
  function turnOffDisplay() {
    Logger.i("PowerService", "Turning off display via DPMS");
    Quickshell.execDetached(["sh", "-c", "wlopm --off '*' 2>/dev/null || wlr-randr --output '*' --off 2>/dev/null || xset dpms force off 2>/dev/null"]);
  }

  // ─── Idle timeout handling ───────────────────────────────────────
  readonly property int activeInactivityTimeout: onAC ? inactivityTimeoutAC : inactivityTimeoutBattery
  readonly property int activeDisplayOffTimeout: onAC ? displayOffAC : displayOffBattery

  Timer {
    id: inactivityTimer
    interval: root.activeInactivityTimeout * 60 * 1000
    repeat: false
    running: root.activeInactivityTimeout > 0 && root.inactivityAction !== "nothing" && !IdleInhibitorService.isInhibited
    onTriggered: {
      Logger.i("PowerService", "Inactivity timeout reached, executing:", root.inactivityAction);
      root.executeAction(root.inactivityAction);
    }
  }

  Timer {
    id: displayOffTimer
    interval: root.activeDisplayOffTimeout * 60 * 1000
    repeat: false
    running: root.activeDisplayOffTimeout > 0 && !IdleInhibitorService.isInhibited
    onTriggered: {
      Logger.i("PowerService", "Display off timeout reached");
      root.turnOffDisplay();
    }
  }

  // ─── Cleanup ─────────────────────────────────────────────────────
  Component.onDestruction: {
    if (lidMonitorProc.running)
      lidMonitorProc.signal(15);
  }
}
