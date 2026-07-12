// Source guard for the R2 broker-vouched trust-chrome boundary.
const assert = require("assert");
const fs = require("fs");
const path = require("path");

const qml = fs.readFileSync(
  path.join(__dirname, "..", "Services/Qdwin/RemoteMachineWindows.qml"), "utf8");

// Ensures: observing a self-shaped secctx app_id does not immediately earn
// trusted colour; broker confirmation is parsed before authorization maps fill.
assert.ok(qml.includes('root._paintBorder(row.handle, "", "", false)'),
  "new remote-looking windows must begin with neutral chrome");
assert.ok(qml.includes('"BindHandleIdentity", "sssst"'),
  "qdshell must request the broker-vouched bound identity");
assert.ok(qml.includes('RM.parseBindIdentity(String(_bindStdout.text || ""))'),
  "BindHandleIdentity output must pass fail-closed parsing");
assert.ok(qml.includes('root._originByHandle[req.handle] = identity.origin'),
  "close authority must come from the accepted broker identity");
assert.ok(qml.includes('root._trustDomainByHandle[req.handle] = identity.trust_domain_id'),
  "trust chrome must use the broker-vouched trust domain");
assert.ok(qml.includes('root._secctxByHandle[req.handle] = req.secctxAppId'),
  "handle authorization must bind the exact secctx observation");

// Ensures: the old unchecked fire-and-forget bind cannot silently return.
assert.ok(!qml.includes('"BindHandle", "sssst"'),
  "unchecked legacy BindHandle call must not return");
assert.ok(!qml.includes('RM.colourForOrigin(row.origin)'),
  "secctx-parsed origin alone must not select trusted chrome");

console.log("remote-machine-binding: broker-vouched chrome invariants passed");
