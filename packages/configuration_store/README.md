# ADELE Configuration Store

`adele_configuration_store` is internal, Flutter-free host infrastructure for
conditional persistence of global `settings.toml` and bounded record files. It
combines explicit
[`adele_platform_storage`](../platform_storage/README.md) roots with the real
Rust-backed [`adele_toml_document`](../toml_document/README.md) editor. It adds no
parser, custom native build hook, application consumer, or plugin-facing service.
Its bounded synchronous Linux directory reader uses libc through Dart FFI.

Settings/record declarations and resolution, Profiles, credentials, provider
semantics, local application-state persistence, and Project storage are not
implemented here. See
[configuration ownership](../../docs/architecture/profiles-and-configuration.md)
and [dependency rules](../../docs/architecture/dependency-rules.md).
The separate [`adele_settings_host`](../settings_host/README.md) adapter combines
this store with public scalar/record declarations, effective global settings
resolution, and record validation without changing this package's low-level
transaction responsibilities.

## Host API

File operations are synchronous and may block on another process's lock. Use one
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

### Record Files

`store.recordFile(collectionId: 'providers', recordId: 'work')` derives another
`ConfigurationStore` at `<configurationRoot>/providers/work.toml`, with its own
file baseline and the **same** `lockPath`. IDs are lowercase ASCII letters/digits
with internal single hyphens, start with a letter, and are at most 64 characters.
Reserved device names (`con`, `prn`, `aux`, `nul`, `com1` through `com9`, `lpt1`
through `lpt9`) are rejected. This is lexical path safety, not schema validation.

Record stores expose the same `filePath`, `load`, and `save`. `create(document)`
requires absence, including when the existing bytes are malformed or empty;
existing content is checked without parsing. It can create an empty file.
Before any record insertion (including `save` with an absent baseline), the
existing write lock protects a fresh capacity check through publication. An
existing collection needs a free entry; creating a collection also needs a free
configuration-root entry. Both limits are inclusive at 1024. Overflow raises
`ConfigurationLimitException` for that directory before creating a collection or
staging a file. Occupied identities still conflict first. Updates and deletes
need no free slot, and a full root does not prevent insertion into an existing
collection with capacity.
`delete(expected)` checks the exact file baseline under the shared lock before
deletion and returns a missing snapshot. An absent delete is an artifact-free
no-op that still rejects a stale baseline. Create/delete are record-only; settings
behavior is unchanged. No collection-wide transaction or automatic retry is added.

Record files are limited to 1 MiB of UTF-8 bytes. Reads check size before data and
also bound the actual read, including every save/delete baseline check. Writes
check encoded size before acquiring the lock or staging. Only regular files are
accepted; file and collection-directory symlinks are rejected for all record
operations, including loads and no-ops. The configuration root may be symlinked.

`await store.listCollection('providers')` returns a bounded, immediate listing,
returning sorted immutable `ConfigurationCollectionEntry` values (`name`, `type`).
It follows no entry symlinks, parses no content, filters no names, and creates no
artifacts. Missing directories return an empty list. Any error rejects the whole
listing, never a successful prefix. Both the configuration-root preflight and the
collection listing have a 1024-entry limit. The root preflight rejects collection
names that differ only by ASCII case or trailing spaces/periods. On Linux it
acquires a shared lock on the existing stable lock file and scans synchronously:
an ordinary writer's transient staging is gone before either directory is read.
This applies to every host identity preflight as well as enumeration, including
settings-file staging in the configuration root. No hidden names are filtered.

Readers never create the lock. If it does not yet exist, a scan is optimistic;
if a first writer creates it during that scan, the reader repeats the observation
under the now-existing lock, including after a scan failure. This is read-side
coordination, not a stale-write retry. Missing directories still create nothing.
The portable read-only path retains Dart's streamed listing; changed writes remain
unsupported outside Linux.

The semantic host must preflight each record operation through this listing and
diagnose record-filename aliases/unexpected names before the synchronous file
operation. Insertions additionally count entries inside the transaction lock;
cooperating writers cannot both claim the last collection/root slot. Linux uses a
bounded libc `opendir`/`readdir64` read, closing its descriptor even on overflow,
rather than an eager `listSync` or an `await` while holding a process-scoped lock.
The Linux `dirent64` layout is validated on the maintained Linux x64 path. No
custom native library/build hook or additional worker/lock is introduced.
Cooperating writers only create canonical names; an external editor can still
change entries after enumeration or the final byte check.

Errors are explicit:

- `TomlException`: malformed TOML or an invalid in-memory edit, with native
  diagnostics retained. A failed edit cannot alter the persisted file.
- `FormatException`: invalid UTF-8, never decoded with replacement characters.
- `FileSystemException` / `ProcessException`: I/O, permissions, or preparation
  failures, not an empty/default document or a parser error.
- `ConfigurationConflictException`: on-disk bytes or existence differ from the
  baseline, even for an unchanged save. Reload and deliberately retry.
- `ConfigurationSymlinkException`: a changed settings save would replace a file
  symlink, or a record operation encounters a file/collection symlink.
- `ConfigurationLimitException`: record bytes or directory entries exceed the
  bound, with `path`, `limit`, and `unit`.
- `ConfigurationPathAliasException`: a collection path has a noncanonical alias,
  with canonical `path` and observed `aliasPath`.
- `ArgumentError`: invalid record path segment or a snapshot from another path.
- `UnsupportedError`: changed saves/deletes on platforms other than Linux.

## Placement and Coordination

- Content: `<configurationRoot>/settings.toml` and
  `<configurationRoot>/<collectionId>/<recordId>.toml`.
- Stable lock: `<localStateRoot>/configuration/settings.lock`.
- Transient staging: a private `.<filename>.*` directory beside the destination,
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
Linux collection scans hold a shared lock only for their bounded synchronous
directory observation; they do not make enumeration and later record reads an
atomic collection snapshot. Keep these reads in the same owning isolate too.

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

Configuration-root symlinks work under ordinary filesystem semantics. A
settings-file symlink may be loaded and checked by a no-op, but changed saves
reject it, including dangling links, rather than replacing the link. Records
apply the stricter symlink policy above. There is no general confinement or
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
not a promise that a rename, deletion, or newly created directories survive every
power loss. Abrupt termination can leave private staging directories; automatic orphan
cleanup is not implemented. Such abandoned entries remain explicit unexpected
entries (and count toward directory limits), never silently filtered or adopted
as valid records. They require deliberate external cleanup. Errors during
post-publication cleanup/unlock can mean the commit already happened: reload to
establish its outcome before retrying.

## Validation

Linux x64 is the maintained, executed path. Changed saves/deletes explicitly reject
macOS and Windows pending platform-specific replacement/permissions validation. The
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
Record tests additionally cover independent file baselines, conditional create and
delete, pipe rejection (`mkfifo`), filename/type enumeration, collection aliases,
symlink policy, and bounded I/O. Process gates cover same-record update/delete in
both orders and independently baselined records under the shared settings lock.
Exact-capacity tests also gate competing creates and read-lock acquisition during
record/settings staging, including first-writer races, full directories, ordinary
failure cleanup, and abrupt process termination.

The contention fixture is compiled to a temporary JIT kernel using the pinned
SDK's kernel generator and the native asset map already prepared by `dart test`.
Its child VMs reuse those assets without nested build-hook execution: on this SDK,
concurrent `dart run` preparation can recopy a library while another process has
it mapped. This is test-fixture setup, not another native build or production loader.
