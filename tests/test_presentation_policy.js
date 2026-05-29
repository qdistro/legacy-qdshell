const assert = require("assert");
const P = require("../Services/Power/PresentationPolicy.js");

// ─── idempotent inhibitor add/remove ────────────────────────────────
let l = [];
l = P.addInhibitor(l, "presentation-mode");
assert.deepStrictEqual(l, ["presentation-mode"]);
// adding the same id again is a no-op (idempotent)
let l2 = P.addInhibitor(l, "presentation-mode");
assert.deepStrictEqual(l2, ["presentation-mode"]);
// add returns a NEW array (QML reassignment requirement) — not the same ref
assert.notStrictEqual(P.addInhibitor(l, "x"), l);
// removing an absent id is a no-op
assert.deepStrictEqual(P.removeInhibitor(["a"], "b"), ["a"]);
// remove the only id
assert.deepStrictEqual(P.removeInhibitor(["presentation-mode"], "presentation-mode"), []);
// non-array input tolerated
assert.deepStrictEqual(P.addInhibitor(null, "z"), ["z"]);
assert.deepStrictEqual(P.removeInhibitor(undefined, "z"), []);
assert.strictEqual(P.hasInhibitor(["a", "b"], "b"), true);
assert.strictEqual(P.hasInhibitor([], "b"), false);

// ─── presentation-mode toggle ───────────────────────────────────────
assert.deepStrictEqual(P.applyPresentationMode([], true), ["presentation-mode"]);
assert.deepStrictEqual(P.applyPresentationMode(["manual"], true), ["manual", "presentation-mode"]);
// enabling twice idempotent
assert.deepStrictEqual(P.applyPresentationMode(["presentation-mode"], true), ["presentation-mode"]);
// disabling removes only the presentation id, leaves others intact
assert.deepStrictEqual(P.applyPresentationMode(["manual", "presentation-mode"], false), ["manual"]);
// disabling when not present is a no-op
assert.deepStrictEqual(P.applyPresentationMode(["manual"], false), ["manual"]);

// ─── auto-disable minutes clamping ──────────────────────────────────
assert.strictEqual(P.clampAutoDisableMinutes(0), 0);
assert.strictEqual(P.clampAutoDisableMinutes(30), 30);
assert.strictEqual(P.clampAutoDisableMinutes(-5), 0); // negative -> 0
assert.strictEqual(P.clampAutoDisableMinutes(99999), 1440); // capped at 24h
assert.strictEqual(P.clampAutoDisableMinutes("45"), 45); // numeric string
assert.strictEqual(P.clampAutoDisableMinutes(NaN), 0);
assert.strictEqual(P.clampAutoDisableMinutes(12.6), 13); // rounded

// ─── state restore ──────────────────────────────────────────────────
assert.strictEqual(P.shouldRestorePresentationMode(true), true);
assert.strictEqual(P.shouldRestorePresentationMode(false), false);
assert.strictEqual(P.shouldRestorePresentationMode(undefined), false);
assert.strictEqual(P.shouldRestorePresentationMode("true"), false); // strict bool only

// ─── disable-notifications-while-inhibited policy ───────────────────
assert.strictEqual(P.shouldSuppressNotifications(true, true), true);
assert.strictEqual(P.shouldSuppressNotifications(true, false), false);
assert.strictEqual(P.shouldSuppressNotifications(false, true), false);
assert.strictEqual(P.shouldSuppressNotifications(false, false), false);

// ─── viewer rows + INJECTION SAFETY ─────────────────────────────────
// Well-known ids get a "known" key; unknown ids fall back to raw verbatim.
const rows = P.inhibitorRows(["presentation-mode", "manual", "fullscreen", "app:firefox"]);
assert.strictEqual(rows.length, 4);
assert.strictEqual(rows[0].known, "presentation");
assert.strictEqual(rows[1].known, "manual");
assert.strictEqual(rows[2].known, "fullscreen");
assert.strictEqual(rows[3].known, null);
assert.strictEqual(rows[3].id, "app:firefox");

// An inhibitor id is OPAQUE UNTRUSTED text. A malicious app could register an
// id containing shell metacharacters. The policy must pass it through VERBATIM
// (for PlainText rendering) and must NOT transform/escape/eval it, and there
// must be no command-building helper that could interpolate it.
const evil = "$(rm -rf ~); `id`; ;|& <script>alert(1)</script>";
const evilRows = P.inhibitorRows([evil]);
assert.strictEqual(evilRows.length, 1);
assert.strictEqual(evilRows[0].id, evil, "untrusted id must be preserved verbatim, never transformed");
assert.strictEqual(evilRows[0].known, null);
// No exported helper may build a shell command / argv from an inhibitor id.
Object.keys(P).forEach(function (name) {
  assert.ok(!/cmd|command|argv|shell|exec|spawn/i.test(name), "no command-builder export: " + name);
});

// non-array tolerated
assert.deepStrictEqual(P.inhibitorRows(null), []);

console.log("presentation-policy: all assertions passed");
