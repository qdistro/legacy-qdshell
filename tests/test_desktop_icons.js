const assert = require("assert");
const M = require("../Modules/DesktopIcons/DesktopIconModel.js");

// ── desktop-id validation + derivation ───────────────────────────────
{
    assert.strictEqual(M.isDesktopId("org.gnome.Calculator"), true);
    assert.strictEqual(M.isDesktopId("firefox"), true);
    assert.strictEqual(M.isDesktopId("a-b_c+d.e"), true);
    assert.strictEqual(M.isDesktopId(""), false);
    assert.strictEqual(M.isDesktopId("/tmp/x"), false, "path is not an id");
    assert.strictEqual(M.isDesktopId("../evil"), false, "traversal is not an id");
    assert.strictEqual(M.isDesktopId("evil; rm"), false, "metacharacter rejected");
    assert.strictEqual(M.isDesktopId(".hidden"), false, "leading dot rejected");

    assert.strictEqual(M.desktopIdFromFileName("org.gnome.Calculator.desktop"), "org.gnome.Calculator");
    assert.strictEqual(M.desktopIdFromFileName("firefox.desktop"), "firefox");
    assert.strictEqual(M.desktopIdFromFileName("notes.txt"), "", "non-.desktop -> empty");
    assert.strictEqual(M.desktopIdFromFileName("evil; rm.desktop"), "", "bad id in name -> empty");
}

// ── hidden-file filtering ─────────────────────────────────────────────
{
    const entries = [
        { name: "Documents", isDir: true },
        { name: ".hiddenfile", isDir: false },
        { name: "visible.txt", isDir: false },
        { name: ".config", isDir: true },
    ];
    const shown = M.filterHidden(entries, false);
    assert.strictEqual(shown.length, 2, "dotfiles filtered when showHidden=false");
    assert.deepStrictEqual(shown.map(e => e.name).sort(), ["Documents", "visible.txt"]);

    const all = M.filterHidden(entries, true);
    assert.strictEqual(all.length, 4, "all kept when showHidden=true");
    // filterHidden must not mutate the input.
    assert.strictEqual(entries.length, 4);

    assert.strictEqual(M.isHiddenName(".x"), true);
    assert.strictEqual(M.isHiddenName("x"), false);
    assert.deepStrictEqual(M.filterHidden(null, false), []);
}

// ── sorting: name, type, folders-first ────────────────────────────────
{
    const entries = [
        { name: "zebra.txt", isDir: false },
        { name: "Apple", isDir: true },
        { name: "banana.png", isDir: false },
        { name: "Zoo", isDir: true },
        { name: "alpha.desktop", isDir: false },
    ];

    // name sort, folders-first (default)
    const byName = M.sortEntries(entries, "name", true);
    assert.deepStrictEqual(byName.map(e => e.name),
        ["Apple", "Zoo", "alpha.desktop", "banana.png", "zebra.txt"],
        "folders first, then case-insensitive name");

    // name sort, NOT folders-first -> pure case-insensitive name order
    const byNameFlat = M.sortEntries(entries, "name", false);
    assert.deepStrictEqual(byNameFlat.map(e => e.name),
        ["alpha.desktop", "Apple", "banana.png", "zebra.txt", "Zoo"],
        "no folders-first -> plain name order");

    // type sort, folders-first: dirs, then .desktop, then by extension
    const byType = M.sortEntries(entries, "type", true);
    assert.deepStrictEqual(byType.map(e => e.name),
        ["Apple", "Zoo", "alpha.desktop", "banana.png", "zebra.txt"],
        "dirs, then .desktop, then png, then txt");

    // sortEntries must not mutate input.
    assert.strictEqual(entries[0].name, "zebra.txt");
    assert.deepStrictEqual(M.sortEntries(null, "name", true), []);
}

// ── arrangeEntries: filter + sort combined, default folders-first ─────
{
    const entries = [
        { name: ".secret", isDir: false },
        { name: "b.txt", isDir: false },
        { name: "Folder", isDir: true },
        { name: "a.txt", isDir: false },
    ];
    const arranged = M.arrangeEntries(entries, { showHidden: false, sortMode: "name" });
    assert.deepStrictEqual(arranged.map(e => e.name), ["Folder", "a.txt", "b.txt"]);

    // arrangeFoldersFirst can be turned off explicitly.
    const flat = M.arrangeEntries(entries, { showHidden: false, sortMode: "name", arrangeFoldersFirst: false });
    assert.deepStrictEqual(flat.map(e => e.name), ["a.txt", "b.txt", "Folder"]);

    // showHidden surfaces the dotfile.
    const withHidden = M.arrangeEntries(entries, { showHidden: true, sortMode: "name" });
    assert.strictEqual(withHidden.length, 4);
}

// ── INJECTION SAFETY: launch argv is always a plain string array ──────
{
    // A clean .desktop entry launches ONLY via gtk-launch with the id token.
    const calc = M.buildLaunchArgv({ isDesktop: true, desktopId: "org.gnome.Calculator" });
    assert.deepStrictEqual(calc, ["gtk-launch", "org.gnome.Calculator"]);
    assert.ok(M.isSafeArgv(calc));
    assert.notStrictEqual(calc[0], "sh");
    assert.notStrictEqual(calc[0], "bash");

    // A crafted desktop id is REJECTED outright — never launched, never shelled.
    assert.strictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: "evil; rm -rf ~" }), null,
        "metacharacter desktop id rejected");
    assert.strictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: "/tmp/payload" }), null,
        "absolute path as id rejected");
    assert.strictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: "../../bin/sh" }), null);
    assert.strictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: "" }), null);

    // A regular file opens via xdg-open with the path as ONE argv token. A
    // metacharacter-laden filename is inert because no shell parses the argv.
    const evilPath = "/home/u/Desktop/$(rm -rf ~).txt; echo pwned";
    const open = M.buildLaunchArgv({ isDesktop: false, path: evilPath });
    assert.deepStrictEqual(open, ["xdg-open", evilPath],
        "path passed as a single literal argv element, never shell-parsed");
    assert.ok(M.isSafeArgv(open));
    assert.notStrictEqual(open[0], "sh");

    // Empty / relative / missing paths are rejected.
    assert.strictEqual(M.buildLaunchArgv({ isDesktop: false, path: "" }), null);
    assert.strictEqual(M.buildLaunchArgv({ isDesktop: false, path: "relative/x" }), null,
        "relative path rejected (must be absolute)");
    assert.strictEqual(M.buildLaunchArgv(null), null);
    assert.strictEqual(M.buildLaunchArgv({}), null, "no path/desktopId -> null");
}

// ── icon mapping incl. generic fallback for unknown files ─────────────
{
    assert.strictEqual(M.iconNameForEntry({ isDir: true, name: "Foo" }), "folder");
    assert.strictEqual(M.iconNameForEntry({ isDesktop: true, icon: "firefox", name: "firefox.desktop" }), "firefox");
    assert.strictEqual(M.iconNameForEntry({ isDesktop: true, icon: "", name: "x.desktop" }), "application-x-executable",
        "desktop entry with no resolved icon -> generic app icon");
    assert.strictEqual(M.iconNameForEntry({ name: "photo.png" }), "image-x-generic");
    assert.strictEqual(M.iconNameForEntry({ name: "song.mp3" }), "audio-x-generic");
    // A standalone (non-installed) .desktop file still shows a launcher icon.
    assert.strictEqual(M.iconNameForEntry({ name: "thing.desktop", isDesktop: false }), "application-x-executable");
    // Unknown extension and no-extension both fall back to the generic file icon.
    assert.strictEqual(M.iconNameForEntry({ name: "data.qwxyz" }), M.GENERIC_FILE_ICON);
    assert.strictEqual(M.iconNameForEntry({ name: "README" }), M.GENERIC_FILE_ICON);
    assert.strictEqual(M.iconNameForEntry(null), M.GENERIC_FILE_ICON);
}

// ── .desktop body parsing is resilient and extracts Name/Icon ─────────
{
    const body = [
        "# a comment",
        "[Desktop Entry]",
        "Type=Application",
        "Name=Calculator",
        "Name[de]=Rechner",
        "Icon=accessories-calculator",
        "Exec=gnome-calculator",
        "NoDisplay=false",
        "[Desktop Action New]",
        "Name=Should Not Win",
    ].join("\n");
    const parsed = M.parseDesktopEntry(body);
    assert.strictEqual(parsed.name, "Calculator", "base Name taken, not localized, not action group");
    assert.strictEqual(parsed.icon, "accessories-calculator");
    assert.strictEqual(parsed.noDisplay, false);
    assert.strictEqual(parsed.hidden, false);

    const hidden = M.parseDesktopEntry("[Desktop Entry]\nHidden=true\nNoDisplay=true\n");
    assert.strictEqual(hidden.hidden, true);
    assert.strictEqual(hidden.noDisplay, true);

    // Garbage never throws.
    assert.deepStrictEqual(M.parseDesktopEntry(null), { name: "", icon: "", noDisplay: false, hidden: false });
    assert.deepStrictEqual(M.parseDesktopEntry("not a desktop file"), { name: "", icon: "", noDisplay: false, hidden: false });
}

// ── single vs double click policy ─────────────────────────────────────
{
    assert.strictEqual(M.activatesOnSingleClick(true), true);
    assert.strictEqual(M.activatesOnSingleClick(false), false);
    assert.strictEqual(M.activatesOnSingleClick(undefined), false, "default is double-click");
}

// ════════════════════════════════════════════════════════════════════
// EXPANDED COVERAGE
// ════════════════════════════════════════════════════════════════════

// ── isDesktopId / desktopIdFromFileName additional edge cases ─────────
{
  // Leading-dash id is rejected (must start alphanumeric) — blocks an id that
  // could ever look like a command-line option (e.g. gtk-launch "-foo").
  assert.strictEqual(M.isDesktopId("-foo"), false, "leading dash rejected (option-injection guard)");
  assert.strictEqual(M.isDesktopId("_foo"), false, "leading underscore rejected (not alphanumeric)");
  assert.strictEqual(M.isDesktopId("+foo"), false, "leading plus rejected");
  assert.strictEqual(M.isDesktopId("9app"), true, "leading digit allowed");
  assert.strictEqual(M.isDesktopId("a b"), false, "internal space rejected");
  assert.strictEqual(M.isDesktopId("a\tb"), false, "tab rejected");
  assert.strictEqual(M.isDesktopId("a$b"), false, "dollar rejected");
  assert.strictEqual(M.isDesktopId("a`b"), false, "backtick rejected");
  assert.strictEqual(M.isDesktopId("évil"), false, "non-ASCII rejected");
  assert.strictEqual(M.isDesktopId(null), false);
  assert.strictEqual(M.isDesktopId(42), false, "non-string rejected");

  assert.strictEqual(M.desktopIdFromFileName("-evil.desktop"), "", "leading-dash base rejected");
  assert.strictEqual(M.desktopIdFromFileName(".desktop"), "", "empty base rejected");
  assert.strictEqual(M.desktopIdFromFileName("a/b.desktop"), "", "slash in base rejected");
  assert.strictEqual(M.desktopIdFromFileName("foo.DESKTOP"), "", "case-sensitive suffix");
  assert.strictEqual(M.desktopIdFromFileName(null), "");
  assert.strictEqual(M.desktopIdFromFileName(42), "");
}

// ── sort stability + folders-first × type-mode interplay ──────────────
{
  // Two entries with identical sort keys keep their RELATIVE input order in a
  // stable sort. Use distinct trailing props to detect any reorder.
  const dup = [
    { name: "same.txt", isDir: false, tag: 1 },
    { name: "same.txt", isDir: false, tag: 2 },
    { name: "same.txt", isDir: false, tag: 3 },
  ];
  const sortedDup = M.sortEntries(dup, "name", true);
  assert.deepStrictEqual(sortedDup.map(e => e.tag), [1, 2, 3], "stable sort preserves input order on ties");

  // Folders-first overrides type ordering: a directory whose name/type would
  // otherwise sort AFTER files is still hoisted to the top.
  const mixed = [
    { name: "alpha.txt", isDir: false },
    { name: "zzz-folder", isDir: true },   // would be last by name, first by folders-first
    { name: "beta.desktop", isDir: false },
  ];
  const ff = M.sortEntries(mixed, "type", true);
  assert.strictEqual(ff[0].name, "zzz-folder", "folders-first hoists dir above all files in type mode");
  // remaining: .desktop (1-) before .txt (2-)
  assert.deepStrictEqual(ff.slice(1).map(e => e.name), ["beta.desktop", "alpha.txt"]);

  // Same set WITHOUT folders-first in type mode: directory sorts by its type
  // key "0-dir" which is < every file type, so it STILL comes first here — but
  // a dir named to collide is ordered purely by the type key, then name.
  const noFf = M.sortEntries(mixed, "type", false);
  assert.strictEqual(noFf[0].name, "zzz-folder", "dir type-key 0-dir sorts before files even w/o folders-first");

  // In NAME mode without folders-first, the dir is interleaved alphabetically.
  const nameNoFf = M.sortEntries(mixed, "name", false);
  assert.deepStrictEqual(nameNoFf.map(e => e.name),
    ["alpha.txt", "beta.desktop", "zzz-folder"], "name mode w/o folders-first interleaves dir");

  // Idempotency: sorting an already-sorted list yields the same order.
  const once = M.sortEntries(mixed, "type", true);
  const twice = M.sortEntries(once, "type", true);
  assert.deepStrictEqual(twice.map(e => e.name), once.map(e => e.name), "sort is idempotent");

  // Two files of the SAME extension fall back to case-insensitive name order.
  const sameExt = [
    { name: "Bravo.txt", isDir: false },
    { name: "alpha.txt", isDir: false },
  ];
  assert.deepStrictEqual(M.sortEntries(sameExt, "type", false).map(e => e.name),
    ["alpha.txt", "Bravo.txt"], "same ext -> case-insensitive name tiebreak");
}

// ── arrangeEntries option defaults ────────────────────────────────────
{
  const entries = [
    { name: "b.txt", isDir: false },
    { name: "Dir", isDir: true },
    { name: "a.txt", isDir: false },
  ];
  // Missing sortMode defaults to "name"; missing arrangeFoldersFirst defaults true.
  const def = M.arrangeEntries(entries, {});
  assert.deepStrictEqual(def.map(e => e.name), ["Dir", "a.txt", "b.txt"], "defaults: name sort, folders first");
  // No opts at all is tolerated.
  const noOpts = M.arrangeEntries(entries);
  assert.deepStrictEqual(noOpts.map(e => e.name), ["Dir", "a.txt", "b.txt"]);
  // Unknown sortMode falls back to "name".
  const bogus = M.arrangeEntries(entries, { sortMode: "bogus" });
  assert.deepStrictEqual(bogus.map(e => e.name), ["Dir", "a.txt", "b.txt"]);
  assert.deepStrictEqual(M.arrangeEntries(null, {}), []);
}

// ── INJECTION SAFETY: more crafted ids + whitespace handling ──────────
{
  // desktopId is .trim()'d, so surrounding whitespace around a CLEAN id is OK,
  // but whitespace INSIDE still fails the charset check.
  assert.deepStrictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: "  firefox  " }),
    ["gtk-launch", "firefox"], "surrounding whitespace trimmed off a clean id");
  assert.strictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: "fire fox" }), null,
    "internal whitespace id rejected");
  // Crafted ids of every flavour are rejected -> null (never gtk-launch'd).
  ["evil; rm -rf ~", "$(touch pwn)", "`reboot`", "a|b", "../../bin/sh",
   "/abs/path", "-deletes-files", "id\nwith\nnewline", ".dotfile", ""].forEach(function (bad) {
    assert.strictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: bad }), null,
      "crafted desktop id rejected: " + JSON.stringify(bad));
  });
  // desktopId numeric / object -> stringified then charset-checked -> rejected
  // (an object stringifies to "[object Object]" which has a space).
  assert.strictEqual(M.buildLaunchArgv({ isDesktop: true, desktopId: {} }), null);
  // A purely-numeric desktopId stringifies to a leading-digit id, which is a
  // VALID id by charset — assert it is accepted as a plain token (no shell).
  const numId = M.buildLaunchArgv({ isDesktop: true, desktopId: 42 });
  assert.deepStrictEqual(numId, ["gtk-launch", "42"], "numeric id stringified to a safe token");

  // xdg-open paths: a path is ONE argv element even with metachars/newlines.
  const weird = "/home/u/Desktop/a b;c$(d)`e`\n.txt";
  assert.deepStrictEqual(M.buildLaunchArgv({ isDesktop: false, path: weird }),
    ["xdg-open", weird], "weird path passed verbatim as single token");
  // Relative / tilde / empty / whitespace-only paths are rejected (need leading /).
  assert.strictEqual(M.buildLaunchArgv({ isDesktop: false, path: "~/x" }), null, "tilde path rejected");
  assert.strictEqual(M.buildLaunchArgv({ isDesktop: false, path: " /leading-space" }), null,
    "leading-space path rejected (first char not '/')");
  assert.strictEqual(M.buildLaunchArgv({ isDesktop: false, path: "   " }), null);

  // Every safe build is a non-empty all-string argv; every reject is null.
  const safeBuilds = [numId, M.buildLaunchArgv({ isDesktop: false, path: weird })];
  safeBuilds.forEach(function (a) { assert.ok(M.isSafeArgv(a)); });
}

// ── isSafeArgv edge cases ─────────────────────────────────────────────
{
  assert.strictEqual(M.isSafeArgv(["a", "b"]), true);
  assert.strictEqual(M.isSafeArgv([]), false, "empty argv is not safe");
  assert.strictEqual(M.isSafeArgv(null), false);
  assert.strictEqual(M.isSafeArgv(undefined), false);
  assert.strictEqual(M.isSafeArgv(["ok", 42]), false, "non-string element makes it unsafe");
  assert.strictEqual(M.isSafeArgv(["ok", null]), false);
  // A bare string must NOT be treated as a safe argv even though it has a
  // numeric .length and string-indexed chars (Array.isArray guards this).
  assert.strictEqual(M.isSafeArgv("not-an-array"), false, "a string is not a safe argv");
  assert.strictEqual(M.isSafeArgv({ 0: "x", length: 1 }), false, "array-like object is not a safe argv");
}

// ── iconNameForEntry additional cases ─────────────────────────────────
{
  // Directory wins even if it also looks like a .desktop or has isDesktop set.
  assert.strictEqual(M.iconNameForEntry({ isDir: true, isDesktop: true, name: "x.desktop" }), "folder");
  // Uppercase extension is matched case-insensitively.
  assert.strictEqual(M.iconNameForEntry({ name: "PHOTO.PNG" }), "image-x-generic");
  // Dotfile with no real extension -> generic (lastIndexOf('.')===0 not > 0).
  assert.strictEqual(M.iconNameForEntry({ name: ".bashrc" }), M.GENERIC_FILE_ICON);
  // Trailing dot -> empty ext -> generic.
  assert.strictEqual(M.iconNameForEntry({ name: "weird." }), M.GENERIC_FILE_ICON);
  // isDesktop with a resolved icon overrides extension mapping.
  assert.strictEqual(M.iconNameForEntry({ isDesktop: true, icon: "myapp", name: "foo.png" }), "myapp");
  // Script extensions.
  assert.strictEqual(M.iconNameForEntry({ name: "run.sh" }), "text-x-script");
  assert.strictEqual(M.iconNameForEntry({ name: "tool.py" }), "text-x-script");
  // Archive.
  assert.strictEqual(M.iconNameForEntry({ name: "bundle.tar" }), "package-x-generic");
  assert.strictEqual(M.iconNameForEntry(undefined), M.GENERIC_FILE_ICON);
}

// ── parseDesktopEntry: missing fields, NoDisplay/Hidden, non-.desktop ─
{
  // A .desktop body lacking Name/Icon/Exec yields empty strings, never throws.
  const minimal = M.parseDesktopEntry("[Desktop Entry]\nType=Application\n");
  assert.deepStrictEqual(minimal, { name: "", icon: "", noDisplay: false, hidden: false });

  // Keys before the [Desktop Entry] group are ignored.
  const preGroup = M.parseDesktopEntry("Name=Ignored\n[Desktop Entry]\nName=Kept\n");
  assert.strictEqual(preGroup.name, "Kept", "only [Desktop Entry] group is read");

  // NoDisplay / Hidden are strictly "true" (case-insensitive) -> true; anything
  // else is false.
  assert.strictEqual(M.parseDesktopEntry("[Desktop Entry]\nNoDisplay=TRUE\n").noDisplay, true);
  assert.strictEqual(M.parseDesktopEntry("[Desktop Entry]\nHidden=True\n").hidden, true);
  assert.strictEqual(M.parseDesktopEntry("[Desktop Entry]\nNoDisplay=1\n").noDisplay, false,
    "only literal 'true' counts, not '1'");
  assert.strictEqual(M.parseDesktopEntry("[Desktop Entry]\nHidden=yes\n").hidden, false);

  // First Name/Icon wins; later duplicates ignored.
  const dupKeys = M.parseDesktopEntry("[Desktop Entry]\nName=First\nName=Second\nIcon=ic1\nIcon=ic2\n");
  assert.strictEqual(dupKeys.name, "First");
  assert.strictEqual(dupKeys.icon, "ic1");

  // A non-.desktop file (plain text, INI without the right group) -> defaults.
  assert.deepStrictEqual(M.parseDesktopEntry("just some text\nwith lines\n"),
    { name: "", icon: "", noDisplay: false, hidden: false });
  assert.deepStrictEqual(M.parseDesktopEntry("[Some Other Group]\nName=Nope\n"),
    { name: "", icon: "", noDisplay: false, hidden: false });

  // CRLF body is handled (split on \r?\n) and values are trimmed.
  const crlf = M.parseDesktopEntry("[Desktop Entry]\r\nName=  Spaced  \r\nIcon=ic\r\n");
  assert.strictEqual(crlf.name, "Spaced", "CRLF + value trimmed");
  assert.strictEqual(crlf.icon, "ic");

  // Comments and blank lines inside the group are skipped.
  const comments = M.parseDesktopEntry("[Desktop Entry]\n# comment\n\nName=Real\n");
  assert.strictEqual(comments.name, "Real");

  // The .desktop BODY is never trusted for the id — there is no exported helper
  // that reads an Exec/id out of the body and turns it into a command. Confirm
  // parseDesktopEntry returns only the four inert display fields.
  assert.deepStrictEqual(Object.keys(comments).sort(), ["hidden", "icon", "name", "noDisplay"]);
}

console.log("desktop-icons: all assertions passed");
process.exit(0);
