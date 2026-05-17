import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.Qdwin
import qs.Widgets

Item {
  id: root

  // Button dimensions
  implicitWidth: 40
  implicitHeight: 40

  // Lock button functionality
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    
    onClicked: {
      // Trigger the lock screen
      PanelService.lockScreen?.active = true;
    }
    
    NIconButton {
      anchors.centerIn: parent
      icon: "lock"
      baseSize: 20
      colorBg: containsMouse ? Color.mPrimary : "transparent"
      colorFg: containsMouse ? Color.mOnPrimary : Color.mOnSurfaceVariant
      tooltipText: "Lock Screen"
    }
  }
}