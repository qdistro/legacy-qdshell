# qdshell agent-assisted UI tests

A regression harness that boots qdshell inside a **headless** nested
weston compositor, drives each panel / settings tab via `qs ipc`,
screenshots the result, and uses a vision LLM to verify the captured
image still matches a developer-authored description.

The goal is to catch *behaviour regressions* during refactors (e.g.
when extracting a `PanelShell` base or collapsing settings tabs)
without requiring pixel-perfect goldens.

## How "what an agent would see" works

For every surface (Settings tab / slide-out panel / bar idle) there is
one human-authored markdown file under `expectations/` listing what
*must* be visible there.  At test time:

1. The harness opens the surface via `qs ipc call …`.
2. `weston-screenshooter` saves a PNG of the framebuffer.
3. The PNG is sent to the local Codex CLI with a "describe what you see"
   prompt -> free-form bullet list of observed elements.
4. The observed description is judged against the expectation file by
   a second Codex call: every reference bullet must be present in the
   observed description for the test to pass.

Step 4 is LLM-as-judge rather than substring matching because UI text
descriptions naturally vary in wording.

## Requirements

System packages:

* **A wlroots-based nested compositor** (any one of):
  `sway`, `labwc`, `cage`, `wayfire`, `river`.
  qdshell uses `wlr-layer-shell` for every panel/bar surface;
  weston does *not* implement this protocol, so weston cannot be used
  to validate panel rendering. The runner auto-probes the candidates
  above in order and uses the first one it finds.
* `grim` — screenshot tool for wlroots (`zypper in grim` / `apt install grim`).
* `qs` / `quickshell`
* `python3` (>=3.10), `pytest`, and the local `codex` CLI

On the current dev machine (openSUSE Tumbleweed) install with:

```bash
sudo zypper install sway grim
```

Vision backend:

* `codex` — required for the describe + judge steps. Without it the harness
  still boots qdshell and captures PNGs into `tests/ui/artifacts/` so a
  human can compare manually, but every test reports SKIP. Set
  `QDSHELL_UI_NO_CODEX=1` to force the secondary local `pi` fallback when it
  is installed.

## Running

```bash
# Make sure pytest is installed and codex is on PATH.
pip install --user pytest

# Run the suite (set the env flag — the suite is opt-in so it does
# not fire in the default qmltest CI workflow that uses
# QT_QPA_PLATFORM=offscreen).
QDSHELL_UI_TESTS=1 pytest tests/ui -v
```

Run a single surface:

```bash
QDSHELL_UI_TESTS=1 pytest tests/ui -v -k settings_audio
```

Artifacts (PNG screenshots, weston/qdshell logs) land in
`tests/ui/artifacts/`. The directory is recreated on every run; the
PNG of `settings_audio` ends up at `artifacts/settings_audio.png`.

## Coverage

* **22 settings tabs** — all reachable via `settings openTab <name>`.
* **13 slide-out panels** — 11 have first-class IPC; 3 (Audio,
  Brightness, Tray) don't expose a `togglePanel` handler in current
  qdshell.  They appear in the manifest with `NO_IPC` and the test
  uses `pytest.xfail` to flag them rather than silently skip.  To
  enable them, add `togglePanel()` IPC handlers in
  `Services/Control/IPCService.qml` (`target: "audio"`, `"brightness"`,
  `"tray"`).
* **Bar** — one idle screenshot is captured to baseline overall
  bar/dock/widget layout.

## Updating expectations after a refactor

If you intentionally change a surface (e.g. you merge OSD into User
Interface), edit the relevant `expectations/<surface>.md` to reflect
the new contract, commit it, then re-run the suite.

## Why this harness, not pixel diffs

Pixel diffs would tie the test to a specific font / DPI / wallpaper.
Vision + judge tolerates incidental visual drift (a slightly different
gradient, a re-ordered card) while still catching *meaningful*
regressions (a section heading disappeared, a slider lost its label).

## Why headless weston, not the host compositor

* The host here is KWin/Plasma; qdshell is built for Hyprland/Niri and
  would overlap plasmashell unpleasantly.
* CI containers have no GPU; weston headless + pixman software
  rendering works anywhere.
* Tests get a deterministic 1920×1200 framebuffer regardless of host.

## Files

* `runner.py` — primitives: Weston/Qdshell lifecycle, IPC, screenshot,
  describe, judge.
* `manifests.py` — the canonical surface list.
* `conftest.py` — pytest fixtures (`weston`, `qdshell` session-scoped).
* `test_settings_tabs.py`, `test_panels.py`, `test_bar.py` — actual
  test cases.
* `expectations/` — one `.md` per surface.
* `artifacts/` — PNGs + logs from each run (git-ignored).
