# ADELE Product

`adele_product` defines the canonical immutable `Project`, `Task`, and
`Environment` values used by the initial Phase V product spine. `Project`
retains a typed source `Uri`; `Task` owns only its Project relationship; and
`Environment` owns its Task relationship, role, generic `ProviderId`, and an
opaque immutable provider-state snapshot.

This package does not provide persistence, Session associations, provider
behavior, filesystem access, or plugin-generation routing.
