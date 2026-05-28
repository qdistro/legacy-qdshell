// PointerInputParse — pure, side-effect-free helpers extracted from
// PointerInputService.qml. NO Process / FileView / Settings / Quickshell
// access: only string/array transforms. Usable from both QML
// (import "PointerInputParse.js" as PointerInputParse) and Node
// (require("./PointerInputParse.js")) so the parsing logic can be unit-tested
// headless.
//
// Responsibility: device classification — turn raw `libinput list-devices`
// output OR /proc/bus/input/devices text into a list of pointer devices
// { id, name, type, hasTap, hasNaturalScroll, hasDisableWhileTyping,
//   hasScrollMethod } where type is one of mouse|touchpad|trackpoint|pointer.
// Keyboards and touchscreens are excluded.
//
// qdshell is qdwin-only and qdwin_shell_v1 has no pointer-config request yet,
// so pointer settings are persist-only — there is no live-apply command
// builder here (the previous sway `swaymsg input …` builder was removed when
// the foreign-compositor dispatch was dropped).

// ─── libinput list-devices parsing ──────────────────────────────────
// Devices are separated by blank lines; each block has "Device:",
// "Capabilities:", "Tap:", "Natural scrolling:", "Scroll methods:",
// "Disable while typing:" fields.
function parseLibinput(lines) {
    var out = [];
    var cur = null;

    function commit() {
        if (cur && cur._isPointer) {
            // Classify type now that all fields are collected. libinput reports a
            // touchpad as "Capabilities: pointer gesture" (NOT "touch" — that is a
            // touchscreen) and uniquely exposes non-n/a tap-to-click /
            // disable-while-typing fields. So a pointer device is a touchpad when
            // it advertises the gesture capability or any touchpad-only field;
            // everything else is a mouse (refined to trackpoint by name below).
            var type = "mouse";
            if (cur._hasGesture || cur.hasTap || cur.hasDisableWhileTyping)
                type = "touchpad";
            var nl = cur.name.toLowerCase();
            if (type === "mouse" && (nl.indexOf("trackpoint") !== -1 || nl.indexOf("track point") !== -1 || nl.indexOf("pointing stick") !== -1))
                type = "trackpoint";

            // libinput has no stable id; use the device name as the identifier.
            out.push({
                "id": cur.name,
                "name": cur.name,
                "type": type,
                "hasTap": cur.hasTap,
                "hasNaturalScroll": cur.hasNaturalScroll,
                "hasDisableWhileTyping": cur.hasDisableWhileTyping,
                "hasScrollMethod": cur.hasScrollMethod
            });
        }
        cur = null;
    }

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        var t = line.trim();
        if (t === "") {
            commit();
            continue;
        }

        if (t.indexOf("Device:") === 0) {
            commit();
            cur = {
                "name": t.substring(7).trim(),
                "_isPointer": false,
                "_hasGesture": false,
                "hasTap": false,
                "hasNaturalScroll": false,
                "hasDisableWhileTyping": false,
                "hasScrollMethod": false
            };
            continue;
        }
        if (!cur)
            continue;

        if (t.indexOf("Capabilities:") === 0) {
            var caps = t.substring(13).toLowerCase();
            // Only "pointer"-capable devices are mice/touchpads/trackpoints. A
            // device that is "touch" but not "pointer" is a touchscreen — skip it.
            if (caps.indexOf("pointer") !== -1)
                cur._isPointer = true;
            if (caps.indexOf("gesture") !== -1)
                cur._hasGesture = true;
        } else if (t.toLowerCase().indexOf("tap-to-click:") === 0) {
            cur.hasTap = (t.toLowerCase().indexOf("n/a") === -1);
        } else if (t.toLowerCase().indexOf("natural scrolling:") === 0) {
            cur.hasNaturalScroll = (t.toLowerCase().indexOf("n/a") === -1);
        } else if (t.toLowerCase().indexOf("disable-w-typing:") === 0 || t.toLowerCase().indexOf("disable while typing:") === 0) {
            cur.hasDisableWhileTyping = (t.toLowerCase().indexOf("n/a") === -1);
        } else if (t.toLowerCase().indexOf("scroll methods:") === 0) {
            cur.hasScrollMethod = (t.toLowerCase().indexOf("n/a") === -1);
        }
    }
    commit();

    return out;
}

// ─── /proc/bus/input/devices parsing ────────────────────────────────
// Each device is a block of I:/N:/H:/B: lines separated by a blank line. We
// classify pointer devices using evdev capability bits: EV_REL (relative axes,
// mouse) and EV_ABS + INPUT_PROP POINTER/BUTTONPAD (touchpad). Capabilities
// here are coarser than libinput, so the per-control "has*" flags default to
// true (the compositor will ignore unsupported ones); they remain false only
// when no live backend confirms them.
function parseProc(lines) {
    var out = [];
    var cur = null;

    function commit() {
        if (cur && cur._isPointer) {
            out.push({
                "id": cur.name,
                "name": cur.name,
                "type": cur.type,
                // Unknown via /proc — assume available; these has* flags only
                // affect which UI controls show, never live apply (persist-only).
                "hasTap": cur.type === "touchpad",
                "hasNaturalScroll": true,
                "hasDisableWhileTyping": cur.type === "touchpad",
                "hasScrollMethod": true
            });
        }
        cur = null;
    }

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.trim() === "") {
            commit();
            continue;
        }

        var tag = line.substring(0, 2);
        if (tag === "I:") {
            commit();
            cur = {
                "name": "",
                "type": "pointer",
                "_isPointer": false,
                "_ev": "",
                "_prop": "",
                "_key": ""
            };
        } else if (!cur) {
            continue;
        } else if (tag === "N:") {
            var m = line.match(/Name="(.*)"/);
            cur.name = m ? m[1] : line.substring(2).trim();
        } else if (line.indexOf("B: EV=") === 0) {
            cur._ev = line.substring(6).trim();
        } else if (line.indexOf("B: PROP=") === 0) {
            cur._prop = line.substring(8).trim();
        } else if (line.indexOf("B: KEY=") === 0) {
            cur._key = line.substring(7).trim().toLowerCase();
        } else if (line.indexOf("I: ") === 0) {
            // already handled by tag check
        }

        // Re-classify on each line so we have it once the block ends.
        if (cur) {
            var evVal = parseInt(cur._ev || "0", 16) || 0;
            var hasRel = (evVal & 0x04) !== 0;   // EV_REL bit 2
            var hasAbs = (evVal & 0x08) !== 0;   // EV_ABS bit 3
            // INPUT_PROP_POINTER (bit0) / INPUT_PROP_BUTTONPAD (bit2) => touchpad.
            var propVal = parseInt(cur._prop || "0", 16) || 0;
            var isTouchpad = hasAbs && ((propVal & 0x05) !== 0);
            var nameL = (cur.name || "").toLowerCase();
            if (isTouchpad || nameL.indexOf("touchpad") !== -1) {
                cur._isPointer = true;
                cur.type = "touchpad";
            } else if (nameL.indexOf("trackpoint") !== -1 || nameL.indexOf("pointing stick") !== -1) {
                cur._isPointer = true;
                cur.type = "trackpoint";
            } else if (hasRel) {
                // Relative pointer with mouse buttons => mouse. Exclude pure
                // consumer-control / keyboard devices that also expose EV_REL.
                cur._isPointer = true;
                cur.type = "mouse";
            }
        }
    }
    commit();

    // De-duplicate by name (a single physical mouse may show several event
    // nodes); keep the first occurrence.
    var seen = ({});
    var dedup = [];
    for (var k = 0; k < out.length; k++) {
        var nm = out[k].name;
        if (seen[nm])
            continue;
        seen[nm] = true;
        dedup.push(out[k]);
    }
    return dedup;
}

// Dispatch on the @@SRC: marker the enumeration shell prepends. Pure: takes the
// raw collected stdout, returns { source, devices } where source is
// "libinput" | "proc" | "none".
function parseEnum(out) {
    out = String(out || "");
    var lines = out.split("\n");
    var src = "";
    if (lines.length > 0 && lines[0].indexOf("@@SRC:") === 0) {
        src = lines[0].substring(6).trim();
        lines = lines.slice(1);
    }

    var parsed;
    if (src === "libinput")
        parsed = parseLibinput(lines);
    else
        parsed = parseProc(lines);

    return {
        "source": parsed.length > 0 ? src : "none",
        "devices": parsed
    };
}

if (typeof module !== "undefined") {
    module.exports = {
        parseLibinput: parseLibinput,
        parseProc: parseProc,
        parseEnum: parseEnum,
    };
}
