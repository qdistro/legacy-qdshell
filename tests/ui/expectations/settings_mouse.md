# Settings → Mouse & Touchpad

What must be visible when this tab is open:

- Tab header / first section text: "Devices" (i18n key `panels.mouse.section-devices`).
- A "Refresh" button on the Devices section header.
- One row per detected pointer device (mouse / touchpad / trackpoint) with a
  type label, OR the "No pointer devices detected" empty state
  (`panels.mouse.no-devices-label`) when none can be enumerated.
- A "Pointer" section with an acceleration-profile combo and a pointer-speed
  slider, plus a left-handed-mode toggle.
- A "Scrolling" section with natural-scroll and horizontal-scroll toggles and a
  scroll-method combo.
- A "Touchpad" section with tap-to-click and disable-while-typing toggles.
- A "Double-click & Drag" section with double-click time/distance and
  drag-threshold spin boxes.
- A cursor hint pointing to the Appearance tab (`panels.mouse.cursor-hint`).
- The standard left-side Settings tab strip is visible.

Notes:
- When the active compositor cannot apply pointer settings live (e.g. qdwin),
  a persist-only banner (`panels.mouse.backend-persist-only`) is shown at the
  top. Live apply is exercised only under sway-compatible compositors.
- Double-click time/distance and drag threshold are persisted UI-interaction
  preferences and are not applied through libinput.
