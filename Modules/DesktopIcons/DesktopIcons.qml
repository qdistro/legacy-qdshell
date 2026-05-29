// xfdesktop-parity desktop file icons — opt-in, DISABLED BY DEFAULT.
//
// When Settings.data.desktopIcons.enabled is false this renders NOTHING (the
// per-screen Loader is inactive), so the desktop behaves exactly as before and
// does not disturb the DesktopWidgets / Background layers.
//
// When enabled, it renders file/launcher icons for the user's Desktop dir
// (XDG_DESKTOP_DIR, fallback $HOME/Desktop) on a Bottom layer-shell surface,
// and adds a small right-click desktop menu. All launching is injection-safe:
// it goes through DesktopIconModel.buildLaunchArgv() (gtk-launch <id> for
// .desktop, xdg-open <path> for files) and Quickshell.execDetached() with a
// plain argv array — a shell is NEVER spawned.
import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Modules.Panels.Settings
import qs.Services.Power
import qs.Services.UI
import qs.Widgets
import "DesktopIconModel.js" as DesktopIconModel

Variants {
  id: root
  model: Quickshell.screens

  // Resolve the Desktop directory once (XDG_DESKTOP_DIR, fallback $HOME/Desktop).
  // Static for the session; the FolderListModel watches the directory contents.
  readonly property string desktopDir: {
    var d = Quickshell.env("XDG_DESKTOP_DIR");
    if (d && d.length > 0)
      return d;
    var home = Quickshell.env("HOME") || "";
    return home + "/Desktop";
  }

  delegate: Loader {
    id: screenLoader
    required property ShellScreen modelData

    // Only create the surface when the feature is enabled. Default-off => no
    // window is ever created, identical to the previous behavior.
    active: modelData && Settings.data.desktopIcons.enabled && !PowerProfileService.qdshellPerformanceMode && !PanelService.lockScreen?.active

    sourceComponent: PanelWindow {
      id: window
      color: "transparent"
      screen: screenLoader.modelData

      // Bottom layer: above the wallpaper (Background uses Background layer),
      // below the desktop widgets surface. Ignore exclusion zones.
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "qdshell-desktop-icons-" + (screen?.name || "unknown")
      // Only receive clicks where there is actually content; let clicks on the
      // empty area through to the right-click handler below (we keep the whole
      // surface interactive so the desktop context menu works).

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      readonly property int iconSize: Settings.data.desktopIcons.iconSize
      readonly property int labelSize: Settings.data.desktopIcons.labelSize
      readonly property int cellW: Math.round(iconSize * 1.8)
      readonly property int cellH: Math.round(iconSize + labelSize * 3.2 + Style.marginM * 2)

      // ---- model of arranged entries (pure logic in DesktopIconModel) ----
      property var entries: []

      // Convert a FolderListModel filePath (a file:// URL or a plain path) to
      // a real local filesystem path, decoding percent-escapes. Doing this
      // deliberately (instead of a naive .replace) avoids corrupting names
      // that legitimately contain "file://" and handles spaces/unicode.
      function _toLocalPath(filePath) {
        var s = String(filePath);
        if (s.indexOf("file://") === 0)
          s = s.substring("file://".length);
        try {
          return decodeURIComponent(s);
        } catch (e) {
          return s;
        }
      }

      function rebuildEntries() {
        var raw = [];
        for (var i = 0; i < folderModel.count; i++) {
          var fileName = folderModel.get(i, "fileName");
          var isDir = folderModel.get(i, "fileIsDir");
          var filePath = folderModel.get(i, "filePath");
          if (!fileName)
            continue;

          var entry = {
            "name": fileName,
            "fileName": fileName,
            "path": window._toLocalPath(filePath),
            "isDir": !!isDir,
            "isDesktop": false,
            "desktopId": "",
            "label": fileName,
            "icon": ""
          };

          // .desktop launcher handling. We derive the freedesktop id from the
          // file name and ONLY treat the entry as a gtk-launch launcher when
          // that id resolves to an INSTALLED application (DesktopEntries.byId).
          // The id is validated by the pure model before launch — no path/Exec
          // is ever shell-executed.
          //
          // A .desktop file that is NOT an installed app (e.g. a standalone
          // launcher dropped in ~/Desktop) is left as a regular file: it opens
          // via `xdg-open <path>` (argv-tokenized, no shell), which routes it
          // through the desktop's own .desktop handler. This keeps arbitrary
          // launchers working without ever exec'ing their Exec= line directly.
          var did = DesktopIconModel.desktopIdFromFileName(fileName);
          if (!isDir && did.length > 0) {
            try {
              if (typeof DesktopEntries !== "undefined" && DesktopEntries.byId) {
                var de = DesktopEntries.byId(did);
                if (de) {
                  // Respect NoDisplay launchers by skipping them entirely.
                  if (de.noDisplay === true)
                    continue;
                  entry.isDesktop = true;
                  entry.desktopId = did;
                  if (de.name)
                    entry.label = de.name;
                  if (de.icon)
                    entry.icon = de.icon;
                }
              }
            } catch (e) {}
          }
          raw.push(entry);
        }

        window.entries = DesktopIconModel.arrangeEntries(raw, {
                                                           "showHidden": Settings.data.desktopIcons.showHidden,
                                                           "sortMode": Settings.data.desktopIcons.sortMode,
                                                           "arrangeFoldersFirst": Settings.data.desktopIcons.arrangeFoldersFirst
                                                         });
      }

      // Launch / open an entry — injection-safe via the pure model + argv exec.
      function activateEntry(entry) {
        var argv = DesktopIconModel.buildLaunchArgv(entry);
        if (!argv || !DesktopIconModel.isSafeArgv(argv)) {
          Logger.w("DesktopIcons", "Refusing to launch unsafe/invalid entry:", entry ? entry.name : "(null)");
          return;
        }
        Logger.i("DesktopIcons", "Launching", argv.join(" "));
        Quickshell.execDetached(argv);
      }

      // Resolve a displayable icon path for an entry.
      function iconPathFor(entry) {
        var name = DesktopIconModel.iconNameForEntry(entry);
        return ThemeIcons.iconFromName(name, DesktopIconModel.GENERIC_FILE_ICON);
      }

      FolderListModel {
        id: folderModel
        folder: "file://" + root.desktopDir
        // Always read everything; hidden filtering is done in the pure model so
        // it is testable and consistent with the sort logic.
        showHidden: true
        showDirs: true
        showDotAndDotDot: false
        showOnlyReadable: false
        sortField: FolderListModel.Name

        onStatusChanged: {
          if (status === FolderListModel.Ready)
            Qt.callLater(window.rebuildEntries);
        }
        onCountChanged: Qt.callLater(window.rebuildEntries)
      }

      // Re-arrange when the relevant settings change (no folder reload needed).
      Connections {
        target: Settings.data.desktopIcons
        function onShowHiddenChanged() { window.rebuildEntries(); }
        function onSortModeChanged() { window.rebuildEntries(); }
        function onArrangeFoldersFirstChanged() { window.rebuildEntries(); }
      }

      Component.onCompleted: Qt.callLater(window.rebuildEntries)

      // ---- the icon grid ----
      Flow {
        id: iconFlow
        anchors {
          top: parent.top
          left: parent.left
          right: parent.right
          bottom: parent.bottom
          margins: Style.marginL
        }
        spacing: Style.marginM

        Repeater {
          model: window.entries

          delegate: Item {
            id: iconItem
            required property var modelData
            width: window.cellW
            height: window.cellH

            Rectangle {
              anchors.fill: parent
              radius: Style.radiusS
              color: cellMouse.containsMouse ? Qt.alpha(Color.mPrimary, 0.18) : "transparent"
              border.width: cellMouse.containsMouse ? Style.borderS : 0
              border.color: Qt.alpha(Color.mPrimary, 0.4)
            }

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.marginXS
              spacing: Style.marginXS

              IconImage {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: window.iconSize
                Layout.preferredHeight: window.iconSize
                implicitSize: window.iconSize
                source: window.iconPathFor(iconItem.modelData)
                smooth: true
                asynchronous: true
              }

              NText {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignHCenter
                text: iconItem.modelData.label || iconItem.modelData.name
                pointSize: window.labelSize
                color: Color.mOnSurface
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight

                // Subtle shadow-ish backing for readability over wallpaper.
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: -Style.marginXS
                  z: -1
                  radius: Style.radiusXS
                  color: Qt.alpha(Color.mSurface, 0.55)
                }
              }
            }

            MouseArea {
              id: cellMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton

              property int _clicks: 0

              onClicked: {
                if (DesktopIconModel.activatesOnSingleClick(Settings.data.desktopIcons.singleClick)) {
                  window.activateEntry(iconItem.modelData);
                }
              }
              onDoubleClicked: {
                if (!DesktopIconModel.activatesOnSingleClick(Settings.data.desktopIcons.singleClick)) {
                  window.activateEntry(iconItem.modelData);
                }
              }
            }
          }
        }
      }

      // ---- right-click empty-desktop menu ----
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        z: -1 // behind the icon grid, so icons get their own clicks first
        onClicked: mouse => {
                     window.showDesktopMenu(mouse.x, mouse.y);
                   }
      }

      // Build a small menu and show it through the existing popup menu window,
      // reusing the dynamic-context-menu plumbing used by desktop widgets.
      function showDesktopMenu(localX, localY) {
        var popupMenuWindow = PanelService.getPopupMenuWindow(window.screen);
        if (!popupMenuWindow) {
          Logger.w("DesktopIcons", "No popup menu window for screen", window.screen?.name);
          return;
        }
        var items = [
          {
            "action": "applications",
            "text": I18n.tr("desktop-icons.menu-open-applications"),
            "icon": "apps"
          },
          {
            "action": "wallpaper",
            "text": I18n.tr("desktop-icons.menu-change-wallpaper"),
            "icon": "settings-wallpaper"
          },
          {
            "action": "settings",
            "text": I18n.tr("desktop-icons.menu-desktop-settings"),
            "icon": "settings"
          }
        ];
        var globalPos = iconFlow.mapToItem(null, localX, localY);
        popupMenuWindow.showDynamicContextMenu(items, globalPos.x, globalPos.y, function (action) {
          window.handleMenuAction(action);
          return false;
        });
      }

      function handleMenuAction(action) {
        switch (action) {
        case "applications":
          // Reuse the existing launcher (app mode) on this screen.
          PanelService.openLauncherWithSearch(window.screen, "");
          break;
        case "wallpaper":
          // Reuse the settings panel service, open to the Wallpaper tab.
          SettingsPanelService.openToTab(SettingsPanel.Tab.Wallpaper, -1, screenLoader.modelData);
          break;
        case "settings":
          // Open settings to the new Desktop Icons tab.
          SettingsPanelService.openToTab(SettingsPanel.Tab.DesktopIcons, -1, screenLoader.modelData);
          break;
        }
      }
    }
  }
}
