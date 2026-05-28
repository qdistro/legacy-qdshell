const assert = require("assert");
const TaskbarLogic = require("../Modules/Bar/Widgets/TaskbarLogic.js");

// Build a plain "running window" entry like updateCombinedModel() produces.
// `win` carries the window-object stand-in (identity + isFocused).
function runEntry(id, appId, title, isFocused) {
  return {
    "id": id,
    "type": "running",
    "window": { "id": id, "isFocused": !!isFocused },
    "appId": appId,
    "title": title,
  };
}

// A pinned-not-running / placeholder entry (window === null) is never grouped.
function pinnedEntry(id, appId, title) {
  return { "id": id, "type": "pinned", "window": null, "appId": appId, "title": title };
}

function ids(entries) {
  return entries.map(function (e) { return e.id; });
}

function noDuplicateIds(entries) {
  const seen = new Set();
  entries.forEach(function (e) {
    assert.ok(!seen.has(e.id), "duplicate entry id in output: " + e.id);
    seen.add(e.id);
  });
}

// ── grouping "never": every window stays its own button, order preserved ──
(function testGroupingNever() {
  const wins = [
    runEntry("a1", "firefox", "Firefox 1"),
    runEntry("a2", "firefox", "Firefox 2"),
    runEntry("b1", "kitty", "kitty"),
  ];
  const grouping = TaskbarLogic.shouldGroup(wins.length, { "groupingMode": "never" });
  assert.strictEqual(grouping, false);
  // "never" -> caller does not group; the model equals the input order.
  assert.deepStrictEqual(ids(wins), ["a1", "a2", "b1"]);
})();

// ── grouping "always": same appId collapses into one group with the right
// member count; empty/undefined appId windows are NOT grouped together ──
(function testGroupingAlways() {
  const wins = [
    runEntry("a1", "firefox", "Firefox 1"),
    runEntry("a2", "firefox", "Firefox 2", true),
    runEntry("b1", "kitty", "kitty"),
    runEntry("a3", "firefox", "Firefox 3"),
  ];
  assert.strictEqual(TaskbarLogic.shouldGroup(wins.length, { "groupingMode": "always" }), true);

  const out = TaskbarLogic.groupApps(wins);
  // firefox group emitted once at the slot of its first member, then kitty.
  assert.strictEqual(out.length, 2);
  noDuplicateIds(out);

  const ff = out[0];
  assert.strictEqual(ff.isGroup, true);
  assert.strictEqual(ff.appId, "firefox");
  assert.strictEqual(ff.windows.length, 3, "firefox group should have 3 members");
  assert.strictEqual(ff.windowEntries.length, 3);
  // Representative title/window comes from the focused member (a2).
  assert.strictEqual(ff.title, "Firefox 2");
  assert.strictEqual(ff.window.id, "a2");

  // kitty stays an individual entry (single window collapses back to plain).
  assert.strictEqual(out[1].id, "b1");
  assert.strictEqual(out[1].isGroup, undefined);
})();

// ── empty / undefined appId guard: such windows must NEVER be grouped
// together — each stays a separate button ──
(function testEmptyAppIdNotGrouped() {
  const wins = [
    runEntry("e1", "", "Untitled A"),
    runEntry("e2", undefined, "Untitled B"),
    runEntry("e3", "   ", "Whitespace"),   // normalizes to "" too
    runEntry("ff1", "firefox", "Firefox 1"),
    runEntry("ff2", "firefox", "Firefox 2"),
  ];
  const out = TaskbarLogic.groupApps(wins);
  noDuplicateIds(out);
  // e1, e2, e3 each stay their own button; firefox collapses to one group
  // (a multi-window group carries the synthetic id "group:firefox").
  assert.deepStrictEqual(ids(out), ["e1", "e2", "e3", "group:firefox"]);
  // None of the empty-appId entries became a group.
  ["e1", "e2", "e3"].forEach(function (id) {
    const e = out.find(function (x) { return x.id === id; });
    assert.notStrictEqual(e, undefined);
    assert.notStrictEqual(e.isGroup, true, id + " must not be a group");
  });
  // The single firefox group carries both members.
  const ff = out.find(function (x) { return x.isGroup === true; });
  assert.strictEqual(ff.windows.length, 2);
})();

// ── pinned-not-running / placeholder entries pass through ungrouped and keep
// their slot ──
(function testNonRunningPassThrough() {
  const wins = [
    runEntry("ff1", "firefox", "Firefox 1"),
    pinnedEntry("pin-kitty", "kitty", "kitty"),
    runEntry("ff2", "firefox", "Firefox 2"),
  ];
  const out = TaskbarLogic.groupApps(wins);
  noDuplicateIds(out);
  // firefox group emitted at the first firefox slot; pinned keeps its slot.
  assert.strictEqual(out.length, 2);
  assert.strictEqual(out[0].isGroup, true);
  assert.strictEqual(out[0].appId, "firefox");
  assert.strictEqual(out[1].id, "pin-kitty");
  assert.strictEqual(out[1].isGroup, undefined);
})();

// ── grouping "limited": groups only when the width budget is exceeded; else
// behaves like "never" ──
(function testGroupingLimited() {
  // 5 entries, budget fits ~3 (perEntry without titles = itemSize + marginXL).
  const opts = {
    "groupingMode": "limited",
    "isVerticalBar": false,
    "maxTaskbarWidth": 300,
    "showTitle": false,
    "itemSize": 40,
    "marginXL": 60,   // perEntry = 100 -> fits floor(300/100) = 3
    "marginS": 0,
    "titleWidth": 0,
  };
  // Under budget (3 entries) -> no grouping.
  assert.strictEqual(TaskbarLogic.shouldGroup(3, opts), false);
  // Over budget (5 entries) -> grouping.
  assert.strictEqual(TaskbarLogic.shouldGroup(5, opts), true);

  // Vertical bar or no width cap -> never groups in limited mode.
  assert.strictEqual(TaskbarLogic.shouldGroup(50, Object.assign({}, opts, { "isVerticalBar": true })), false);
  assert.strictEqual(TaskbarLogic.shouldGroup(50, Object.assign({}, opts, { "maxTaskbarWidth": 0 })), false);

  // When titles are shown, per-entry width includes spacing + titleWidth.
  const optsTitled = Object.assign({}, opts, { "showTitle": true, "marginS": 4, "titleWidth": 56 });
  // perEntry = 40 + 4 + 56 + 60 = 160 -> fits floor(300/160) = 1.
  assert.strictEqual(TaskbarLogic.shouldGroup(1, optsTitled), false);
  assert.strictEqual(TaskbarLogic.shouldGroup(2, optsTitled), true);
})();

// ── sort "none": preserves launch/stable order (returns entries unchanged) ──
(function testSortNone() {
  const wins = [
    runEntry("z", "zed", "Zed"),
    runEntry("a", "alpha", "Alpha"),
    runEntry("m", "mid", "Mid"),
  ];
  const out = TaskbarLogic.applySortMode(wins, "none");
  assert.deepStrictEqual(ids(out), ["z", "a", "m"]);
  noDuplicateIds(out);
})();

// ── sort "title": orders by window title (case-insensitive) ──
(function testSortTitle() {
  const wins = [
    runEntry("z", "zed", "Zebra"),
    runEntry("a", "alpha", "apple"),
    runEntry("m", "mid", "Mango"),
  ];
  const out = TaskbarLogic.applySortMode(wins, "title");
  assert.deepStrictEqual(out.map(function (e) { return e.title; }), ["apple", "Mango", "Zebra"]);
  noDuplicateIds(out);
  // Non-mutating: input order preserved.
  assert.deepStrictEqual(ids(wins), ["z", "a", "m"]);
})();

// ── sort "group": orders by appId, then keeps members together (then title) ──
(function testSortGroup() {
  const wins = [
    runEntry("k1", "kitty", "kitty B"),
    runEntry("f1", "firefox", "Firefox 2"),
    runEntry("k2", "kitty", "kitty A"),
    runEntry("f2", "firefox", "Firefox 1"),
  ];
  const out = TaskbarLogic.applySortMode(wins, "group");
  noDuplicateIds(out);
  // firefox before kitty; within each app, members are adjacent and
  // ordered by title.
  assert.deepStrictEqual(out.map(function (e) { return e.appId; }), ["firefox", "firefox", "kitty", "kitty"]);
  assert.deepStrictEqual(out.map(function (e) { return e.title; }), ["Firefox 1", "Firefox 2", "kitty A", "kitty B"]);
})();

// ── single ordered pass with no duplicated entries (regression guard) ──
(function testNoDuplicationRegression() {
  const wins = [
    runEntry("a1", "firefox", "Firefox 1"),
    runEntry("b1", "kitty", "kitty 1"),
    runEntry("a2", "firefox", "Firefox 2"),
    runEntry("b2", "kitty", "kitty 2"),
    runEntry("a3", "firefox", "Firefox 3"),
  ];
  const out = TaskbarLogic.groupApps(wins);
  noDuplicateIds(out);
  // Two groups only, emitted at the slot of each group's first member.
  assert.strictEqual(out.length, 2);
  assert.strictEqual(out[0].appId, "firefox");
  assert.strictEqual(out[1].appId, "kitty");
  // Total members across the output equals the input running-window count.
  const totalMembers = out.reduce(function (n, e) {
    return n + (e.isGroup ? e.windows.length : 1);
  }, 0);
  assert.strictEqual(totalMembers, wins.length);
})();

// ── prototype-pollution guard: app ids that collide with Object.prototype
// member names (toString / __proto__ / hasOwnProperty) must group like any
// other key, not corrupt or suppress emission ──
(function testPrototypePollutionKeys() {
  const wins = [
    runEntry("p1", "__proto__", "Proto 1"),
    runEntry("p2", "__proto__", "Proto 2"),
    runEntry("t1", "toString", "ToStr 1"),
    runEntry("t2", "toString", "ToStr 2"),
    runEntry("h1", "hasOwnProperty", "HasOwn 1"),
  ];
  const out = TaskbarLogic.groupApps(wins);
  noDuplicateIds(out);
  // __proto__ and toString each collapse to a 2-member group; hasOwnProperty
  // stays a single plain entry. Order preserved at first-member slots.
  assert.strictEqual(out.length, 3);
  assert.strictEqual(out[0].appId, "__proto__");
  assert.strictEqual(out[0].isGroup, true);
  assert.strictEqual(out[0].windows.length, 2);
  assert.strictEqual(out[1].appId, "toString");
  assert.strictEqual(out[1].isGroup, true);
  assert.strictEqual(out[1].windows.length, 2);
  assert.strictEqual(out[2].id, "h1");
  assert.notStrictEqual(out[2].isGroup, true);
})();

// ── normalizeAppId guard behavior ──
(function testNormalizeAppId() {
  assert.strictEqual(TaskbarLogic.normalizeAppId(undefined), "");
  assert.strictEqual(TaskbarLogic.normalizeAppId(null), "");
  assert.strictEqual(TaskbarLogic.normalizeAppId(""), "");
  assert.strictEqual(TaskbarLogic.normalizeAppId(123), "");
  assert.strictEqual(TaskbarLogic.normalizeAppId("  Firefox  "), "firefox");
})();

console.log("taskbar-logic: all assertions passed");
