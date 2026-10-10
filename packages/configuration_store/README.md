# ADELE Configuration Store

`adele_configuration_store` is internal, Flutter-free host infrastructure for
conditional persistence of global `settings.toml`. It combines explicit
[`adele_platform_storage`](../platform_storage/README.md) roots with the real
Rust-backed [`adele_toml_document`](../toml_document/README.md) editor. It adds no
parser, native bridge, build hook, application consumer, or plugin-facing service.

Settings declarations/resolution, Profiles, credentials, provider records, local
application-state persistence, and Project storage are not implemented here. See
[configuration ownership](../../docs/architecture/profiles-and-configuration.md)
and [dependency rules](../../docs/architecture/dependency-rules.md).

## Host API

The operations are synchronous and may block on another process's lock. Use one
owning host isolate per process, optionally a dedicated isolate to keep I/O off
the UI isolate. Route other isolates' configuration work to that owner; do not
independently instantiate writers in multiple isolates of the same process.

```dart
import 'dart:io';

import 'package:adele_configuration_store/adele_configuration_store.dart';
import 'package:adele_platform_storage/adele_platform_storage.dart';

final roots = PlatformStorageRoots.resolve(
  operatingSystem: Platform.operatingSystem,
  environment: Platform.environment,
);
final store = ConfigurationStore(roots);
final loaded = store.load();
final edited = loaded.document.setScalar(['outputLimit'], 8000);
final committed = store.save(loaded, edited);
final reloaded = ConfigurationStore(roots).load();
assert(reloaded.document.readScalar(['outputLimit']) == 8000);
```

`load()` returns a `ConfigurationSnapshot` with an immutable `document`, `exists`,
and an opaque baseline retaining the exact bytes observed, including absence.
Missing files become valid empty documents without creating directories, files,
or lock artifacts. Existing comments and unknown fields remain in the document.

`save(expected, document)` accepts the existing validated `TomlDocument`, returns
the new snapshot, and never automatically reloads/merges/retries. The returned
snapshot is the baseline for the next edit. A snapshot may be used by another
store instance for the same file path, but not by a store for another path.
Equal document text is a no-op: it checks the baseline without creating locks or
rewriting the file. An unchanged missing document remains missing.

Errors are explicit:

- `TomlException`: malformed TOML or an invalid in-memory edit, with native
  diagnostics retained. A failed edit cannot alter the persisted file.
- `FormatException`: invalid UTF-8, never decoded with replacement characters.
- `FileSystemException` / `ProcessException`: I/O, permissions, or preparation
  failures, not an empty/default document or a parser error.
- `ConfigurationConflictException`: on-disk bytes or existence differ from the
  baseline, even for an unchanged save. Reload and deliberately retry.
- `ConfigurationSymlinkException`: a changed save would replace a file symlink.
- `UnsupportedError`: changed saves on platforms other than Linux.

## Placement and Coordination

- Content: `<configurationRoot>/settings.toml`.
- Stable lock: `<localStateRoot>/configuration/settings.lock`.
- Transient staging: a private `.settings.toml.*` directory beside the destination,
  removed after success or an ordinary failure.
- Local data, cache, and Project storage are never used.

All cooperating processes/windows must share the same local-state location and
one owning isolate within each process. Synchronous operations prevent interleaving
within that isolate; Dart's blocking exclusive advisory file lock protects the
read/check/stage/recheck/rename critical section across processes. Unix locks are
process-scoped, so they do not coordinate independent isolates, and another handle
closed by that process can release the lock. Do not independently open the lock
in other isolates. Never delete/replace the lock while writers may run: its inode
must remain stable. A process exit releases the OS lock; an empty persistent lock
file does not mean the store is locked. The lock intentionally remains outside
Git-managed configuration, including when the configuration root is symlinked.

Conflicts cover the whole document, not individual keys. Byte equality, not mtime,
defines identity; deleting and recreating identical bytes is not a conflict.
The existence distinction makes an externally created empty file conflict with a
previously missing file. Changed malformed content also conflicts without repair.

External editors and Git need not use this lock. The store rechecks content after
staging and just before publication, but an uncooperative writer can still race
the last check and rename. This is not unconditional filesystem compare-and-swap,
a distributed lock, a network-filesystem guarantee, or automatic conflict merging.

## Replacement and Preservation

Changed saves lazily create the needed configuration and state directories.
Complete UTF-8 content is staged on the destination filesystem, flushed, assigned
the existing file's ordinary permission bits (0600 for a new file), flushed again,
then published with Linux rename. The old file is never truncated or deleted as a
preparation step. Preparation failure leaves it untouched; successful publication
does not expose a partial document. Read-only mode bits are retained as well.

Directory symlinks work under ordinary filesystem semantics. A configuration-file
symlink may be loaded and checked by a no-op, but changed saves reject it, including
dangling links, rather than replacing the link. There is no general confinement or
protection against malicious concurrent path/ancestor replacement. Explicit roots
must refer to the host's intended, appropriately protected storage locations.

The store preserves ordinary permission bits, not ownership, ACLs, extended
attributes, hard-link identity, or all metadata. Such arrangements need additional
design before relying on metadata-preserving replacement. TOML edits inherit the
document package's [best-effort preservation limits](../toml_document/README.md#preservation-limits),
including newline normalization; UTF-8 decoding also removes an optional BOM on
an actual edit, while no-op saves retain the original bytes.

The staged file is fsynced through Dart's flush API, but the containing directory
is not fsynced. This is atomic visibility on the maintained Linux filesystem path,
not a promise that the rename or newly created directories survive every power
loss. Abrupt termination can leave private staging directories; automatic orphan
cleanup is not implemented. Errors during post-publication cleanup/unlock can mean
the commit already happened: reload to establish its outcome before retrying.

## Validation

Linux x64 is the maintained, executed path. Changed saves explicitly reject macOS
and Windows pending platform-specific replacement/permissions validation. The
read path uses ordinary Dart I/O but is also only validated on Linux here.

After [bootstrap and native TOML prerequisites](../../docs/development/toolchain.md#native-toml-documents):

```sh
dart tools/adele.dart test --target adele_configuration_store
```

Run `dart analyze --fatal-infos` in this package for focused analysis. Tests use
temporary roots exclusively, call real Rust TOML, inject faults at staging I/O
boundaries, and gate independent writer processes through pipes to check the
held lock and stale-write outcome without sleep-based scheduling. Permission tests
require an unprivileged Linux user; runtime uses `chmod`, and tests also use GNU
`stat`, normally supplied by the maintained Linux toolchain's coreutils.

The contention fixture is compiled to a temporary JIT kernel using the pinned
SDK's kernel generator and the native asset map already prepared by `dart test`.
Its child VMs reuse those assets without nested build-hook execution: on this SDK,
concurrent `dart run` preparation can recopy a library while another process has
it mapped. This is test-fixture setup, not another native build or production loader.
