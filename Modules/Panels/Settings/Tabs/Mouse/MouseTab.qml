import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.Hardware
import qs.Services.UI
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginL
  Layout.fillWidth: true

  Component.onCompleted: {
    PointerInputService.detectApplyBackend();
    PointerInputService.refresh();
  }

  // ─── Helper models ───────────────────────────────────────────────
  readonly property var accelProfileModel: [
    {
      "key": "adaptive",
      "name": I18n.tr("panels.mouse.accel-profile-adaptive")
    },
    {
      "key": "flat",
      "name": I18n.tr("panels.mouse.accel-profile-flat")
    }
  ]

  readonly property var scrollMethodModel: [
    {
      "key": "two_finger",
      "name": I18n.tr("panels.mouse.scroll-method-two-finger")
    },
    {
      "key": "edge",
      "name": I18n.tr("panels.mouse.scroll-method-edge")
    },
    {
      "key": "on_button_down",
      "name": I18n.tr("panels.mouse.scroll-method-button")
    },
    {
      "key": "none",
      "name": I18n.tr("panels.mouse.scroll-method-none")
    }
  ]

  function deviceTypeLabel(type) {
    switch (type) {
    case "touchpad":
      return I18n.tr("panels.mouse.device-type-touchpad");
    case "trackpoint":
      return I18n.tr("panels.mouse.device-type-trackpoint");
    case "mouse":
      return I18n.tr("panels.mouse.device-type-mouse");
    default:
      return I18n.tr("panels.mouse.device-type-pointer");
    }
  }

  function deviceTypeIcon(type) {
    switch (type) {
    case "touchpad":
      return "device-laptop";
    case "trackpoint":
      return "point";
    default:
      return "mouse";
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Backend status banner (capability gating, PowerService-style)
  // ═══════════════════════════════════════════════════════════════════
  Rectangle {
    Layout.fillWidth: true
    visible: PointerInputService.ready && !PointerInputService.canApply
    radius: Style.iRadiusS
    color: Color.mSurfaceVariant
    border.color: Color.mOutline
    border.width: Style.borderS
    implicitHeight: backendRow.implicitHeight + Style.marginM * 2

    RowLayout {
      id: backendRow
      anchors.fill: parent
      anchors.margins: Style.marginM
      spacing: Style.marginM

      NIcon {
        icon: "info-circle"
        pointSize: Style.fontSizeXL
        color: Color.mTertiary
        Layout.alignment: Qt.AlignTop
      }

      NText {
        Layout.fillWidth: true
        text: I18n.tr("panels.mouse.backend-persist-only")
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
        wrapMode: Text.WordWrap
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Devices section
  // ═══════════════════════════════════════════════════════════════════
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginM

    NText {
      text: I18n.tr("panels.mouse.section-devices")
      pointSize: Style.fontSizeM
      font.weight: Style.fontWeightBold
      color: Color.mPrimary
      Layout.fillWidth: true
    }

    NButton {
      text: I18n.tr("common.refresh")
      icon: "filepicker-refresh"
      outlined: true
      onClicked: {
        PointerInputService.detectApplyBackend();
        PointerInputService.refresh();
      }
    }
  }

  // Empty / unavailable state
  NLabel {
    Layout.fillWidth: true
    visible: PointerInputService.ready && !PointerInputService.hasDevices
    label: I18n.tr("panels.mouse.no-devices-label")
    description: I18n.tr("panels.mouse.no-devices-description")
  }

  // Device rows
  Repeater {
    model: PointerInputService.devices

    delegate: Rectangle {
      Layout.fillWidth: true
      implicitHeight: deviceRow.implicitHeight + Style.marginM * 2
      radius: Style.iRadiusS
      color: "transparent"
      border.color: Color.mOutline
      border.width: Style.borderS

      RowLayout {
        id: deviceRow
        anchors.fill: parent
        anchors.margins: Style.marginM
        spacing: Style.marginM

        NIcon {
          icon: root.deviceTypeIcon(modelData.type)
          pointSize: Style.fontSizeXXL
          color: Color.mPrimary
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.marginXXS

          NText {
            text: modelData.name
            pointSize: Style.fontSizeM
            font.weight: Style.fontWeightSemiBold
            color: Color.mOnSurface
            Layout.fillWidth: true
            elide: Text.ElideRight
            maximumLineCount: 1
          }

          NText {
            text: root.deviceTypeLabel(modelData.type)
            pointSize: Style.fontSizeS
            color: Color.mOnSurfaceVariant
            Layout.fillWidth: true
          }
        }
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Pointer behaviour section
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    text: I18n.tr("panels.mouse.section-pointer")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  NComboBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.accel-profile-label")
    description: I18n.tr("panels.mouse.accel-profile-description")
    model: root.accelProfileModel
    currentKey: Settings.data.pointer.accelProfile
    defaultValue: Settings.getDefaultValue("pointer.accelProfile")
    onSelected: key => Settings.data.pointer.accelProfile = key
  }

  NValueSlider {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.speed-label")
    description: I18n.tr("panels.mouse.speed-description")
    from: 0.0
    to: 1.0
    stepSize: 0.05
    value: Settings.data.pointer.pointerSpeed
    text: Math.round(Settings.data.pointer.pointerSpeed * 100) + "%"
    defaultValue: Settings.getDefaultValue("pointer.pointerSpeed")
    onMoved: value => Settings.data.pointer.pointerSpeed = value
  }

  NToggle {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.left-handed-label")
    description: I18n.tr("panels.mouse.left-handed-description")
    checked: Settings.data.pointer.leftHanded
    onToggled: checked => Settings.data.pointer.leftHanded = checked
    defaultValue: Settings.getDefaultValue("pointer.leftHanded")
  }

  // ═══════════════════════════════════════════════════════════════════
  // Scrolling section
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    text: I18n.tr("panels.mouse.section-scrolling")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  NToggle {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.natural-scroll-label")
    description: I18n.tr("panels.mouse.natural-scroll-description")
    checked: Settings.data.pointer.naturalScroll
    onToggled: checked => Settings.data.pointer.naturalScroll = checked
    defaultValue: Settings.getDefaultValue("pointer.naturalScroll")
  }

  NToggle {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.horizontal-scroll-label")
    description: I18n.tr("panels.mouse.horizontal-scroll-description")
    checked: Settings.data.pointer.horizontalScroll
    onToggled: checked => Settings.data.pointer.horizontalScroll = checked
    defaultValue: Settings.getDefaultValue("pointer.horizontalScroll")
  }

  NText {
    Layout.fillWidth: true
    visible: PointerInputService.canApply
    text: I18n.tr("panels.mouse.horizontal-scroll-note")
    color: Color.mOnSurfaceVariant
    pointSize: Style.fontSizeXS
    wrapMode: Text.WordWrap
  }

  NComboBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.scroll-method-label")
    description: I18n.tr("panels.mouse.scroll-method-description")
    model: root.scrollMethodModel
    currentKey: Settings.data.pointer.scrollMethod
    defaultValue: Settings.getDefaultValue("pointer.scrollMethod")
    onSelected: key => Settings.data.pointer.scrollMethod = key
  }

  // ═══════════════════════════════════════════════════════════════════
  // Touchpad section
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    text: I18n.tr("panels.mouse.section-touchpad")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  NToggle {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.tap-to-click-label")
    description: I18n.tr("panels.mouse.tap-to-click-description")
    checked: Settings.data.pointer.tapToClick
    onToggled: checked => Settings.data.pointer.tapToClick = checked
    defaultValue: Settings.getDefaultValue("pointer.tapToClick")
  }

  NToggle {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.disable-while-typing-label")
    description: I18n.tr("panels.mouse.disable-while-typing-description")
    checked: Settings.data.pointer.disableWhileTyping
    onToggled: checked => Settings.data.pointer.disableWhileTyping = checked
    defaultValue: Settings.getDefaultValue("pointer.disableWhileTyping")
  }

  // ═══════════════════════════════════════════════════════════════════
  // Double-click & drag section (compositor-independent UI behaviour)
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    text: I18n.tr("panels.mouse.section-doubleclick")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  NText {
    Layout.fillWidth: true
    text: I18n.tr("panels.mouse.doubleclick-note")
    color: Color.mOnSurfaceVariant
    pointSize: Style.fontSizeXS
    wrapMode: Text.WordWrap
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.double-click-time-label")
    description: I18n.tr("panels.mouse.double-click-time-description")
    minimum: 100
    maximum: 1000
    stepSize: 50
    suffix: " ms"
    value: Settings.data.pointer.doubleClickTime
    onValueChanged: Settings.data.pointer.doubleClickTime = value
    defaultValue: Settings.getDefaultValue("pointer.doubleClickTime")
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.double-click-distance-label")
    description: I18n.tr("panels.mouse.double-click-distance-description")
    minimum: 1
    maximum: 30
    stepSize: 1
    suffix: " px"
    value: Settings.data.pointer.doubleClickDistance
    onValueChanged: Settings.data.pointer.doubleClickDistance = value
    defaultValue: Settings.getDefaultValue("pointer.doubleClickDistance")
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.mouse.drag-threshold-label")
    description: I18n.tr("panels.mouse.drag-threshold-description")
    minimum: 1
    maximum: 50
    stepSize: 1
    suffix: " px"
    value: Settings.data.pointer.dragThreshold
    onValueChanged: Settings.data.pointer.dragThreshold = value
    defaultValue: Settings.getDefaultValue("pointer.dragThreshold")
  }

  // ═══════════════════════════════════════════════════════════════════
  // Cursor note (cursor theme/size lives in the Appearance tab)
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    Layout.fillWidth: true
    text: I18n.tr("panels.mouse.cursor-hint")
    color: Color.mOnSurfaceVariant
    pointSize: Style.fontSizeS
    wrapMode: Text.WordWrap
  }
}
