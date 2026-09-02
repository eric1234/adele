# ADELE Product

`adele_product` defines the canonical immutable `Project`, `Task`, and
`Environment` values used by the Phase V product spine, plus ADELE's one
canonical `SessionId`. `Project` retains a typed source `Uri`; `Task` owns only
its Project relationship; and `Environment` owns its Task relationship, role,
generic `ProviderId`, and an opaque immutable provider-state snapshot.

This package does not yet define a complete strategy-bound Session aggregate.
The provisional Session-to-Task/Environment authority relation, persistence,
provider behavior, filesystem access, and plugin-generation routing remain
outside this package.
