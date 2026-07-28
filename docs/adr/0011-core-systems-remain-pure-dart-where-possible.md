# ADR 0011: Core systems remain pure Dart where possible

## Status

Accepted

## Context

Core plugin concepts do not inherently require Flutter. Unnecessary Flutter dependencies would constrain where core code can run and make non-UI testing and reuse more expensive.

## Decision

Core systems remain pure Dart where practical. Flutter dependencies are introduced only at boundaries that require Flutter or platform integration.

## Consequences

Core logic can be used and tested without a Flutter runtime. Boundary code must translate between pure-Dart concepts and Flutter-specific behavior, and genuinely Flutter-dependent concerns are not forced into an artificial pure-Dart form.
