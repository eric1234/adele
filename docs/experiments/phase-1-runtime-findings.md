# Phase I Runtime Findings

Phase I produced two preserved experiment branches:

- `experiment/phase1-dual-runtime` at `70f6337`: **FAILED**. Stock Flutter
  3.38.10 Linux profile mode did not execute the external plugin AOT snapshot
  supplied to `Isolate.spawnUri`.
- `experiment/phase1-backend-host` at `7b41d37`: **SUCCESS — complete Linux x64
  profile vertical path proven**. One child `dartaotruntime` host loaded the
  plugin into a separate isolate group, served typed filesystem calls, drove a
  persisted interpreted frontend, survived repeated rebuild/reload cycles, and
  handled plugin crashes and restart.

The mainline implementation selectively retains the durable process host,
runtime connection, builder, workspace reference fixture, eval adapter, and
automated tests. One-off reproduction drivers and the temporary Phase I shell
remain only on the experiment branches.

The maintained Linux profile smoke proves three complete build/start/typed
listing/EVC construction/stop cycles. Widget tests separately prove second-file
selection, interpreted state updates, selected text rendering, and ignoring a
delayed completion after disposal.

The validation pin remains Flutter 3.38.10, bundled Dart 3.10.9,
`dart_eval 0.8.5`, `flutter_eval 0.8.2`, and analyzer 8.4.1. It is temporary and
does not establish Flutter 3.44 or Dart 3.12 compatibility.
