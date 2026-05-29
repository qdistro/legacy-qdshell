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
#include <QStringList>
#include <QSocketNotifier>
#include <QTimer>
#include <QVariantMap>
#include <QVariantList>
#include <cstdint>
#include <utility>
#include <vector>

class CtrlServer;

struct wl_display;
struct wl_registry;
struct qdwin_shell_v1;
struct ext_workspace_manager_v1;
struct ext_workspace_group_handle_v1;
struct ext_workspace_handle_v1;
struct zwlr_output_manager_v1;
struct zwlr_output_head_v1;
struct zwlr_output_mode_v1;
struct zwlr_output_configuration_v1;

class QdwinBinding : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool bound READ bound NOTIFY boundChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(quint32 shellVersion READ shellVersion NOTIFY boundChanged)
    Q_PROPERTY(quint32 focusedHandle READ focusedHandle NOTIFY focusedHandleChanged)
    Q_PROPERTY(QString focusedSeat READ focusedSeat NOTIFY focusedHandleChanged)
    Q_PROPERTY(quint64 overlayKeyCount READ overlayKeyCount NOTIFY overlayKeyCountChanged)
    // v24 workspaces (ext-workspace-v1). count + active index reflect the
    // compositor's live workspace state; the bar overlays user names from
    // qdshell settings by index and computes occupancy from per-window
    // workspace ids (toplevelWorkspace sidecar).
    Q_PROPERTY(quint32 workspaceCount READ workspaceCount NOTIFY workspacesChanged)
    Q_PROPERTY(quint32 activeWorkspace READ activeWorkspace NOTIFY workspacesChanged)

    // Output (display) management (wlr-output-management-unstable-v1).
    // outputManagementAvailable flips true once qdwin advertises the
    // zwlr_output_manager_v1 global (CapabilityService.outputManagement
    // gates on it). `outputs` is the enumerated head/mode set the Display
    // layout tab renders; outputSerial is the current configuration serial
    // a layout must be applied against (a stale serial is rejected).
    Q_PROPERTY(bool outputManagementAvailable READ outputManagementAvailable
               NOTIFY outputsChanged)
    Q_PROPERTY(QVariantList outputs READ outputs NOTIFY outputsChanged)
    Q_PROPERTY(quint32 outputSerial READ outputSerial NOTIFY outputsChanged)

public:
    explicit QdwinBinding(QObject *parent = nullptr);
    ~QdwinBinding() override;

    bool bound() const { return bound_; }
    QString lastError() const { return lastError_; }
    quint32 shellVersion() const { return shellVersion_; }
    quint32 focusedHandle() const { return focusedHandle_; }
    QString focusedSeat() const { return focusedSeat_; }
    quint64 overlayKeyCount() const { return overlayKeyCount_; }
    quint32 lastOverlayRole() const { return lastOverlayRole_; }
    quint32 lastOverlaySym() const { return lastOverlaySym_; }
    QString lastOverlayUtf8() const { return lastOverlayUtf8_; }
    quint32 workspaceCount() const { return workspaceCount_; }
    quint32 activeWorkspace() const { return activeWorkspace_; }

    bool outputManagementAvailable() const { return omManager_ != nullptr; }
    QVariantList outputs() const { return outputs_; }
    quint32 outputSerial() const { return outputSerial_; }

    Q_INVOKABLE void focusWindow(quint32 handle, const QString &seat = QStringLiteral("default"));
    Q_INVOKABLE void closeWindow(quint32 handle);
    Q_INVOKABLE void requestMaximize(quint32 handle, bool maximized);
    Q_INVOKABLE void requestMinimize(quint32 handle);
    Q_INVOKABLE void setBorderColor(quint32 handle, quint32 argb);

    // v24 workspaces. activate/create/remove drive ext-workspace-v1;
    // setWorkspaceCount reconciles the compositor's workspace count to
    // the shell's persisted setting (issuing create/remove as needed);
    // moveToplevelToWorkspace rides the qdwin_shell_v1 sidecar request.
    // All are no-ops until the relevant global is bound.
    Q_INVOKABLE void activateWorkspace(quint32 index);
    Q_INVOKABLE void createWorkspace();
    Q_INVOKABLE void removeWorkspace(quint32 index);
    Q_INVOKABLE void setWorkspaceCount(quint32 count);
    Q_INVOKABLE void moveToplevelToWorkspace(quint32 handle, quint32 index);

    // v25 window-manager policy (qdwin_shell_v1.set_wm_policy). One
    // idempotent snapshot of the live WM policy; no-op until the shell is
    // bound at >= v25. focusPolicy: 0=click, 1=follow-mouse. placement:
    // 0=center, 1=under-mouse, 2=smart, 3=cascade.
    Q_INVOKABLE void setWmPolicy(quint32 focusPolicy, quint32 ffmDelayMs,
                                 bool raiseOnClick, bool raiseOnHover,
                                 quint32 placement, bool snapEnabled,
                                 quint32 snapDistance);
    // v25 shell-driven fullscreen + half-screen tiling (the
    // toggle-fullscreen / tile-left / tile-right WM shortcuts). tileEdge:
    // 0=none(restore), 1=left, 2=right.
    Q_INVOKABLE void requestFullscreen(quint32 handle, bool fullscreen);
    Q_INVOKABLE void requestTile(quint32 handle, quint32 tileEdge);
    // v19 global hotkey registration (wired at v25 for WM shortcuts).
    // modifiers is a bitmask: ctrl=1, alt=2, super=4, shift=8. key is a
    // linux input keycode. hotkeyPressed(id) fires on each press.
    Q_INVOKABLE void registerHotkey(quint32 id, quint32 modifiers, quint32 key);
    Q_INVOKABLE void unregisterHotkey(quint32 id);

    // Output (display) management. applyLayout builds a configuration
    // against `serial` (pass outputSerial), enabling/disabling + configuring
    // each head per the supplied list, then `apply`s it ATOMICALLY. testLayout
    // validates without applying. The compositor's reply (succeeded/failed/
    // cancelled) arrives asynchronously via layoutResult(); on a failed/
    // cancelled apply the compositor has reverted to the prior layout, so the
    // shell's confirm-or-revert can re-apply the saved layout via a second
    // applyLayout. Each layout entry is a QVariantMap:
    //   name (string, required — matches outputs[].name)
    //   enabled (bool)
    //   x, y (int)         — position in global compositor space
    //   width, height (int), refresh (int mHz)  — mode (custom/exact match)
    //   scale (real)       — integer scale (fractional rounded by compositor)
    //   transform (int)    — wl_output.transform enum (0..7)
    // All numeric fields optional; an omitted field keeps the head's current
    // value. `name` is the only required key. Returns false synchronously if
    // the binding has no live manager (no apply attempted).
    Q_INVOKABLE bool applyLayout(const QVariantList &layout, quint32 serial);
    Q_INVOKABLE bool testLayout(const QVariantList &layout, quint32 serial);

    // spec/10 §"compositor-mediated gating" — once the shell has a
    // broker verdict on the most recent selection_set, it calls
    // clearSelection on a "deny". `isPrimary` mirrors the event
    // arg: 0 = clipboard, 1 = primary selection.
    Q_INVOKABLE void clearSelection(const QString &seat, quint32 isPrimary);

    // spec/10 §"receive-time gating" (v15+) — echoes the broker's
    // allow/deny verdict back to the compositor for a pending
    // wl_data_offer.receive. Mirrors clearSelection: must be sent
    // exactly once per dataOfferReceivePending event, else the
    // compositor times out (~2s) and DENIES (empty paste).
    Q_INVOKABLE void sendDataOfferReceiveDecision(quint32 requestHandle,
                                                  bool allow);
    Q_INVOKABLE void nestedProxyDecision(quint32 handle, quint32 decision,
                                         const QString &reason);
    Q_INVOKABLE void activationDecision(quint32 handle, quint32 decision,
                                        const QString &reason);
    Q_INVOKABLE QVariantMap checkPermission(const QString &action,
                                            const QVariantMap &details = QVariantMap());
    Q_INVOKABLE bool verifyClientIdentity(
        quint32 pid,
        quint64 starttime,
        quint32 uid,
        const QString &exe,
        const QString &selinuxLabel,
        const QString &sandboxEngine,
        const QString &appId,
        const QString &instanceId);
    // sourcePid / sourceStarttime: the source app's kernel-authenticated
    // (pid, starttime) as captured by qdwin via SO_PEERCRED at secctx-bind
    // and relayed here from the toplevel peer-identity sidecar. The broker
    // resolves THIS pid (not qdshell's own) against its launch-record store
    // to attest the source silo for cross-silo lineage (P1-1). 0/0 means
    // "not available"; under broker enforce that fails closed (cross-silo
    // deny). Defaulted so older call sites keep compiling.
    Q_INVOKABLE QVariantMap checkHandoffActivation(
        const QString &sourceSilo,
        const QString &destSilo,
        const QString &sourceAppId,
        const QString &destAppId,
        const QString &sourceSandboxEngine,
        bool identityVerified,
        uint sourcePid = 0,
        qulonglong sourceStarttime = 0);
    Q_INVOKABLE QVariantMap checkClipboardTransfer(
        const QString &sourceSilo,
        const QString &destSilo,
        const QStringList &mimeTypes,
        const QString &sourceAppId,
        const QString &destAppId,
        const QString &sourceSandboxEngine,
        bool identityVerified,
        uint sourcePid = 0,
        qulonglong sourceStarttime = 0);
    // spec/10 §"receive-time gating" — receive-time twin of
    // checkClipboardTransfer. Consults the broker's
    // CheckClipboardReceive for a SINGLE requested mime (no list/
    // count, since the compositor gates each receive() individually).
    Q_INVOKABLE QVariantMap checkClipboardReceive(
        const QString &sourceSilo,
        const QString &destSilo,
        const QString &mimeType,
        const QString &sourceAppId,
        const QString &destAppId,
        const QString &sourceSandboxEngine,
        bool identityVerified,
        uint sourcePid = 0,
        qulonglong sourceStarttime = 0);

signals:
    void boundChanged();
    void lastErrorChanged();
    void focusedHandleChanged();
    void overlayKeyCountChanged();

    void hello(quint32 uid);
    void toplevelAdded(quint32 handle, quint32 ownerUid, const QString &appId,
                       const QString &title, bool isXwayland);
    void toplevelRemoved(quint32 handle);
    void toplevelTitle(quint32 handle, const QString &title);
    void toplevelGeometry(quint32 handle, int x, int y, quint32 width, quint32 height);
    void toplevelState(quint32 handle, quint32 state);
    void seatFocusChanged(const QString &seat, quint32 handle);

    // v24 sidecar — qdwin_shell_v1.toplevel_workspace. Fires after
    // toplevelAdded (and on move / bind replay) telling the shell which
    // workspace a window lives on, so the bar can compute occupancy.
    void toplevelWorkspace(quint32 handle, quint32 index);
    // v19/v25 — a registered WM-shortcut hotkey fired. `id` is the
    // shell-assigned token from registerHotkey(); WindowManagerService maps
    // it back to a window-manager action on the focused window.
    void hotkeyPressed(quint32 id);
    // Fires after every ext-workspace done that changes the workspace
    // count or active index. Drives Qdwin.qml's workspace ListModel.
    void workspacesChanged();

    // Fires whenever the enumerated output set or the current configuration
    // serial changes (manager bind, output hotplug/resize, or an applied
    // layout). Drives the Display layout tab's model + re-arms the
    // confirm-or-revert baseline. Also drives outputManagementAvailable.
    void outputsChanged();
    // Async result of an applyLayout/testLayout. `applied` distinguishes an
    // apply (true) from a test (false). `ok` is the compositor's verdict:
    // true = succeeded, false = failed or cancelled. On a failed/cancelled
    // apply the compositor reverted; the shell may re-apply the saved layout.
    void layoutResult(bool applied, bool ok, bool cancelled);

    // spec/10 §"selection-set event" — fires whenever a client sets
    // the seat selection. Carries the source toplevel handle, the
    // newline-separated mime types, and the primary/clipboard flag.
    // qdshell resolves source/dest silo from windows + focus and
    // calls broker.CheckClipboardTransfer.
    void selectionSet(const QString &seat, quint32 sourceHandle,
                      const QString &mimeTypesConcat, quint32 isPrimary);

    // spec/10 §"receive-time gating" (v15+) — fires when a destination
    // client calls wl_data_offer.receive on a gated selection. The
    // compositor blocks the receive (~2s) awaiting the shell's
    // sendDataOfferReceiveDecision echoing requestHandle. sourceHandle
    // and targetHandle map to silos via the handle→silo table and may
    // be UINT32_MAX (no toplevel maps → treated as "unknown"). Unlike
    // set-time, the target is explicit (the receiving client), not the
    // keyboard-focused toplevel.
    void dataOfferReceivePending(quint32 requestHandle, const QString &seat,
                                 quint32 sourceHandle, quint32 targetHandle,
                                 const QString &mimeType);

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
    void nestedProxyPending(quint32 handle,
                            const QString &appId,
                            quint32 originUid);
    void activationPending(quint32 handle,
                           quint32 sourceHandle,
                           quint32 targetHandle,
                           const QString &sourceAppId);

    void launcherRequested();
    void switcherNext(int dir);
    void switcherCommit();
    void lockRequested();
    void idleLockHint(quint32 reason);
    void overlayKey(quint32 role, quint32 sym, const QString &utf8, quint32 state);

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
    friend struct QdwinWsDispatch;

    wl_display *display_ = nullptr;
    wl_registry *registry_ = nullptr;
    qdwin_shell_v1 *shell_ = nullptr;
    QSocketNotifier *readNotifier_ = nullptr;

    bool bound_ = false;
    QString lastError_;
    quint32 shellVersion_ = 0;
    quint32 focusedHandle_ = UINT32_MAX;
    QString focusedSeat_;
    quint64 overlayKeyCount_ = 0;
    quint32 lastOverlayRole_ = 0;
    quint32 lastOverlaySym_ = 0;
    QString lastOverlayUtf8_;

    // ---- v24 ext-workspace-v1 client state ----
    // One manager + one group (qdwin advertises a single desktop-spanning
    // group). wsEntries_ accumulates per-workspace handles as the
    // workspace/handle events arrive; rebuildWorkspaces() (called on the
    // manager `done`) collapses them into workspaceCount_/activeWorkspace_
    // and the index-ordered wsByIndex_ used to target activate/remove.
    struct WsEntry {
        ext_workspace_handle_v1 *proxy = nullptr;
        quint32 coord = 0;     // 1-D coordinate (== index) from qdwin
        bool haveCoord = false;
        quint32 state = 0;     // ext_workspace_handle_v1 state bitmask
        bool removed = false;
    };
    ext_workspace_manager_v1 *wsManager_ = nullptr;
    ext_workspace_group_handle_v1 *wsGroup_ = nullptr;
    std::vector<WsEntry> wsEntries_;
    std::vector<ext_workspace_handle_v1 *> wsByIndex_;
    quint32 workspaceCount_ = 0;
    quint32 activeWorkspace_ = 0;
    void wsBindGroup(ext_workspace_group_handle_v1 *grp);
    void wsBindHandle(ext_workspace_handle_v1 *ws);
    void wsRebuild();              // collapse wsEntries_ → count/active/index
    WsEntry *wsEntryFor(ext_workspace_handle_v1 *h);
    void wsTeardownState();        // disconnect path: drop state, proxies dead
    void wsFinished();             // manager.finished: release live proxies

    // ---- output (display) management client state ----
    // One manager. Heads + their modes accumulate as the head/mode events
    // arrive; omRebuild() (on the manager `done`) collapses them into the
    // QVariantList `outputs_` the Display tab renders and stashes the
    // proxies in omHeadProxies_ / omModeProxies_ for building configurations.
    struct OmModeInfo {
        zwlr_output_mode_v1 *proxy = nullptr;
        int width = 0, height = 0, refresh = 0;
        bool preferred = false;
    };
    struct OmHeadInfo {
        zwlr_output_head_v1 *proxy = nullptr;
        QString name, description, make, model, serial;
        bool finished = false;    // compositor sent head.finished → inert
        bool enabled = false;
        int x = 0, y = 0;
        int scale = 1;            // integer scale (wl_fixed → int)
        int transform = 0;
        zwlr_output_mode_v1 *currentMode = nullptr;
        std::vector<OmModeInfo> modes;
    };
    zwlr_output_manager_v1 *omManager_ = nullptr;
    std::vector<OmHeadInfo> omHeads_;     // accumulator since last done
    QVariantList outputs_;                // collapsed, QML-facing
    quint32 outputSerial_ = 0;
    // Configuration objects in flight (apply/test issued, awaiting reply).
    // We track whether each was an apply so layoutResult can report it.
    struct OmConfig {
        zwlr_output_configuration_v1 *proxy = nullptr;
        bool applied = false;
    };
    std::vector<OmConfig> omConfigs_;
    void omBindManager(zwlr_output_manager_v1 *mgr);
    void omBindHead(zwlr_output_head_v1 *head);
    OmHeadInfo *omHeadFor(zwlr_output_head_v1 *h);
    OmModeInfo *omModeFor(zwlr_output_mode_v1 *m);
    void omRebuild();                     // collapse omHeads_ → outputs_
    void omTeardownState();
    bool omSubmitLayout(const QVariantList &layout, quint32 serial,
                        bool apply);
    void omConfigResult(zwlr_output_configuration_v1 *cfg, bool ok,
                        bool cancelled);
    friend struct QdwinOmDispatch;

    CtrlServer *ctrlServer_ = nullptr;

    // Auto-reconnect after a dispatch error / compositor restart.
    // teardown() schedules connectAndBind() via singleShot with an
    // exponential backoff (capped). destroying_ short-circuits the
    // schedule from the destructor so we don't fire after the object
    // is gone.
    bool destroying_ = false;
    int reconnectAttempts_ = 0;
    QTimer reconnectTimer_;
};
