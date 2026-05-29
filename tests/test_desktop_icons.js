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

console.log("desktop-icons: all assertions passed");
process.exit(0);
