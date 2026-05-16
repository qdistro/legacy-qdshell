pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.Qdwin
import qs.Services.Qdistro
import qs.Services.Qdshell

// Tier3FocusIPC — Quickshell IPC bridge exposing qdwin_shell_v1@v14
// focus + selection driving to external CLIs (primarily the bats
// test driver tests/integration/vm/s48-focus-aware-clear.sh).
//
// Why this exists:
//   spec/10 v14 added `set_keyboard_focus` (request) +
//   `seat_focus_changed` (event) so the shell can drive cross-silo
//   focus moves headlessly. The bats VM has no keyboard hardware
//   under sdl-freerdp /v: dummy, so the only way to exercise the
//   cross-silo flow in CI is to *inject* focus from the shell side.
//   This IPC is that injection surface.
//
//   Without it, s48's "qdshell cleared the admin selection on cross-
//   silo focus" assertion has no test driver — see the lead comment
//   on s53-data-offer-receive-v15.sh ("[the ctrl-socket inject-focus]
//   isn't a shipped CLI on the qdshell side").
//
// Surface (target alias = "tier3focus"):
//   qs ipc call tier3focus injectFocus <handle> [seat]
//   qs ipc call tier3focus clearSelection [seat] [primary]
//   qs ipc call tier3focus findSiloHandle <silo>
//   qs ipc call tier3focus selectionState
//
//   injectFocus delegates to Qdwin.injectFocus → qdwin_shell_v1
//   set_keyboard_focus. qdwin's v14 contract clears the seat
//   selection unconditionally on every focus injection that crosses
//   silo boundaries; the bats driver observes that via journal grep.
//
//   findSiloHandle scans Tier3Apps.tier3Windows for the first
//   toplevel matching the given silo and prints its handle on a
//   single stdout line ("HANDLE=N"). Used by the bats driver to
//   resolve "silo=user1's current toplevel handle" without grepping
//   weston logs.
//
//   selectionState emits a Logger.i log line snapshotting the
//   current src_silo / dst_silo from ClipboardGate's last gate
//   event. Bats greps the journal for the snapshot.
//
// All operations are admin-only by virtue of running through
// qdshell, which itself runs as admin. There's no auth boundary
// inside the IPC because there's no cross-user trust boundary
// inside qdshell.
Singleton {
    id: root

    // Marker for the shell.qml force-instantiate trick.
    readonly property bool isQdistroFocusIPC: true

    Component.onCompleted: Logger.i("Tier3FocusIPC", "service started")

    // Track the last-seen ClipboardGate event so selectionState
    // can return a meaningful snapshot. Populated by the Connections
    // block below.
    property string _lastSrcSilo: ""
    property string _lastDstSilo: ""
    property string _lastVerdict: ""
    property string _lastSeat: ""

    Connections {
        target: ClipboardGate
        // ClipboardGate doesn't currently expose a clean signal —
        // we tap into its logging side-effect by scraping from the
        // _onSelectionSet path. To avoid duplicating that logic,
        // we'd ideally have a `selectionStateChanged(srcSilo,
        // dstSilo, verdict)` signal; absent that, the IPC selection-
        // State command emits a "snapshot needs journal grep"
        // marker that the bats driver pairs with the canonical
        // CLIPBOARD_GATE log line.
        //
        // The simpler v1: just emit a probe log line on demand;
        // the driver greps the most recent CLIPBOARD_GATE line.
        ignoreUnknownSignals: true
    }

    function _findSiloHandle(silo) {
        if (!silo) return -1;
        const wm = Tier3Apps.tier3Windows;
        if (!wm) return -1;
        for (let i = 0; i < wm.count; i++) {
            const row = wm.get(i);
            if (row.silo === silo) return row.handle;
        }
        return -1;
    }

    IpcHandler {
        target: "tier3focus"

        // qs ipc call tier3focus injectFocus <handle> [seat]
        function injectFocus(handle: int, seat: string): string {
            const seatName = seat && seat.length > 0 ? seat : "default";
            Qdwin.injectFocus(handle, seatName);
            return "ok handle=" + handle + " seat=" + seatName;
        }

        // qs ipc call tier3focus clearSelection [seat] [primary]
        function clearSelection(seat: string, primary: string): string {
            const seatName = seat && seat.length > 0 ? seat : "default";
            const isPri = primary === "1" || primary === "true";
            Qdwin.clearSeatSelection(seatName, isPri);
            return "ok seat=" + seatName + " primary=" + (isPri ? 1 : 0);
        }

        // qs ipc call tier3focus findSiloHandle <silo>
        // Returns "HANDLE=<n>" or "HANDLE=-1" so the bats driver
        // can parse a single key=value line.
        function findSiloHandle(silo: string): string {
            const h = root._findSiloHandle(silo);
            const out = "HANDLE=" + h;
            Logger.i("Tier3FocusIPC", "findSiloHandle silo=" + silo + " → " + out);
            return out;
        }

        // qs ipc call tier3focus selectionState
        // Emits a journal probe line; the driver pairs with the
        // most recent CLIPBOARD_GATE log entry to identify the
        // current selection owner. Returns the IPC reply for the
        // CLI caller's convenience.
        function selectionState(): string {
            const reply = "src_silo=" + (root._lastSrcSilo || "?")
                        + " dst_silo=" + (root._lastDstSilo || "?")
                        + " verdict=" + (root._lastVerdict || "?")
                        + " seat="   + (root._lastSeat || "default");
            Logger.i("Tier3FocusIPC", "selectionState " + reply);
            return reply;
        }
    }
}
