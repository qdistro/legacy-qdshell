const assert = require("assert");
const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const qml = fs.readFileSync(
    path.join(repo, "Services/Qdwin/Qdwin.qml"), "utf8");
const handler = qml.match(
    /onNestedProxyPixelSource:[\s\S]*?\n        onToplevelRemoved:/
);

assert.ok(handler, "nested proxy pixel-source handler should exist");

// Ensures: the production tier-2 nested display uses the reliable SHM lane;
// the opt-in dmabuf path must not crash the inner compositor underneath it.
assert.ok(
    handler[0].includes(
        '["env", "QDWIN_PIXELFEED_NO_DMABUF=1",\n' +
        '                          "qdistro-nested-pixelfeed", String(handle), pwNode]'
    ),
    "nested pixelfeed launch must pin the production path to SHM"
);

// Ensures: argv stays tokenized; a protocol-provided node string is never
// interpolated into a shell command while applying the environment override.
assert.ok(
    handler[0].includes("Quickshell.execDetached(argv)"),
    "nested pixelfeed must use tokenized execDetached argv"
);
assert.ok(
    !handler[0].includes('execDetached(["sh"') &&
    !handler[0].includes('execDetached(["bash"'),
    "nested pixelfeed must not route protocol strings through a shell"
);

console.log("nested-pixelfeed-launch: SHM and tokenized-argv invariants passed");
