const assert = require("assert");
const ClipboardSilo = require("../Services/Qdshell/ClipboardSilo.js");

function sameStableSilo(left, right, expected) {
    const leftSilo = ClipboardSilo.fromSecctx(
        left.sandboxEngine,
        left.appId,
        left.instanceId
    );
    const rightSilo = ClipboardSilo.fromSecctx(
        right.sandboxEngine,
        right.appId,
        right.instanceId
    );

    assert.strictEqual(leftSilo, expected);
    assert.strictEqual(rightSilo, expected);
    assert.strictEqual(leftSilo, rightSilo);
}

sameStableSilo(
    {
        sandboxEngine: "qdistro.tier2",
        appId: "work/firefox",
        instanceId: "launch-token-a",
    },
    {
        sandboxEngine: "qdistro.tier2",
        appId: "work/firefox",
        instanceId: "launch-token-b",
    },
    "tier2/work"
);

sameStableSilo(
    {
        sandboxEngine: "qdistro.tier3",
        appId: "qdistro.tier3.user1",
        instanceId: "launch-token-a",
    },
    {
        sandboxEngine: "qdistro.tier3",
        appId: "qdistro.tier3.user1",
        instanceId: "launch-token-b",
    },
    "user1"
);

sameStableSilo(
    {
        sandboxEngine: "qdistro.tier5",
        appId: "qdistro.tier5.firefox",
        instanceId: "launch-token-a",
    },
    {
        sandboxEngine: "qdistro.tier5",
        appId: "qdistro.tier5.firefox",
        instanceId: "launch-token-b",
    },
    "vm-firefox"
);

assert.notStrictEqual(
    ClipboardSilo.fromSecctx("flatpak", "org.example.App", "launch-token-a"),
    ClipboardSilo.fromSecctx("flatpak", "org.example.App", "launch-token-b")
);

assert.notStrictEqual(
    ClipboardSilo.fromSecctx("flatpak", "", "instance-a"),
    ClipboardSilo.fromSecctx("flatpak", "", "instance-b")
);

assert.strictEqual(
    ClipboardSilo.fromSecctx("flatpak", "qdistro.tier3.user1", "instance-a"),
    "instance-a"
);

assert.strictEqual(
    ClipboardSilo.fromSecctx("qdistro.tier5", "qdistro.tier3.user1", "launch-token-a"),
    "qdistro.tier5:qdistro.tier3.user1"
);

assert.notStrictEqual(
    ClipboardSilo.fromSecctx("qdistro.tier3", "qdistro.tier3.user1", "same-token"),
    ClipboardSilo.fromSecctx("qdistro.tier3", "qdistro.tier3.user2", "same-token")
);
