# qdshell is QML at heart — but Phase 5+ needs a tiny native QML
# plugin that binds qdwin_shell_v1 and exposes it to QML, so we ship
# one C++ artifact alongside the QML tree. The QML files themselves
# install with their own pipeline (install-qdwin-session-for-vm.sh
# rsyncs Modules/, Services/, Commons/, etc. directly to
# /usr/share/quickshell/qdshell); this meson build only handles the
# native plugin under qml-plugin/.

project('qdshell', ['c', 'cpp'],
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  default_options: [
    'c_std=gnu11',
    'cpp_std=c++20',
    'warning_level=2',
    'werror=false',
  ],
)

subdir('qml-plugin')

node = find_program('node', required: false)
if node.found()
  test('clipboard-silo', node, args: files('tests/test_clipboard_silo.js'))
  test('clipboard-actions', node, args: files('tests/test_clipboard_actions.js'))
  test('clipboard-id-guard', node, args: files('tests/test_clipboard_id_guard.js'))
  test('clipboard-broker', node, args: files('tests/test_clipboard_broker.js'))
  test('broker-gate', node, args: files('tests/test_broker_gate.js'))
  test('pointer-parse', node, args: files('tests/test_pointer_parse.js'))
  test('pointer-overrides', node, args: files('tests/test_pointer_overrides.js'))
  test('pointer-config', node, args: files('tests/test_pointer_config.js'))
  test('keyboard-xkb', node, args: files('tests/test_keyboard_xkb.js'))
  test('taskbar-logic', node, args: files('tests/test_taskbar_logic.js'))
  test('window-manager-policy', node, args: files('tests/test_window_manager_policy.js'))
  test('settings-tree', node, args: files('tests/test_settings_tree.js'))
  test('gtk-settings', node, args: files('tests/test_gtk_settings.js'))
  test('shortcut-conflicts', node, args: files('tests/test_shortcut_conflicts.js'))
  test('tray-known-items', node, args: files('tests/test_tray_known_items.js'))
  test('notification-detail', node, args: files('tests/test_notification_detail.js'))
  test('notification-theme', node, args: files('tests/test_notification_theme.js'))
  test('mime-associations', node, args: files('tests/test_mime_associations.js'))
  test('session-model', node, args: files('tests/test_session_model.js'))
  test('launcher-items', node, args: files('tests/test_launcher_items.js'))
  test('launcher-navigation', node, args: files('tests/test_launcher_navigation.js'))
  test('settings-recovery', node, args: files('tests/test_settings_recovery.js'))
  test('presentation-policy', node, args: files('tests/test_presentation_policy.js'))
  test('brightness-policy', node, args: files('tests/test_brightness_policy.js'))
  test('system-clock', node, args: files('tests/test_system_clock.js'))
  test('desktop-icons', node, args: files('tests/test_desktop_icons.js'))
  test('removable-media', node, args: files('tests/test_removable_media.js'))
  test('output-layout', node, args: files('tests/test_output_layout.js'))
  test('qdwin-only-guard', node, args: files('tests/test_qdwin_only_guard.js'))
endif
