# ADELE

ADELE is an extensible, cross-platform desktop environment for building,
running, inspecting, and extending agent systems. The long-term goal is for
ADELE to become capable of developing ADELE itself.

ADELE is unreleased and experimental. The maintained practical development path
is currently primarily Linux x64; important product capabilities remain
incomplete, and public/plugin-facing APIs remain experimental.

## Read next

The normal orientation path is:

1. [Documentation map and authority policy](docs/README.md)
2. [System architecture overview](docs/architecture/overview.md)
3. Task-relevant architecture, local READMEs, and source/tests

Read [AGENTS.md](AGENTS.md) for repository working guidance before making changes.

## Repository map

```text
app/       Flutter desktop application and composition root
packages/  public/plugin-facing contracts and internal runtime packages
plugins/   stock and reference plugin implementations
docs/      architecture, product/direction, decisions, evidence, development docs
tools/     repository development/build tooling
```

## Getting started

Use the repository's [pinned toolchain](docs/development/toolchain.md), with its
Flutter and bundled Dart available on `PATH`. From the repository root:

```sh
dart tools/adele.dart bootstrap
dart tools/adele.dart run linux
```

The maintained entrypoint is [`tools/adele.dart`](tools/adele.dart).
`dart tools/adele.dart check` runs repository checks; analysis and focused test
commands are also available. See [development documentation](docs/development/README.md)
for toolchain, generation, and validation guidance, and the
[application README](app/README.md) for local launch configuration and limitations.
