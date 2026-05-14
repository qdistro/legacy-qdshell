# Qdistro.Qdwin QML plugin — exposes qdwin_shell_v1 to QML.
#
# Lives in the qdshell repo because qdshell is the sole consumer and
# the lifecycle of the plugin tracks qdshell's QML surface, not
# qdwin's compositor internals. The protocol XML still lives in the
# qdwin repo (it's the protocol owner); we pull it via a relative
# sibling path. Repo layout (memory: project-layout):
#
#   qdistro-org/
#     qdwin/qdwin/qdwin-shell-v1.xml    ← protocol authority
#     qdshell/qml-plugin/               ← this directory
#
# Built as a side-by-side native QML plugin (no qs/quickshell fork).
# qmldir + libqdistro-qdwin.so install under
# datadir/qdistro/qml/Qdistro/Qdwin/ so that anything launched with
# QML_IMPORT_PATH=/usr/share/qdistro/qml picks up
# `import Qdistro.Qdwin 1.0`. The qdshell systemd unit grew that env
# var in qdistro/scripts/install/install-qdwin-session-for-vm.sh
# (noctalia-shell.service drop-in) — keep both locations consistent
# if the install dir ever changes.

qt6 = import('qt6')

dep_qt6_core           = dependency('Qt6Core')
dep_qt6_qml            = dependency('Qt6Qml')
dep_qt6_qmlintegration = dependency('Qt6QmlIntegration', required: false)
dep_wayland_client     = dependency('wayland-client')
dep_wayland_scanner    = dependency('wayland-scanner', native: true)

wayland_scanner = find_program(
  dep_wayland_scanner.get_variable(pkgconfig: 'wayland_scanner'),
  native: true,
)

# qdwin_shell_v1 protocol XML — owned by the qdwin sibling repo. We
# read it through a relative path rather than copying, so the two
# repos can't drift out of sync. If the qdistro-org parent layout
# changes, update both this path and the project-layout memory entry.
proto_xml = files('../../qdwin/qdwin/qdwin-shell-v1.xml')

qdwin_shell_client_header = custom_target(
  'qdwin-shell-v1-client-header',
  input: proto_xml,
  output: 'qdwin-shell-v1-client-protocol.h',
  command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
)
qdwin_shell_protocol_code = custom_target(
  'qdwin-shell-v1-private-code',
  input: proto_xml,
  output: 'qdwin-shell-v1-protocol.c',
  command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
)

moc_files = qt6.preprocess(
  moc_headers: ['qdwin-binding.h'],
  moc_sources: ['qdistro-qdwin-plugin.cpp'],
  dependencies: [dep_qt6_core, dep_qt6_qml],
)

qml_plugin_install_dir = get_option('datadir') / 'qdistro' / 'qml' / 'Qdistro' / 'Qdwin'

shared_library(
  'qdistro-qdwin',
  sources: [
    'qdwin-binding.cpp',
    'qdistro-qdwin-plugin.cpp',
    moc_files,
    qdwin_shell_client_header,
    qdwin_shell_protocol_code,
  ],
  dependencies: [
    dep_wayland_client,
    dep_qt6_core,
    dep_qt6_qml,
  ],
  cpp_args: ['-fPIC'],
  install: true,
  install_dir: qml_plugin_install_dir,
)

install_data('qmldir', install_dir: qml_plugin_install_dir)
