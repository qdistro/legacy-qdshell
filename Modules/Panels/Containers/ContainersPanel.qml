import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Modules.MainScreen
import qs.Services.Qdistro
import qs.Services.UI
import qs.Widgets

// Containers — small panel listing tier-2 podman containers known to
// qdshell (anything that's surfaced through qdistro-podapps-scan, plus
// anything currently running on the host).
//
// Source-of-truth doc: qdistro/doc/containers.md.
//
// Per-row affordances:
//   - status pill (running / off)
//   - "Stop" for running containers
//   - "Apps..." → opens a sub-menu listing the apps from
//     PodApps.apps for that container, each one launches via
//     PodApps.launch().
//
// "Start" is deliberately absent — tier-2 starts on-demand when a user
// clicks a containerised app, not as a separate action. The Containers
// panel is a status / wind-down surface, not a process manager.
SmartPanel {
  id: root

  preferredWidth: Math.round(420 * Style.uiScaleRatio)
  preferredHeight: Math.round(440 * Style.uiScaleRatio)

  panelContent: PanelShell {
    id: panelContent

    title: I18n.tr("containers.title")
    icon: "box"
    onCloseRequested: root.close()

    // Reactive list. Each entry: { name, runningApps[], state }.
    property var rowsModel: ListModel {}

    function rebuildRows() {
      const byContainer = {};
      // Collect known containers from PodApps.apps cache.
      for (let i = 0; i < PodApps.apps.count; i++) {
        const a = PodApps.apps.get(i);
        if (!byContainer[a.container])
          byContainer[a.container] = { name: a.container, workload: a.workload,
                                        state: a.containerState, apps: [] };
        byContainer[a.container].apps.push({
          appId: a.appId, name: a.name, iconName: a.iconName,
        });
      }
      // Also include running containers that have no cache yet.
      for (const name in PodApps._containerStates) {
        if (!byContainer[name])
          byContainer[name] = { name: name, workload: "",
                                 state: PodApps._containerStates[name],
                                 apps: [] };
      }
      rowsModel.clear();
      for (const k in byContainer) rowsModel.append(byContainer[k]);
    }

    Component.onCompleted: rebuildRows()
    Connections {
      target: PodApps
      function onContainerStateChanged() { panelContent.rebuildRows(); }
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginS

      NLabel {
        text: I18n.tr("containers.subtitle.tier2")
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
      }

      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: Style.marginS
        model: panelContent.rowsModel

        delegate: NBox {
          width: list.width
          implicitHeight: rowLayout.implicitHeight + Style.marginM * 2

          RowLayout {
            id: rowLayout
            anchors.fill: parent
            anchors.margins: Style.marginM
            spacing: Style.marginM

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 2
              NLabel {
                text: model.name
                font.bold: true
              }
              NLabel {
                visible: !!model.workload
                text: model.workload
                opacity: 0.7
              }
              NLabel {
                text: model.apps.length + " app" + (model.apps.length === 1 ? "" : "s")
                opacity: 0.6
              }
            }

            NLabel {
              text: model.state === "running" ? I18n.tr("containers.state.running")
                                              : I18n.tr("containers.state.off")
              color: model.state === "running" ? Color.mPrimary : Color.mOnSurface
              opacity: 0.85
            }

            NButton {
              visible: model.state === "running"
              text: I18n.tr("containers.action.stop")
              onClicked: stopProc.start(["podman", "stop", "-t", "2", model.name])
            }

            Process {
              id: stopProc
              function start(cmd) { command = cmd; running = true; }
              onRunningChanged: {
                if (!running) PodApps.refreshContainerStates();
              }
            }
          }
        }
      }
    }
  }
}
