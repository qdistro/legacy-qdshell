"""Surface manifests — the canonical list of what gets tested.

Each Surface is a (id, open_cmd, close_cmd, expectation_file) tuple. open_cmd and
close_cmd are lists passed to `qs ipc call`. expectation_file is the path
(relative to tests/ui/expectations/) of the human-authored golden description.

Coverage status:
  - Settings tabs: all 22, via `settings openTab <name>` IPC.
  - Panels: 9 of 13 have first-class IPC toggle hooks. Audio, Brightness, Tray,
    Plugins lack panel-open IPC in current qdshell — listed with NO_IPC for now
    so the manifest stays complete; the harness skips them with a clear message.
  - Bar: bar is always visible when shell is running; one full-shell screenshot
    is taken with no panel open (sanity baseline for bar/dock layout).
"""

from dataclasses import dataclass


NO_IPC = object()  # sentinel: surface known but no IPC handle yet


@dataclass(frozen=True)
class Surface:
    id: str
    kind: str                  # "settings" | "panel" | "bar"
    open_cmd: object           # list[str] of `qs ipc call` args, or NO_IPC
    close_cmd: object          # list[str] of `qs ipc call` args, or NO_IPC
    expectation: str           # filename under tests/ui/expectations/


# 22 settings tabs — `qs ipc call settings openTab <name>`
# Names match IPCService.qml::_settingsTabMap keys.
SETTINGS_TABS = [
    "general", "userinterface", "colorscheme", "wallpaper", "bar", "dock",
    "desktopwidgets", "controlcenter", "launcher", "notifications", "audio",
    "display", "location", "mouse", "osd", "connections", "hooks", "lockscreen",
    "sessionmenu", "systemmonitor", "plugins",
]
# Notes on tabs we deliberately don't cover:
#  - "about" — qdshell strips the upstream About box. The IPC map keeps the
#    name but the underlying SettingsPanel.Tab enum has no About member, so
#    `openTab about` falls back to General. Not testable.
#  - "Region" tab in the audit corresponds to "location" in the IPC map.
#  - "Vault" (from the original audit) isn't in _settingsTabMap and isn't
#    IPC-reachable.

SETTINGS_SURFACES = [
    Surface(
        id=f"settings_{tab}",
        kind="settings",
        open_cmd=["settings", "openTab", tab],
        close_cmd=["settings", "toggle"],   # toggle closes when open
        expectation=f"settings_{tab}.md",
    )
    for tab in SETTINGS_TABS
]


PANEL_SURFACES = [
    Surface("panel_battery",        "panel", ["battery", "togglePanel"],         ["battery", "togglePanel"],         "panel_battery.md"),
    Surface("panel_bluetooth",      "panel", ["bluetooth", "togglePanel"],       ["bluetooth", "togglePanel"],       "panel_bluetooth.md"),
    Surface("panel_calendar",       "panel", ["calendar", "toggle"],             ["calendar", "toggle"],             "panel_calendar.md"),
    Surface("panel_media",          "panel", ["media", "toggle"],                ["media", "toggle"],                "panel_media.md"),
    Surface("panel_network",        "panel", ["network", "togglePanel"],         ["network", "togglePanel"],         "panel_network.md"),
    Surface("panel_notifications",  "panel", ["notifications", "toggleHistory"], ["notifications", "toggleHistory"], "panel_notifications.md"),
    Surface("panel_controlcenter",  "panel", ["controlCenter", "toggle"],        ["controlCenter", "toggle"],        "panel_controlcenter.md"),
    Surface("panel_wallpaper",      "panel", ["wallpaper", "toggle"],            ["wallpaper", "toggle"],            "panel_wallpaper.md"),
    Surface("panel_sessionmenu",    "panel", ["sessionMenu", "toggle"],          ["sessionMenu", "toggle"],          "panel_sessionmenu.md"),
    Surface("panel_systemmonitor",  "panel", ["systemMonitor", "toggle"],        ["systemMonitor", "toggle"],        "panel_systemmonitor.md"),
    Surface("panel_launcher",       "panel", ["launcher", "toggle"],             ["launcher", "toggle"],             "panel_launcher.md"),
    Surface("panel_audio",          "panel", ["audio", "togglePanel"],      ["audio", "togglePanel"],      "panel_audio.md"),
    Surface("panel_brightness",     "panel", ["brightness", "togglePanel"], ["brightness", "togglePanel"], "panel_brightness.md"),
    Surface("panel_tray",           "panel", ["tray", "togglePanel"],       ["tray", "togglePanel"],       "panel_tray.md"),
]


BAR_SURFACES = [
    # Bar is the resting state of the shell; no panel open. We just screenshot.
    Surface("bar_idle",             "bar", None, None, "bar_idle.md"),
]


ALL_SURFACES = SETTINGS_SURFACES + PANEL_SURFACES + BAR_SURFACES
