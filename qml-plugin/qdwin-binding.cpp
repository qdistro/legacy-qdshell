// qdwin-binding.cpp — see qdwin-binding.h for shape + rationale.
//
// Listener stubs we don't yet expose to QML still need to exist
// (the qdwin_shell_v1_listener struct is checked field-by-field at
// add_listener time and a NULL slot crashes on dispatch). For each
// field we either forward to a Q_SIGNAL or hold a no-op so future
// phase-2 wiring is one edit.
//
// SPDX-License-Identifier: GPL-3.0-or-later

#include "qdwin-binding.h"
#include "ctrl-server.h"

#include <wayland-client.h>
#include "qdwin-shell-v1-client-protocol.h"
#include "ext-workspace-v1-client-protocol.h"
#include "wlr-output-management-unstable-v1-client-protocol.h"

#include <algorithm>

#include <QDebug>
#include <QMetaType>
#include <QProcess>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <cerrno>
#include <cstring>

namespace {
// Bump to 23 to pick up `selection_set_source_identity` — the v23 sidecar
// emitted IMMEDIATELY BEFORE `selection_set` carrying the secctx tuple
// (engine, app_id, instance_id) of the wl_client that issued the
// set_selection. ClipboardGate.qml uses it to derive src_silo from the
// wire instead of from keyboard-focus state, closing the R9 P04 hole
// where a tagged wl_client without focused-toplevel ownership had its
// src_silo collapse to the focused admin shell's silo.
//
// Earlier bumps in this file:
//   22 — toplevel_peer_identity (Option-B identity sidecar, see
//        todo/decisions/secctx-identity-contract.md)
// Bump to 24 to pick up `toplevel_workspace` (per-window→workspace
// sidecar for the bar's occupancy) and the `move_toplevel_to_workspace`
// request. The workspace list/active state itself rides the standard
// ext-workspace-v1 client below, not this private binding. See
// todo/decisions/qdwin-workspaces-ext-protocol.md.
constexpr uint32_t kBindVersion = 24;
constexpr int kBrokerStartTimeoutMs = 250;
constexpr int kBrokerGateTimeoutMs = 2000;
constexpr int kBrokerDefaultTimeoutMs = 200;
constexpr auto kBrokerGateBusctlTimeout = "--timeout=2s";
constexpr auto kBrokerDefaultBusctlTimeout = "--timeout=200ms";

inline QString qstr(const char *s) {
    return s ? QString::fromUtf8(s) : QString();
}

void appendVariantDict(QStringList &args, const QVariantMap &details) {
    args.append(QString::number(details.size()));
    for (auto it = details.cbegin(); it != details.cend(); ++it) {
        args.append(it.key());
        const QVariant value = it.value();
        const int typeId = value.metaType().id();
        if (it.key() == QStringLiteral("origin_uid")) {
            args.append(QStringLiteral("u"));
            args.append(QString::number(value.toUInt()));
            continue;
        }
        switch (typeId) {
        case QMetaType::Bool:
            args.append(QStringLiteral("b"));
            args.append(value.toBool() ? QStringLiteral("true")
                                       : QStringLiteral("false"));
            break;
        case QMetaType::Int:
        case QMetaType::LongLong:
            args.append(QStringLiteral("x"));
            args.append(QString::number(value.toLongLong()));
            break;
        case QMetaType::UInt:
        case QMetaType::ULongLong:
            args.append(QStringLiteral("t"));
            args.append(QString::number(value.toULongLong()));
            break;
        case QMetaType::Double:
            if (value.toDouble() >= 0) {
                args.append(QStringLiteral("t"));
                args.append(QString::number(static_cast<qulonglong>(value.toDouble())));
            } else {
                args.append(QStringLiteral("x"));
                args.append(QString::number(static_cast<qlonglong>(value.toDouble())));
            }
            break;
        default:
            args.append(QStringLiteral("s"));
            args.append(value.toString());
            break;
        }
    }
}
}

// -------------------- C wayland listener trampolines ---------------------

// All trampolines forward to QdwinBinding via the void *data pointer
// that we register with wl_registry_add_listener / qdwin_shell_v1_add_listener.

struct QdwinBindingDispatch {
    static void hello(void *d, qdwin_shell_v1 *, uint32_t uid) {
        auto *b = static_cast<QdwinBinding *>(d);
        b->setBound(true);
        emit b->hello(uid);
    }
    static void toplevel_added(void *d, qdwin_shell_v1 *,
                               uint32_t handle, uint32_t owner_uid,
                               const char *app_id, const char *title,
                               uint32_t is_xwayland) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->toplevelAdded(handle, owner_uid, qstr(app_id), qstr(title),
                              is_xwayland != 0);
    }
    static void toplevel_geometry(void *d, qdwin_shell_v1 *,
                                  uint32_t handle, int32_t x, int32_t y,
                                  uint32_t w, uint32_t h) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->toplevelGeometry(handle, x, y, w, h);
    }
    static void toplevel_state(void *d, qdwin_shell_v1 *,
                               uint32_t handle, uint32_t state) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->toplevelState(handle, state);
    }
    static void toplevel_title(void *d, qdwin_shell_v1 *,
                               uint32_t handle, const char *title) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->toplevelTitle(handle, qstr(title));
    }
    static void toplevel_removed(void *d, qdwin_shell_v1 *, uint32_t handle) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->toplevelRemoved(handle);
    }
    static void locked_changed(void *, qdwin_shell_v1 *, uint32_t) {}
    static void seat_created(void *, qdwin_shell_v1 *, const char *) {}
    static void seat_removed(void *, qdwin_shell_v1 *, const char *) {}
    static void output_created(void *, qdwin_shell_v1 *, const char *) {}
    static void output_removed(void *, qdwin_shell_v1 *, const char *) {}
    static void launcher_requested(void *d, qdwin_shell_v1 *) {
        emit static_cast<QdwinBinding *>(d)->launcherRequested();
    }
    static void switcher_next(void *d, qdwin_shell_v1 *, int32_t dir) {
        emit static_cast<QdwinBinding *>(d)->switcherNext(dir);
    }
    static void switcher_commit(void *d, qdwin_shell_v1 *) {
        emit static_cast<QdwinBinding *>(d)->switcherCommit();
    }
    static void lock_requested(void *d, qdwin_shell_v1 *) {
        emit static_cast<QdwinBinding *>(d)->lockRequested();
    }
    static void idle_lock_hint(void *d, qdwin_shell_v1 *, uint32_t reason) {
        emit static_cast<QdwinBinding *>(d)->idleLockHint(reason);
    }
    static void nested_proxy_pending(void *d, qdwin_shell_v1 *,
                                     uint32_t handle, const char *app_id,
                                     uint32_t origin_uid) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->nestedProxyPending(handle, qstr(app_id), origin_uid);
    }
    static void nested_proxy_pixel_source(void *d, qdwin_shell_v1 *,
                                          uint32_t handle,
                                          const char *pw_node,
                                          const char *input_sink) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->nestedProxyPixelSource(handle,
                                       qstr(pw_node), qstr(input_sink));
    }
    // spec/10 selection_set — forward to QML so ClipboardGate can
    // consult the broker and call clearSelection on a deny verdict.
    static void selection_set(void *d, qdwin_shell_v1 *,
                              const char *seat_name, uint32_t source_handle,
                              const char *mime_types_concat,
                              uint32_t is_primary) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->selectionSet(qstr(seat_name), source_handle,
                             qstr(mime_types_concat), is_primary);
    }
    // v23 sidecar — qdwin_shell_v1.selection_set_source_identity fires
    // IMMEDIATELY BEFORE the matching `selection_set` for tagged source
    // clients. We forward the tuple as a distinct signal; ClipboardGate
    // stashes it as "pending" and consumes it on the very next
    // selectionSet. Order is preserved because wayland dispatch is
    // single-threaded and Qt direct-connect signal delivery runs
    // synchronously inside this dispatch frame.
    static void selection_set_source_identity(void *d, qdwin_shell_v1 *,
                                              const char *src_sandbox_engine,
                                              const char *src_app_id,
                                              const char *src_instance_id) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->selectionSetSourceIdentity(qstr(src_sandbox_engine),
                                           qstr(src_app_id),
                                           qstr(src_instance_id));
    }
    static void activation_pending(void *d, qdwin_shell_v1 *,
                                   uint32_t handle, uint32_t source_handle,
                                   uint32_t target_handle,
                                   const char *source_app_id) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->activationPending(handle, source_handle, target_handle,
                                  qstr(source_app_id));
    }
    // wp_security_context_v1 tag — load-bearing for both the cold-
    // start placeholder resolution (claude/tier2-podman) and spec/10's
    // handle→silo map for the clipboard gate.
    static void toplevel_security_context(void *d, qdwin_shell_v1 *,
                                          uint32_t handle,
                                          const char *sandbox_engine,
                                          const char *app_id,
                                          const char *instance_id) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->toplevelSecurityContext(handle, qstr(sandbox_engine),
                                        qstr(app_id), qstr(instance_id));
    }
    // Option-B identity sidecar (qdwin_shell_v1@v22). Fires immediately
    // after `toplevel_security_context` for the same handle. starttime
    // is reassembled from the lo/hi uint32 split that the protocol
    // carries (wayland has no native uint64 arg type).
    static void toplevel_peer_identity(void *d, qdwin_shell_v1 *,
                                       uint32_t handle,
                                       uint32_t peer_pid,
                                       uint32_t peer_starttime_lo,
                                       uint32_t peer_starttime_hi,
                                       uint32_t peer_uid,
                                       const char *peer_exe,
                                       const char *peer_selinux_label) {
        auto *b = static_cast<QdwinBinding *>(d);
        quint64 st = (static_cast<quint64>(peer_starttime_hi) << 32)
                     | static_cast<quint64>(peer_starttime_lo);
        emit b->toplevelPeerIdentity(handle, peer_pid, st, peer_uid,
                                     qstr(peer_exe),
                                     qstr(peer_selinux_label));
    }
    static void seat_focus_changed(void *d, qdwin_shell_v1 *,
                                   const char *seat_name,
                                   uint32_t focused_handle) {
        auto *b = static_cast<QdwinBinding *>(d);
        b->setFocused(qstr(seat_name), focused_handle);
        emit b->seatFocusChanged(qstr(seat_name), focused_handle);
    }

    // v15+ slots — wired at our bind version (23); overlay_key
    // forwards to QML, the rest are no-ops awaiting consumers.
    static void overlay_key(void *d, qdwin_shell_v1 *,
                            uint32_t role, uint32_t sym,
                            const char *utf8, uint32_t state) {
        auto *b = static_cast<QdwinBinding *>(d);
        b->overlayKeyCount_++;
        b->lastOverlayRole_ = role;
        b->lastOverlaySym_ = sym;
        b->lastOverlayUtf8_ = qstr(utf8);
        emit b->overlayKeyCountChanged();
        emit b->overlayKey(role, sym, b->lastOverlayUtf8_, state);
    }
    // spec/10 receive-time gate — forward to QML so ClipboardGate can
    // consult the broker (CheckClipboardReceive) and echo the verdict
    // back via sendDataOfferReceiveDecision. The compositor blocks the
    // receive() until we answer (or ~2s timeout → deny), so the QML
    // handler MUST answer exactly once on every path.
    static void data_offer_receive_pending(void *d, qdwin_shell_v1 *,
                                           uint32_t request_handle,
                                           const char *seat_name,
                                           uint32_t source_handle,
                                           uint32_t target_handle,
                                           const char *mime_type) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->dataOfferReceivePending(request_handle, qstr(seat_name),
                                        source_handle, target_handle,
                                        qstr(mime_type));
    }
    static void hotkey_pressed(void *, qdwin_shell_v1 *, uint32_t) {}
    static void chrome_button(void *, qdwin_shell_v1 *,
                              uint32_t, uint32_t, wl_fixed_t, wl_fixed_t,
                              uint32_t, uint32_t) {}
    static void popup_button(void *, qdwin_shell_v1 *,
                             uint32_t, wl_fixed_t, wl_fixed_t,
                             uint32_t, uint32_t) {}
    // v24 sidecar — which workspace a toplevel is on.
    static void toplevel_workspace(void *d, qdwin_shell_v1 *,
                                   uint32_t handle, uint32_t index) {
        emit static_cast<QdwinBinding *>(d)->toplevelWorkspace(handle, index);
    }
};

static const qdwin_shell_v1_listener kShellListener = {
    .hello                     = QdwinBindingDispatch::hello,
    .toplevel_added            = QdwinBindingDispatch::toplevel_added,
    .toplevel_geometry         = QdwinBindingDispatch::toplevel_geometry,
    .toplevel_state            = QdwinBindingDispatch::toplevel_state,
    .toplevel_title            = QdwinBindingDispatch::toplevel_title,
    .toplevel_removed          = QdwinBindingDispatch::toplevel_removed,
    .locked_changed            = QdwinBindingDispatch::locked_changed,
    .seat_created              = QdwinBindingDispatch::seat_created,
    .seat_removed              = QdwinBindingDispatch::seat_removed,
    .output_created            = QdwinBindingDispatch::output_created,
    .output_removed            = QdwinBindingDispatch::output_removed,
    .launcher_requested        = QdwinBindingDispatch::launcher_requested,
    .switcher_next             = QdwinBindingDispatch::switcher_next,
    .switcher_commit           = QdwinBindingDispatch::switcher_commit,
    .lock_requested            = QdwinBindingDispatch::lock_requested,
    .overlay_key               = QdwinBindingDispatch::overlay_key,
    .idle_lock_hint            = QdwinBindingDispatch::idle_lock_hint,
    .nested_proxy_pending      = QdwinBindingDispatch::nested_proxy_pending,
    .nested_proxy_pixel_source = QdwinBindingDispatch::nested_proxy_pixel_source,
    .selection_set             = QdwinBindingDispatch::selection_set,
    .selection_set_source_identity =
        QdwinBindingDispatch::selection_set_source_identity,
    .activation_pending        = QdwinBindingDispatch::activation_pending,
    .toplevel_security_context = QdwinBindingDispatch::toplevel_security_context,
    .toplevel_peer_identity    = QdwinBindingDispatch::toplevel_peer_identity,
    .seat_focus_changed        = QdwinBindingDispatch::seat_focus_changed,
    .data_offer_receive_pending = QdwinBindingDispatch::data_offer_receive_pending,
    .hotkey_pressed            = QdwinBindingDispatch::hotkey_pressed,
    .chrome_button             = QdwinBindingDispatch::chrome_button,
    .popup_button              = QdwinBindingDispatch::popup_button,
    .toplevel_workspace        = QdwinBindingDispatch::toplevel_workspace,
};

// -------------------- ext-workspace-v1 client trampolines --------------------
//
// The standard workspace protocol. We bind the manager on the same
// wl_display as qdwin_shell_v1 (one notifier, one dispatch loop). The
// manager streams workspace_group + workspace handles and batches state
// with `done`; we collapse that into workspaceCount_ / activeWorkspace_
// on each done and emit workspacesChanged. Handle/group binding is routed
// through QdwinBinding members so the trampolines don't need to reference
// the listener globals defined below them.

struct QdwinWsDispatch {
    // ---- ext_workspace_handle_v1 ----
    static void h_id(void *, ext_workspace_handle_v1 *, const char *) {}
    static void h_name(void *, ext_workspace_handle_v1 *, const char *) {}
    static void h_coordinates(void *d, ext_workspace_handle_v1 *h,
                              wl_array *coords) {
        auto *b = static_cast<QdwinBinding *>(d);
        auto *e = b->wsEntryFor(h);
        if (e && coords && coords->size >= sizeof(uint32_t)) {
            e->coord = *static_cast<uint32_t *>(coords->data);
            e->haveCoord = true;
        }
    }
    static void h_state(void *d, ext_workspace_handle_v1 *h, uint32_t state) {
        auto *b = static_cast<QdwinBinding *>(d);
        auto *e = b->wsEntryFor(h);
        if (e) e->state = state;
    }
    static void h_capabilities(void *, ext_workspace_handle_v1 *, uint32_t) {}
    static void h_removed(void *d, ext_workspace_handle_v1 *h) {
        auto *b = static_cast<QdwinBinding *>(d);
        auto *e = b->wsEntryFor(h);
        if (e) e->removed = true;
    }
    // ---- ext_workspace_group_handle_v1 (single desktop-spanning group) ----
    static void g_capabilities(void *, ext_workspace_group_handle_v1 *, uint32_t) {}
    static void g_output_enter(void *, ext_workspace_group_handle_v1 *, wl_output *) {}
    static void g_output_leave(void *, ext_workspace_group_handle_v1 *, wl_output *) {}
    static void g_workspace_enter(void *, ext_workspace_group_handle_v1 *,
                                  ext_workspace_handle_v1 *) {}
    static void g_workspace_leave(void *, ext_workspace_group_handle_v1 *,
                                  ext_workspace_handle_v1 *) {}
    static void g_removed(void *, ext_workspace_group_handle_v1 *) {}
    // ---- ext_workspace_manager_v1 ----
    static void m_workspace_group(void *d, ext_workspace_manager_v1 *,
                                  ext_workspace_group_handle_v1 *grp) {
        static_cast<QdwinBinding *>(d)->wsBindGroup(grp);
    }
    static void m_workspace(void *d, ext_workspace_manager_v1 *,
                            ext_workspace_handle_v1 *ws) {
        static_cast<QdwinBinding *>(d)->wsBindHandle(ws);
    }
    static void m_done(void *d, ext_workspace_manager_v1 *) {
        static_cast<QdwinBinding *>(d)->wsRebuild();
    }
    static void m_finished(void *d, ext_workspace_manager_v1 *) {
        static_cast<QdwinBinding *>(d)->wsFinished();
    }
};

static const ext_workspace_handle_v1_listener kWsHandleListener = {
    .id           = QdwinWsDispatch::h_id,
    .name         = QdwinWsDispatch::h_name,
    .coordinates  = QdwinWsDispatch::h_coordinates,
    .state        = QdwinWsDispatch::h_state,
    .capabilities = QdwinWsDispatch::h_capabilities,
    .removed      = QdwinWsDispatch::h_removed,
};

static const ext_workspace_group_handle_v1_listener kWsGroupListener = {
    .capabilities    = QdwinWsDispatch::g_capabilities,
    .output_enter    = QdwinWsDispatch::g_output_enter,
    .output_leave    = QdwinWsDispatch::g_output_leave,
    .workspace_enter = QdwinWsDispatch::g_workspace_enter,
    .workspace_leave = QdwinWsDispatch::g_workspace_leave,
    .removed         = QdwinWsDispatch::g_removed,
};

static const ext_workspace_manager_v1_listener kWsManagerListener = {
    .workspace_group = QdwinWsDispatch::m_workspace_group,
    .workspace       = QdwinWsDispatch::m_workspace,
    .done            = QdwinWsDispatch::m_done,
    .finished        = QdwinWsDispatch::m_finished,
};

// ---- wlr-output-management-v1 client dispatch ----
// Mirror of QdwinWsDispatch: trampolines from the C listener structs into
// QdwinBinding member functions (QdwinOmDispatch is a friend).
struct QdwinOmDispatch {
    // ---- zwlr_output_mode_v1 ----
    static void md_size(void *d, zwlr_output_mode_v1 *m, int32_t w, int32_t h) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omModeFor(m)) { e->width = w; e->height = h; }
    }
    static void md_refresh(void *d, zwlr_output_mode_v1 *m, int32_t r) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omModeFor(m)) e->refresh = r;
    }
    static void md_preferred(void *d, zwlr_output_mode_v1 *m) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omModeFor(m)) e->preferred = true;
    }
    static void md_finished(void *d, zwlr_output_mode_v1 *m) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omModeFor(m)) {
            if (e->proxy) {
                zwlr_output_mode_v1_release(e->proxy);
                e->proxy = nullptr;
            }
        }
    }
    // ---- zwlr_output_head_v1 ----
    static void hd_name(void *d, zwlr_output_head_v1 *h, const char *n) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->name = qstr(n);
    }
    static void hd_description(void *d, zwlr_output_head_v1 *h, const char *s) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->description = qstr(s);
    }
    static void hd_physical_size(void *, zwlr_output_head_v1 *, int32_t, int32_t) {}
    static void hd_mode(void *d, zwlr_output_head_v1 *h, zwlr_output_mode_v1 *m) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) {
            QdwinBinding::OmModeInfo mi;
            mi.proxy = m;
            e->modes.push_back(mi);
            zwlr_output_mode_v1_add_listener(m, &kOmModeListener, b);
        }
    }
    static void hd_enabled(void *d, zwlr_output_head_v1 *h, int32_t en) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->enabled = (en != 0);
    }
    static void hd_current_mode(void *d, zwlr_output_head_v1 *h,
                                zwlr_output_mode_v1 *m) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->currentMode = m;
    }
    static void hd_position(void *d, zwlr_output_head_v1 *h, int32_t x, int32_t y) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) { e->x = x; e->y = y; }
    }
    static void hd_transform(void *d, zwlr_output_head_v1 *h, int32_t t) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->transform = t;
    }
    static void hd_scale(void *d, zwlr_output_head_v1 *h, wl_fixed_t s) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) {
            int sc = wl_fixed_to_int(s);
            e->scale = sc < 1 ? 1 : sc;
        }
    }
    static void hd_finished(void *d, zwlr_output_head_v1 *h) {
        // The head is now inert (the compositor destroyed it as part of a
        // resync or a hotplug-remove). Mark it so omRebuild() reaps it and
        // omSubmitLayout() never references the dead proxy. Per spec we send
        // a destroy request and release it.
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) {
            e->finished = true;
            if (e->proxy) {
                zwlr_output_head_v1_release(e->proxy);
                e->proxy = nullptr;
            }
        }
    }
    static void hd_make(void *d, zwlr_output_head_v1 *h, const char *s) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->make = qstr(s);
    }
    static void hd_model(void *d, zwlr_output_head_v1 *h, const char *s) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->model = qstr(s);
    }
    static void hd_serial(void *d, zwlr_output_head_v1 *h, const char *s) {
        auto *b = static_cast<QdwinBinding *>(d);
        if (auto *e = b->omHeadFor(h)) e->serial = qstr(s);
    }
    static void hd_adaptive_sync(void *, zwlr_output_head_v1 *, uint32_t) {}
    // ---- zwlr_output_manager_v1 ----
    static void mgr_head(void *d, zwlr_output_manager_v1 *,
                         zwlr_output_head_v1 *h) {
        static_cast<QdwinBinding *>(d)->omBindHead(h);
    }
    static void mgr_done(void *d, zwlr_output_manager_v1 *, uint32_t serial) {
        auto *b = static_cast<QdwinBinding *>(d);
        b->outputSerial_ = serial;
        b->omRebuild();
    }
    static void mgr_finished(void *d, zwlr_output_manager_v1 *) {
        static_cast<QdwinBinding *>(d)->omTeardownState();
    }
    // ---- zwlr_output_configuration_v1 ----
    static void cfg_succeeded(void *d, zwlr_output_configuration_v1 *c) {
        static_cast<QdwinBinding *>(d)->omConfigResult(c, true, false);
    }
    static void cfg_failed(void *d, zwlr_output_configuration_v1 *c) {
        static_cast<QdwinBinding *>(d)->omConfigResult(c, false, false);
    }
    static void cfg_cancelled(void *d, zwlr_output_configuration_v1 *c) {
        static_cast<QdwinBinding *>(d)->omConfigResult(c, false, true);
    }

    static const zwlr_output_mode_v1_listener kOmModeListener;
};

const zwlr_output_mode_v1_listener QdwinOmDispatch::kOmModeListener = {
    .size      = QdwinOmDispatch::md_size,
    .refresh   = QdwinOmDispatch::md_refresh,
    .preferred = QdwinOmDispatch::md_preferred,
    .finished  = QdwinOmDispatch::md_finished,
};

static const zwlr_output_head_v1_listener kOmHeadListener = {
    .name          = QdwinOmDispatch::hd_name,
    .description    = QdwinOmDispatch::hd_description,
    .physical_size  = QdwinOmDispatch::hd_physical_size,
    .mode           = QdwinOmDispatch::hd_mode,
    .enabled        = QdwinOmDispatch::hd_enabled,
    .current_mode   = QdwinOmDispatch::hd_current_mode,
    .position       = QdwinOmDispatch::hd_position,
    .transform      = QdwinOmDispatch::hd_transform,
    .scale          = QdwinOmDispatch::hd_scale,
    .finished       = QdwinOmDispatch::hd_finished,
    .make           = QdwinOmDispatch::hd_make,
    .model          = QdwinOmDispatch::hd_model,
    .serial_number  = QdwinOmDispatch::hd_serial,
    .adaptive_sync  = QdwinOmDispatch::hd_adaptive_sync,
};

static const zwlr_output_manager_v1_listener kOmManagerListener = {
    .head     = QdwinOmDispatch::mgr_head,
    .done     = QdwinOmDispatch::mgr_done,
    .finished = QdwinOmDispatch::mgr_finished,
};

static const zwlr_output_configuration_v1_listener kOmConfigListener = {
    .succeeded = QdwinOmDispatch::cfg_succeeded,
    .failed    = QdwinOmDispatch::cfg_failed,
    .cancelled = QdwinOmDispatch::cfg_cancelled,
};

// wl_registry global handler — looks for qdwin_shell_v1 specifically.
// QdwinBindingDispatch is already a friend of QdwinBinding so it can
// write shell_ / shellVersion_ directly. We piggyback the registry
// callbacks on the same struct rather than introducing a second friend.
struct QdwinRegistry {
    static void global(void *data, wl_registry *reg, uint32_t name,
                       const char *interface, uint32_t version) {
        auto *b = static_cast<QdwinBinding *>(data);
        if (std::strcmp(interface, qdwin_shell_v1_interface.name) == 0) {
            uint32_t v = version < kBindVersion ? version : kBindVersion;
            auto *proxy = static_cast<qdwin_shell_v1 *>(
                wl_registry_bind(reg, name, &qdwin_shell_v1_interface, v));
            b->shell_ = proxy;
            b->shellVersion_ = v;
            return;
        }
        // v24: standard workspace protocol (advertised to all clients).
        if (std::strcmp(interface, ext_workspace_manager_v1_interface.name) == 0) {
            auto *mgr = static_cast<ext_workspace_manager_v1 *>(
                wl_registry_bind(reg, name,
                                 &ext_workspace_manager_v1_interface, 1));
            b->wsManager_ = mgr;
            ext_workspace_manager_v1_add_listener(mgr, &kWsManagerListener, b);
            return;
        }
        // Output (display) management (advertised to all clients).
        if (std::strcmp(interface, zwlr_output_manager_v1_interface.name) == 0) {
            uint32_t v = version < 4 ? version : 4;
            auto *mgr = static_cast<zwlr_output_manager_v1 *>(
                wl_registry_bind(reg, name,
                                 &zwlr_output_manager_v1_interface, v));
            b->omBindManager(mgr);
            return;
        }
    }
    static void global_remove(void *, wl_registry *, uint32_t) {}
};

static const wl_registry_listener kRegistryListener = {
    QdwinRegistry::global,
    QdwinRegistry::global_remove,
};

// -------------------- QdwinBinding --------------------

QdwinBinding::QdwinBinding(QObject *parent) : QObject(parent) {
    reconnectTimer_.setSingleShot(true);
    connect(&reconnectTimer_, &QTimer::timeout, this, [this]() {
        if (destroying_) return;
        qWarning().noquote() << "qdwin-binding: reconnect attempt"
                             << reconnectAttempts_;
        connectAndBind();
    });
    connectAndBind();

    ctrlServer_ = new CtrlServer(*this, this);
}

QdwinBinding::~QdwinBinding() {
    destroying_ = true;
    reconnectTimer_.stop();
    teardown(QStringLiteral("binding destroyed"));
}

void QdwinBinding::connectAndBind() {
    display_ = wl_display_connect(nullptr);
    if (!display_) {
        setLastError(QStringLiteral(
            "wl_display_connect failed (WAYLAND_DISPLAY=%1, errno=%2: %3)")
            .arg(qstr(std::getenv("WAYLAND_DISPLAY")))
            .arg(errno).arg(qstr(std::strerror(errno))));
        emit disconnected();
        return;
    }

    registry_ = wl_display_get_registry(display_);
    wl_registry_add_listener(registry_, &kRegistryListener, this);
    wl_display_roundtrip(display_);

    if (!shell_) {
        setLastError(QStringLiteral(
            "qdwin_shell_v1 global not advertised on this display"));
        teardown(lastError_);
        return;
    }

    qdwin_shell_v1_add_listener(shell_, &kShellListener, this);
    qdwin_shell_v1_bind_as_shell(shell_);

    // Bind initiated. The hello event arrives on the next dispatch and
    // sets bound_ = true via QdwinBindingDispatch::hello. Flush so the
    // bind_as_shell write actually hits the socket.
    if (wl_display_flush(display_) == -1) {
        setLastError(QStringLiteral("wl_display_flush after bind_as_shell failed"));
        teardown(lastError_);
        return;
    }

    readNotifier_ = new QSocketNotifier(wl_display_get_fd(display_),
                                        QSocketNotifier::Read, this);
    connect(readNotifier_, &QSocketNotifier::activated,
            this, &QdwinBinding::onWaylandReadable);
}

void QdwinBinding::onWaylandReadable() {
    if (!display_) return;

    // wl_display_dispatch reads + dispatches; non-blocking when the fd
    // is readable, which QSocketNotifier guarantees here.
    int n = wl_display_dispatch(display_);
    if (n == -1) {
        setLastError(QStringLiteral("wl_display_dispatch failed: errno=%1: %2")
                     .arg(errno).arg(qstr(std::strerror(errno))));
        teardown(lastError_);
        return;
    }
    // Flush so any outgoing requests written from QML during dispatch
    // (e.g. focusWindow called from a signal handler) reach the socket.
    if (wl_display_flush(display_) == -1 && errno != EAGAIN) {
        setLastError(QStringLiteral("wl_display_flush failed: errno=%1: %2")
                     .arg(errno).arg(qstr(std::strerror(errno))));
        teardown(lastError_);
        return;
    }
}

void QdwinBinding::teardown(const QString &reason) {
    if (readNotifier_) {
        readNotifier_->setEnabled(false);
        readNotifier_->deleteLater();
        readNotifier_ = nullptr;
    }
    if (display_) {
        wl_display_disconnect(display_);
        display_ = nullptr;
    }
    registry_ = nullptr;
    shell_ = nullptr;
    wsTeardownState();
    omTeardownState();
    if (bound_) setBound(false);
    if (!reason.isEmpty() && lastError_.isEmpty())
        setLastError(reason);
    emit disconnected();
    // Schedule a reconnect on any non-destructor teardown — covers
    // qdwin/weston restarts, transient broken-pipe on the wayland
    // socket, and bind-time failures (display not yet up). The
    // destructor sets destroying_ so we don't fire after delete.
    if (!destroying_) scheduleReconnect();
}

void QdwinBinding::scheduleReconnect() {
    if (destroying_) return;
    // Exponential backoff with a cap so we don't busy-loop if the
    // compositor never comes back. 200 ms → 400 ms → 800 ms → … →
    // 5000 ms ceiling. Reset on a successful hello (setBound(true)).
    int ms = 200;
    for (int i = 0; i < reconnectAttempts_ && ms < 5000; ++i) ms *= 2;
    if (ms > 5000) ms = 5000;
    reconnectAttempts_++;
    reconnectTimer_.start(ms);
}

void QdwinBinding::setLastError(const QString &s) {
    if (lastError_ == s) return;
    lastError_ = s;
    qWarning().noquote() << "qdwin-binding: error:" << s;
    emit lastErrorChanged();
}

void QdwinBinding::setBound(bool b) {
    if (bound_ == b) return;
    bound_ = b;
    if (b) {
        // A successful hello resets the reconnect backoff so the next
        // unexpected disconnect retries promptly rather than at the
        // previous attempt's ceiling.
        reconnectAttempts_ = 0;
        lastError_.clear();
    }
    emit boundChanged();
}

void QdwinBinding::setFocused(const QString &seat, quint32 handle) {
    if (focusedSeat_ == seat && focusedHandle_ == handle) return;
    focusedSeat_ = seat;
    focusedHandle_ = handle;
    emit focusedHandleChanged();
}

// -------- imperative requests ----------

void QdwinBinding::focusWindow(quint32 handle, const QString &seat) {
    if (!shell_) return;
    QByteArray seatUtf8 = seat.toUtf8();
    qdwin_shell_v1_set_keyboard_focus(shell_, seatUtf8.constData(), handle);
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::closeWindow(quint32 handle) {
    if (!shell_) return;
    qdwin_shell_v1_request_close(shell_, handle);
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::requestMaximize(quint32 handle, bool maximized) {
    if (!shell_) return;
    qdwin_shell_v1_request_maximize(shell_, handle, maximized ? 1u : 0u);
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::requestMinimize(quint32 handle) {
    if (!shell_) return;
    qdwin_shell_v1_request_minimize(shell_, handle);
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::setBorderColor(quint32 handle, quint32 argb) {
    if (!shell_) return;
    qdwin_shell_v1_set_border_color(shell_, handle, argb);
    if (display_) wl_display_flush(display_);
}

// -------- v24 workspaces (ext-workspace-v1 client) --------

void QdwinBinding::wsBindGroup(ext_workspace_group_handle_v1 *grp) {
    wsGroup_ = grp;
    ext_workspace_group_handle_v1_add_listener(grp, &kWsGroupListener, this);
}

void QdwinBinding::wsBindHandle(ext_workspace_handle_v1 *ws) {
    WsEntry e;
    e.proxy = ws;
    wsEntries_.push_back(e);
    ext_workspace_handle_v1_add_listener(ws, &kWsHandleListener, this);
}

QdwinBinding::WsEntry *QdwinBinding::wsEntryFor(ext_workspace_handle_v1 *h) {
    for (auto &e : wsEntries_)
        if (e.proxy == h)
            return &e;
    return nullptr;
}

// Collapse the accumulated handle events (fired since the last `done`)
// into the index-ordered view the bar consumes. Drops removed entries,
// orders by the 1-D coordinate qdwin sends (falls back to arrival order),
// and recomputes count + active. Emits workspacesChanged only on a real
// change so QML rebinds aren't spammed by no-op state echoes.
void QdwinBinding::wsRebuild() {
    // Reap removed handles (the compositor sent `removed`; the proxy is
    // inert — destroy it and forget the entry).
    for (auto it = wsEntries_.begin(); it != wsEntries_.end();) {
        if (it->removed) {
            if (it->proxy)
                ext_workspace_handle_v1_destroy(it->proxy);
            it = wsEntries_.erase(it);
        } else {
            ++it;
        }
    }
    // Order by coordinate so wsByIndex_[i] is workspace i.
    std::vector<WsEntry *> ordered;
    ordered.reserve(wsEntries_.size());
    for (auto &e : wsEntries_)
        ordered.push_back(&e);
    std::stable_sort(ordered.begin(), ordered.end(),
                     [](const WsEntry *a, const WsEntry *b) {
                         if (a->haveCoord && b->haveCoord)
                             return a->coord < b->coord;
                         return false;  // keep arrival order otherwise
                     });

    std::vector<ext_workspace_handle_v1 *> byIndex;
    quint32 active = 0;
    constexpr uint32_t kActive = 1u;  // EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE
    byIndex.reserve(ordered.size());
    for (auto *e : ordered) {
        if (e->state & kActive)
            active = static_cast<quint32>(byIndex.size());
        byIndex.push_back(e->proxy);
    }

    const quint32 count = static_cast<quint32>(byIndex.size());
    const bool changed = (count != workspaceCount_) ||
                         (active != activeWorkspace_) ||
                         (byIndex != wsByIndex_);
    wsByIndex_ = std::move(byIndex);
    workspaceCount_ = count;
    activeWorkspace_ = active;
    if (changed)
        emit workspacesChanged();
}

void QdwinBinding::wsTeardownState() {
    // Disconnect path: the wl_display is already gone (teardown()
    // disconnects before calling us), so the proxies are reaped with it.
    // Just drop our view so a fresh bind starts clean — do NOT touch the
    // dead proxies.
    wsEntries_.clear();
    wsByIndex_.clear();
    wsManager_ = nullptr;
    wsGroup_ = nullptr;
    if (workspaceCount_ != 0 || activeWorkspace_ != 0) {
        workspaceCount_ = 0;
        activeWorkspace_ = 0;
        emit workspacesChanged();
    }
}

// manager.finished path: the display is still live, so we own and must
// release the workspace/group proxies. (We never call ext_workspace_
// manager_v1.stop ourselves, so in practice this only fires if the
// compositor tears the manager down on its own.) The manager interface
// has no destroy request; we drop our reference and the proxy is reaped
// on the next disconnect.
void QdwinBinding::wsFinished() {
    for (auto &e : wsEntries_)
        if (e.proxy)
            ext_workspace_handle_v1_destroy(e.proxy);
    if (wsGroup_)
        ext_workspace_group_handle_v1_destroy(wsGroup_);
    wsTeardownState();
}

void QdwinBinding::activateWorkspace(quint32 index) {
    if (!wsManager_ || index >= wsByIndex_.size())
        return;
    ext_workspace_handle_v1_activate(wsByIndex_[index]);
    ext_workspace_manager_v1_commit(wsManager_);
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::createWorkspace() {
    if (!wsManager_ || !wsGroup_)
        return;
    // Name is positional on the qdwin side (ignored); the user's display
    // name is a shell-side overlay. Pass empty.
    ext_workspace_group_handle_v1_create_workspace(wsGroup_, "");
    ext_workspace_manager_v1_commit(wsManager_);
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::removeWorkspace(quint32 index) {
    if (!wsManager_ || index >= wsByIndex_.size())
        return;
    ext_workspace_handle_v1_remove(wsByIndex_[index]);
    ext_workspace_manager_v1_commit(wsManager_);
    if (display_) wl_display_flush(display_);
}

// Reconcile the compositor's workspace count to the shell's persisted
// setting by appending / removing from the end, then commit once. The
// model updates asynchronously via the manager `done`(s) that follow.
void QdwinBinding::setWorkspaceCount(quint32 count) {
    if (!wsManager_ || !wsGroup_)
        return;
    if (count < 1) count = 1;
    if (count > 32) count = 32;
    const quint32 cur = static_cast<quint32>(wsByIndex_.size());
    if (count > cur) {
        for (quint32 i = cur; i < count; i++)
            ext_workspace_group_handle_v1_create_workspace(wsGroup_, "");
    } else if (count < cur) {
        // Remove the highest-index workspaces first.
        for (quint32 i = cur; i > count; i--)
            ext_workspace_handle_v1_remove(wsByIndex_[i - 1]);
    } else {
        return;  // already matches
    }
    ext_workspace_manager_v1_commit(wsManager_);
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::moveToplevelToWorkspace(quint32 handle, quint32 index) {
    if (!shell_ || shellVersion_ < 24)
        return;
    qdwin_shell_v1_move_toplevel_to_workspace(shell_, handle, index);
    if (display_) wl_display_flush(display_);
}

// ==================== output (display) management ====================

void QdwinBinding::omBindManager(zwlr_output_manager_v1 *mgr) {
    omManager_ = mgr;
    zwlr_output_manager_v1_add_listener(mgr, &kOmManagerListener, this);
}

void QdwinBinding::omBindHead(zwlr_output_head_v1 *head) {
    OmHeadInfo h;
    h.proxy = head;
    omHeads_.push_back(std::move(h));
    zwlr_output_head_v1_add_listener(head, &kOmHeadListener, this);
}

QdwinBinding::OmHeadInfo *QdwinBinding::omHeadFor(zwlr_output_head_v1 *h) {
    for (auto &e : omHeads_)
        if (e.proxy == h)
            return &e;
    return nullptr;
}

QdwinBinding::OmModeInfo *QdwinBinding::omModeFor(zwlr_output_mode_v1 *m) {
    for (auto &h : omHeads_)
        for (auto &md : h.modes)
            if (md.proxy == m)
                return &md;
    return nullptr;
}

// Collapse the accumulated head/mode events into the QVariantList the
// Display layout tab renders. The protocol re-sends the whole head set on
// every `done` (after destroying the old heads with `finished`), so we
// rebuild from scratch each time and forget the stale proxies — they are
// inert. Each output map carries name/description/make/model/serial (all
// PlainText on the QML side — never shell-interpolated), enabled, x/y,
// scale, transform, the mode list, and the current mode index.
void QdwinBinding::omRebuild() {
    // Reap heads the compositor has finished (it destroys + recreates the
    // whole head set on every resync). Their proxies were already released in
    // hd_finished; drop the entries so outputs_ and omSubmitLayout only ever
    // see live heads.
    omHeads_.erase(std::remove_if(omHeads_.begin(), omHeads_.end(),
                   [](const OmHeadInfo &h) { return h.finished; }),
                   omHeads_.end());
    QVariantList out;
    for (const auto &h : omHeads_) {
        QVariantMap m;
        m["name"] = h.name;
        m["description"] = h.description;
        m["make"] = h.make;
        m["model"] = h.model;
        m["serial"] = h.serial;
        m["enabled"] = h.enabled;
        m["x"] = h.x;
        m["y"] = h.y;
        m["scale"] = h.scale;
        m["transform"] = h.transform;
        QVariantList modes;
        int currentIdx = -1;
        for (int i = 0; i < static_cast<int>(h.modes.size()); ++i) {
            const auto &md = h.modes[i];
            QVariantMap mm;
            mm["width"] = md.width;
            mm["height"] = md.height;
            mm["refresh"] = md.refresh;
            mm["preferred"] = md.preferred;
            modes.append(mm);
            if (md.proxy == h.currentMode)
                currentIdx = i;
        }
        m["modes"] = modes;
        m["currentMode"] = currentIdx;
        out.append(m);
    }
    outputs_ = std::move(out);
    emit outputsChanged();
}

void QdwinBinding::omTeardownState() {
    // Disconnect / manager.finished path: proxies are reaped with the
    // display (or inert after finished). Drop our view so a fresh bind
    // starts clean.
    omHeads_.clear();
    omConfigs_.clear();
    outputs_.clear();
    omManager_ = nullptr;
    outputSerial_ = 0;
    emit outputsChanged();
}

void QdwinBinding::omConfigResult(zwlr_output_configuration_v1 *cfg, bool ok,
                                  bool cancelled) {
    bool applied = false;
    for (auto it = omConfigs_.begin(); it != omConfigs_.end(); ++it) {
        if (it->proxy == cfg) {
            applied = it->applied;
            omConfigs_.erase(it);
            break;
        }
    }
    // Per spec the client destroys the configuration object on any of
    // succeeded/failed/cancelled.
    zwlr_output_configuration_v1_destroy(cfg);
    if (display_) wl_display_flush(display_);
    emit layoutResult(applied, ok, cancelled);
}

// Build a configuration for `layout` against `serial` and apply or test it.
// Returns false (no attempt) if there is no live manager. Every advertised
// head must be configured (the protocol errors on an omitted head), so we
// iterate the enumerated head set and either match it to a layout entry
// (by name) or carry its current enabled state forward unchanged.
bool QdwinBinding::omSubmitLayout(const QVariantList &layout, quint32 serial,
                                  bool apply) {
    if (!omManager_)
        return false;

    auto *cfg = zwlr_output_manager_v1_create_configuration(omManager_, serial);
    if (!cfg)
        return false;
    OmConfig rec;
    rec.proxy = cfg;
    rec.applied = apply;
    omConfigs_.push_back(rec);
    zwlr_output_configuration_v1_add_listener(cfg, &kOmConfigListener, this);

    for (auto &h : omHeads_) {
        if (h.finished || !h.proxy)
            continue;  // inert head — never reference a dead proxy
        // Find the matching layout entry by name (PlainText match; names
        // come from the compositor, not user input).
        const QVariantMap *want = nullptr;
        QVariantMap wantStore;
        for (const QVariant &v : layout) {
            QVariantMap e = v.toMap();
            if (e.value("name").toString() == h.name) {
                wantStore = e;
                want = &wantStore;
                break;
            }
        }
        bool enable = want ? want->value("enabled", h.enabled).toBool()
                           : h.enabled;
        if (!enable) {
            zwlr_output_configuration_v1_disable_head(cfg, h.proxy);
            continue;
        }
        auto *ch = zwlr_output_configuration_v1_enable_head(cfg, h.proxy);
        if (!want)
            continue;  // enabled, untouched — keep all current properties
        // Mode: prefer an exact width/height/refresh match against an
        // advertised mode (set_mode); fall back to set_custom_mode so the
        // compositor can validate against its mode_list.
        if (want->contains("width") && want->contains("height")) {
            int w = want->value("width").toInt();
            int hh = want->value("height").toInt();
            int refresh = want->value("refresh", 0).toInt();
            zwlr_output_mode_v1 *exact = nullptr;
            for (const auto &md : h.modes) {
                if (md.width == w && md.height == hh &&
                    (refresh == 0 || md.refresh == refresh)) {
                    exact = md.proxy;
                    break;
                }
            }
            if (exact)
                zwlr_output_configuration_head_v1_set_mode(ch, exact);
            else
                zwlr_output_configuration_head_v1_set_custom_mode(ch, w, hh,
                                                                  refresh);
        }
        if (want->contains("x") && want->contains("y"))
            zwlr_output_configuration_head_v1_set_position(ch,
                want->value("x").toInt(), want->value("y").toInt());
        if (want->contains("transform"))
            zwlr_output_configuration_head_v1_set_transform(ch,
                want->value("transform").toInt());
        if (want->contains("scale")) {
            double sc = want->value("scale").toDouble();
            if (sc <= 0) sc = 1.0;
            zwlr_output_configuration_head_v1_set_scale(ch,
                wl_fixed_from_double(sc));
        }
    }

    if (apply)
        zwlr_output_configuration_v1_apply(cfg);
    else
        zwlr_output_configuration_v1_test(cfg);
    if (display_) wl_display_flush(display_);
    return true;
}

bool QdwinBinding::applyLayout(const QVariantList &layout, quint32 serial) {
    return omSubmitLayout(layout, serial, true);
}

bool QdwinBinding::testLayout(const QVariantList &layout, quint32 serial) {
    return omSubmitLayout(layout, serial, false);
}

// spec/10 §"clear_selection" — deny verdict from broker; compositor
// drops the seat's selection (and primary equivalent when isPrimary=1).
void QdwinBinding::clearSelection(const QString &seat, quint32 isPrimary) {
    if (!shell_) return;
    QByteArray seatUtf8 = seat.toUtf8();
    qdwin_shell_v1_clear_selection(shell_, seatUtf8.constData(), isPrimary);
    if (display_) wl_display_flush(display_);
}

// spec/10 §"receive-time gating" — echo the broker verdict back for a
// pending wl_data_offer.receive. "allow" runs the source's original
// send; anything else (incl. our "deny") closes the destination fd.
void QdwinBinding::sendDataOfferReceiveDecision(quint32 requestHandle,
                                                bool allow) {
    if (!shell_) return;
    qdwin_shell_v1_data_offer_receive_decision(shell_, requestHandle,
                                               allow ? "allow" : "deny");
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::nestedProxyDecision(quint32 handle, quint32 decision,
                                       const QString &reason) {
    if (!shell_) return;
    QByteArray reasonUtf8 = reason.toUtf8();
    qdwin_shell_v1_nested_proxy_decision(shell_, handle, decision,
                                         reasonUtf8.constData());
    if (display_) wl_display_flush(display_);
}

void QdwinBinding::activationDecision(quint32 handle, quint32 decision,
                                      const QString &reason) {
    if (!shell_) return;
    QByteArray reasonUtf8 = reason.toUtf8();
    qdwin_shell_v1_activation_decision(shell_, handle, decision,
                                       reasonUtf8.constData());
    if (display_) wl_display_flush(display_);
}

QVariantMap QdwinBinding::checkPermission(const QString &action,
                                          const QVariantMap &details) {
    QStringList args = {
        QStringLiteral("--system"),
        QStringLiteral("--no-pager"),
        QString::fromLatin1(kBrokerGateBusctlTimeout),
        QStringLiteral("call"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("/org/qdistro/AdminBroker1"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("CheckPermission"),
        QStringLiteral("sa{sv}"),
        action,
    };
    appendVariantDict(args, details);

    QProcess proc;
    proc.setProgram(QStringLiteral("busctl"));
    proc.setArguments(args);
    proc.start();
    if (!proc.waitForStarted(kBrokerStartTimeoutMs)) {
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"), QString()},
            {QStringLiteral("stderr"), proc.errorString()},
            {QStringLiteral("timedOut"), false},
        };
    }
    if (!proc.waitForFinished(kBrokerGateTimeoutMs)) {
        proc.kill();
        proc.waitForFinished(50);
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"),
             QString::fromUtf8(proc.readAllStandardOutput())},
            {QStringLiteral("stderr"), QStringLiteral("timeout")},
            {QStringLiteral("timedOut"), true},
        };
    }
    return {
        {QStringLiteral("exitCode"), proc.exitCode()},
        {QStringLiteral("stdout"),
         QString::fromUtf8(proc.readAllStandardOutput())},
        {QStringLiteral("stderr"),
         QString::fromUtf8(proc.readAllStandardError())},
        {QStringLiteral("timedOut"), false},
    };
}

bool QdwinBinding::verifyClientIdentity(
    quint32 pid,
    quint64 starttime,
    quint32 uid,
    const QString &exe,
    const QString &selinuxLabel,
    const QString &sandboxEngine,
    const QString &appId,
    const QString &instanceId) {
    QStringList args = {
        QStringLiteral("--system"),
        QStringLiteral("--no-pager"),
        QString::fromLatin1(kBrokerGateBusctlTimeout),
        QStringLiteral("call"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("/org/qdistro/AdminBroker1"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("VerifyClientIdentity"),
        QStringLiteral("utusssss"),
        QString::number(pid),
        QString::number(starttime),
        QString::number(uid),
        exe,
        selinuxLabel,
        sandboxEngine,
        appId,
        instanceId,
    };

    QProcess proc;
    proc.setProgram(QStringLiteral("busctl"));
    proc.setArguments(args);
    proc.start();
    if (!proc.waitForStarted(kBrokerStartTimeoutMs))
        return false;
    if (!proc.waitForFinished(kBrokerGateTimeoutMs)) {
        proc.kill();
        proc.waitForFinished(50);
        return false;
    }
    if (proc.exitCode() != 0)
        return false;
    const QString out = QString::fromUtf8(proc.readAllStandardOutput()).trimmed();
    return out == QStringLiteral("b true");
}

QVariantMap QdwinBinding::checkHandoffActivation(
    const QString &sourceSilo,
    const QString &destSilo,
    const QString &sourceAppId,
    const QString &destAppId,
    const QString &sourceSandboxEngine,
    bool identityVerified,
    uint sourcePid,
    qulonglong sourceStarttime) {
    QStringList args = {
        QStringLiteral("--system"),
        QStringLiteral("--no-pager"),
        QString::fromLatin1(kBrokerGateBusctlTimeout),
        QStringLiteral("call"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("/org/qdistro/AdminBroker1"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("CheckHandoffActivation"),
        QStringLiteral("sssssbut"),
        sourceSilo,
        destSilo,
        sourceAppId,
        destAppId,
        sourceSandboxEngine,
        identityVerified ? QStringLiteral("true") : QStringLiteral("false"),
        QString::number(sourcePid),
        QString::number(sourceStarttime),
    };

    QProcess proc;
    proc.setProgram(QStringLiteral("busctl"));
    proc.setArguments(args);
    proc.start();
    if (!proc.waitForStarted(kBrokerStartTimeoutMs)) {
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"), QString()},
            {QStringLiteral("stderr"), proc.errorString()},
            {QStringLiteral("timedOut"), false},
        };
    }
    if (!proc.waitForFinished(kBrokerGateTimeoutMs)) {
        proc.kill();
        proc.waitForFinished(50);
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"),
             QString::fromUtf8(proc.readAllStandardOutput())},
            {QStringLiteral("stderr"), QStringLiteral("timeout")},
            {QStringLiteral("timedOut"), true},
        };
    }
    return {
        {QStringLiteral("exitCode"), proc.exitCode()},
        {QStringLiteral("stdout"),
         QString::fromUtf8(proc.readAllStandardOutput())},
        {QStringLiteral("stderr"),
         QString::fromUtf8(proc.readAllStandardError())},
        {QStringLiteral("timedOut"), false},
    };
}

QVariantMap QdwinBinding::checkClipboardTransfer(
    const QString &sourceSilo,
    const QString &destSilo,
    const QStringList &mimeTypes,
    const QString &sourceAppId,
    const QString &destAppId,
    const QString &sourceSandboxEngine,
    bool identityVerified,
    uint sourcePid,
    qulonglong sourceStarttime) {
    QStringList args = {
        QStringLiteral("--system"),
        QStringLiteral("--no-pager"),
        QString::fromLatin1(kBrokerDefaultBusctlTimeout),
        QStringLiteral("call"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("/org/qdistro/AdminBroker1"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("CheckClipboardTransfer"),
        QStringLiteral("ssassssbut"),
        sourceSilo,
        destSilo,
        QString::number(mimeTypes.size()),
    };
    args.append(mimeTypes);
    args.append(sourceAppId);
    args.append(destAppId);
    args.append(sourceSandboxEngine);
    args.append(identityVerified ? QStringLiteral("true")
                                 : QStringLiteral("false"));
    args.append(QString::number(sourcePid));
    args.append(QString::number(sourceStarttime));

    QProcess proc;
    proc.setProgram(QStringLiteral("busctl"));
    proc.setArguments(args);
    proc.start();
    if (!proc.waitForStarted(kBrokerStartTimeoutMs)) {
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"), QString()},
            {QStringLiteral("stderr"), proc.errorString()},
            {QStringLiteral("timedOut"), false},
        };
    }
    if (!proc.waitForFinished(kBrokerDefaultTimeoutMs)) {
        proc.kill();
        proc.waitForFinished(50);
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"),
             QString::fromUtf8(proc.readAllStandardOutput())},
            {QStringLiteral("stderr"), QStringLiteral("timeout")},
            {QStringLiteral("timedOut"), true},
        };
    }
    return {
        {QStringLiteral("exitCode"), proc.exitCode()},
        {QStringLiteral("stdout"),
         QString::fromUtf8(proc.readAllStandardOutput())},
        {QStringLiteral("stderr"),
         QString::fromUtf8(proc.readAllStandardError())},
        {QStringLiteral("timedOut"), false},
    };
}

// spec/10 receive-time twin of checkClipboardTransfer. Signature
// ssssssb with a SINGLE mime (the compositor gates each receive()
// individually, so there is no count/list as at set time).
QVariantMap QdwinBinding::checkClipboardReceive(
    const QString &sourceSilo,
    const QString &destSilo,
    const QString &mimeType,
    const QString &sourceAppId,
    const QString &destAppId,
    const QString &sourceSandboxEngine,
    bool identityVerified,
    uint sourcePid,
    qulonglong sourceStarttime) {
    QStringList args = {
        QStringLiteral("--system"),
        QStringLiteral("--no-pager"),
        QString::fromLatin1(kBrokerDefaultBusctlTimeout),
        QStringLiteral("call"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("/org/qdistro/AdminBroker1"),
        QStringLiteral("org.qdistro.AdminBroker1"),
        QStringLiteral("CheckClipboardReceive"),
        QStringLiteral("ssssssbut"),
        sourceSilo,
        destSilo,
        mimeType,
        sourceAppId,
        destAppId,
        sourceSandboxEngine,
        identityVerified ? QStringLiteral("true")
                         : QStringLiteral("false"),
        QString::number(sourcePid),
        QString::number(sourceStarttime),
    };

    QProcess proc;
    proc.setProgram(QStringLiteral("busctl"));
    proc.setArguments(args);
    proc.start();
    if (!proc.waitForStarted(kBrokerStartTimeoutMs)) {
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"), QString()},
            {QStringLiteral("stderr"), proc.errorString()},
            {QStringLiteral("timedOut"), false},
        };
    }
    if (!proc.waitForFinished(kBrokerDefaultTimeoutMs)) {
        proc.kill();
        proc.waitForFinished(50);
        return {
            {QStringLiteral("exitCode"), -1},
            {QStringLiteral("stdout"),
             QString::fromUtf8(proc.readAllStandardOutput())},
            {QStringLiteral("stderr"), QStringLiteral("timeout")},
            {QStringLiteral("timedOut"), true},
        };
    }
    return {
        {QStringLiteral("exitCode"), proc.exitCode()},
        {QStringLiteral("stdout"),
         QString::fromUtf8(proc.readAllStandardOutput())},
        {QStringLiteral("stderr"),
         QString::fromUtf8(proc.readAllStandardError())},
        {QStringLiteral("timedOut"), false},
    };
}
