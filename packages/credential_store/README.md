# Internal Credential Store

`adele_credential_store` is Flutter-free internal host infrastructure, not a
plugin API. It supplies the synchronous native boundary used by the application's
credential service. Application admission, serialization, verification of mutations,
uncertain outcomes, asynchronous dispatch, and shutdown belong to the app, not this
package. See the global [dependency rules](../../docs/architecture/dependency-rules.md)
and [credential ownership](../../docs/architecture/profiles-and-configuration.md).

## API and lifecycle

Import `package:adele_credential_store/adele_credential_store.dart`.
`NativeCredentialStore` exposes only static `read`, `contains`, `write`, `delete`,
`isSupported`, and `maximumBytes` (2560). All operations must run on an operation
isolate, never the Flutter UI isolate. The app owns `Isolate.run` or equivalent
dispatch and must drain admitted work before shutdown. Native calls can block on
Secret Service, including unlock prompts; there is no cancellation or deadline
guarantee here.

References are exactly `cred1_` followed by 32 lowercase hexadecimal characters.
Secrets are nonempty, NUL-free, strict UTF-8 with a maximum of 2560 encoded bytes.
Dart rejects unpaired UTF-16 surrogates instead of silently encoding replacements.
Both Dart and the native ABI validate inputs and returned values.

`read` returns null and `contains` returns false only for a successful lookup with
no matching entry. `contains` reads and validates the one secret internally, but
returns no secret bytes. `delete` treats an already missing entry as a no-op.
Malformed stored values report `corruptData` without deletion, repair, or reset.
Ambiguous matches and unknown failures report `failed`, not absence.
`NativeCredentialFailure` retains only a `NativeCredentialFailureKind`; its text
is fixed and it has no native diagnostic, cause, reference, or secret payload.

Each call constructs a fresh explicit store and entry and drops them before
returning. A later request can recover from an earlier connection failure without
restarting the Dart process. There is no `keyring::v1` facade, global default
store, cached initialization failure, retained native handle, secret cache, or
automatic retry. A failed mutation can still have an uncertain outcome; the app
must reconcile it explicitly.

## Backend and build

Linux x64 is the only supported credential backend. The fixed namespace is
`dev.adele.credentials.v1`; callers cannot select a namespace, collection, backend,
or fallback. `isSupported` checks the platform only and does not probe keyring
health. macOS, Windows, and non-x64 Linux are explicitly unavailable. The hook
uses the same host-native target mappings as `adele_toml_document`, building an
unsupported stub for those other desktop targets so host imports remain
compilable. That is not native acceptance or a promise of future support.
Other targets and cross-compilation are rejected, never silently substituted.

The code-assets hook builds a bundled `cdylib` with pinned Rust **1.93.0** and
`cargo build --locked --release --lib`. Linux x64 uses exactly
`keyring-core = 1.0.1` and `zbus-secret-service-keyring-store = 1.0.1` with
`default-features = false` and `crypto-rust`. `Cargo.lock` retains the audited
`secret-service = 5.2.0` and `zbus = 5.19.0`. There is no keyring facade, Apple or
Windows credential backend, libsecret, or OpenSSL dependency. The Linux build
needs the platform linker and binutils `nm`/`readelf` in addition to Rust.

The backend uses Secret Service's encrypted session transport and its default
collection for new entries. Searches match the fixed service and exact username
across collections. The OS daemon owns collection persistence, prompts and
at-rest policy; this package does not independently guarantee those policies or
substitute a file/session backend when the default collection is unavailable.

## ABI and memory

`lib/src/native.dart` uses `@Native` code assets, not library-path discovery.
`adele_credentials_abi_version` returns 1 without touching a keyring.
`adele_credentials_request_v1` takes explicit lengths and distinct caller-owned
buffers. Operations are read=1, write=2, delete=3, contains=4. Statuses are
ok=0, missing=1, unavailable=2, failed=3, invalidReference=4, invalidSecret=5,
corruptData=6. Unknown operations fail closed. Only successful reads publish
bytes; the read buffer is exactly 2560 bytes and the output length resets to zero
on entry. See the Rust function's safety contract before any non-Dart call.

Dart allocates buffers with `calloc`, clears them in `finally`, and frees them
with the same allocator. Native code retains no pointers and does not allocate
outputs for the caller to free. Rust-owned read buffers use `Zeroizing`; Dart
also clears its temporary encoded byte arrays. This is bounded transient-buffer
hygiene, not a claim that immutable Dart strings, runtime copies, dependency
internals, or OS memory can all be zeroized.

## Panic confidentiality

The Linux x64 library owns a private, statically linked Rust runtime. Its no-op
panic hook suppresses payload diagnostics for that runtime, including dependency
worker threads. It does **not** replace the hook in TOML, CodeForge, or another
native library's runtime. This relies on the pinned `cdylib` linkage, not a
general claim that Rust hooks are per-library.

The hook forces `prefer-dynamic=no` and `panic=unwind`. Before bundling, it checks
the actual ELF for local `std::panicking::HOOK` and exception-runtime symbols,
absence of imported/exported Rust symbols, exactly the two C ABI exports, and
only allowlisted system shared-library dependencies. Missing inspection tools or
unproven isolation fail the build. Static linking, sanitizers, shared libstd,
`rlib`/`staticlib` reuse, another toolchain, or another supported platform would
require a new ownership review rather than weakening these checks.

Same-thread unwinding panics inside a request become the fixed `failed` status.
The boundary separately catches a panicking panic-payload destructor; a secondary
payload is deliberately forgotten rather than invoking another arbitrary Drop.
No Rust exception may cross the C ABI. `catch_unwind` does not suppress hooks by
itself and does not recover aborts, OOM, undefined behavior, or double-panic
termination. A dependency worker panic is silent in this runtime but is not
guaranteed to become a request error or to finish the operation.

## Validation

After repository bootstrap, from this package:

```sh
dart test
dart analyze --fatal-infos
```

From `native/`, using its pinned toolchain:

```sh
cargo test --locked
cargo clippy --locked --all-targets --features fixture-probe -- -D warnings
cargo fmt --check
```

Ordinary tests do not access a real keyring. They cover strict encoding/bounds,
fixed error mapping, malformed ABI requests/responses, caller buffer ownership,
panic containment/redaction, and build-audit rejection cases. See the maintained
[testing guide](../../docs/development/testing.md) for repository target wiring
and the separately opt-in disposable Secret Service smoke.

`native/src/probe.rs` is available only through the `fixture-probe` Cargo feature,
not a production backend injection API. The smoke runner owns its private bus,
daemon and child processes. The binary requires the smoke opt-in and matching
disposable-fixture bus environment. Commands are `read`, `contains`, `write`,
`delete`, `verify`, or `corrupt`, followed by one reference. `write`/`verify` take
exact bytes on stdin, not argv. Stdout is only `<status> <verified>`; `corrupt`
uses explicit core access to check invalid UTF-8 preservation without repair.
It leaves that item for the runner's exact-reference cleanup. Never run it
against a user's keyring.
