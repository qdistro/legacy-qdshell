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

#include <wayland-client.h>
#include "qdwin-shell-v1-client-protocol.h"

#include <QDebug>
#include <QString>

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
constexpr uint32_t kBindVersion = 23;

inline QString qstr(const char *s) {
    return s ? QString::fromUtf8(s) : QString();
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
    static void nested_proxy_pending(void *, qdwin_shell_v1 *,
                                     uint32_t, const char *, uint32_t) {}
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
    static void activation_pending(void *, qdwin_shell_v1 *,
                                   uint32_t, uint32_t, uint32_t, const char *) {}
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

    // v15+ slots — never fired at our current bind version (14) but
    // wired as no-ops so a future BIND_VERSION bump doesn't crash on a
    // NULL listener slot.
    static void overlay_key(void *, qdwin_shell_v1 *,
                            uint32_t, uint32_t, const char *, uint32_t) {}
    static void data_offer_receive_pending(void *, qdwin_shell_v1 *,
                                           uint32_t, const char *,
                                           uint32_t, uint32_t, const char *) {}
    static void hotkey_pressed(void *, qdwin_shell_v1 *, uint32_t) {}
    static void chrome_button(void *, qdwin_shell_v1 *,
                              uint32_t, uint32_t, wl_fixed_t, wl_fixed_t,
                              uint32_t, uint32_t) {}
    static void popup_button(void *, qdwin_shell_v1 *,
                             uint32_t, wl_fixed_t, wl_fixed_t,
                             uint32_t, uint32_t) {}
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
};

// wl_registry global handler — looks for qdwin_shell_v1 specifically.
// QdwinBindingDispatch is already a friend of QdwinBinding so it can
// write shell_ / shellVersion_ directly. We piggyback the registry
// callbacks on the same struct rather than introducing a second friend.
struct QdwinRegistry {
    static void global(void *data, wl_registry *reg, uint32_t name,
                       const char *interface, uint32_t version) {
        auto *b = static_cast<QdwinBinding *>(data);
        if (std::strcmp(interface, qdwin_shell_v1_interface.name) != 0)
            return;
        uint32_t v = version < kBindVersion ? version : kBindVersion;
        auto *proxy = static_cast<qdwin_shell_v1 *>(
            wl_registry_bind(reg, name, &qdwin_shell_v1_interface, v));
        b->shell_ = proxy;
        b->shellVersion_ = v;
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

// spec/10 §"clear_selection" — deny verdict from broker; compositor
// drops the seat's selection (and primary equivalent when isPrimary=1).
void QdwinBinding::clearSelection(const QString &seat, quint32 isPrimary) {
    if (!shell_) return;
    QByteArray seatUtf8 = seat.toUtf8();
    qdwin_shell_v1_clear_selection(shell_, seatUtf8.constData(), isPrimary);
    if (display_) wl_display_flush(display_);
}
