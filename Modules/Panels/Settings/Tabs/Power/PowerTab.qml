import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Services.Power
import qs.Services.UI
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginL
  Layout.fillWidth: true

  // ─── Helper models for action combos ─────────────────────────────
  readonly property var buttonActionModel: {
    var items = [
      { "key": "nothing",  "name": I18n.tr("panels.power.action-nothing") },
      { "key": "suspend",  "name": I18n.tr("common.suspend") }
    ];
    if (PowerService.canHibernate)
      items.push({ "key": "hibernate", "name": I18n.tr("common.hibernate") });
    items.push({ "key": "shutdown", "name": I18n.tr("common.shutdown") });
    items.push({ "key": "ask",      "name": I18n.tr("panels.power.action-ask") });
    return items;
  }

  readonly property var lidActionModel: {
    var items = [
      { "key": "nothing",  "name": I18n.tr("panels.power.action-nothing") },
      { "key": "suspend",  "name": I18n.tr("common.suspend") }
    ];
    if (PowerService.canHibernate)
      items.push({ "key": "hibernate", "name": I18n.tr("common.hibernate") });
    return items;
  }

  readonly property var inactivityActionModel: {
    var items = [
      { "key": "nothing",      "name": I18n.tr("panels.power.action-nothing") },
      { "key": "suspend",      "name": I18n.tr("common.suspend") }
    ];
    if (PowerService.canHibernate)
      items.push({ "key": "hibernate", "name": I18n.tr("common.hibernate") });
    if (PowerService.canHybridSleep)
      items.push({ "key": "hybrid-sleep", "name": I18n.tr("panels.power.action-hybrid-sleep") });
    return items;
  }

  readonly property var criticalActionModel: {
    var items = [
      { "key": "suspend",  "name": I18n.tr("common.suspend") }
    ];
    if (PowerService.canHibernate)
      items.push({ "key": "hibernate", "name": I18n.tr("common.hibernate") });
    items.push({ "key": "shutdown", "name": I18n.tr("common.shutdown") });
    return items;
  }

  // ═══════════════════════════════════════════════════════════════════
  // Buttons section
  // ═══════════════════════════════════════════════════════════════════
  NText {
    text: I18n.tr("panels.power.section-buttons")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  NComboBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.power-button-action-label")
    description: I18n.tr("panels.power.power-button-action-description")
    model: buttonActionModel
    currentKey: Settings.data.power.powerButtonAction
    defaultValue: Settings.getDefaultValue("power.powerButtonAction")
    onSelected: key => Settings.data.power.powerButtonAction = key
  }

  NComboBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.sleep-button-action-label")
    description: I18n.tr("panels.power.sleep-button-action-description")
    model: buttonActionModel
    currentKey: Settings.data.power.sleepButtonAction
    defaultValue: Settings.getDefaultValue("power.sleepButtonAction")
    onSelected: key => Settings.data.power.sleepButtonAction = key
  }

  // ═══════════════════════════════════════════════════════════════════
  // Lid section (only shown on laptops)
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
    visible: PowerService.hasLid
  }

  NText {
    text: I18n.tr("panels.power.section-lid")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
    visible: PowerService.hasLid
  }

  NComboBox {
    Layout.fillWidth: true
    visible: PowerService.hasLid
    label: I18n.tr("panels.power.lid-close-battery-label")
    description: I18n.tr("panels.power.lid-close-battery-description")
    model: lidActionModel
    currentKey: Settings.data.power.lidCloseOnBattery
    defaultValue: Settings.getDefaultValue("power.lidCloseOnBattery")
    onSelected: key => Settings.data.power.lidCloseOnBattery = key
  }

  NComboBox {
    Layout.fillWidth: true
    visible: PowerService.hasLid
    label: I18n.tr("panels.power.lid-close-ac-label")
    description: I18n.tr("panels.power.lid-close-ac-description")
    model: lidActionModel
    currentKey: Settings.data.power.lidCloseOnAC
    defaultValue: Settings.getDefaultValue("power.lidCloseOnAC")
    onSelected: key => Settings.data.power.lidCloseOnAC = key
  }

  NToggle {
    Layout.fillWidth: true
    visible: PowerService.hasLid
    label: I18n.tr("panels.power.lid-ignore-external-label")
    description: I18n.tr("panels.power.lid-ignore-external-description")
    checked: Settings.data.power.lidIgnoreExternalDisplay
    onToggled: checked => Settings.data.power.lidIgnoreExternalDisplay = checked
    defaultValue: Settings.getDefaultValue("power.lidIgnoreExternalDisplay")
  }

  // ═══════════════════════════════════════════════════════════════════
  // Inactivity section
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    text: I18n.tr("panels.power.section-inactivity")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  // Capability note: qdwin has no idle/DPMS IPC yet, so the inactivity and
  // display-off policy below is persist-only until the compositor supports it.
  Rectangle {
    Layout.fillWidth: true
    visible: !PowerService.canApplyIdle
    radius: Style.iRadiusS
    color: Color.mSurfaceVariant
    border.color: Color.mOutline
    border.width: Style.borderS
    implicitHeight: idleBannerRow.implicitHeight + Style.marginM * 2

    RowLayout {
      id: idleBannerRow
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
        text: I18n.tr("panels.power.idle-persist-only")
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
        wrapMode: Text.WordWrap
      }
    }
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.inactivity-battery-label")
    description: I18n.tr("panels.power.inactivity-battery-description")
    minimum: 0
    maximum: 120
    value: Settings.data.power.inactivityTimeoutBattery
    stepSize: 1
    suffix: " min"
    onValueChanged: Settings.data.power.inactivityTimeoutBattery = value
    defaultValue: Settings.getDefaultValue("power.inactivityTimeoutBattery")
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.inactivity-ac-label")
    description: I18n.tr("panels.power.inactivity-ac-description")
    minimum: 0
    maximum: 120
    value: Settings.data.power.inactivityTimeoutAC
    stepSize: 1
    suffix: " min"
    onValueChanged: Settings.data.power.inactivityTimeoutAC = value
    defaultValue: Settings.getDefaultValue("power.inactivityTimeoutAC")
  }

  NComboBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.inactivity-action-label")
    description: I18n.tr("panels.power.inactivity-action-description")
    model: inactivityActionModel
    currentKey: Settings.data.power.inactivityAction
    defaultValue: Settings.getDefaultValue("power.inactivityAction")
    onSelected: key => Settings.data.power.inactivityAction = key
  }

  // ═══════════════════════════════════════════════════════════════════
  // Critical battery section
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    text: I18n.tr("panels.power.section-critical-battery")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.critical-level-label")
    description: I18n.tr("panels.power.critical-level-description")
    minimum: 1
    maximum: 20
    value: Settings.data.power.criticalBatteryLevel
    stepSize: 1
    suffix: "%"
    onValueChanged: Settings.data.power.criticalBatteryLevel = value
    defaultValue: Settings.getDefaultValue("power.criticalBatteryLevel")
  }

  NComboBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.critical-action-label")
    description: I18n.tr("panels.power.critical-action-description")
    model: criticalActionModel
    currentKey: Settings.data.power.criticalBatteryAction
    defaultValue: Settings.getDefaultValue("power.criticalBatteryAction")
    onSelected: key => Settings.data.power.criticalBatteryAction = key
  }

  // ═══════════════════════════════════════════════════════════════════
  // Display section
  // ═══════════════════════════════════════════════════════════════════
  NDivider {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    Layout.bottomMargin: Style.marginM
  }

  NText {
    text: I18n.tr("panels.power.section-display")
    pointSize: Style.fontSizeM
    font.weight: Style.fontWeightBold
    color: Color.mPrimary
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.display-off-battery-label")
    description: I18n.tr("panels.power.display-off-battery-description")
    minimum: 0
    maximum: 120
    value: Settings.data.power.displayOffBattery
    stepSize: 1
    suffix: " min"
    onValueChanged: Settings.data.power.displayOffBattery = value
    defaultValue: Settings.getDefaultValue("power.displayOffBattery")
  }

  NSpinBox {
    Layout.fillWidth: true
    label: I18n.tr("panels.power.display-off-ac-label")
    description: I18n.tr("panels.power.display-off-ac-description")
    minimum: 0
    maximum: 120
    value: Settings.data.power.displayOffAC
    stepSize: 1
    suffix: " min"
    onValueChanged: Settings.data.power.displayOffAC = value
    defaultValue: Settings.getDefaultValue("power.displayOffAC")
  }

  NText {
    Layout.fillWidth: true
    text: I18n.tr("panels.power.display-brightness-hint")
    color: Color.mOnSurfaceVariant
    pointSize: Style.fontSizeS
    wrapMode: Text.WordWrap
  }
}
