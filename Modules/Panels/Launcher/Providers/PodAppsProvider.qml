import QtQuick
import Quickshell
import qs.Commons
import qs.Services.Qdistro

// PodAppsProvider — surface tier-2 container apps in the launcher.
//
// Pulls from Services.Qdistro.PodApps (which reads
// /var/lib/qdistro/podapps/*/apps.json, written by
// qdistro/tier2/podapps-scan.sh). On activate, calls PodApps.launch()
// which forks qdistro-tier2-spawn and registers a cold-start
// placeholder; qdshell's PodApps service resolves the placeholder
// when toplevel_security_context arrives with a matching instance_id.
//
// Visual note: the launcher's standard entry delegate renders the
// entry's name + icon + description. Until the badge convention from
// doc/ui.md is implemented as a delegate-side overlay, this provider
// prefixes the description with the silo identifier so the user can
// tell same-app-different-silo entries apart. The badge ring/glyph
// is tracked as follow-up in doc/containers.md "Future work".
Item {
  id: root

  property var launcher: null
  property string name: I18n.tr("launcher.providers.containers")
  property bool handleSearch: true
  property var entries: []
  property string supportedLayouts: "both"
  property bool isDefaultProvider: false
  property bool ignoreDensity: false
  property bool showsCategories: false

  function init() {
    PodApps.refresh();
  }

  function onOpened() {
    PodApps.refresh();
    PodApps.refreshContainerStates();
  }

  function getResults(query) {
    const all = [];
    for (let i = 0; i < PodApps.apps.count; i++) {
      const row = PodApps.apps.get(i);
      all.push(row);
    }
    let filtered = all;
    if (query && query.trim() !== "") {
      const q = query.toLowerCase();
      filtered = all.filter(r =>
        (r.name || "").toLowerCase().includes(q)
        || (r.comment || "").toLowerCase().includes(q)
        || (r.container || "").toLowerCase().includes(q)
      );
    }
    return filtered.slice(0, 20).map(row => ({
      "appId":       row.appId,
      "name":        row.name,
      "description": "[" + row.silo + "] " + (row.comment || ""),
      "icon":        row.iconName || "application-x-executable",
      "isImage":     false,
      "_score":      0,
      "provider":    root,
      "onActivate":  function () {
        if (launcher && launcher.closeImmediately)
          launcher.closeImmediately();
        Qt.callLater(() => {
          Logger.d("PodAppsProvider",
            "Launching " + row.appId + " in " + row.container);
          PodApps.launch(row);
        });
      },
    }));
  }
}
