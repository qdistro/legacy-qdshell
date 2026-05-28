pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Hardware
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
    detectLid(); // triggers startLidMonitor() via onHasLidChanged when a lid is found
    detectACState();
    startButtonMonitor();
    swayidleCheck.running = true;
    checkCriticalBattery();
  }

  // ─── Capability detection (loginctl) ─────────────────────────────
  Process {
    id: canSuspendProc
    command: ["sh", "-c", "out=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend 2>/dev/null) || { echo yes; exit 0; }; echo \"$out\" | sed 's/^s \"//;s/\"$//'"]
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
    command: ["sh", "-c", "out=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null) || { echo no; exit 0; }; echo \"$out\" | sed 's/^s \"//;s/\"$//'"]
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
    command: ["sh", "-c", "out=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHybridSleep 2>/dev/null) || { echo no; exit 0; }; echo \"$out\" | sed 's/^s \"//;s/\"$//'"]
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
    command: ["sh", "-c", "out=$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanPowerOff 2>/dev/null) || { echo yes; exit 0; }; echo \"$out\" | sed 's/^s \"//;s/\"$//'"]
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
    command: ["sh", "-c", "online=; for p in /sys/class/power_supply/*; do t=$(cat \"$p/type\" 2>/dev/null); if [ \"$t\" = Mains ] || [ \"$t\" = USB ]; then v=$(cat \"$p/online\" 2>/dev/null); [ \"$v\" = 1 ] && online=1; [ -z \"$online\" ] && [ \"$v\" = 0 ] && online=0; fi; done; echo \"$online\""]
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

  // ─── Lid switch handling ─────────────────────────────────────────
  // logind decides the default lid action from /etc/systemd/logind.conf
  // (HandleLidSwitch*), which a user session cannot change. To make the
  // qdshell lid policy effective we take an inhibitor lock on the handle
  // events so logind defers to us, then poll the kernel lid state and apply
  // the configured action ourselves. Power/sleep button actions likewise
  // require either logind config or evdev access; we surface them in the UI
  // and apply them when the user invokes them through qdshell, but logind
  // remains the authority for the physical keys.
  property string _lidState: "open"

  // Hold an inhibitor lock so logind does not run its own lid handler.
  Process {
    id: lidInhibitProc
    running: false
    command: ["sh", "-c", "systemd-inhibit --what=handle-lid-switch --who=qdshell --why='qdshell power manager lid policy' --mode=block sleep infinity"]
    stderr: StdioCollector {}
  }

  Process {
    id: lidStateProc
    command: ["sh", "-c", "cat /proc/acpi/button/lid/LID0/state /proc/acpi/button/lid/LID/state 2>/dev/null | head -1"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var line = String(text || "").trim().toLowerCase();
        var newState = line.indexOf("closed") !== -1 ? "closed" : "open";
        if (newState !== root._lidState) {
          var wasOpen = root._lidState === "open";
          root._lidState = newState;
          if (wasOpen && newState === "closed")
            root.onLidClosed();
        }
      }
    }
    stderr: StdioCollector {}
  }

  Timer {
    id: lidPollTimer
    interval: 2000
    repeat: true
    running: false
    onTriggered: lidStateProc.running = true
  }

  function onLidClosed() {
    Logger.i("PowerService", "Lid closed");
    if (IdleInhibitorService.isInhibited)
      return;
    if (lidIgnoreExternalDisplay && Quickshell.screens && Quickshell.screens.length > 1) {
      Logger.i("PowerService", "Lid close ignored — external display connected");
      return;
    }
    var action = onAC ? lidCloseOnAC : lidCloseOnBattery;
    executeAction(action);
  }

  function startLidMonitor() {
    if (!hasLid)
      return;
    lidInhibitProc.running = true;
    lidPollTimer.start();
  }

  onHasLidChanged: {
    if (hasLid && !lidPollTimer.running)
      startLidMonitor();
  }

  // ─── Power / Sleep button handling ───────────────────────────────
  // As with the lid, logind owns the physical keys by default. We take
  // inhibitor locks on handle-power-key / handle-suspend-key so logind
  // defers to qdshell, then watch evdev (via libinput debug-events) for
  // KEY_POWER / KEY_SLEEP presses and apply the configured action. If
  // libinput is unavailable or unreadable, the locks are released so
  // logind resumes its default behaviour (never leaving the keys dead).
  property bool _buttonMonitorActive: false

  Process {
    id: powerKeyInhibitProc
    running: false
    command: ["sh", "-c", "systemd-inhibit --what=handle-power-key:handle-suspend-key --who=qdshell --why='qdshell power manager button policy' --mode=block sleep infinity"]
    stderr: StdioCollector {}
  }

  Process {
    id: buttonMonitorProc
    running: false
    // libinput emits e.g. "KEY_POWER (116) pressed" lines on KEYBOARD_KEY events.
    command: ["sh", "-c", "command -v libinput >/dev/null 2>&1 || exit 1; libinput debug-events 2>/dev/null"]
    stdout: SplitParser {
      onRead: data => {
        var line = String(data || "");
        if (line.indexOf("pressed") === -1)
          return;
        if (line.indexOf("KEY_POWER") !== -1) {
          Logger.i("PowerService", "Power button pressed");
          root.executeAction(root.powerButtonAction);
        } else if (line.indexOf("KEY_SLEEP") !== -1 || line.indexOf("KEY_SUSPEND") !== -1) {
          Logger.i("PowerService", "Sleep button pressed");
          root.executeAction(root.sleepButtonAction);
        }
      }
    }
    stderr: StdioCollector {}
    onExited: function (exitCode) {
      // libinput missing or not permitted — release the inhibitor locks so
      // logind keeps handling the keys with its own configuration.
      if (root._buttonMonitorActive) {
        Logger.w("PowerService", "Button monitor unavailable (exit", exitCode + "); releasing key inhibitors, logind will handle power/sleep keys");
        root._buttonMonitorActive = false;
        if (powerKeyInhibitProc.running)
          powerKeyInhibitProc.signal(15);
      }
    }
  }

  function startButtonMonitor() {
    buttonMonitorProc.running = true;
    // Only take the inhibitor locks if the monitor actually started; if it
    // exits immediately the onExited handler releases them.
    powerKeyInhibitProc.running = true;
    _buttonMonitorActive = true;
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
      // Open the session menu to let the user choose
      Logger.i("PowerService", "Opening session menu for user choice");
      PanelService.getPanel("sessionMenuPanel")?.toggle();
      break;
    case "nothing":
    default:
      break;
    }
  }

  // ─── DPMS / Display off ──────────────────────────────────────────
  function dpmsOffCommand() {
    return "wlopm --off '*' 2>/dev/null || wlr-randr --output '*' --off 2>/dev/null || hyprctl dispatch dpms off 2>/dev/null";
  }

  function dpmsOnCommand() {
    return "wlopm --on '*' 2>/dev/null || wlr-randr --output '*' --on 2>/dev/null || hyprctl dispatch dpms on 2>/dev/null";
  }

  function turnOffDisplay() {
    Logger.i("PowerService", "Turning off display via DPMS");
    Quickshell.execDetached(["sh", "-c", dpmsOffCommand()]);
  }

  // ─── Idle timeout handling (real input idle via swayidle) ─────────
  // QML Timers cannot observe Wayland input activity, so a naive timer would
  // fire while the user is active. Instead we drive swayidle, which is
  // input-aware, and rebuild its argument list whenever the policy or the
  // AC/inhibit state changes. The idle inhibitor still gates the whole thing.
  readonly property int activeInactivityTimeout: onAC ? inactivityTimeoutAC : inactivityTimeoutBattery
  readonly property int activeDisplayOffTimeout: onAC ? displayOffAC : displayOffBattery

  property bool swayidleAvailable: false

  Process {
    id: swayidleCheck
    command: ["sh", "-c", "command -v swayidle >/dev/null 2>&1 && echo yes || echo no"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.swayidleAvailable = String(text || "").trim() === "yes";
        Logger.d("PowerService", "swayidleAvailable:", root.swayidleAvailable);
        if (root.swayidleAvailable)
          root.rebuildIdleDaemon();
      }
    }
    stderr: StdioCollector {}
  }

  Process {
    id: idleDaemonProc
    running: false
    stderr: StdioCollector {}
  }

  // Rebuild and (re)start the idle daemon whenever the effective policy changes.
  function rebuildIdleDaemon() {
    if (!swayidleAvailable)
      return;

    // Stop any running instance first.
    if (idleDaemonProc.running)
      idleDaemonProc.signal(15);

    // When inhibited, leave the daemon stopped entirely.
    if (IdleInhibitorService.isInhibited) {
      Logger.d("PowerService", "Idle inhibited — idle daemon stopped");
      return;
    }

    var args = ["swayidle", "-w"];

    var dispOff = activeDisplayOffTimeout;
    if (dispOff > 0) {
      args.push("timeout");
      args.push(String(dispOff * 60));
      args.push(dpmsOffCommand());
      args.push("resume");
      args.push(dpmsOnCommand());
    }

    var inact = activeInactivityTimeout;
    if (inact > 0 && inactivityAction !== "nothing") {
      var cmd = "";
      switch (inactivityAction) {
      case "suspend":
        cmd = "systemctl suspend || loginctl suspend";
        break;
      case "hibernate":
        cmd = "systemctl hibernate || loginctl hibernate";
        break;
      case "hybrid-sleep":
        cmd = "systemctl hybrid-sleep || loginctl hybrid-sleep";
        break;
      }
      if (cmd !== "") {
        args.push("timeout");
        args.push(String(inact * 60));
        args.push(cmd);
      }
    }

    // Nothing to do — keep the daemon stopped.
    if (args.length <= 2) {
      Logger.d("PowerService", "No idle actions configured — idle daemon stopped");
      return;
    }

    idleDaemonProc.command = args;
    idleDaemonProc.running = true;
    Logger.i("PowerService", "Idle daemon (re)started:", args.join(" "));
  }

  // React to policy / state changes.
  onActiveInactivityTimeoutChanged: rebuildIdleDaemon()
  onActiveDisplayOffTimeoutChanged: rebuildIdleDaemon()
  onInactivityActionChanged: rebuildIdleDaemon()

  Connections {
    target: IdleInhibitorService
    function onIsInhibitedChanged() {
      root.rebuildIdleDaemon();
    }
  }

  // ─── Critical battery handling ───────────────────────────────────
  // Watch the primary battery and trigger the configured action once when the
  // level drops to/below the configured threshold while discharging.
  property bool _criticalActionTaken: false

  Connections {
    target: BatteryService
    function onBatteryPercentageChanged() {
      root.checkCriticalBattery();
    }
    function onBatteryChargingChanged() {
      root.checkCriticalBattery();
    }
    function onLaptopBatteriesChanged() {
      root.checkCriticalBattery();
    }
  }

  // Safety-net poll in case a laptop battery is not the primary device and
  // its change signals are not observed through the aggregate properties.
  Timer {
    id: criticalBatteryPoll
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.checkCriticalBattery()
  }

  // Resolve an effective critical-battery action, falling back when the
  // configured one is unavailable so protection still happens.
  function effectiveCriticalAction() {
    var action = criticalBatteryAction;
    if (action === "hibernate" && !canHibernate)
      action = "suspend";
    if (action === "suspend" && !canSuspend)
      action = "shutdown";
    return action;
  }

  function checkCriticalBattery() {
    // Only consider the laptop/internal battery — never a Bluetooth
    // peripheral (mouse/headset), which would otherwise suspend a desktop.
    var batteries = BatteryService.laptopBatteries;
    if (!batteries || batteries.length === 0) {
      _criticalActionTaken = false;
      return;
    }
    var dev = batteries[0];

    var pct = BatteryService.getPercentage(dev);
    var charging = BatteryService.isCharging(dev);
    var plugged = BatteryService.isPluggedIn(dev);

    // Reset latch once charging or comfortably above the threshold.
    if (charging || plugged || pct > criticalBatteryLevel + 2) {
      _criticalActionTaken = false;
      return;
    }

    if (!BatteryService.isDevicePresent(dev) || !BatteryService.isDeviceReady(dev))
      return;

    if (_criticalActionTaken)
      return;

    if (pct <= criticalBatteryLevel) {
      _criticalActionTaken = true;
      var action = effectiveCriticalAction();
      Logger.w("PowerService", "Critical battery level reached, executing:", action);
      executeAction(action);
    }
  }

  // ─── Cleanup ─────────────────────────────────────────────────────
  Component.onDestruction: {
    if (lidInhibitProc.running)
      lidInhibitProc.signal(15);
    if (powerKeyInhibitProc.running)
      powerKeyInhibitProc.signal(15);
    if (buttonMonitorProc.running)
      buttonMonitorProc.signal(15);
    if (idleDaemonProc.running)
      idleDaemonProc.signal(15);
  }
}
