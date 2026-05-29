const assert = require("assert");
const B = require("../Services/Power/BrightnessPolicy.js");

// ─── clamp 0..100 ───────────────────────────────────────────────────
assert.strictEqual(B.clampPercent(50), 50);
assert.strictEqual(B.clampPercent(0), 0);
assert.strictEqual(B.clampPercent(100), 100);
assert.strictEqual(B.clampPercent(-10), 0);    // below range
assert.strictEqual(B.clampPercent(150), 100);  // above range
assert.strictEqual(B.clampPercent(33.6), 34);  // rounds
assert.strictEqual(B.clampPercent(NaN), 0);    // NaN -> safe floor
assert.strictEqual(B.clampPercent("80"), 80);  // numeric string
assert.strictEqual(B.clampPercent(undefined), 0);

// ─── percent <-> fraction ───────────────────────────────────────────
assert.strictEqual(B.percentToFraction(50), 0.5);
assert.strictEqual(B.percentToFraction(0), 0);
assert.strictEqual(B.percentToFraction(100), 1);
assert.strictEqual(B.percentToFraction(200), 1);   // clamped first
assert.strictEqual(B.fractionToPercent(0.5), 50);
assert.strictEqual(B.fractionToPercent(1), 100);
assert.strictEqual(B.fractionToPercent(1.5), 100); // clamped
assert.strictEqual(B.fractionToPercent(-0.2), 0);
assert.strictEqual(B.fractionToPercent(NaN), 0);

// ─── target for power source ────────────────────────────────────────
// On AC always the normal level.
assert.strictEqual(B.targetPercentForSource(true, true, 80, 30), 80);
assert.strictEqual(B.targetPercentForSource(true, false, 80, 30), 80);
// On battery + enabled -> reduced.
assert.strictEqual(B.targetPercentForSource(false, true, 80, 30), 30);
// On battery + disabled -> normal (no reduction).
assert.strictEqual(B.targetPercentForSource(false, false, 80, 30), 80);
// out-of-range levels are clamped
assert.strictEqual(B.targetPercentForSource(false, true, 80, 999), 100);
assert.strictEqual(B.targetPercentForSource(false, true, 80, -5), 0);

// ─── transition resolution ──────────────────────────────────────────
// Disabled feature never applies.
let t = B.resolveTransition(false, false, 80, 30);
assert.strictEqual(t.apply, false);
// Transition to battery (enabled) applies reduced fraction.
t = B.resolveTransition(false, true, 80, 30);
assert.strictEqual(t.apply, true);
assert.strictEqual(t.fraction, 0.3);
// Transition to AC (enabled) restores normal fraction.
t = B.resolveTransition(true, true, 80, 30);
assert.strictEqual(t.apply, true);
assert.strictEqual(t.fraction, 0.8);
// Edge: reduced level clamps into a valid 0..1 fraction even if mis-set.
t = B.resolveTransition(false, true, 80, 250);
assert.strictEqual(t.fraction, 1);

console.log("brightness-policy: all assertions passed");
