# Terminal

Role: Local stock plugin map

Terminal is a frontend-only stock console contribution, prepared as interpreted
EVC under `dev.adele.plugin.terminal`. Its
[`terminal_frontend`](packages/frontend/README.md) package depends on Flutter and
public UI APIs, not the app, a concrete Environment provider, or a PTY library in
production. The [build-side descriptors](../../tools/stock_frontend_descriptors.dart)
register `dev.adele.plugin.terminal.console` with the `New Terminal` creation action
and terminal content entrypoint. There is no Terminal backend or model tool.

The host owns the shared tab strip, creation menu, selection, visibility,
confirmation, and forced cleanup. Terminal supplies independent content and its
policy, not a replacement console panel or nested tab system. The
[console architecture](../../docs/architecture/plugin-system.md#shared-console)
and [public UI contract](../../packages/ui/README.md#shared-console) define that
boundary; the [app map](../../app/README.md#session-console) locates native hosting.

## Terminal policy

`newTerminal` asks the host to create a default interactive shell in the admitted
Session's canonical Environment association, never a Task-primary fallback. The
host captures that scope; the frontend cannot choose an Environment, executable,
working directory, or process handle. Shell selection and normal interactive
startup belong to the [Environment contract](../../packages/environment/README.md#interactive-terminals)
and [Git provider](../git_environment/README.md#interactive-terminals), not Terminal.

The action supplies a fallback label, conservative live-close message, title-follow
policy, and actual-exit removal policy. Native hosting copies validated values out
of that short-lived EVC operation. They survive hidden/unmounted views without
retaining evaluator callbacks. Each later `buildTerminal` gets fresh revocable
surface access to the same runtime-owned resource.

- Fallback titles are `Terminal N`. A usable normalized process title replaces
  the fallback, including while hidden. Title text is untrusted display metadata,
  not identity, shell activity, completion, or cleanup evidence. Host chrome shows
  lifecycle status separately from that title.
- Opening and live shells require confirmation because activity is unknown; an
  idle-looking screen is not proof that closing is harmless.
- Automatic removal requires actual shell exit **and** settled successful cleanup.
  Nonzero exit is still exit. EOF, disconnect, explicit closure, and title changes
  are not substitutes for that evidence.
- Launch failures and disconnections remain visible rather than auto-removing.
  A proven failure before any terminal request needs no close confirmation;
  uncertain termination or cleanup failure receives conservative dismissal advice.
- User-confirmed close requests resource cleanup. Failure or bounded cleanup
  timeout removes the tab with a safe warning, not a claim of successful process
  termination. Host close and contribution retirement force cleanup without a
  plugin veto or a mounted view.

Hiding the console, changing tabs, or visiting Task Browser does not stop output,
title observation, or resource lifetime. Task Browser exposes no console panel,
toggle, or creation actions. Sessions sharing the Environment can revisit the same
resources with fresh view access. Restart restores neither terminals nor console
state.

Future retained read-only command output is separate contributed console content
with invocation provenance, not a Terminal child or interactive shell. Command
Inspection integration is not implemented here. Validation commands and integration
scope live in [testing](../../docs/development/testing.md#focused-console-checks).
