# ADR 0013: Contract declarations and generation are separate

## Status

Accepted

## Context

Contract declarations describe an integration boundary, while generation is tooling that may consume those declarations to produce artifacts. Combining them would make the contract model depend on a particular generation workflow.

## Decision

Contract declaration and artifact generation are separate concerns. Declarations define the source contract; generation, when used, is a distinct process with distinct outputs.

## Consequences

Declarations can be reviewed and reasoned about independently of generator execution. Generated artifacts do not become the authoritative declaration, and generator behavior can evolve without redefining the separation.
