// Pure taskbar grouping / sort logic, extracted from Taskbar.qml so it can be
// unit-tested under Node (see tests/test_taskbar_logic.js) while still being
// imported from QML (`import "TaskbarLogic.js" as TaskbarLogic`).
//
// Everything here operates ONLY on a plain entries array plus plain
// settings/value arguments. There is NO access to the Qdwin / Process /
// Settings / Style singletons — the QML side reads those and passes the
// resulting primitives in. This keeps the functions deterministic and
// testable, and keeps the no-duplication / empty-appId guards in one place.

// Normalize an app id for case-insensitive matching. Empty/missing/non-string
// ids collapse to "" — callers MUST treat "" as "no group key" so that
// unrelated windows with a missing appId are never lumped together.
function normalizeAppId(appId) {
  if (!appId || typeof appId !== "string")
    return "";
  return appId.toLowerCase().trim();
}

// Decide whether grouping should be active right now, given a plain options
// bag (no singletons). Mirrors the QML shouldGroup():
//   - "always" -> on
//   - "never"  -> off
//   - "limited" -> on only when the ungrouped button count would overflow the
//     width budget. Only meaningful on a horizontal bar with a positive width
//     cap; otherwise off.
// opts: { groupingMode, isVerticalBar, maxTaskbarWidth, showTitle, itemSize,
//         titleWidth, marginS, marginXL }
function shouldGroup(entryCount, opts) {
  opts = opts || {};
  if (opts.groupingMode === "always")
    return true;
  if (opts.groupingMode === "limited") {
    if (opts.isVerticalBar || !(opts.maxTaskbarWidth > 0))
      return false;
    var itemSize = opts.itemSize || 0;
    var marginS = opts.marginS || 0;
    var marginXL = opts.marginXL || 0;
    var titleWidth = opts.titleWidth || 0;
    // Same estimate as the delegate's Layout.preferredWidth so "fits" matches
    // the real layout: with titles a button is itemSize + spacing + titleWidth
    // + margins; without titles it is itemSize + margins.
    var perEntry = opts.showTitle ? (itemSize + marginS + titleWidth + marginXL) : (itemSize + marginXL);
    if (!(perEntry > 0))
      return false;
    var fits = Math.max(1, Math.floor(opts.maxTaskbarWidth / perEntry));
    return entryCount > fits;
  }
  return false;
}

// Is this entry a running window button (the only thing we ever group)?
// Pinned-not-running and cold-start placeholder entries are never grouped.
function isRunningWindowEntry(e) {
  return !!(e && e.window && (e.type === "running" || e.type === "pinned-running"));
}

// Collapse entries that share a normalized appId into a single group entry,
// preserving the ORIGINAL order and emitting each entry exactly once.
//
// Guards:
//   - Windows with an empty/missing appId (normalizeAppId -> "") are NEVER
//     grouped: each stays its own individual button.
//   - Non-running entries (pinned-only / placeholder) pass through untouched.
//   - A group with a single window collapses back to the plain entry so it
//     keeps the normal single-window code paths.
//   - Each group is emitted once, at the slot of its first member (regression
//     guard: an earlier version duplicated grouped entries).
function groupApps(entries) {
  entries = entries || [];
  // Null-prototype maps so app ids like "toString" / "__proto__" / "hasOwnProperty"
  // are treated as ordinary keys and never collide with Object.prototype members
  // (which would corrupt grouping or suppress emission).
  var groups = Object.create(null);

  // First pass: accumulate members per app key.
  entries.forEach(function (e) {
    if (!isRunningWindowEntry(e))
      return;
    var key = normalizeAppId(e.appId);
    if (key === "")
      return;
    if (!groups[key]) {
      groups[key] = {
        "id": "group:" + key,
        "type": e.type,
        "window": e.window,
        "appId": e.appId,
        "title": e.title,
        "isGroup": true,
        "windows": [e.window],
        "windowEntries": [e]
      };
    } else {
      var g = groups[key];
      g.windows.push(e.window);
      g.windowEntries.push(e);
      // Prefer the focused window for the representative title/icon.
      if (e.window && e.window.isFocused) {
        g.window = e.window;
        g.title = e.title;
      }
      if (e.type === "pinned-running")
        g.type = "pinned-running";
    }
  });

  // Second pass: emit in original order, each entry exactly once.
  var result = [];
  var emittedGroups = Object.create(null);
  entries.forEach(function (e) {
    if (!isRunningWindowEntry(e)) {
      result.push(e);
      return;
    }
    var key = normalizeAppId(e.appId);
    var g = (key !== "") ? groups[key] : null;
    if (!g) {
      // Empty/missing appId — never grouped, emit as an individual button.
      result.push(e);
      return;
    }
    if (emittedGroups[key])
      return;
    emittedGroups[key] = true;
    if (g.windows.length === 1)
      result.push(g.windowEntries[0]);
    else
      result.push(g);
  });
  return result;
}

// Apply the configured sort order. "none" preserves the launch/session order
// (handled by the caller, so we return the entries unchanged here); "title"
// sorts by visible title; "group" sorts by appId then title. A non-mutating
// copy is returned for the sorting modes.
function applySortMode(entries, sortMode) {
  entries = entries || [];
  if (sortMode === "title") {
    return entries.slice().sort(function (a, b) {
      return ((a && a.title) || "").toLowerCase().localeCompare(((b && b.title) || "").toLowerCase());
    });
  }
  if (sortMode === "group") {
    return entries.slice().sort(function (a, b) {
      var ka = normalizeAppId(a && a.appId);
      var kb = normalizeAppId(b && b.appId);
      if (ka !== kb)
        return ka.localeCompare(kb);
      return ((a && a.title) || "").toLowerCase().localeCompare(((b && b.title) || "").toLowerCase());
    });
  }
  // "none" — preserve session/launch order.
  return entries;
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeAppId: normalizeAppId,
    shouldGroup: shouldGroup,
    isRunningWindowEntry: isRunningWindowEntry,
    groupApps: groupApps,
    applySortMode: applySortMode,
  };
}
