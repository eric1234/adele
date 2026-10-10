# ADELE Platform Storage

`adele_platform_storage` is Flutter-free internal host infrastructure for locating
ADELE's global configuration, local state, local data, and disposable cache roots.
It depends only on the pure-Dart `path` package. It is not a plugin-facing API,
persistence store, Settings model, Profile resolver, or credential store.
See [dependency rules](../../docs/architecture/dependency-rules.md) and
[configuration boundaries](../../docs/architecture/profiles-and-configuration.md).

## API

Import `package:adele_platform_storage/adele_platform_storage.dart`.
`PlatformStorageRoots.resolve` takes an explicit `operatingSystem` (`linux`,
`macos`, or `windows`), `environment` map, and optional `homeDirectory` override.
It returns immutable `configurationRoot`, `localStateRoot`, `localDataRoot`, and
`cacheRoot` strings. The unnamed constructor accepts those four roots explicitly
plus `operatingSystem`, for callers supplying isolated storage locations.

Neither constructor reads ambient platform/environment values or performs
filesystem I/O. The host may pass `Platform.operatingSystem` and
`Platform.environment`; tests can supply entirely synthetic inputs. Paths need
not exist. Creation, permissions, persistence, and cleanup belong to callers.

## Paths

`HOME` below means the injected `homeDirectory`, or `environment['HOME']` when no
override was supplied.

| Domain | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Configuration | `$XDG_CONFIG_HOME/adele/config` | `$HOME/Library/Application Support/ADELE/config` | `%APPDATA%\ADELE\config` |
| Local state | `$XDG_STATE_HOME/adele/state` | `$HOME/Library/Application Support/ADELE/state` | `%LOCALAPPDATA%\ADELE\state` |
| Local data | `$XDG_DATA_HOME/adele/data` | `$HOME/Library/Application Support/ADELE/data` | `%LOCALAPPDATA%\ADELE\data` |
| Cache | `$XDG_CACHE_HOME/adele/cache` | `$HOME/Library/Caches/ADELE` | `%LOCALAPPDATA%\ADELE\cache` |

Linux uses the XDG default bases `$HOME/.config`, `$HOME/.local/state`,
`$HOME/.local/share`, and `$HOME/.cache`, respectively. Empty or relative XDG
overrides are ignored, as required by the
[XDG Base Directory specification](https://specifications.freedesktop.org/basedir/latest/).
Paths containing NUL are also invalid. Values are not trimmed, expanded as shell
expressions, or interpreted relative to the current directory. Home is required
only for missing/invalid XDG overrides; four valid XDG bases work without home.

Each Linux path **always** has its domain suffix below `adele`, even when its base
already distinguishes the domain. This keeps all four roots distinct when users
choose identical XDG bases, without moving an existing root conditionally when
another environment variable changes. macOS and Windows use the same separation
under `ADELE`, except for macOS's already separate cache location.

Required missing, empty, non-absolute, or NUL-containing paths throw `ArgumentError`
naming the offending input. Windows requires both `APPDATA` and `LOCALAPPDATA`;
there is no guessed fallback through home, `USERPROFILE`, or the working directory.
Fully qualified drive paths and UNC paths with a server and share are accepted.
Drive-relative (`C:folder`), root-relative (`\folder`), incomplete UNC paths, and
device-namespace paths are rejected. Both Windows separator styles are accepted.
Unsupported operating systems throw `UnsupportedError`.

Explicit roots receive the same absolute-path validation and normalization;
duplicate roots are rejected, including Windows case/separator aliases. Validation
is lexical, not a filesystem existence, filename-legality, permission, or symlink
check. Filesystem aliases (including case aliases on macOS) are not resolved.

## Validation

After repository bootstrap, run in this package:

```sh
dart test
dart analyze --fatal-infos
```

Tests inject platform/environment/home inputs, cover each layout and failure
boundary, and check that resolution never constructs filesystem handles. A
temporary-directory fixture separately verifies that resolution does not create
the requested directories. No tests use real user storage roots.
