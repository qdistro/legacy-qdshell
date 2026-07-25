// Lock-screen live-capture indicator logic (J28).
//
// The security property under test is FAIL VISIBLE: every path that does not
// positively establish "nothing is capturing" must render as "unverified", and
// never as a quiet/clear indicator. That covers a dead observer, a stale scan,
// unparsable output, and the kinds whose negative qdistro cannot observe at all
// (camera via a direct /dev/videoN open, a weston_capture_v1 screen grab,
// virtual input — which has no observer whatsoever).
"use strict";

const assert = require("assert");
const C = require("../Services/Qdistro/CaptureState.js");

function node(state, props) {
  return { type: "PipeWire:Interface:Node", id: 1, info: { state: state, props: props } };
}
function dump(objs) {
  return JSON.stringify(objs);
}

// ─── parsing ────────────────────────────────────────────────────────────────
// A failed observation must be distinguishable from an empty graph.
assert.strictEqual(C.parsePwDump("").ok, false);
assert.strictEqual(C.parsePwDump(null).ok, false);
assert.strictEqual(C.parsePwDump(undefined).ok, false);
assert.strictEqual(C.parsePwDump("not json").ok, false);
assert.strictEqual(C.parsePwDump('{"id":1}').ok, false, "a non-array dump is not a graph");
assert.strictEqual(C.parsePwDump("[]").ok, true, "an empty array IS a successful observation");
assert.deepStrictEqual(C.parsePwDump("[]").nodes, []);

const mixed = C.parsePwDump(dump([
  { type: "PipeWire:Interface:Link", id: 7 },
  node("running", { "media.class": "Audio/Sink", "node.name": "sink" }),
]));
assert.strictEqual(mixed.ok, true);
assert.strictEqual(mixed.nodes.length, 1, "non-node objects are dropped");
assert.strictEqual(mixed.nodes[0].state, "running");

// ─── classification ─────────────────────────────────────────────────────────
// Only running nodes are evidence — idle/suspended streams are connected but
// not moving samples.
assert.strictEqual(
  C.classifyNode({ state: "idle", props: { "media.class": "Stream/Input/Audio" } }), null);
assert.strictEqual(
  C.classifyNode({ state: "suspended", props: { "media.class": "Stream/Input/Video" } }), null);

assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Input/Audio" } }).kind,
  "microphone");
// A monitor/loopback capture of the sink is system-audio capture, not the mic.
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Input/Audio", "stream.capture.sink": "1" } }).kind,
  "systemAudio");
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Input/Audio", "stream.capture.sink": true } }).kind,
  "systemAudio");
// "false"/"0"/"" must not be read as truthy by the string-valued prop.
["false", "0", "", "no"].forEach(function (v) {
  assert.strictEqual(
    C.classifyNode({ state: "running", props: { "media.class": "Stream/Input/Audio", "stream.capture.sink": v } }).kind,
    "microphone", "stream.capture.sink=" + JSON.stringify(v) + " must not mean system audio");
});

// Video: camera-ish props win, everything else is treated as screencast.
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Input/Video", "media.role": "Camera" } }).kind,
  "camera");
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Input/Video", "device.api": "libcamera" } }).kind,
  "camera");
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Video/Source", "device.api": "v4l2" } }).kind,
  "camera");
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Input/Video", "application.name": "obs" } }).kind,
  "screencast");
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Output/Video", "node.name": "kwin_wayland" } }).kind,
  "screencast");
// qdwin pins a forwarded toplevel onto a weston backend-pipewire output; a live
// `weston.pipewire-N` node means a remote-display/screencast stream is running.
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "node.name": "weston.pipewire-0" } }).kind,
  "screencast");
// Plain playback is not capture.
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Stream/Output/Audio", "application.name": "mpv" } }), null);
assert.strictEqual(
  C.classifyNode({ state: "running", props: { "media.class": "Audio/Sink" } }), null);

// ─── entries: dedupe + ordering ─────────────────────────────────────────────
const entries = C.captureEntries(C.parsePwDump(dump([
  node("running", { "media.class": "Stream/Input/Video", "application.name": "obs" }),
  node("running", { "media.class": "Stream/Output/Video", "application.name": "obs" }),
  node("running", { "media.class": "Stream/Input/Audio", "application.name": "zoom" }),
  node("running", { "media.class": "Stream/Input/Audio", "application.name": "meet" }),
  node("idle", { "media.class": "Stream/Input/Audio", "application.name": "quiet" }),
])).nodes);
assert.deepStrictEqual(entries.map(e => e.kind + ":" + e.app),
  ["microphone:meet", "microphone:zoom", "screencast:obs"],
  "kind order, then app order, with both ends of one screencast deduped");

// ─── summarise: the fail-visible contract ───────────────────────────────────
// 1. Observer failed → every kind unverified, nothing reads as clear.
const dead = C.summarise(C.parsePwDump(""), { fresh: true });
assert.strictEqual(dead.observerOk, false);
assert.strictEqual(dead.anyActive, false);
assert.strictEqual(dead.activeCount, 0);
assert.deepStrictEqual(dead.unverifiedKinds, C.KINDS, "a dead observer leaves NOTHING clear");
assert.strictEqual(dead.anyUnverified, true);
assert.strictEqual(dead.visible, true, "a dead observer must still show the indicator");
C.KINDS.forEach(function (k) {
  assert.strictEqual(dead.kinds[k].state, "unverified", k + " must not read as clear");
});

// 2. Stale scan → same, even though the parse succeeded.
const stale = C.summarise(C.parsePwDump(dump([
  node("running", { "media.class": "Stream/Input/Audio", "application.name": "zoom" }),
])), { fresh: false });
assert.strictEqual(stale.observerOk, false);
assert.strictEqual(stale.anyActive, false, "stale evidence is not live evidence");
assert.deepStrictEqual(stale.unverifiedKinds, C.KINDS);
assert.strictEqual(stale.visible, true);

// 3. Healthy observer, quiet graph → only the kinds with an authoritative
//    negative may go clear; the blind-spot kinds stay unverified.
const quiet = C.summarise(C.parsePwDump("[]"), { fresh: true });
assert.strictEqual(quiet.observerOk, true);
assert.strictEqual(quiet.anyActive, false);
assert.strictEqual(quiet.kinds.microphone.state, "clear");
assert.strictEqual(quiet.kinds.systemAudio.state, "clear");
assert.deepStrictEqual(quiet.unverifiedKinds, ["camera", "screencast", "virtualInput"]);
assert.strictEqual(quiet.unverifiedLabel, "camera, screen, virtual input");
assert.strictEqual(quiet.visible, true,
  "virtual input has no observer at all, so the cluster is never suppressed");

// 4. Live capture → active kinds, counts, and a truncated label.
const live = C.summarise(C.parsePwDump(dump([
  node("running", { "media.class": "Stream/Input/Audio", "application.name": "zoom" }),
  node("running", { "media.class": "Stream/Input/Video", "media.role": "Camera", "application.name": "zoom" }),
  node("running", { "node.name": "weston.pipewire-0", "application.name": "weston" }),
])), { fresh: true, limit: 2 });
assert.strictEqual(live.observerOk, true);
assert.strictEqual(live.anyActive, true);
assert.strictEqual(live.activeCount, 3);
assert.deepStrictEqual(live.activeKinds, ["microphone", "camera", "screencast"]);
assert.strictEqual(live.activeLabel, "mic:zoom, camera:zoom +1");
assert.strictEqual(live.activeDetail, "mic:zoom, camera:zoom, screen:weston");
assert.strictEqual(live.kinds.microphone.state, "active");
assert.strictEqual(live.kinds.microphone.count, 1);
assert.strictEqual(live.kinds.camera.detail, "camera:zoom");
// systemAudio saw nothing but has an authoritative negative; virtualInput never
// does, so the "?" row is still shown alongside the active rows.
assert.strictEqual(live.kinds.systemAudio.state, "clear");
assert.deepStrictEqual(live.unverifiedKinds, ["virtualInput"]);
assert.strictEqual(live.anyUnverified, true);

// 5. A kind that IS active is never simultaneously reported unverified.
C.KINDS.forEach(function (k) {
  assert.ok(!(live.activeKinds.indexOf(k) !== -1 && live.unverifiedKinds.indexOf(k) !== -1),
    k + " cannot be both active and unverified");
});

// 6. Every kind has display metadata the lock panel can render.
C.KINDS.forEach(function (k) {
  assert.ok(C.KIND_LABELS[k], "missing label for " + k);
  assert.ok(C.KIND_ICONS[k], "missing icon for " + k);
  assert.ok(quiet.kinds[k].icon === C.KIND_ICONS[k]);
  assert.ok(typeof C.NEGATIVE_AUTHORITATIVE[k] === "boolean");
});
// The blind spots are a deliberate, pinned set — flipping one to "authoritative
// negative" silently turns a "?" into a silent all-clear, so it must fail here.
assert.deepStrictEqual(
  C.KINDS.filter(k => !C.NEGATIVE_AUTHORITATIVE[k]),
  ["camera", "screencast", "virtualInput"]);

// 7. Defaults: summarise() with no opts treats the reading as fresh, and a
//    missing/garbage parse result still fails visible.
assert.strictEqual(C.summarise(null).observerOk, false);
assert.deepStrictEqual(C.summarise(undefined).unverifiedKinds, C.KINDS);
assert.strictEqual(C.summarise(C.parsePwDump("[]")).kinds.microphone.state, "clear");

// ─── lock-panel wiring ──────────────────────────────────────────────────────
// Host qmllint cannot resolve the `qs.*` module imports (that needs a GUI VM),
// so these are source-level invariants on the QML rather than a real QML lint:
// they pin the wiring that makes the indicator non-suppressible and post-lock.
const fs = require("fs");
const path = require("path");
const ROOT = path.resolve(__dirname, "..");
const panel = fs.readFileSync(
  path.join(ROOT, "Modules", "LockScreen", "LockScreenPanel.qml"), "utf8");
const service = fs.readFileSync(
  path.join(ROOT, "Services", "Qdistro", "CaptureStateService.qml"), "utf8");

assert.ok(/import qs\.Services\.Qdistro/.test(panel),
  "lock panel must import the service module");
assert.ok(panel.includes("CaptureStateService.markStale()") &&
          panel.includes("CaptureStateService.refresh()"),
  "lock panel must re-observe after the lock instead of inheriting pre-lock state");
// Compact mode: the container is sized and shown for the capture cluster too,
// so it cannot be squeezed out by the other indicators being absent.
assert.ok((panel.match(/CaptureStateService\.indicatorVisible/g) || []).length >= 3,
  "capture cluster must drive compact width, compact visibility and full-mode visibility");
assert.ok(panel.includes("CaptureStateService.activeKinds") &&
          panel.includes("CaptureStateService.anyUnverified"),
  "full panel must render both the active kinds and the unverified ones");
// Non-suppressible: no Settings flag may gate a capture row's visibility.
const captureVisibility = (panel.match(/visible:[^\n]*CaptureStateService[^\n]*/g) || []);
assert.ok(captureVisibility.length >= 3, "expected the capture visibility bindings");
captureVisibility.forEach(function (line) {
  assert.ok(!/Settings\.data\.general\.(?!compactLockScreen)/.test(line),
    "capture indicators must not be gated by a settings toggle: " + line.trim());
});

// The service must never let a failed scan refresh the freshness clock, and
// must have a stale horizon at all.
assert.ok(/if \(next\.ok\)\s*\n\s*root\.lastOkMs = Date\.now\(\);/.test(service),
  "only a usable graph may refresh the freshness clock");
assert.ok(/readonly property bool fresh: lastOkMs > 0 &&/.test(service),
  "freshness must require a successful scan to have happened");

console.log("capture-state: all assertions passed");
process.exit(0);
