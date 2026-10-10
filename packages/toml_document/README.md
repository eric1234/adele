# ADELE TOML Documents

`adele_toml_document` is Flutter-free internal host infrastructure for in-memory
TOML document operations. Rust `toml_edit` owns parsing and editing; the Dart API
exposes immutable text snapshots, literal key paths, and ordinary Dart scalars.
It is independent of CodeForge, the app, plugins, and the
[storage-location package](../platform_storage/README.md).

This is not the public plugin settings API or a Settings/Profile resolver. It
does not open files, choose filenames, watch changes, store credentials, or write
transactions. See [configuration boundaries](../../docs/architecture/profiles-and-configuration.md)
and [dependency rules](../../docs/architecture/dependency-rules.md).

## API

```dart
import 'package:adele_toml_document/adele_toml_document.dart';

final original = TomlDocument.parse('[tools]\noutputLimit = 5000 # keep\n');
final updated = original.setScalar(['tools', 'outputLimit'], 8000);
final value = updated.readScalar(['tools', 'outputLimit']); // int: 8000
final added = updated.setScalar(['tools', 'enabled'], true);
final removed = added.removeScalar(['tools', 'enabled']);
final text = removed.source;
```

- `parse` validates the entire document and retains its input text.
- `readScalar`, `setScalar`, and `removeScalar` support strings, signed 64-bit
  integers, and booleans. Other TOML types can remain in a document but are not
  editable through this API. Existing values must keep their scalar type.
- Paths are nonempty lists of literal keys, not expressions. Dots and empty strings
  inside a segment are valid literal keys. Parent tables must already exist;
  dotted-key tables work, but inline tables and arrays are not traversed.
- Equal-value writes and absent-leaf removals return the same snapshot without
  reserialization. A missing parent is an error, including during removal.
- Failures expose `TomlException.kind` (`parse`, `path`, `type`, or `edit`) and
  a diagnostic message. Parser diagnostics include upstream source locations.
  Failed operations leave the original snapshot intact; an edited document is
  reparsed before it is returned. There is no mutable native document handle.

## Preservation Limits

Updates copy the existing value's `toml_edit` decoration. Ordinary comments,
spacing, key order, table layout, and unrelated value spelling are retained in
the tested cases. Preservation is best effort, not byte-for-byte fidelity for
every input. In particular, an actual edit normalizes CRLF to LF with the selected
dependency lock; no-op operations retain the exact input. Replacement scalar
spelling (such as quote style or integer radix) is chosen by the library. Removing
a key can remove its attached comments. Explicit empty parent tables are retained,
but removing the last dotted key can remove its implicit parent table entirely;
later operations requiring that parent then fail with a path error. There is no
custom table synthesis, text-preservation algorithm, or upstream fork.

Each operation reparses a complete text snapshot synchronously. This deliberately
small boundary is not a large-file editor, schema validator, collection editor,
concurrent-writer coordinator, or persistent transaction service.

## Native Build

After [repository bootstrap](../../docs/development/toolchain.md), normal `dart
test` / `dart run` consumers invoke `hook/build.dart`. The hook uses the exact
compiler in `native/rust-toolchain`, `cargo build --locked --release`, and the
committed `Cargo.lock`. It bundles a dynamic code asset resolved by Dart's
`@Native`; no manual library search path, checked-in binary, or runtime fallback
parser is used. Build outputs remain in ignored Dart/Cargo directories.

`toml_edit =0.23.10` (registry version `0.23.10+spec-1.0.0`) and the private
`serde_json =1.0.149` bridge are pinned in `native/Cargo.toml`. The bridge's JSON
is an implementation detail, not a configuration format or public protocol.
Dart releases the input with its allocator; Rust transfers each response once
and frees it through its matching exported function in Dart's `finally` block.
Rust panics are caught at the request boundary, not unwound across FFI. As with
ordinary native code, invalid external pointers and process-wide allocation
failure are not recoverable document errors.

Linux x64 with Rust 1.93.0 and the pinned Dart SDK is the maintained native path.
The hook maps native-host Linux/macOS/Windows x64 and arm64 targets, but only
Linux x64 has been executed here. Cross-compilation, static linking, sanitizers,
mobile/web, and release packaging are not supported by this hook. Provision
rustup, the exact toolchain/target, and the platform linker before building.

The selected `hooks`, `code_assets`, and `ffi` versions were already present in
the workspace lock. Pinned Flutter supports this standard code-asset mechanism
for eventual desktop consumers without a Flutter dependency here. No production
application or plugin consumer is wired in this slice. On pinned Dart, raw
`dart compile` does not support build hooks; independently loaded ADELE backend
AOT snapshots therefore require a future packaging decision, not an implicit
claim of compatibility. `dart build cli` is the SDK's hook-aware standalone AOT
path (preview on this SDK).

The retained [native dependency notices](third_party_notices.txt) cover the current
Cargo runtime closure. Flutter's Dart notices do not automatically collect Rust
dependency licenses. Preserve these notices when bundling the native library;
release redistribution still needs review of the actual target and contents.

## Validation

From the repository root:

```sh
dart tools/adele.dart test --target adele_toml_document
```

For focused iteration in this package:

```sh
dart test
dart analyze --fatal-infos
cargo +1.93.0 test --locked --manifest-path native/Cargo.toml
cargo +1.93.0 fmt --manifest-path native/Cargo.toml --check
```

The explicit compiler above matches the directory-local pin in `native/`.
Dart integration tests call the real
Rust asset from the normal standalone test runner, covering scalar operations,
diagnostics, formatting, literal keys, Unicode, no-ops, and failure isolation.
Rust tests cover the C ABI's malformed-input and response-release paths.
