const assert = require("assert");
const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const qml = fs.readFileSync(
    path.join(repo, "Services/Qdwin/Qdwin.qml"), "utf8");
const fn = qml.match(/function _pushWorkspaceNames\(\) \{[\s\S]*?\n    \}/);
assert.ok(fn, "_pushWorkspaceNames function should exist");
const body = fn[0];

assert.ok(
    body.includes("var desired = Math.max(1, Math.min(_settingsWorkspaceCount, 32));"),
    "_pushWorkspaceNames must account for the desired settings count"
);
assert.ok(
    body.includes("var count = Math.max(desired, live);"),
    "workspace-name push must cover newly requested workspaces before live count refreshes"
);
assert.ok(
    !body.includes("var count = bound ? qdwinBinding.workspaceCount"),
    "old live-count-only workspace-name loop must not return"
);

console.log("workspace-names: growth push invariant passed");
