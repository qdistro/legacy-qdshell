# Settings → Window Manager

What must be visible when this tab is open:

- A "Focus" section header (i18n key `panels.window-manager.section-focus`).
- A focus-policy combo (`panels.window-manager.focus-policy-label`) offering
  "Click to focus" and "Focus follows mouse".
- A focus-follows-mouse delay spin box (in ms), enabled only when the focus
  policy is "Focus follows mouse".
- "Raise window on click" and "Raise window on hover" toggles.
- A "Placement" section with a new-window placement combo
  (`panels.window-manager.placement-label`) offering Center / Under the mouse /
  Smart / Cascade.
- A "Snapping & Tiling" section with a snapping/edge-tiling toggle
  (`panels.window-manager.snap-enabled-label`) and a snap-distance spin box (px),
  the spin box enabled only when snapping is on.
- A "Titlebar & Decorations" section with a titlebar double-click action combo
  (Maximize / Shade / Minimize / Do nothing) and a free-text decoration-theme
  name input (`panels.window-manager.decoration-theme-label`).
- A "Keyboard Shortcuts" section with a note
  (`panels.window-manager.shortcuts-note`) and free-text accelerator inputs for:
  close window, toggle maximize, toggle fullscreen, tile left, tile right.
- The standard left-side Settings tab strip is visible.

Notes:
- When the active compositor cannot apply WM policy live (e.g. qdwin), a
  persist-only banner (`panels.window-manager.backend-persist-only`) is shown at
  the top of the tab. Under qdwin all of these controls are persist-only: the
  values are saved and will be applied once a supporting backend (sway-style or
  labwc) is detected, where WindowManagerService reconfigures via tokenised
  argv (never a raw shell string).
- The decoration-theme name and shortcut strings are treated as untrusted free
  text and are never interpolated into a shell command.
