# Credits

`qdshell` is a hard fork of [Noctalia](https://github.com/noctalia-dev/noctalia-shell)
v4.5.0 (2026-02-17, commit `dbfe3634d`), tagged in this repository as
`fork-base/upstream-v4.5.0` for traceability.

## Why fork

Noctalia upstream targets a different audience (multi-compositor
desktop shell, hobbyist project) than qdshell (single-compositor —
qdwin — security-aware shell layer for [qdistro](https://github.com/qdistro)).
The fork rationale, scope, and discipline are documented in
`todo/noctalia-fork-plan.md` of the qdistro repository.

## What we kept from upstream

The bulk of the codebase: `Modules/Bar/`, `Modules/Panels/`,
`Modules/Launcher/`, `Modules/LockScreen/`, `Modules/Notification/`,
`Modules/OSD/`, `Modules/Dock/`, `Modules/Cards/`, `Widgets/`,
`Commons/` (minus migrations), most of `Services/`, the plugin
loader machinery, the settings tab system, and the theming engine.

## What we changed (rename pass — first commit)

- All `Noctalia` / `noctalia` identifiers in code → `Qdshell` /
  `qdshell` to avoid identity confusion and search-result pollution.
  This includes service files, asset filenames, color scheme
  directory, font filename, settings paths, and translation strings.
- Translations: kept (per qdistro project direction). User-facing
  brand strings within them were rewritten alongside the codebase.

## Credits

- **Upstream Noctalia maintainers**:
  - Lemmy (primary, ~42% commits)
  - Ly-sec (~24% commits)
  - All [Noctalia contributors](https://github.com/noctalia-dev/noctalia-shell/graphs/contributors)
- **Quickshell framework**: [outfoxxed and contributors](https://github.com/outfoxxed/quickshell)
- **Tabler Icons**: licensed under MIT, see
  `Assets/Fonts/tabler/tabler-icons-license.txt`

## License

This fork inherits Noctalia's license (see `LICENSE`). All
contributions to `qdshell` retain the same license unless noted.
