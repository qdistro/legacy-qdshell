function tierSuffix(appId, prefix) {
    if (!appId || !appId.startsWith(prefix))
        return "";
    return appId.slice(prefix.length);
}

function fromSecctx(sandboxEngine, appId, instanceId) {
    const engine = sandboxEngine || "";
    const app = appId || "";

    let tag = tierSuffix(app, "qdistro.tier2.");
    if (engine === "qdistro.tier2" && tag.length > 0)
        return "tier2/" + tag.split("/", 1)[0];

    tag = tierSuffix(app, "qdistro.tier3.");
    if (engine === "qdistro.tier3" && tag.length > 0)
        return tag;

    tag = tierSuffix(app, "qdistro.tier4.");
    if (engine === "qdistro.tier4" && tag.length > 0)
        return tag;

    tag = tierSuffix(app, "qdistro.tier5.");
    if (engine === "qdistro.tier5" && tag.length > 0)
        return "vm-" + tag;

    if (engine === "qdistro.tier2" && app.length > 0)
        return "tier2/" + app.split("/", 1)[0];

    if (engine === "qdistro-silo" && app.length > 0)
        return app;

    if (!engine.startsWith("qdistro.")) {
        if (instanceId && instanceId.length > 0)
            return instanceId;
        if (engine.length > 0 && app.length > 0)
            return engine + ":" + app;
    }

    if (engine.startsWith("qdistro.") && app.length > 0)
        return engine + ":" + app;

    if (engine.length > 0)
        return "engine:" + engine;

    return "";
}

if (typeof module !== "undefined") {
    module.exports = {
        fromSecctx: fromSecctx,
    };
}
