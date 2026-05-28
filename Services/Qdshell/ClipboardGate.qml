pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "ClipboardBroker.js" as ClipboardBroker
import "ClipboardSilo.js" as ClipboardSilo

// spec/10 Phase-1 — compositor-mediated clipboard gate.
// Track-04 Phase-1 scope. Implements the cross-silo clipboard
// protection that pairs with qdwin's `selection_set` and
// `toplevel_security_context` events (qdwin_shell_v1 v13+).
// Lifecycle:
//   - Qdwin.qml's QdwinBinding emits `toplevelSecurityContext(handle,
//     sandboxEngine, appId, instanceId)` shortly after each
//     `toplevelAdded`. We build a handle → silo map from these events.
//   - On `selectionSet(seat, sourceHandle, mimeTypesConcat, isPrimary)`,
//     we look up the source silo from the map, the destination silo
//     from the currently-focused toplevel, and decide allow/deny
//     by asking the qdistro broker's CheckClipboardTransfer method.
//   - On deny, we call `QdwinBinding.clearSelection(seat, isPrimary)`.
// Decision audit: every verdict emits a journal line of the form
//   CLIPBOARD_GATE seat=<s> src_silo=<s> dst_silo=<s> mime_types=<csv>
//                  verdict=<allow|deny> reason=<text>
// (the qdistro VM test harness asserts on these — the line shape is
// stable and any field re-ordering is a breaking change).
// Broker failures are fail-closed: absent broker, timeout, malformed
// reply, and unknown verdict all deny and clear. Unknown source or
// destination identity is denied locally before broker evaluation
// because there is no trustworthy action key for rules/cache lookup.
// ClipboardPolicy.qml is still loaded for settings/probe compatibility
// but is intentionally not used as a fallback for live enforcement.
// TODO(track-04-phase-2): focus-aware-clear primitive (clipboard.md
// §"focus-aware-clear"). On every seatFocusChanged, if the newly
// focused toplevel's silo differs from the silo that set the active
// selection, call clearSelection. Phase-1 only gates set-time.
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
        // Option-B identity sidecar (qdwin_shell_v1@v22). Older bindings
        // simply never emit; the same-silo gate then stays unverified and
        // falls through to the cross-silo policy path. See
        // todo/decisions/secctx-identity-contract.md.
        if (binding.toplevelPeerIdentity !== undefined) {
            binding.toplevelPeerIdentity.connect(root._onPeerIdentity);
        }
        binding.selectionSet.connect(root._onSelectionSet);
        // v23 sidecar — selection_set_source_identity. Fires IMMEDIATELY
        // BEFORE the matching selectionSet (qdwin guarantees the pair-by-
        // sequence ordering on the wire; the Qt direct-connect signal
        // delivery in qdwin-binding.cpp preserves it). Older bindings
        // simply never emit; src_silo then falls back to the v11
        // focus-handle path verbatim.
        if (binding.selectionSetSourceIdentity !== undefined) {
            binding.selectionSetSourceIdentity.connect(root._onSelectionSetSourceIdentity);
        }
        root._wired = true;
        ClipboardPolicy.load();
        Logger.i("ClipboardGate", "wired to qdwin_shell_v1; broker default=deny");
    }

    // -- internal state -------------------------------------------------
    property bool _wired: false
    property var _binding: null

    // handle (uint32) → silo (string). Stored as a plain JS object since
    // QML ListModel doesn't support uint32 keys well.
    property var _handleToSilo: ({})
    property var _handleToAppId: ({})
    property var _handleToSandboxEngine: ({})

    // Option-B identity bookkeeping (todo/decisions/secctx-identity-contract.md):
    //   _handleToIdentity[handle] = { pid, starttime, uid, exe, label,
    //                                 sandboxEngine, appId, instanceId }
    //   _verifyCache[verifyKey]   = bool   (true = broker said OK)
    //   _verifyInFlight[verifyKey] = bool  (suppress duplicate calls)
    // verifyKey = pid + ":" + starttime — anti-PID-reuse.
    property var _handleToIdentity: ({})
    property var _verifyCache: ({})
    property var _verifyInFlight: ({})

    // v23 sidecar — selection_set_source_identity. The compositor fires
    // this IMMEDIATELY BEFORE the matching selectionSet for tagged
    // source clients; we stash the tuple here and consume it on the
    // very next _onSelectionSet, then clear. Pair-by-sequence: at most
    // one outstanding entry. Stale untagged-source events on a v23
    // shell skip the sidecar entirely, so _pendingSrcIdentity stays
    // null and the v11 focus-handle path takes over.
    //   { sandboxEngine, appId, instanceId }   (or null)
    property var _pendingSrcIdentity: null

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
        delete root._handleToSandboxEngine[handle];
        delete root._handleToIdentity[handle];
    }

    // Option-B identity sidecar from qdwin_shell_v1@v22. Caches the
    // tuple keyed by toplevel handle so the selection-set gate can find
    // it without racing the broker round-trip; the verify call itself
    // fires lazily on first use and caches by (pid, starttime).
    function _onPeerIdentity(handle, peerPid, peerStarttime, peerUid, peerExe, peerSelinuxLabel) {
        const existing = root._handleToIdentity[handle] || {};
        root._handleToIdentity[handle] = {
            "pid": peerPid >>> 0,
            "starttime": peerStarttime,
            "uid": peerUid >>> 0,
            "exe": peerExe || "",
            "label": peerSelinuxLabel || "",
            "sandboxEngine": existing.sandboxEngine || "",
            "appId": existing.appId || "",
            "instanceId": existing.instanceId || ""
        };
    }

    function _verifyKey(identity) {
        return (identity.pid >>> 0) + ":" + identity.starttime;
    }

    // Issue (or reuse) a broker VerifyClientIdentity call. Async-fire-and-
    // forget: the result lands in _verifyCache and gates future
    // selection_set decisions for that (pid, starttime). The very first
    // transfer from a given client racing the verify still falls through
    // to the cross-silo path (default-deny), which is exactly the
    // conservative posture the decision doc calls for.
    function _ensureVerified(handle) {
        const id = root._handleToIdentity[handle];
        if (!id || !id.pid)
            return false;
        const key = root._verifyKey(id);
        if (root._verifyCache.hasOwnProperty(key))
            return root._verifyCache[key];
        if (root._verifyInFlight[key])
            return false;
        root._verifyInFlight[key] = true;
        _verifyProc.command = ["busctl", "--system", "--no-pager", "call", "org.qdistro.AdminBroker1", "/org/qdistro/AdminBroker1", "org.qdistro.AdminBroker1", "VerifyClientIdentity", "utusssss", String(id.pid >>> 0), String(id.starttime), String(id.uid >>> 0), String(id.exe || ""), String(id.label || ""), String(id.sandboxEngine || ""), String(id.appId || ""), String(id.instanceId || ""),];
        _verifyProc._pendingKey = key;
        _verifyProc.running = true;
        return false;
    }

    Process {
        id: _verifyProc
        running: false
        property string _pendingKey: ""
        stdout: StdioCollector {
            id: _verifyStdout
        }
        stderr: StdioCollector {
            id: _verifyStderr
        }
        onExited: (exitCode, exitStatus) => {
            const key = _verifyProc._pendingKey;
            _verifyProc._pendingKey = "";
            delete root._verifyInFlight[key];
            if (exitCode !== 0) {
                // Broker absent or method missing — treat as unverified. The
                // cross-silo path takes over (default-deny under policy).
                root._verifyCache[key] = false;
                return;
            }
            const out = String(_verifyStdout.text || "").trim();
            // busctl prints booleans as "b true" / "b false".
            const verified = out.endsWith("true");
            root._verifyCache[key] = verified;
            if (!verified) {
                Logger.w("ClipboardGate", "VerifyClientIdentity denied for key=" + key + " out=" + out);
            }
        }
    }

    // Derive a stable silo string from a (sandboxEngine, appId,
    // instanceId) tuple.
    // Mirrors the per-engine resolution rules in _onSecurityContext so a
    // wire-sourced tuple (v23 sidecar) and a toplevel-handle-sourced
    // tuple (v13 toplevel_security_context) yield the same silo string
    // for the same client. instance_id is a launch-correlation token for
    // qdistro tier2/tier3/tier5 and must not enter clipboard silo identity.
    function _siloFromSecctx(sandboxEngine, appId, instanceId) {
        return ClipboardSilo.fromSecctx(sandboxEngine, appId, instanceId);
    }

    // v23 sidecar handler. Stash the tuple as "pending"; the very next
    // _onSelectionSet consumes it. Overwrites any previous pending entry
    // — by the qdwin contract there is at most one outstanding sidecar
    // per resource, so a back-to-back pair {sidecar, sidecar} would only
    // arise from a bug, and "last write wins" matches what selection_set
    // itself would do.
    function _onSelectionSetSourceIdentity(sandboxEngine, appId, instanceId) {
        root._pendingSrcIdentity = {
            "sandboxEngine": sandboxEngine || "",
            "appId": appId || "",
            "instanceId": instanceId || ""
        };
    }

    function _onSecurityContext(handle, sandboxEngine, appId, instanceId) {
        const stableSilo = root._siloFromSecctx(sandboxEngine, appId, instanceId);
        if (stableSilo.length > 0)
            root._handleToSilo[handle] = stableSilo;
        if (appId && appId.length > 0) {
            root._handleToAppId[handle] = appId;
        }
        root._handleToSandboxEngine[handle] = sandboxEngine || "";
        // Stash the secctx tuple on the identity entry so the broker
        // VerifyClientIdentity call can include "claimed" values alongside
        // the (pid, starttime, exe, label) the compositor observed.
        const existing = root._handleToIdentity[handle] || {};
        root._handleToIdentity[handle] = Object.assign({}, existing, {
                "sandboxEngine": sandboxEngine || "",
                "appId": appId || "",
                "instanceId": instanceId || ""
            });
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
            if (typeof s !== "string" || s.length === 0)
                continue;
            const base = s.split(";", 1)[0].trim().toLowerCase();
            if (root._tier4AllowedMimeBases.indexOf(base) < 0)
                continue;
            if (seen[s])
                continue;
            seen[s] = true;
            out.push(s);
        }
        return out;
    }

    function _logDecisionAndMaybeClear(entry, verdict, reason) {
        Logger.i("ClipboardGate", "CLIPBOARD_GATE", "seat=" + (entry.seat || "default"), "src_silo=" + entry.srcSilo, "dst_silo=" + entry.dstSilo, "mime_types=" + entry.mimeCsv, "verdict=" + verdict, "reason=" + reason);
        if (verdict === "deny" && root._binding) {
            root._binding.clearSelection(entry.seat || "default", entry.isPrimary);
        }
    }

    // -- the gate itself -------------------------------------------------
    function _onSelectionSet(seat, sourceHandle, mimeTypesConcat, isPrimary) {
        // v23 wire-sourced identity wins over the focus-handle map. The
        // compositor only emits the sidecar when the source wl_client
        // carries a wp_security_context_v1 tag, so a non-null
        // _pendingSrcIdentity means "we know the source silo from the
        // wire — don't trust the focus-handle map" (which collapses to the
        // focused admin shell's silo when the tagged client doesn't own a
        // focused toplevel). Consume + clear.
        const pending = root._pendingSrcIdentity;
        root._pendingSrcIdentity = null;
        let srcSilo;
        if (pending !== null) {
            const wireSilo = root._siloFromSecctx(pending.sandboxEngine, pending.appId, pending.instanceId);
            srcSilo = wireSilo.length > 0 ? wireSilo : (root._handleToSilo[sourceHandle] || "unknown");
        } else {
            srcSilo = root._handleToSilo[sourceHandle] || "unknown";
        }
        // Destination silo = silo of the currently-focused toplevel on this
        // seat. The binding caches focusedHandle on the seat that last
        // changed; for Phase-1 (single seat) we just read that.
        const focusedHandle = root._binding ? root._binding.focusedHandle : 4294967295;
        const dstSilo = (focusedHandle !== 4294967295) ? (root._handleToSilo[focusedHandle] || "unknown") : "unknown";
        let mimeList = (mimeTypesConcat || "").split("\n").filter(s => s.length > 0);

        // Tier-4 source → strict MIME allow-list (text/plain + text/uri-list).
        // The strip runs BEFORE policy consult so a tier-4 guest advertising
        // text/html or image/png has those types dropped, not evaluated.
        // (P05a security MS-2 / integration MEDIUM-1.)
        const srcAppId = (pending !== null && pending.appId) ? pending.appId : (root._handleToAppId[sourceHandle] || "");
        if (srcAppId.startsWith("qdistro.tier4.")) {
            const before = mimeList.length;
            mimeList = root._stripTier4Mimes(mimeList);
            if (mimeList.length !== before) {
                Logger.i("ClipboardGate", "tier4 mime-strip", "src_app=" + srcAppId, "before=" + before, "after=" + mimeList.length);
            }
        }
        const mimeCsv = mimeList.join(",");
        const decisionEntry = {
            "seat": seat || "default",
            "isPrimary": isPrimary,
            "srcSilo": srcSilo,
            "dstSilo": dstSilo,
            "mimeCsv": mimeCsv
        };

        // If after stripping there are no allowed MIMEs, deny without
        // consulting policy. The Python strip_mimes contract is "deny on
        // empty stripped list" — keep that semantics here.
        if (srcAppId.startsWith("qdistro.tier4.") && mimeList.length === 0) {
            root._logDecisionAndMaybeClear(decisionEntry, "deny", "tier4-no-allowed-mimes");
            return;
        }

        // Option-B identity gate (todo/decisions/secctx-identity-contract.md):
        // the same-silo string match short-circuits to allow only when the
        // broker has independently re-verified the source AND destination
        // process identity against /proc. Without verification (broker
        // absent, race before first verify, mismatch), fall through to the
        // cross-silo policy path — which is default-deny. _ensureVerified
        // returns synchronously cached results and fires off an async
        // broker round-trip on first sight.
        // If the v23 wire sidecar supplied the source silo, sourceHandle is
        // explicitly not trusted for source identity; it can name the focused
        // destination/admin toplevel. Fail closed unless qdwin grows a peer
        // identity sidecar for the actual selection source.
        const srcVerified = (pending === null) ? root._ensureVerified(sourceHandle) : false;
        const dstVerified = (focusedHandle !== 4294967295) ? root._ensureVerified(focusedHandle) : false;
        const identityVerified = srcVerified && dstVerified;
        if (!ClipboardBroker.hasKnownIdentity(srcSilo, dstSilo)) {
            root._logDecisionAndMaybeClear(decisionEntry, "deny", "unknown-identity");
            return;
        }

        const dstAppId = (focusedHandle !== 4294967295) ? (root._handleToAppId[focusedHandle] || "") : "";
        const sourceSandboxEngine = (pending !== null && pending.sandboxEngine) ? pending.sandboxEngine : (root._handleToSandboxEngine[sourceHandle] || "");
        if (!root._binding || root._binding.checkClipboardTransfer === undefined) {
            root._logDecisionAndMaybeClear(decisionEntry, "deny", "broker-unavailable");
            return;
        }
        const brokerResult = root._binding.checkClipboardTransfer(
            srcSilo, dstSilo, mimeList, srcAppId, dstAppId,
            sourceSandboxEngine, identityVerified);
        const decision = ClipboardBroker.parseCheckClipboardTransferResult(
            brokerResult.exitCode, brokerResult.stdout || "");
        root._logDecisionAndMaybeClear(decisionEntry, decision.verdict,
                                      decision.reason);
    }
}
