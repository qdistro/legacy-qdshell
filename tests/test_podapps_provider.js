const assert = require("assert");
const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const provider = fs.readFileSync(
    path.join(repo, "Modules/Panels/Launcher/Providers/PodAppsProvider.qml"),
    "utf8"
);
const core = fs.readFileSync(
    path.join(repo, "Modules/Panels/Launcher/LauncherCore.qml"),
    "utf8"
);

// Ensures: an async apps.json scan updates a launcher that is already open.
assert.ok(provider.includes("target: PodApps.apps"));
assert.ok(provider.includes("function onCountChanged()"));
assert.ok(provider.includes("root.launcher.updateResults();"));

// Ensures: tier-2 entries retain a non-text silo signal even when their app
// icon is absent from the host theme.
assert.ok(provider.includes('"badgeIcon":   "container"'));
assert.ok(provider.includes('"badgeColor":  "#ce93d8"'));
assert.strictEqual(
    (core.match(/modelData\.badgeColor \|\| Color\.mSurfaceVariant/g) || []).length,
    2,
    "both list and grid delegates must render provider badge colors"
);
assert.strictEqual(
    (core.match(/modelData\.badgeIconColor \|\| Color\.mOnSurfaceVariant/g) || []).length,
    2,
    "both list and grid delegates must render readable badge glyph colors"
);

console.log("podapps-provider: async refresh and tier-2 badge invariants passed");
