// qdwin-binding — Qt6 QML plugin that exposes qdwin_shell_v1 to QML.
//
// Loaded by qs / noctalia-qs via QML_IMPORT_PATH; consumed from
// qdshell/Services/Qdwin/Qdwin.qml as `import Qdistro.Qdwin 1.0`
// then `QdwinBinding { id: binding; ... }`. On construction the
// binding wl_registry_binds qdwin_shell_v1 at v14, calls bind_as_shell,
// and starts dispatching events on a QSocketNotifier attached to the
// wl_display fd — so all wayland traffic flows through the host Qt
// event loop without a worker thread.
//
// MVP scope: observable bind state, focus events, toplevel adds/
// removes, and the imperative methods qdshell's existing
// Services/Qdwin/Qdwin.qml TODO stubs need (focusWindow/closeWindow/
// requestMaximize/requestMinimize). Anything in qdwin-shell-v1.xml
// beyond that (workspaces, seats lifecycle, outputs, view streams,
// activation tokens, clipboard mirror, nested) is reserved for phase
// 2 — add signals/methods one at a time as consumers grow.
//
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <QObject>
#include <QString>
#include <QSocketNotifier>
#include <QTimer>
#include <cstdint>

struct wl_display;
struct wl_registry;
struct qdwin_shell_v1;

class QdwinBinding : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool bound READ bound NOTIFY boundChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(quint32 shellVersion READ shellVersion NOTIFY boundChanged)
    Q_PROPERTY(quint32 focusedHandle READ focusedHandle NOTIFY focusedHandleChanged)
    Q_PROPERTY(QString focusedSeat READ focusedSeat NOTIFY focusedHandleChanged)

public:
    explicit QdwinBinding(QObject *parent = nullptr);
    ~QdwinBinding() override;

    bool bound() const { return bound_; }
    QString lastError() const { return lastError_; }
    quint32 shellVersion() const { return shellVersion_; }
    quint32 focusedHandle() const { return focusedHandle_; }
    QString focusedSeat() const { return focusedSeat_; }

    Q_INVOKABLE void focusWindow(quint32 handle, const QString &seat = QStringLiteral("default"));
    Q_INVOKABLE void closeWindow(quint32 handle);
    Q_INVOKABLE void requestMaximize(quint32 handle, bool maximized);
    Q_INVOKABLE void requestMinimize(quint32 handle);
    Q_INVOKABLE void setBorderColor(quint32 handle, quint32 argb);

    // spec/10 §"compositor-mediated gating" — once the shell has a
    // broker verdict on the most recent selection_set, it calls
    // clearSelection on a "deny". `isPrimary` mirrors the event
    // arg: 0 = clipboard, 1 = primary selection.
    Q_INVOKABLE void clearSelection(const QString &seat, quint32 isPrimary);

signals:
    void boundChanged();
    void lastErrorChanged();
    void focusedHandleChanged();

    void hello(quint32 uid);
    void toplevelAdded(quint32 handle, quint32 ownerUid, const QString &appId,
                       const QString &title, bool isXwayland);
    void toplevelRemoved(quint32 handle);
    void toplevelTitle(quint32 handle, const QString &title);
    void toplevelGeometry(quint32 handle, int x, int y, quint32 width, quint32 height);
    void toplevelState(quint32 handle, quint32 state);
    void seatFocusChanged(const QString &seat, quint32 handle);

    // spec/10 §"selection-set event" — fires whenever a client sets
    // the seat selection. Carries the source toplevel handle, the
    // newline-separated mime types, and the primary/clipboard flag.
    // qdshell resolves source/dest silo from windows + focus and
    // calls broker.CheckClipboardTransfer.
    void selectionSet(const QString &seat, quint32 sourceHandle,
                      const QString &mimeTypesConcat, quint32 isPrimary);

    // v23 sidecar — fires IMMEDIATELY BEFORE the matching selectionSet
    // when the wl_client that issued set_selection carries a
    // wp_security_context_v1 tag. ClipboardGate caches this as the
    // "pending source identity" and consumes it on the very next
    // selectionSet, deriving src_silo from the wire instead of from
    // the keyboard-focused toplevel handle. Pre-v23 shells never emit
    // it; untagged source clients on a v23 shell skip it too — in
    // both cases ClipboardGate falls back to the v11 focus-handle
    // path verbatim.
    void selectionSetSourceIdentity(const QString &srcSandboxEngine,
                                    const QString &srcAppId,
                                    const QString &srcInstanceId);

    // wp_security_context_v1 tag emitted by qdwin once it resolves
    // the secctx for a toplevel. Fires after toplevelAdded; instanceId
    // is the load-bearing correlation token for cold-start placeholder
    // resolution (see doc/window-hierarchy.md "Cold-start placeholder
    // taskbar entries"). Also feeds spec/10's clipboard-gate handle→
    // silo mapping.
    void toplevelSecurityContext(quint32 handle,
                                 const QString &sandboxEngine,
                                 const QString &appId,
                                 const QString &instanceId);

    // Option-B identity sidecar — fires immediately after
    // toplevelSecurityContext for the same handle, carrying the
    // compositor-observed peer identity. ClipboardGate forwards the
    // tuple to the broker's VerifyClientIdentity method before honouring
    // any same-silo short-circuit. See todo/decisions/
    // secctx-identity-contract.md.
    void toplevelPeerIdentity(quint32 handle,
                              quint32 peerPid,
                              quint64 peerStarttime,
                              quint32 peerUid,
                              const QString &peerExe,
                              const QString &peerSelinuxLabel);

    // qdwin_shell_v1.nested_proxy_pixel_source — the compositor is
    // asking the shell to spawn a pixel-consumer process for a nested
    // (tier-2) proxy toplevel. pwNode is the PipeWire node name the
    // consumer should attach to; inputSink is forwarded for shells
    // that fold input + pixels into one consumer (we don't). Until
    // this signal is handled the proxy stays on the placeholder
    // curtain. Consumed in QML by spawning qdistro-nested-pixelfeed.
    void nestedProxyPixelSource(quint32 handle,
                                const QString &pwNode,
                                const QString &inputSink);

    void launcherRequested();
    void switcherNext(int dir);
    void switcherCommit();
    void lockRequested();
    void idleLockHint(quint32 reason);

    // Emitted whenever the dispatch loop hits an unrecoverable error
    // and the binding tears itself down (display closed, bind_as_shell
    // rejected, etc.). lastError carries the human-readable reason.
    void disconnected();

private slots:
    void onWaylandReadable();

private:
    void connectAndBind();
    void teardown(const QString &reason);
    void scheduleReconnect();
    void setLastError(const QString &s);
    void setBound(bool b);
    void setFocused(const QString &seat, quint32 handle);

    // Event entry points invoked from the C wayland listeners. Public-
    // to-the-file via a friend struct rather than method-on-class to
    // keep the C callback signatures clean.
    friend struct QdwinBindingDispatch;
    friend struct QdwinRegistry;

    wl_display *display_ = nullptr;
    wl_registry *registry_ = nullptr;
    qdwin_shell_v1 *shell_ = nullptr;
    QSocketNotifier *readNotifier_ = nullptr;

    bool bound_ = false;
    QString lastError_;
    quint32 shellVersion_ = 0;
    quint32 focusedHandle_ = UINT32_MAX;
    QString focusedSeat_;

    // Auto-reconnect after a dispatch error / compositor restart.
    // teardown() schedules connectAndBind() via singleShot with an
    // exponential backoff (capped). destroying_ short-circuits the
    // schedule from the destructor so we don't fire after the object
    // is gone.
    bool destroying_ = false;
    int reconnectAttempts_ = 0;
    QTimer reconnectTimer_;
};
