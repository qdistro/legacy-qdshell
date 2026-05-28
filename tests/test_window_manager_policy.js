const assert = require("assert");
const WM = require("../Services/Qdwin/WindowManagerPolicy.js");

// ─── Focus policy normalisation ─────────────────────────────────────
assert.strictEqual(WM.normalizeFocusPolicy("click"), "click");
assert.strictEqual(WM.normalizeFocusPolicy("follow-mouse"), "follow-mouse");
assert.strictEqual(WM.normalizeFocusPolicy("FOLLOW-MOUSE"), "follow-mouse", "case-insensitive");
assert.strictEqual(WM.normalizeFocusPolicy("  click  "), "click", "trimmed");
assert.strictEqual(WM.normalizeFocusPolicy("garbage"), "click", "unknown -> click fallback");
assert.strictEqual(WM.normalizeFocusPolicy(undefined), "click", "undefined -> click");
assert.strictEqual(WM.normalizeFocusPolicy(null), "click", "null -> click");
assert.strictEqual(WM.normalizeFocusPolicy(42), "click", "non-string -> click");

// ─── Placement normalisation ────────────────────────────────────────
assert.strictEqual(WM.normalizePlacement("center"), "center");
assert.strictEqual(WM.normalizePlacement("under-mouse"), "under-mouse");
assert.strictEqual(WM.normalizePlacement("smart"), "smart");
assert.strictEqual(WM.normalizePlacement("cascade"), "cascade");
assert.strictEqual(WM.normalizePlacement("Cascade"), "cascade", "case-insensitive");
assert.strictEqual(WM.normalizePlacement(""), "smart", "empty -> smart fallback");
assert.strictEqual(WM.normalizePlacement("tile"), "smart", "unknown -> smart fallback");

// ─── Titlebar action normalisation ──────────────────────────────────
assert.strictEqual(WM.normalizeTitlebarAction("maximize"), "maximize");
assert.strictEqual(WM.normalizeTitlebarAction("shade"), "shade");
assert.strictEqual(WM.normalizeTitlebarAction("minimize"), "minimize");
assert.strictEqual(WM.normalizeTitlebarAction("nothing"), "nothing");
assert.strictEqual(WM.normalizeTitlebarAction("MAXIMIZE"), "maximize", "case-insensitive");
assert.strictEqual(WM.normalizeTitlebarAction("roll-up"), "maximize", "unknown -> maximize fallback");
assert.strictEqual(WM.normalizeTitlebarAction(undefined), "maximize");

// ─── Numeric clamping ───────────────────────────────────────────────
assert.strictEqual(WM.clampFfmDelay(0), 0);
assert.strictEqual(WM.clampFfmDelay(250), 250);
assert.strictEqual(WM.clampFfmDelay(1000), 1000);
assert.strictEqual(WM.clampFfmDelay(-50), 0, "below min clamps to 0");
assert.strictEqual(WM.clampFfmDelay(99999), 1000, "above max clamps to 1000");
assert.strictEqual(WM.clampFfmDelay("abc"), 0, "garbage -> min");
assert.strictEqual(WM.clampFfmDelay(NaN), 0, "NaN -> min");
assert.strictEqual(WM.clampFfmDelay("300"), 300, "numeric string parsed");

assert.strictEqual(WM.clampSnapDistance(16), 16);
assert.strictEqual(WM.clampSnapDistance(1), 1);
assert.strictEqual(WM.clampSnapDistance(64), 64);
assert.strictEqual(WM.clampSnapDistance(0), 1, "below min clamps to 1");
assert.strictEqual(WM.clampSnapDistance(1000), 64, "above max clamps to 64");
assert.strictEqual(WM.clampSnapDistance(Infinity), 1, "Infinity is not a parseable int -> min");
assert.strictEqual(WM.clampSnapDistance(undefined), 1, "undefined -> min");

// ─── Full policy normalisation ──────────────────────────────────────
const norm = WM.normalizePolicy({
    focusPolicy: "FOLLOW-MOUSE",
    focusFollowsMouseDelay: 5000,
    raiseOnClick: 1,
    raiseOnHover: 0,
    placement: "junk",
    snapEnabled: "yes",
    snapDistance: -3,
    titlebarDoubleClick: "shade",
    decorationTheme: "Adwaita-dark"
});
assert.strictEqual(norm.focusPolicy, "follow-mouse");
assert.strictEqual(norm.focusFollowsMouseDelay, 1000, "delay clamped");
assert.strictEqual(norm.raiseOnClick, true, "truthy coerced to bool");
assert.strictEqual(norm.raiseOnHover, false, "falsy coerced to bool");
assert.strictEqual(norm.placement, "smart", "junk placement -> smart");
assert.strictEqual(norm.snapEnabled, true);
assert.strictEqual(norm.snapDistance, 1, "negative snap distance clamped");
assert.strictEqual(norm.titlebarDoubleClick, "shade");
assert.strictEqual(norm.decorationTheme, "Adwaita-dark");

// Empty input yields sane defaults.
const def = WM.normalizePolicy({});
assert.strictEqual(def.focusPolicy, "click");
assert.strictEqual(def.placement, "smart");
assert.strictEqual(def.titlebarDoubleClick, "maximize");
assert.strictEqual(def.snapDistance, 1, "missing snap distance -> min");
assert.strictEqual(def.decorationTheme, "");
const defNoArg = WM.normalizePolicy();
assert.strictEqual(defNoArg.focusPolicy, "click", "undefined raw handled");

// ─── focusFollowsMouseValue mapping ─────────────────────────────────
assert.strictEqual(WM.focusFollowsMouseValue("follow-mouse"), "yes");
assert.strictEqual(WM.focusFollowsMouseValue("click"), "no");
assert.strictEqual(WM.focusFollowsMouseValue("garbage"), "no", "unknown -> no (click default)");

// ─── sway reconfigure command building ──────────────────────────────
const swayCmds = WM.buildSwayReconfigureCommands({
    focusPolicy: "follow-mouse",
    snapEnabled: true
});
// Every command must be a fully-tokenised argv with swaymsg first.
swayCmds.forEach(c => {
    assert.ok(Array.isArray(c), "command is an argv array");
    assert.strictEqual(c[0], "swaymsg", "argv[0] is swaymsg");
});
// focus_follows_mouse yes is emitted.
const ffmCmd = swayCmds.find(c => c[1] === "focus_follows_mouse");
assert.ok(ffmCmd, "focus_follows_mouse command present");
assert.strictEqual(ffmCmd[2], "yes");
// tiling_drag enable when snapping on.
const tdCmd = swayCmds.find(c => c[1] === "tiling_drag");
assert.ok(tdCmd, "tiling_drag command present");
assert.strictEqual(tdCmd[2], "enable");

const swayCmdsOff = WM.buildSwayReconfigureCommands({
    focusPolicy: "click",
    snapEnabled: false
});
assert.strictEqual(swayCmdsOff.find(c => c[1] === "focus_follows_mouse")[2], "no");
assert.strictEqual(swayCmdsOff.find(c => c[1] === "tiling_drag")[2], "disable");

// ─── sway keybind command building ──────────────────────────────────
const kbCmds = WM.buildSwayKeybindCommands({
    shortcutClose: "Alt+F4",
    shortcutToggleMaximize: "Super+Up",
    shortcutToggleFullscreen: "Super+F",
    shortcutTileLeft: "Super+Left",
    shortcutTileRight: "Super+Right"
});
assert.strictEqual(kbCmds.length, 5, "five shortcuts bound");
kbCmds.forEach(c => {
    assert.strictEqual(c[0], "swaymsg");
    assert.strictEqual(c[1], "bindsym");
    assert.ok(typeof c[2] === "string" && c[2].length > 0, "accelerator is one token");
});
assert.strictEqual(kbCmds[0][2], "Alt+F4", "close accelerator passed through verbatim");
// tile-left and tile-right must map to DISTINCT actions.
const tileLeft = kbCmds.find(c => c[2] === "Super+Left");
const tileRight = kbCmds.find(c => c[2] === "Super+Right");
assert.ok(tileLeft && tileRight, "both tile shortcuts present");
assert.notStrictEqual(tileLeft[3], tileRight[3], "tile left/right map to distinct actions");
// Empty accelerators are skipped (no bindsym for an unset shortcut).
const kbPartial = WM.buildSwayKeybindCommands({
    shortcutClose: "Alt+F4",
    shortcutToggleMaximize: "",
    shortcutToggleFullscreen: "",
    shortcutTileLeft: "",
    shortcutTileRight: ""
});
assert.strictEqual(kbPartial.length, 1, "empty accelerators skipped");

// ─── Accelerator validation ─────────────────────────────────────────
assert.strictEqual(WM.isValidAccelerator("Super+Shift+Left"), true);
assert.strictEqual(WM.isValidAccelerator("Alt+F4"), true);
assert.strictEqual(WM.isValidAccelerator("XF86AudioPlay"), true);
assert.strictEqual(WM.isValidAccelerator(""), false, "empty rejected");
assert.strictEqual(WM.isValidAccelerator("Alt+F4 kill"), false, "whitespace rejected");
assert.strictEqual(WM.isValidAccelerator("Alt+F4;exec foo"), false, "semicolon rejected");
assert.strictEqual(WM.isValidAccelerator("a`b`"), false, "backtick rejected");
assert.strictEqual(WM.isValidAccelerator("$(rm)"), false, "command-subst rejected");
assert.strictEqual(WM.isValidAccelerator(undefined), false);

// ─── labwc reconfigure ──────────────────────────────────────────────
const labwcCmd = WM.buildLabwcReconfigureCommand();
assert.deepStrictEqual(labwcCmd, ["labwc", "--reconfigure"],
    "labwc reconfigure is argument-free");

// ─── INJECTION SAFETY ───────────────────────────────────────────────
// An untrusted decoration theme name containing shell metacharacters must
// NEVER reach a raw shell string. The sway command builder does not emit the
// theme name at all, and the labwc reconfigure takes no arguments — so a
// malicious theme name cannot appear in any command argv.
const EVIL = ";rm -rf ~";
const evilPolicy = {
    focusPolicy: "follow-mouse",
    snapEnabled: true,
    decorationTheme: EVIL
};
const evilSway = WM.buildSwayReconfigureCommands(evilPolicy);
evilSway.forEach(argv => {
    argv.forEach(tok => {
        assert.strictEqual(tok.indexOf(EVIL), -1,
            "untrusted theme name must not appear in any sway argv token");
        // Also ensure no shell control characters leaked into a token.
        assert.strictEqual(/[;&|`$]/.test(tok), false,
            "no shell metacharacter in any controlled argv token");
    });
});
// normalizePolicy keeps the evil name verbatim as DATA (single argv element if
// ever used), never interpreting it — proving it is preserved but inert.
assert.strictEqual(WM.normalizePolicy(evilPolicy).decorationTheme, EVIL,
    "theme name preserved as opaque data, not parsed");
// labwc command never carries the theme name.
assert.strictEqual(WM.buildLabwcReconfigureCommand().join(" ").indexOf(EVIL), -1,
    "untrusted theme name must not appear in labwc argv");

// An untrusted SHORTCUT accelerator that embeds sway/shell command separators
// must NEVER reach `swaymsg bindsym` at all. argv separation alone is not
// enough — sway's bindsym parser would split on whitespace, so an accelerator
// like "Alt+F4 kill; exec touch /tmp/pwned" could inject extra sway commands.
// isValidAccelerator() rejects it, so buildSwayKeybindCommands emits NOTHING
// for it (zero commands), proving the malicious string can never be dispatched.
const EVIL_ACCEL = "Alt+F4 kill; exec touch /tmp/pwned";
const evilKb = WM.buildSwayKeybindCommands({
    shortcutClose: EVIL_ACCEL,
    shortcutToggleMaximize: "",
    shortcutToggleFullscreen: "",
    shortcutTileLeft: "",
    shortcutTileRight: ""
});
assert.strictEqual(evilKb.length, 0,
    "malicious accelerator is rejected outright — no bindsym command emitted");
// And no emitted command anywhere contains the evil payload.
WM.buildSwayKeybindCommands({
    shortcutClose: "Alt+F4",
    shortcutToggleMaximize: EVIL_ACCEL,
    shortcutToggleFullscreen: EVIL_ACCEL,
    shortcutTileLeft: "Super+Left",
    shortcutTileRight: "Super+Right"
}).forEach(argv => {
    // No emitted command carries the malicious payload at all.
    argv.forEach(tok => {
        assert.strictEqual(tok.indexOf("pwned"), -1,
            "malicious accelerator payload never appears in any keybind argv");
    });
    // The accelerator token (index 2) — the only user-controlled element — is
    // a validated single token with no separator/metacharacter. (The action
    // token at index 3 is a controlled literal and may contain spaces, e.g.
    // "fullscreen toggle", so it is exempt from this check.)
    assert.strictEqual(/[;&|`$\s]/.test(argv[2]), false,
        "accelerator token has no separator/metacharacter");
});
// normalizePolicy preserves shortcuts verbatim as opaque DATA (never parsed);
// validation/rejection happens only at command-build time.
assert.strictEqual(WM.normalizePolicy({ shortcutClose: EVIL_ACCEL }).shortcutClose,
    EVIL_ACCEL, "shortcut preserved as opaque data, not parsed");

console.log("window-manager-policy: all assertions passed");
