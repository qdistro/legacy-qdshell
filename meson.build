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
  test('clipboard-broker', node, args: files('tests/test_clipboard_broker.js'))
  test('broker-gate', node, args: files('tests/test_broker_gate.js'))
  test('pointer-parse', node, args: files('tests/test_pointer_parse.js'))
  test('keyboard-xkb', node, args: files('tests/test_keyboard_xkb.js'))
  test('taskbar-logic', node, args: files('tests/test_taskbar_logic.js'))
  test('gtk-settings', node, args: files('tests/test_gtk_settings.js'))
endif
