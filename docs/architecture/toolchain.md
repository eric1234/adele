# Toolchain Policy

## Exact Phase 0 pin

| Component | Identity |
| --- | --- |
| Flutter | `3.44.8`, framework revision `058e0af2c2` |
| Dart | `3.12.2`, derived from the pinned Flutter SDK |

The framework revision is part of the Flutter identity; the semantic version
alone is not sufficient for reproducible plugin builds. Dart must be the
version supplied by that Flutter pin where Flutter tooling is involved. ADELE's
own product version is independent of Dart's semantic version.

## Local plugin compilation

Source is the canonical plugin distribution format. A future ADELE
distribution is expected to include or otherwise provision a precisely pinned
toolchain capable of compiling plugin source locally. The proposed pipeline
will compile backend source to native Dart AOT and frontend source to
`dart_eval`/`flutter_eval` bytecode.

That pipeline does not exist in Phase 0. Local AOT compilation and loading,
eval compilation and interpreted Flutter rendering, typed communication,
rebuild/reload, and consistent Windows, macOS, and Linux behavior are explicit
Phase 1 risks rather than validated capabilities.

## Artifact identity and invalidation

A compiled artifact is valid only for its source and build context. Future
cache keys and provenance must include enough toolchain identity to prevent an
artifact built by an incompatible Flutter or Dart SDK from being reused.
Changing Flutter, its framework revision, Dart, eval/compiler dependencies,
target platform, architecture, build mode, or relevant build inputs may require
recompilation.

Artifacts should normally be reusable by multiple profiles and configured
capability instances when source and build context are identical. Profiles do
not inherently own compiled artifacts.

The concrete cache format, compatibility checks, provenance record, and
invalidation algorithm are deferred until compilation is implemented.

## No SDK vendoring in Phase 0

The repository records the exact toolchain but does not vendor Flutter or Dart.
Vendoring would add large binaries, platform-specific content, update and
licensing maintenance, and release-distribution concerns before the local
plugin pipeline has proven its requirements. Developers and CI provision the
pinned SDK externally for Phase 0.

Bundling or provisioning a pinned SDK for end-user ADELE distributions is a
future packaging decision. Phase 0 also excludes compiled plugin artifacts,
SDK caches, and build output from source control.
