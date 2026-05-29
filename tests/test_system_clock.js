const assert = require("assert");
const SC = require("../Services/System/SystemClock.js");

// ─── timedatectl show parsing ───────────────────────────────────────
// Representative machine-readable output.
const show = [
    "Timezone=Europe/Berlin",
    "LocalRTC=no",
    "CanNTP=yes",
    "NTP=yes",
    "NTPSynchronized=yes",
    "TimeUSec=Thu 2026-05-29 12:34:56 CEST",
    "RTCTimeUSec=Thu 2026-05-29 10:34:56 UTC",
    ""
].join("\n");

let st = SC.parseShow(show);
assert.strictEqual(st.timezone, "Europe/Berlin");
assert.strictEqual(st.ntp, true);
assert.strictEqual(st.ntpSynchronized, true);
assert.strictEqual(st.localRTC, false);
assert.strictEqual(st.canNTP, true);
assert.strictEqual(st.timeUSec, "Thu 2026-05-29 12:34:56 CEST");
// Raw map preserves every key, including values that contain spaces.
assert.strictEqual(st.raw.RTCTimeUSec, "Thu 2026-05-29 10:34:56 UTC");

// NTP off + older true/false spelling for booleans.
st = SC.parseShow("Timezone=UTC\nNTP=no\nNTPSynchronized=false\n");
assert.strictEqual(st.timezone, "UTC");
assert.strictEqual(st.ntp, false);
assert.strictEqual(st.ntpSynchronized, false);
// CanNTP absent -> defaults to true (do not needlessly disable the toggle).
assert.strictEqual(st.canNTP, true);

// Garbage / empty input parses to a safe empty-ish state, never throws.
st = SC.parseShow("");
assert.strictEqual(st.timezone, "");
assert.strictEqual(st.ntp, false);
st = SC.parseShow(null);
assert.strictEqual(st.timezone, "");

// ─── list-timezones parsing ─────────────────────────────────────────
const tzText = [
    "UTC",
    "Africa/Abidjan",
    "America/New_York",
    "Europe/Berlin",
    "Pacific/Auckland",
    "",                          // blank dropped
    "  Asia/Tokyo  ",            // trimmed
    "Not A Zone With Spaces",    // malformed -> dropped
    "America/New_York; rm -rf /" // injection attempt -> dropped (has space/;)
].join("\n");

const zones = SC.parseTimezones(tzText);
assert.deepStrictEqual(zones, [
    "UTC",
    "Africa/Abidjan",
    "America/New_York",
    "Europe/Berlin",
    "Pacific/Auckland",
    "Asia/Tokyo"
]);
// The crafted entries never make it into the allow-list.
assert.ok(zones.indexOf("America/New_York; rm -rf /") === -1);
assert.ok(zones.indexOf("Not A Zone With Spaces") === -1);

// ─── isWellFormedTimezone shape check ───────────────────────────────
assert.ok(SC.isWellFormedTimezone("Europe/Berlin"));
assert.ok(SC.isWellFormedTimezone("UTC"));
assert.ok(SC.isWellFormedTimezone("America/Argentina/Buenos_Aires"));
assert.ok(!SC.isWellFormedTimezone(""));
assert.ok(!SC.isWellFormedTimezone("/etc/passwd"));        // leading slash
assert.ok(!SC.isWellFormedTimezone("../../etc/passwd"));   // traversal
assert.ok(!SC.isWellFormedTimezone("Europe/Berlin; reboot")); // space + ;
assert.ok(!SC.isWellFormedTimezone("$(reboot)"));

// ─── normalizeTimezone: the injection gate ──────────────────────────
// Accepts an exact member of the enumerated set.
assert.strictEqual(SC.normalizeTimezone("Europe/Berlin", zones), "Europe/Berlin");
assert.strictEqual(SC.normalizeTimezone("  UTC  ", zones), "UTC"); // trimmed
// Rejects anything not in the list — including a crafted injection string.
assert.strictEqual(SC.normalizeTimezone("America/New_York; rm -rf /", zones), null);
assert.strictEqual(SC.normalizeTimezone("Europe/London", zones), null); // not enumerated
assert.strictEqual(SC.normalizeTimezone("", zones), null);
assert.strictEqual(SC.normalizeTimezone("$(reboot)", zones), null);
assert.strictEqual(SC.normalizeTimezone("Europe/Berlin", null), null); // no list -> reject

// ─── validateDateTime ───────────────────────────────────────────────
// Valid input round-trips canonically.
assert.strictEqual(SC.validateDateTime("2026-05-29 12:34:56"), "2026-05-29 12:34:56");
assert.strictEqual(SC.validateDateTime("2024-02-29 00:00:00"), "2024-02-29 00:00:00"); // leap day
// Malformed / out-of-range / injection -> null.
assert.strictEqual(SC.validateDateTime("2026-05-29T12:34:56"), null);   // 'T' separator
assert.strictEqual(SC.validateDateTime("2026-5-9 1:2:3"), null);        // unpadded
assert.strictEqual(SC.validateDateTime("2026-13-01 00:00:00"), null);   // month 13
assert.strictEqual(SC.validateDateTime("2026-02-30 00:00:00"), null);   // Feb 30
assert.strictEqual(SC.validateDateTime("2023-02-29 00:00:00"), null);   // non-leap Feb 29
assert.strictEqual(SC.validateDateTime("2026-05-29 24:00:00"), null);   // hour 24
assert.strictEqual(SC.validateDateTime("2026-05-29 12:60:00"), null);   // minute 60
assert.strictEqual(SC.validateDateTime("1969-12-31 23:59:59"), null);   // before 1970
assert.strictEqual(SC.validateDateTime("2026-05-29 12:34:56; reboot"), null); // trailing payload
assert.strictEqual(SC.validateDateTime("$(date)"), null);
assert.strictEqual(SC.validateDateTime(""), null);
assert.strictEqual(SC.validateDateTime(null), null);

// ─── argv builders are argv arrays, never `sh -c` ───────────────────
let argv = SC.buildSetTimezoneArgv("Europe/Berlin", zones);
assert.deepStrictEqual(argv, ["timedatectl", "set-timezone", "Europe/Berlin"]);
assert.ok(Array.isArray(argv));
assert.notStrictEqual(argv[0], "sh");
assert.ok(argv.indexOf("-c") === -1, "no -c flag => not a shell string");

// A crafted timezone is REJECTED before any argv is built (returns null).
assert.strictEqual(SC.buildSetTimezoneArgv("America/New_York; rm -rf /", zones), null);
assert.strictEqual(SC.buildSetTimezoneArgv("`reboot`", zones), null);
assert.strictEqual(SC.buildSetTimezoneArgv("Europe/Berlin", []), null); // empty allow-list

// set-ntp maps the bool to literal true/false tokens (never raw text).
assert.deepStrictEqual(SC.buildSetNtpArgv(true), ["timedatectl", "set-ntp", "true"]);
assert.deepStrictEqual(SC.buildSetNtpArgv(false), ["timedatectl", "set-ntp", "false"]);

// set-time: valid datetime stays a SINGLE argv token (the embedded space does
// not split it — there is no shell).
argv = SC.buildSetTimeArgv("2026-05-29 12:34:56");
assert.deepStrictEqual(argv, ["timedatectl", "set-time", "2026-05-29 12:34:56"]);
assert.strictEqual(argv.length, 3, "datetime is exactly one argv element");
assert.notStrictEqual(argv[0], "sh");
// Malformed datetime -> null (no command built).
assert.strictEqual(SC.buildSetTimeArgv("2026-05-29 12:34:56; rm -rf /"), null);
assert.strictEqual(SC.buildSetTimeArgv("garbage"), null);

// Every built argv element is a plain string (no nested arrays / shell wrap).
[SC.buildSetTimezoneArgv("UTC", zones),
 SC.buildSetNtpArgv(true),
 SC.buildSetTimeArgv("2026-05-29 12:34:56")].forEach(function (a) {
    assert.ok(Array.isArray(a));
    a.forEach(function (tok) { assert.strictEqual(typeof tok, "string"); });
});

console.log("system-clock: all assertions passed");
