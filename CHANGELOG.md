# Changelog

All notable changes to GPush are documented here.

## 4.0.1

### Fixed
- Cleaned up Windows PowerShell analyzer warnings.
- Cleaned up Linux ShellCheck warnings.
- Reformatted the Linux implementation for readability.
- Fixed help table spacing and long example formatting.
- Fixed key/value output alignment, including `Working tree  Clean`.
- Protected branch confirmation now uses `[Y/n]`, where pressing Enter confirms the action.
- Improved Windows and Linux installers.
- Unified Windows and Linux release structure and documentation.

## 4.0.0

### Added
- New command-based CLI while keeping the original syntax fully supported.
- `repo` commands for status, diff, log, open, fetch, pull and sync.
- `branch` commands for list, create, switch, delete and prune.
- `tag` commands for list, create, push, delete and release.
- `remote` commands for list, add, set-url and remove.
- `stash`, `cache`, `config`, `alias`, `favorite` and `all` command groups.
- `clone`, `recent`, `help` and `version` commands.

### Changed
- Reworked help output around the new command syntax.
- Existing `gp <project> "message"` workflow remains supported.
- Existing flag-based commands remain supported for backward compatibility.

## 3.9.1

### Fixed
- Prevented long help examples from overflowing into the description column.
- Replaced long URLs in help examples with readable placeholders such as `<url>` and `<destination>`.

## 3.9.0

### Added
- Repository cloning with `--clone`.
- Remote management with `--remote-add`, `--remote-set-url` and `--remote-remove`.
- Safe stale branch cleanup with `--prune-branches`.
- Improved remote listing.

### Safety
- Branch pruning only considers branches with a gone upstream.
- Current, protected and unmerged branches are skipped.
- Safe deletion uses `git branch -d`; force deletion is not used.

## 3.8.0

### Added
- Decorated Git graph output for `--log`.
- Tag listing with `--tags`.
- Annotated tag creation with `--tag`.
- Individual tag push with `--tag-push`.
- Local tag deletion with `--tag-delete`.
- Safe release workflow with `--release`.

### Safety
- Releases require a clean working tree and synchronized upstream.
- Existing local and remote release tags are checked before creation.
- Remote tags are never deleted automatically.

## 3.7.0

### Added
- Repository aliases.
- Favorites.
- Recently used repositories.
- `--open` for opening repository folders in File Explorer.
- Persistent recent repository history outside the main config file.

## 3.6.0

### Added
- Multi-repository dashboard with `--all`.
- `--all --fetch` for refreshing repository state.
- `--all --sync` for conservative bulk synchronization.

### Safety
- Dirty, detached, diverged and otherwise unsafe repositories are skipped.
- Bulk sync does not automatically rebase conflicting repositories.

## 3.5.0

### Added
- Persistent GPush configuration.
- `--config` and `--config-path`.
- `--doctor` diagnostics.
- Configurable search roots, ignored directories, protected branches, large-file threshold and default remote.
- Current-repository support for `--status` and `--diff`.

## 3.4.0

### Added
- `--amend`.
- Safe `--undo`.
- Branch creation, switching and deletion.
- Protected branch checks for branch operations.

## 3.3.0

### Added
- `--sync`.
- Stash support.
- `--autostash`.
- Protected branch confirmation.
- Sensitive filename checks.
- Large-file warnings.

## Earlier versions

Initial versions established the core GPush workflow:

- Repository discovery and cache.
- Project selection by name.
- Git status inspection.
- Commit creation.
- Safe pull/rebase handling.
- Push and upstream creation.
- Repository refresh and manual cache add.
