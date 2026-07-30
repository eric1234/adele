# Toolchain Policy

## Exact Phase 1 validation pin

| Component | Identity |
| --- | --- |
| Flutter | `3.38.10` |
| Framework revision | `c6f67dede3d4aa1aa7a69dd56a3494a5cde6cc80` |
| Engine revision | `cafcda5721a78a7884db92f13c5e89f7643d52dd` |
| Dart | `3.10.9`, bundled with the pinned Flutter SDK |

The framework revision is part of the Flutter identity; the semantic version
alone is not sufficient for reproducible plugin builds. Dart must be the
version supplied by that Flutter pin where Flutter tooling is involved. ADELE's
own product version is independent of Dart's semantic version.

This pin is the matched validation toolchain for the Phase 1 walking skeleton,
not ADELE's permanent toolchain. The initial Flutter `3.44.8`, framework
`058e0af2c2b57e369d905a03ac9748b0ebf543c6`, engine
`0cd610717bde95fd88343c64f81c11ba4e5c0010`, Dart `3.12.2` experiment failed:
`flutter_eval 0.8.2` does not implement Flutter's new
`Container.isAntiAlias` member. Upstream issue
[flutter_eval #140](https://github.com/ethanblake4/flutter_eval/issues/140)
independently confirms the same failure. Phase 1 will not patch
`flutter_eval`; upgrading Flutter and modernizing or contributing upstream
compatibility is a post-walking-skeleton workstream.

The repository tracks the temporary Flutter validation pin in `.tool-versions`
for asdf users. This improves repeatability for local sessions but does not make
asdf mandatory; `toolchain.json` remains the manager-independent identity
record, and validation still checks the complete framework, engine, and bundled
Dart identities.

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
