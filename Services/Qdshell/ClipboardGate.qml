pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// spec/10 Phase-1 — compositor-mediated clipboard gate.
//
// Track-04 Phase-1 scope. Implements the cross-silo clipboard
// protection that pairs with qdwin's `selection_set` and
// `toplevel_security_context` events (qdwin_shell_v1 v13+).
//
// Lifecycle:
//   - Qdwin.qml's QdwinBinding emits `toplevelSecurityContext(handle,
//     sandboxEngine, appId, instanceId)` shortly after each
//     `toplevelAdded`. We build a handle → silo map from these events.
//   - On `selectionSet(seat, sourceHandle, mimeTypesConcat, isPrimary)`,
//     we look up the source silo from the map, the destination silo
//     from the currently-focused toplevel, and decide allow/deny
//     based on the local policy file (loaded at startup) with a
//     same-silo short-circuit.
//   - On deny, we call `QdwinBinding.clearSelection(seat, isPrimary)`.
//
// Decision audit: every verdict emits a journal line of the form
//
//   CLIPBOARD_GATE seat=<s> src_silo=<s> dst_silo=<s> mime_types=<csv>
//                  verdict=<allow|deny> reason=<text>
//
// (the qdistro VM test harness asserts on these — the line shape is
// stable and any field re-ordering is a breaking change).
//
// Policy fallback path: same `busctl call` shape as HooksGate. Phase-1
// stays *local-policy-only* — broker round-trip is wired as a TODO
// because the spec calls out the broker's `CheckClipboardTransfer`
// path as Phase-2 work (admin-cache + prompt UI). The local YAML/JSON
// file is the always-on defense.
//
// TODO(track-04-phase-2): replace `_consultLocalPolicy` with a busctl
// shell-out to `com.qdistro.AdminBroker1.CheckClipboardTransfer`,
// mirroring HooksGate's Process+env pattern. Keep the local-policy
// branch as the "broker absent" graceful fallback.
//
// TODO(track-04-phase-2): focus-aware-clear primitive (clipboard.md
// §"focus-aware-clear"). On every seatFocusChanged, if the newly
// focused toplevel's silo differs from the silo that set the active
// selection, call clearSelection. Phase-1 only gates set-time.
//
// TODO(track-04-phase-3): receive-time gate using qdwin_shell_v1 v15
// `data_offer_receive_pending`. Per-MIME, per-app, with extension /
// qdbrowser metadata (passwordField, codeBlock, ...) feeding finer
// policy. Phase-1 has no metadata channel yet.

Singleton {
  id: root

  // Public init — Qdwin.qml calls this after its QdwinBinding fires
  // `boundChanged → bound`, so we have a live shell handle to subscribe
  // through. Idempotent.
  function init(binding) {
    if (root._wired) {
      return;
    }
    if (!binding) {
      Logger.w("ClipboardGate", "init called with null binding");
      return;
    }
    root._binding = binding;
    binding.toplevelAdded.connect(root._onToplevelAdded);
    binding.toplevelRemoved.connect(root._onToplevelRemoved);
    binding.toplevelSecurityContext.connect(root._onSecurityContext);
    binding.selectionSet.connect(root._onSelectionSet);
    root._wired = true;
    ClipboardPolicy.load();
    Logger.i("ClipboardGate", "wired to qdwin_shell_v1; policy default=deny");
  }

  // -- internal state -------------------------------------------------

  property bool _wired: false
  property var _binding: null

  // handle (uint32) → silo (string). Stored as a plain JS object since
  // QML ListModel doesn't support uint32 keys well.
  property var _handleToSilo: ({})
  property var _handleToAppId: ({})

  // -- handle/silo tracking -------------------------------------------

  function _onToplevelAdded(handle, ownerUid, appId, title, isXwayland) {
    // Until the security_context event arrives (it may, or may not —
    // qdwin only emits it for clients that bound wp_security_context_v1
    // or carry a waypipe secctx tag), we fall back to a uid-derived
    // placeholder so same-silo paste between two unctx'd toplevels in
    // the same uid still short-circuits to allow.
    if (!(handle in root._handleToSilo)) {
      root._handleToSilo[handle] = "uid:" + ownerUid;
    }
    root._handleToAppId[handle] = appId || "";
  }

  function _onToplevelRemoved(handle) {
    delete root._handleToSilo[handle];
    delete root._handleToAppId[handle];
  }

  function _onSecurityContext(handle, sandboxEngine, appId, instanceId) {
    // The instance_id in qdistro carries the silo name — that's the
    // convention from clipboard.md §"compositor-mediated gating". When
    // sandbox_engine is "qdistro", instance_id IS the silo. For other
    // engines (flatpak, firejail) we still bucket by instance_id for
    // policy purposes but tag the engine so policy rules can match.
    //
    // EXCEPTION — tier-4 (qdistro.tier4.*): spawn-tier4.sh stamps the
    // instance_id as "$VM_NAME-$$" (pid-suffixed), so the same VM
    // launched twice would get two different "silo" strings under the
    // naive instance_id rule. The chrome-paint side (Tier4Apps.qml)
    // derives silo from the secctx app_id suffix instead — for the
    // same-silo gate to match, we MUST use the same derivation here.
    // (P05a security H3 / integration MEDIUM-2.)
    if (appId && appId.length > 0 && appId.startsWith("qdistro.tier4.")) {
      root._handleToSilo[handle] = appId.slice("qdistro.tier4.".length);
    } else if (instanceId && instanceId.length > 0) {
      root._handleToSilo[handle] = instanceId;
    } else if (sandboxEngine && sandboxEngine.length > 0) {
      // Engine-only context — bucket by engine. Better than a uid.
      root._handleToSilo[handle] = "engine:" + sandboxEngine;
    }
    if (appId && appId.length > 0) {
      root._handleToAppId[handle] = appId;
    }
  }

  // Tier-4 strict MIME allow-list. The base type (everything before the
  // first ";") must equal text/plain or text/uri-list; charset suffixes
  // are preserved. Mirrors qdistro/tier4-vm/tier4_chrome.py::strip_mimes
  // — Python is the canonical implementation; this is the QML port.
  // (P05a security MS-2 / integration MEDIUM-1.)
  readonly property var _tier4AllowedMimeBases: ["text/plain", "text/uri-list"]

  function _stripTier4Mimes(mimes) {
    const seen = {};
    const out = [];
    for (let i = 0; i < mimes.length; i++) {
      const s = mimes[i];
      if (typeof s !== "string" || s.length === 0) continue;
      const base = s.split(";", 1)[0].trim().toLowerCase();
      if (root._tier4AllowedMimeBases.indexOf(base) < 0) continue;
      if (seen[s]) continue;
      seen[s] = true;
      out.push(s);
    }
    return out;
  }

  // -- the gate itself -------------------------------------------------

  function _onSelectionSet(seat, sourceHandle, mimeTypesConcat, isPrimary) {
    const srcSilo = root._handleToSilo[sourceHandle] || "unknown";
    // Destination silo = silo of the currently-focused toplevel on this
    // seat. The binding caches focusedHandle on the seat that last
    // changed; for Phase-1 (single seat) we just read that.
    const focusedHandle = root._binding ? root._binding.focusedHandle : 4294967295;
    const dstSilo = (focusedHandle !== 4294967295)
      ? (root._handleToSilo[focusedHandle] || "unknown")
      : "unknown";

    let mimeList = (mimeTypesConcat || "").split("\n").filter(s => s.length > 0);

    // Tier-4 source → strict MIME allow-list (text/plain + text/uri-list).
    // The strip runs BEFORE policy consult so a tier-4 guest advertising
    // text/html or image/png has those types dropped, not evaluated.
    // (P05a security MS-2 / integration MEDIUM-1.)
    const srcAppId = root._handleToAppId[sourceHandle] || "";
    if (srcAppId.startsWith("qdistro.tier4.")) {
      const before = mimeList.length;
      mimeList = root._stripTier4Mimes(mimeList);
      if (mimeList.length !== before) {
        Logger.i("ClipboardGate",
                 "tier4 mime-strip",
                 "src_app=" + srcAppId,
                 "before=" + before,
                 "after=" + mimeList.length);
      }
    }
    const mimeCsv = mimeList.join(",");

    let verdict = "deny";
    let reason = "default-deny";

    // If after stripping there are no allowed MIMEs, deny without
    // consulting policy. The Python strip_mimes contract is "deny on
    // empty stripped list" — keep that semantics here.
    if (srcAppId.startsWith("qdistro.tier4.") && mimeList.length === 0) {
      verdict = "deny";
      reason = "tier4-no-allowed-mimes";

      Logger.i("ClipboardGate",
               "CLIPBOARD_GATE",
               "seat=" + (seat || "default"),
               "src_silo=" + srcSilo,
               "dst_silo=" + dstSilo,
               "mime_types=" + mimeCsv,
               "verdict=" + verdict,
               "reason=" + reason);

      if (root._binding) {
        root._binding.clearSelection(seat || "default", isPrimary);
      }
      return;
    }

    if (srcSilo === dstSilo && srcSilo !== "unknown") {
      verdict = "allow";
      reason = "same-silo";
    } else if (srcSilo === "unknown" || dstSilo === "unknown") {
      // Unknown silo on either end — fall through to policy. Default
      // deny ensures we don't leak before security_context lands.
      const decision = ClipboardPolicy.consult(srcSilo, dstSilo, mimeList);
      verdict = decision.verdict;
      reason = "policy:" + decision.reason;
    } else {
      const decision = ClipboardPolicy.consult(srcSilo, dstSilo, mimeList);
      verdict = decision.verdict;
      reason = "policy:" + decision.reason;
    }

    // Journal line — the VM probe asserts on this exact shape.
    Logger.i("ClipboardGate",
             "CLIPBOARD_GATE",
             "seat=" + (seat || "default"),
             "src_silo=" + srcSilo,
             "dst_silo=" + dstSilo,
             "mime_types=" + mimeCsv,
             "verdict=" + verdict,
             "reason=" + reason);

    if (verdict === "deny" && root._binding) {
      root._binding.clearSelection(seat || "default", isPrimary);
    }

    // TODO(track-04-phase-2): on "prompt" verdict, surface the
    // "Request transfer" affordance described in 04-compositor-
    // clipboard.md §"Default when no cache hit". Today we collapse
    // prompt → deny (with reason=prompt-collapsed) so the user-visible
    // behaviour is conservative until the affordance ships.
  }
}
