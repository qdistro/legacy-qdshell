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
constexpr uint32_t kBindVersion = 14;

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
    static void nested_proxy_pixel_source(void *, qdwin_shell_v1 *,
                                          uint32_t, const char *, const char *) {}
    static void selection_set(void *, qdwin_shell_v1 *,
                              const char *, uint32_t, const char *, uint32_t) {}
    static void activation_pending(void *, qdwin_shell_v1 *,
                                   uint32_t, uint32_t, uint32_t, const char *) {}
    static void toplevel_security_context(void *d, qdwin_shell_v1 *,
                                          uint32_t handle,
                                          const char *sandbox_engine,
                                          const char *app_id,
                                          const char *instance_id) {
        auto *b = static_cast<QdwinBinding *>(d);
        emit b->toplevelSecurityContext(handle,
                                        qstr(sandbox_engine),
                                        qstr(app_id),
                                        qstr(instance_id));
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
    .activation_pending        = QdwinBindingDispatch::activation_pending,
    .toplevel_security_context = QdwinBindingDispatch::toplevel_security_context,
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
    connectAndBind();
}

QdwinBinding::~QdwinBinding() {
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
