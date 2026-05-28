import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.System
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginL
  Layout.fillWidth: true

  NText {
    Layout.fillWidth: true
    text: I18n.tr("panels.default-apps.description")
    pointSize: Style.fontSizeS
    color: Color.mOnSurfaceVariant
    wrapMode: Text.WordWrap
  }

  NDivider {
    Layout.fillWidth: true
  }

  // Loading indicator
  NText {
    visible: !DefaultAppsService.ready
    text: I18n.tr("panels.default-apps.scanning")
    pointSize: Style.fontSizeM
    color: Color.mOnSurfaceVariant
  }

  // Category combo boxes
  Repeater {
    model: DefaultAppsService.ready ? DefaultAppsService.categories : []

    ColumnLayout {
      required property var modelData
      required property int index

      Layout.fillWidth: true
      spacing: Style.marginS

      NComboBox {
        id: combo
        Layout.fillWidth: true
        label: I18n.tr("panels.default-apps.category-" + modelData.id)
        description: I18n.tr("panels.default-apps.category-" + modelData.id + "-description")

        property var apps: DefaultAppsService.availableApps[modelData.id] || []

        model: {
          var items = [
            {
              "key": "",
              "name": I18n.tr("panels.default-apps.system-default")
            }
          ];
          for (var i = 0; i < apps.length; i++) {
            items.push({
              "key": apps[i].desktopId,
              "name": apps[i].name
            });
          }
          return items;
        }

        currentKey: DefaultAppsService.currentDefaults[modelData.id] || ""
        defaultValue: ""

        onSelected: function (key) {
          DefaultAppsService.setDefault(modelData.id, key);
        }
      }

      // No applications found hint
      NText {
        visible: (DefaultAppsService.availableApps[modelData.id] || []).length === 0
        text: I18n.tr("panels.default-apps.no-apps-found")
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
        Layout.leftMargin: Style.marginL
      }

      // Effective system handler hint (shown when "System default" is selected)
      NText {
        readonly property string resolvedId: DefaultAppsService.resolvedDefaults[modelData.id] || ""
        visible: (DefaultAppsService.currentDefaults[modelData.id] || "") === "" && resolvedId !== ""
        text: I18n.tr("panels.default-apps.currently-using", {
          "app": DefaultAppsService.getAppName(resolvedId)
        })
        pointSize: Style.fontSizeXS
        color: Color.mOnSurfaceVariant
        Layout.leftMargin: Style.marginL
      }

      // Reset button
      NButton {
        visible: (DefaultAppsService.currentDefaults[modelData.id] || "") !== ""
        text: I18n.tr("panels.default-apps.reset-to-default")
        icon: "rotate-clockwise"
        outlined: true
        Layout.alignment: Qt.AlignRight
        onClicked: DefaultAppsService.resetDefault(modelData.id)
      }

      NDivider {
        visible: index < DefaultAppsService.categories.length - 1
        Layout.fillWidth: true
      }
    }
  }

  // Rescan button
  NButton {
    visible: DefaultAppsService.ready
    Layout.fillWidth: true
    text: I18n.tr("panels.default-apps.rescan")
    icon: "refresh"
    onClicked: DefaultAppsService.rescan()
  }

  // Bottom spacer
  Item {
    Layout.fillHeight: true
  }
}
