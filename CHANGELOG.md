# Changelog

All notable changes to GPush are documented here.

## 4.2.1

### Fixed
- Fixed Windows unresolved-conflict detection incorrectly treating Git stderr warnings as conflicted file paths.
- Git line-ending notices such as `LF will be replaced by CRLF` no longer cause GPush to stop with `Unresolved conflicts detected`.
- Conflict detection now evaluates only actual unmerged paths from Git stdout and separately validates the Git command exit code.

### Changed
- Bumped Windows and Linux versions, including both installers, to 4.2.1 for release consistency.

## 4.2.0

### Added
- Added a quick repository picker when `gp` is run without arguments.
- The quick picker shows up to five recently used repositories and a separate Favorites section.
- Added `fav` as a short alias for the `favorite` command group.
- Added `favorites` as a direct shortcut for listing favorite repositories.
- Added matching quick-picker and favorite-management behavior on Windows and Linux.

### Changed
- Bumped Windows and Linux versions, including both installers, to 4.2.0.
- Reworked the Windows help output into clearer option groups and reduced the examples to a compact set of common workflows.
- Improved Favorites output so repository names and paths are easier to scan.
- Favorite repositories are omitted from the Recent section of the quick picker to avoid duplicate entries.
- Existing repository search remains available directly from the quick picker by typing a project name or partial match.

### Fixed
- Fixed Windows `gp` with no arguments raising a parameter-binding error when the subcommand parser received an empty argument array.
- Fixed single-argument Windows subcommands being treated as strings instead of argument arrays, which caused commands such as `gp favorite list` to be parsed as the first character only.
- Fixed Windows configuration initialization so existing configurations can safely gain `aliases` and `favorites` properties without property-assignment errors.
- Made Windows config saving tolerant of older configuration files that do not yet contain the newer properties.

## 4.1.0

### Added
- Added project tooling with the new `project` command group:
  - `gp project info [project]`
  - `gp project build [project]`
  - `gp project test [project]`
  - `gp project run [project]`
  - `gp project open [project]`
  - `gp project shell [project]`
- Added automatic project type detection for Rust, .NET, Node.js, Python and C/C++/CMake projects.
- Added toolchain-aware project actions:
  - Rust uses Cargo.
  - .NET uses the `dotnet` CLI.
  - Node.js uses npm, pnpm or Yarn based on the available lock file.
  - Python uses the local virtual environment when available and supports common build, test and run entry points.
  - C/C++ projects use CMake and CTest.
- Added the new self-update command group:
  - `gp update check`
  - `gp update`
  - `gp update install`
  - `gp update rollback`
- Added automatic latest-release checks through GitHub Releases.
- Added local update backups and rollback support.
- Added optional SHA-256 verification when a matching checksum asset is published.
- Added legacy flag equivalents for the new features:
  - `--project`
  - `--update`

### Changed
- Bumped Windows and Linux versions to 4.1.0.
- Extended help output with dedicated Project Tools and Self Update documentation.
- Added `project` and `update` to the main command list and V4 command router.
- Kept the classic `gp <project> "message"` workflow unchanged.
- Kept the existing Git safety and synchronization logic unchanged.
- Linux `project open` now uses `xdg-open`.
- Linux `project shell` opens an interactive shell in the selected project directory.
- Linux Python project handling prefers `.venv/bin/python` when available.
- Windows and Linux updater behavior is aligned around release assets, backups, rollback and checksum verification.

### Fixed
- Fixed Linux ShellCheck SC2015 warnings by replacing `A && B || C` command chains with explicit `if`/`else` logic.
- Fixed Linux ShellCheck SC2034 warning by removing the unused `checksum_name` variable.
- Cleaned up Linux project command execution to avoid ambiguous failure fallbacks.

## 4.0.2

### Fixed
- Fixed Windows path handling for filenames containing non-ASCII characters such as Czech diacritics.
- Disabled Git path quoting for changed-file detection so paths are passed to PowerShell as real filenames instead of escaped octal sequences.
- Prevented `GetFileName()` and `Test-Path` errors caused by quoted Git paths.

### Changed
- Bumped both Windows and Linux package versions to 4.0.2 for release consistency.

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
