# Settings → Keyboard

The harness opens this tab via `settings openTab keyboard`, which lands on the
default ("General") sub-tab. What must be visible:

- A sub-tab strip across the top with two tabs: "General" (`common.general`)
  and "Layout" (`panels.keyboard.layout-title`), with "General" selected.
- The General sub-tab content (the default, so this is what renders):
  - A "Use system defaults" toggle (`panels.keyboard.use-system-defaults-label`)
    governing the layout block.
  - A "Typing" section (`panels.keyboard.section-typing`) with a key-repeat
    delay spin box in ms (`repeat-delay-label`) and a repeat-rate spin box in Hz
    (`repeat-rate-label`).
  - A test-area text input (`panels.keyboard.test-area-label`) for trying out
    the repeat settings.
  - A "Cursor" section (`panels.keyboard.section-cursor`) with a persist note
    (`cursor-persist-note`), a cursor-blink toggle (`cursor-blink-label`), and a
    cursor-blink-rate spin box in ms (`cursor-blink-rate-label`).
  - A NumLock restore toggle (`panels.keyboard.restore-numlock-label`).
- The standard left-side Settings tab strip is visible.

Notes:
- Only the default ("General") sub-tab content is rendered after
  `openTab keyboard`; the harness does not click sub-tabs. The "Layout" sub-tab
  (reached by selecting its strip entry) covers:
  - A "Keyboard model" section (`panels.keyboard.section-model`) with a model
    combo (`model-label`).
  - A "Layouts" section (`panels.keyboard.section-layouts`) with its description
    (`layouts-description`), one row per configured layout (layout name +
    variant combo + move-up / move-down / remove buttons), and an "Add layout"
    searchable combo (`add-layout-label`).
  - An "Options" section (`panels.keyboard.section-options`) with a layout
    switch-shortcut combo (`switch-shortcut-label`), a Compose-key combo
    (`compose-key-label`), and an "XKB options" group (`xkb-options-label`) of
    checkboxes (caps:swapescape, caps:escape, caps:none, terminate, altwin:menu).
- A capability note banner (`panels.keyboard.capability-note`) appears at the
  top of the General sub-tab when no live-apply backend exists
  (KeyboardInputService.persistOnly); settings are persisted only in that case.
- Key repeat and cursor blink are behavior settings and are NOT scoped by
  "Use system defaults"; that toggle (per XFCE) only governs the model / layout
  / options block, whose controls disable when it is on.
