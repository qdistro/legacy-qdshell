pragma Singleton

import QtQuick
import Quickshell
import qs.Commons
import qs.Services.Qdwin

// VMApps — tier-5 (per-app VM, waypipe-over-AF_VSOCK) toplevel filter
// for the qdshell launcher / taskbar / containers panel.
//
// Unlike PodApps (tier-2), tier-5 apps do NOT arrive via
// qdwin_nested_manager_v1. They're regular xdg_toplevels on the
// outer compositor — connections from the host-side `waypipe-client`
// half of the waypipe-over-vsock bridge — tagged with
// wp_security_context_v1 fields. The bridge / spawn-tier5.sh design
// is in qdistro/doc/isolation-tiers.md (Tier 5) and the design
// pivot from the earlier nested-compositor approach is in
// qdistro/doc/containers.md "Why tier-2 first" + Future work.
//
// What this service does:
//   - Watches Qdwin.windows (the canonical toplevel list).
//   - Exposes the subset whose secctxAppId starts with
//     `qdistro.tier5.` as `tier5Windows`, indexed by handle.
//   - Derives a `silo` per row (`vm-<silo>` per the convention) so
//     the same vocabulary the broker rules engine uses lines up
//     on the qdshell side.
//
// What this service deliberately does NOT do in v1:
//   - **No `launch()` / spawn-tier5 integration.** Launching a
//     tier-5 app from qdshell requires resolving "which app inside
//     which VM" — a UX question (per-VM launcher list? scan the
//     base qcow2's xdg .desktop entries? curated config?). Until
//     that's decided, tier-5 apps are cold-started by admin via
//     `sudo qdistro-tier5-spawn --vm <name> -- <cmd>` from a shell.
//   - **No cold-start placeholder UX.** PodApps's cold-start
//     spinner relies on a per-launch LAUNCH_TOKEN that spawn-tier2.sh
//     emits on stdout and threads through wp_security_context_v1's
//     instance_id field. spawn-tier5.sh today only passes a single
//     `--secctx <app_id>` to waypipe (no engine/instance triple), so
//     there's nothing to correlate a placeholder against. Add this
//     once spawn-tier5.sh + waypipe wire the full secctx triple
//     (tracked in todo/qdwin-vm/tier5-vm-bringup.md, step 5 follow-up).
//
// See:
//   - qdistro/doc/isolation-tiers.md "Tier 5 — per-app VM windowed"
//   - qdistro/doc/containers.md (UI surface vocabulary parity)
//   - qdistro/doc/ui.md "silo-badges" (badge ring colour for tier-5)
//   - qdistro/tier5-vm/spawn-tier5.sh
Singleton {
    id: root

    Component.onCompleted: Logger.i("VMApps", "service started")

    // The reverse-DNS engine prefix that identifies a tier-5 app.
    // Matches the SECCTX default in qdistro/tier5-vm/spawn-tier5.sh.
    readonly property string tier5Prefix: "qdistro.tier5."

    // Filtered subset of Qdwin.windows. Each row carries the same
    // fields Qdwin.windows does (handle, ownerUid, appId, title,
    // isXwayland, workspaceId, sandboxEngine, secctxAppId,
    // instanceId) plus a derived `silo` string.
    property ListModel tier5Windows: ListModel {}

    // Quick lookup: handle (int) -> silo (string).
    property var _siloByHandle: ({})

    signal tier5WindowAdded(int handle, string silo, string appId)
    signal tier5WindowRemoved(int handle, string silo)

    // ---- helpers ----------------------------------------------------------
    // Derive the silo name from a tier-5 secctxAppId.
    // `qdistro.tier5.<silo>` → `vm-<silo>` (matches broker/qdshell silo
    // convention used by tier-3's `user-<uid>` and tier-2's
    // `tier2/<container>`).
    function siloFromSecctx(secctxAppId) {
        if (!secctxAppId || !secctxAppId.startsWith(root.tier5Prefix))
            return "";
        const tag = secctxAppId.slice(root.tier5Prefix.length);
        if (!tag) return "";
        return "vm-" + tag;
    }

    function isTier5(secctxAppId) {
        return !!secctxAppId && secctxAppId.startsWith(root.tier5Prefix);
    }

    // Build tier5Windows from scratch off Qdwin.windows. Cheap enough
    // (handful of windows) that incremental tracking isn't worth the
    // complexity; rebuild on any windowListChanged or
    // windowSecctxResolved event.
    function rebuild() {
        const fresh = [];
        const seenHandles = new Set();
        const wm = Qdwin.windows;
        if (!wm) return;
        for (let i = 0; i < wm.count; i++) {
            const w = wm.get(i);
            if (!root.isTier5(w.secctxAppId)) continue;
            const silo = root.siloFromSecctx(w.secctxAppId);
            fresh.push({
                handle:       w.handle,
                ownerUid:     w.ownerUid,
                appId:        w.appId,
                title:        w.title,
                isXwayland:   w.isXwayland,
                workspaceId:  w.workspaceId,
                sandboxEngine: w.sandboxEngine,
                secctxAppId:  w.secctxAppId,
                instanceId:   w.instanceId,
                silo:         silo,
            });
            seenHandles.add(w.handle);
        }

        // Diff against the current tier5Windows for signal emission.
        const prevHandles = new Set();
        for (let i = 0; i < root.tier5Windows.count; i++)
            prevHandles.add(root.tier5Windows.get(i).handle);

        root.tier5Windows.clear();
        const nextSiloByHandle = ({});
        for (const row of fresh) {
            root.tier5Windows.append(row);
            nextSiloByHandle[row.handle] = row.silo;
            if (!prevHandles.has(row.handle))
                root.tier5WindowAdded(row.handle, row.silo, row.appId);
        }
        for (const h of prevHandles) {
            if (!seenHandles.has(h))
                root.tier5WindowRemoved(h, root._siloByHandle[h] || "");
        }
        root._siloByHandle = nextSiloByHandle;
    }

    // ---- wire-up ----------------------------------------------------------
    // Rebuild on any change to the canonical window list. secctx fields
    // arrive AFTER toplevel_added (per Qdwin.qml's comment on the
    // windowSecctxResolved signal), so windowListChanged alone misses
    // the moment a window becomes recognisably tier-5 — also listen to
    // the secctx-resolved signal.
    Connections {
        target: Qdwin
        function onWindowListChanged() { root.rebuild(); }
        function onWindowSecctxResolved(handle, sandboxEngine, secctxAppId, instanceId) {
            if (root.isTier5(secctxAppId))
                root.rebuild();
            else if (root._siloByHandle[handle])
                // A previously-tier-5 toplevel had its secctx changed
                // (shouldn't happen in practice, but harmless).
                root.rebuild();
        }
    }
}
