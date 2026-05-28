// WindowManagerPolicy — pure, side-effect-free helpers extracted from
// WindowManagerService.qml. NO Process / Settings / Quickshell access: only
// string/array transforms and enum normalisation. Usable from both QML
// (import "WindowManagerPolicy.js" as WMPolicy) and Node
// (require("./WindowManagerPolicy.js")) so the policy/command-building logic
// can be unit-tested headless.
//
// Responsibilities:
//   1. Normalise/validate the window-manager policy enums (focus policy,
//      new-window placement, titlebar double-click action) to canonical
//      tokens, with safe fallbacks for unknown/garbage input.
//   2. Clamp the numeric policy values (focus-follows-mouse delay, snap
//      distance) into their valid ranges.
//   3. Build a backend reconfigure command (labwc / sway-style) as a
//      fully-tokenised argv array. There is NO `sh -c`; every token is a
//      separate array element, so untrusted strings (e.g. a decoration theme
//      name like `;rm -rf ~`) are passed as a single literal argv element and
//      can NEVER be re-parsed by a shell.

// ─── Enum vocabularies ───────────────────────────────────────────────
var FOCUS_POLICIES = ["click", "follow-mouse"];
var PLACEMENTS = ["center", "under-mouse", "smart", "cascade"];
var TITLEBAR_ACTIONS = ["maximize", "shade", "minimize", "nothing"];

// ─── Bounds (mirror the NSpinBox/NValueSlider limits in the QML tab) ──
var FFM_DELAY_MIN = 0;     // ms
var FFM_DELAY_MAX = 1000;  // ms
var SNAP_DISTANCE_MIN = 1; // px
var SNAP_DISTANCE_MAX = 64; // px

function _normEnum(value, vocab, fallback) {
    var v = String(value === undefined || value === null ? "" : value).trim().toLowerCase();
    for (var i = 0; i < vocab.length; i++) {
        if (vocab[i] === v)
            return v;
    }
    return fallback;
}

// Focus policy: "click" (click-to-focus) | "follow-mouse"
// (focus-follows-mouse). Anything else falls back to click-to-focus, the
// conservative default.
function normalizeFocusPolicy(value) {
    return _normEnum(value, FOCUS_POLICIES, "click");
}

// New-window placement strategy.
function normalizePlacement(value) {
    return _normEnum(value, PLACEMENTS, "smart");
}

// Titlebar double-click action canonical token.
function normalizeTitlebarAction(value) {
    return _normEnum(value, TITLEBAR_ACTIONS, "maximize");
}

// Clamp an integer into [min,max]; non-finite/garbage -> min.
function _clampInt(value, min, max) {
    var n = parseInt(value, 10);
    if (!isFinite(n))
        n = min;
    if (n < min)
        n = min;
    if (n > max)
        n = max;
    return n;
}

function clampFfmDelay(value) {
    return _clampInt(value, FFM_DELAY_MIN, FFM_DELAY_MAX);
}

function clampSnapDistance(value) {
    return _clampInt(value, SNAP_DISTANCE_MIN, SNAP_DISTANCE_MAX);
}

// Coerce an untrusted free-text value (theme name, shortcut accelerator) to a
// string. Kept verbatim as DATA — it has no shell meaning when placed in a
// single argv element. We NEVER concatenate it into a shell string.
function _str(value) {
    return String(value === undefined || value === null ? "" : value);
}

// Produce a fully-normalised policy object from a raw settings-shaped object.
// Booleans are coerced with !! so any truthy/falsy persisted value is sane.
function normalizePolicy(raw) {
    raw = raw || {};
    return {
        focusPolicy: normalizeFocusPolicy(raw.focusPolicy),
        focusFollowsMouseDelay: clampFfmDelay(raw.focusFollowsMouseDelay),
        raiseOnClick: !!raw.raiseOnClick,
        raiseOnHover: !!raw.raiseOnHover,
        placement: normalizePlacement(raw.placement),
        snapEnabled: !!raw.snapEnabled,
        snapDistance: clampSnapDistance(raw.snapDistance),
        titlebarDoubleClick: normalizeTitlebarAction(raw.titlebarDoubleClick),
        // Decoration theme name is UNTRUSTED free text — kept as-is here (no
        // shell meaning in an argv element) but never trusted into a shell.
        decorationTheme: _str(raw.decorationTheme),
        // WM keyboard shortcut accelerators are likewise UNTRUSTED free text.
        shortcutClose: _str(raw.shortcutClose),
        shortcutToggleMaximize: _str(raw.shortcutToggleMaximize),
        shortcutToggleFullscreen: _str(raw.shortcutToggleFullscreen),
        shortcutTileLeft: _str(raw.shortcutTileLeft),
        shortcutTileRight: _str(raw.shortcutTileRight)
    };
}

// ─── Backend reconfigure command (argv) building ─────────────────────
// Map the focus policy onto a sway-style `focus_follows_mouse` value.
function focusFollowsMouseValue(focusPolicy) {
    return normalizeFocusPolicy(focusPolicy) === "follow-mouse" ? "yes" : "no";
}

// Build the ordered list of backend reconfigure argv arrays for a sway-style
// compositor. Each entry is its OWN argv array — there is NO `sh -c`, so no
// element is shell-parsed. The decoration theme name is passed as a single
// literal argv element (never concatenated into a string), so shell
// metacharacters in it are inert.
//
// Settings with no sway equivalent are intentionally omitted (persist-only)
// rather than emitting inert commands.
function buildSwayReconfigureCommands(policy) {
    var p = normalizePolicy(policy);
    var cmds = [];

    // Focus-follows-mouse on/off.
    cmds.push(["swaymsg", "focus_follows_mouse", focusFollowsMouseValue(p.focusPolicy)]);

    // Edge tiling / snapping. sway uses smart_borders + a tiling drag toggle;
    // we map the snap toggle onto `tiling_drag` which is the closest live
    // equivalent and accepts a literal on/off token.
    cmds.push(["swaymsg", "tiling_drag", p.snapEnabled ? "enable" : "disable"]);

    return cmds;
}

// A keybinding accelerator is a `+`-joined list of modifier/key tokens, e.g.
// "Super+Shift+Left". We VALIDATE it against a strict allowlist before it ever
// reaches `swaymsg bindsym`: not only must it survive argv separation (no
// `sh -c`), it must ALSO not contain whitespace or any character sway's
// bindsym parser would treat as a command separator — otherwise an accelerator
// like "Alt+F4 kill; exec touch /tmp/pwned" could inject extra sway commands.
// Allowed: ASCII letters, digits, `+`, `_`, and `-` only. Anything else makes
// the whole accelerator invalid (rejected, never emitted).
var _ACCEL_RE = /^[A-Za-z0-9_+-]+$/;

function isValidAccelerator(accel) {
    var a = String(accel === undefined || accel === null ? "" : accel);
    if (a.length === 0)
        return false;
    return _ACCEL_RE.test(a);
}

// Build the ordered list of `swaymsg bindsym <accelerator> <action>` argv
// arrays for the WM keyboard shortcuts. Each entry is its OWN argv array —
// there is NO `sh -c`. The accelerator strings are UNTRUSTED user input, so in
// addition to argv separation we REJECT any accelerator that fails
// isValidAccelerator() (which excludes whitespace and sway command separators
// like `;`), defending against sway-command injection — not just shell
// injection. Invalid or empty accelerators are skipped (no bindsym emitted).
// The action is always a controlled literal, never derived from user input.
function buildSwayKeybindCommands(policy) {
    var p = normalizePolicy(policy);
    var binds = [
        [p.shortcutClose, "kill"],
        // sway has no single "maximize"; fullscreen is the closest live action.
        [p.shortcutToggleMaximize, "fullscreen toggle"],
        [p.shortcutToggleFullscreen, "fullscreen toggle global"],
        // Tiling left/right: split then focus the appropriate sibling so the
        // two shortcuts produce distinct behaviour.
        [p.shortcutTileLeft, "move left"],
        [p.shortcutTileRight, "move right"]
    ];
    var cmds = [];
    for (var i = 0; i < binds.length; i++) {
        var accel = binds[i][0];
        if (!isValidAccelerator(accel))
            continue;
        // accel is a validated single token; action is a controlled literal.
        cmds.push(["swaymsg", "bindsym", accel, binds[i][1]]);
    }
    return cmds;
}

// Build a labwc theme-apply argv. labwc reads its theme name from a config
// file rather than a live IPC, so the "apply" we can do safely is to ask labwc
// to reconfigure after the config has been written. The theme name itself is
// NEVER interpolated into a command — it is written to config by the caller
// and only the (argument-free) reconfigure signal is dispatched here. We still
// accept the name so callers can log it, but it is returned separately and is
// NOT part of the argv.
function buildLabwcReconfigureCommand() {
    // `labwc --reconfigure` re-reads themerc/rc.xml. No untrusted data in argv.
    return ["labwc", "--reconfigure"];
}

if (typeof module !== "undefined") {
    module.exports = {
        FOCUS_POLICIES: FOCUS_POLICIES,
        PLACEMENTS: PLACEMENTS,
        TITLEBAR_ACTIONS: TITLEBAR_ACTIONS,
        FFM_DELAY_MIN: FFM_DELAY_MIN,
        FFM_DELAY_MAX: FFM_DELAY_MAX,
        SNAP_DISTANCE_MIN: SNAP_DISTANCE_MIN,
        SNAP_DISTANCE_MAX: SNAP_DISTANCE_MAX,
        normalizeFocusPolicy: normalizeFocusPolicy,
        normalizePlacement: normalizePlacement,
        normalizeTitlebarAction: normalizeTitlebarAction,
        clampFfmDelay: clampFfmDelay,
        clampSnapDistance: clampSnapDistance,
        normalizePolicy: normalizePolicy,
        focusFollowsMouseValue: focusFollowsMouseValue,
        isValidAccelerator: isValidAccelerator,
        buildSwayReconfigureCommands: buildSwayReconfigureCommands,
        buildSwayKeybindCommands: buildSwayKeybindCommands,
        buildLabwcReconfigureCommand: buildLabwcReconfigureCommand,
    };
}
