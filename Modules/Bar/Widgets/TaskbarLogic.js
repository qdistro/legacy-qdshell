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

// --- qdistro isolation menu (D16 v1) -------------------------------------
// A per-window "qdistro" section for the taskbar context menu: shows the
// window's silo identity (silo, isolation tier, secctx) and offers
// snapshot / dispose / permissions actions. Pure: identity in, menu-model
// rows out — the QML side reads Qdwin window fields and passes the
// primitives, and dispatches the returned actions.

// Human-readable isolation tier from the secctx identity. The app_id /
// sandbox_engine prefix encodes the tier (see doc/isolation-tiers.md and the
// secctx contract): qdistro.disp.<token> = a tier-2 disposable;
// qdistro.tier4.<vm> = per-app VM; qdistro.tier3.<silo> = waypipe VM app;
// qdistro.tier2 = rootless container. An empty identity is a native window.
function siloTierLabel(secctxAppId, sandboxEngine) {
  var id = (secctxAppId || "") + "";
  var eng = (sandboxEngine || "") + "";
  if (id.indexOf("qdistro.disp.") === 0)
    return "disposable (tier 2)";
  if (id.indexOf("qdistro.tier5.") === 0 || eng.indexOf("qdistro.tier5") === 0)
    return "tier 5 (VM)";
  if (id.indexOf("qdistro.tier4.") === 0 || eng.indexOf("qdistro.tier4") === 0)
    return "tier 4 (VM)";
  if (id.indexOf("qdistro.tier3.") === 0 || eng.indexOf("qdistro.tier3") === 0)
    return "tier 3 (VM app)";
  if (eng.indexOf("qdistro.tier2") === 0 || id.indexOf("qdistro.tier2") === 0)
    return "tier 2 (container)";
  if (!id && !eng)
    return "native (tier 0/1)";
  return "sandboxed";
}

// A window is a disposable iff its secctx app_id is qdistro.disp.<token>.
// That is the authoritative, host-assigned signal (the same one the broker
// gates on). We deliberately do NOT also match on a "disp-" silo name: the
// derived silo for a disposable is "tier2/qdistro.disp.<token>", never a bare
// "disp-…", so a silo-name check would be dead code AND could false-positive
// on a persistent silo that merely happens to be named "disp-something".
function isDisposableWindow(identity) {
  if (!identity)
    return false;
  var id = (identity.secctxAppId || "") + "";
  return id.indexOf("qdistro.disp.") === 0;
}

// Build the qdistro section of the taskbar context menu for one window's
// identity. Returns [] for a native window (no secctx identity at all) so
// the menu is UNCHANGED for non-silo apps. Identity rows are disabled
// (informational, "show identity"); snapshot / dispose / permissions are
// live actions the QML onTriggered handler dispatches. `dispose` only
// appears for disposable windows.
function buildIsolationMenuItems(identity) {
  identity = identity || {};
  var secctx = (identity.secctxAppId || "") + "";
  var engine = (identity.sandboxEngine || "") + "";
  var silo = (identity.silo || "") + "";
  // Native window: no isolation identity -> no qdistro section.
  if (!secctx && !engine && !silo)
    return [];
  var tier = siloTierLabel(secctx, engine);
  var disposable = isDisposableWindow(identity);
  var items = [];
  // Identity (disabled, informational rows).
  items.push({ "label": "qdistro silo", "action": "qd-header",
               "icon": "shield", "enabled": false, "isQdistro": true });
  items.push({ "label": "Silo: " + (silo || "(unnamed)"),
               "action": "qd-id-silo", "enabled": false, "isQdistro": true });
  items.push({ "label": "Isolation: " + tier,
               "action": "qd-id-tier", "enabled": false, "isQdistro": true });
  if (secctx)
    items.push({ "label": "Context: " + secctx, "action": "qd-id-secctx",
                 "enabled": false, "isQdistro": true });
  // Actions.
  items.push({ "label": "Snapshot now", "action": "qd-snapshot",
               "icon": "camera", "isQdistro": true });
  if (disposable)
    items.push({ "label": "Dispose", "action": "qd-dispose",
                 "icon": "trash-2", "isQdistro": true });
  items.push({ "label": "Permissions…", "action": "qd-permissions",
               "icon": "lock", "isQdistro": true });
  return items;
}

// Decide HOW the taskbar should dispose a window when the user picks
// "Dispose". A disposable window whose `instanceId` carries a well-formed
// launch token (== the container's `qdistro_tier2_token` label, the spawn-time
// LAUNCH_TOKEN — NOT the independent random hex inside the secctx app_id) is
// torn down by token: qdshell asks the session manager to resolve the token to
// its container and remove it (an explicit, admin-gated, audited lease
// teardown). A disposable window with no usable token on the wire (e.g. an
// untagged admin-driven spawn) falls back to window-close, which exits the app
// and lets `--rm` / the startup reaper tear the container down. A
// non-disposable window is never disposed (`dispose: false`). The token regex
// mirrors the session manager's _TOKEN_RE and doubles as an injection guard
// (no leading '-', hex only) before the value reaches the gdbus argv.
function disposeWindowPlan(identity) {
  identity = identity || {};
  if (!isDisposableWindow(identity))
    return { "dispose": false, "byToken": false, "token": "" };
  var token = (identity.instanceId || "") + "";
  if (/^[0-9a-f]{8,64}$/.test(token))
    return { "dispose": true, "byToken": true, "token": token };
  return { "dispose": true, "byToken": false, "token": "" };
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeAppId: normalizeAppId,
    shouldGroup: shouldGroup,
    isRunningWindowEntry: isRunningWindowEntry,
    groupApps: groupApps,
    applySortMode: applySortMode,
    siloTierLabel: siloTierLabel,
    isDisposableWindow: isDisposableWindow,
    buildIsolationMenuItems: buildIsolationMenuItems,
    disposeWindowPlan: disposeWindowPlan,
  };
}
