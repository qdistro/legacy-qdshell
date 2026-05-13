# qdshell

A Wayland desktop shell for [qdistro](https://codeberg.org/qdistro/qdistro)
— bar, panels, launcher, lock screen, notifications, OSD — running on
top of the [qdwin](https://codeberg.org/qdistro/qdwin) compositor.

qdshell is a hard fork of [Noctalia](https://github.com/noctalia-dev/noctalia-shell)
v4.5.0. The upstream history is preserved in this repository (reachable
from the `fork-base/upstream-v4.5.0` tag); fork-local changes were
collapsed into a small set of thematic commits when qdshell was
published. See [CREDITS.md](CREDITS.md).

## What's different from Noctalia

- Single compositor: qdshell only targets qdwin. The
  `CompositorService` abstraction was dropped — qdshell binds Qdwin
  APIs directly.
- Broker integration: every hook script and notification is mediated
  by the qdistro broker. The user lock screen is wired to the
  `qdistro-pwd` vault API.
- Strip pass: telemetry, the update channel, supporter banner, setup
  wizard, changelog, about box, wallhaven, and GitHub release plumbing
  were removed. The upstream migration chain was reset to schema v1.

## Build

qdshell is Quickshell QML. From a checkout:

```sh
quickshell -p shell.qml
```

Tests:

```sh
scripts/ci-local.sh    # host-side smoke
scripts/ci-in-vm.sh    # full qmltest suite (133 cases) in a VM
```

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).

Upstream Noctalia is MIT-licensed; the MIT license permits relicensing
to GPL. Attribution to upstream contributors is in
[CREDITS.md](CREDITS.md).
