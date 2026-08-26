# ADR 0029: Ordered profile composition and configuration direction

## Status

Accepted as architectural direction; implementation deferred

Supersedes ADR 0018 for full-profile direction.

**ADR 0031 subsequently resolves the Project/Workspace identity question this ADR intentionally left deferred.** The profile/configuration decisions here remain accepted.

## Context

ADR 0018 intentionally deferred complete profile behavior while the maintained
runtime needed only an implicit activation context and optional configuration
overrides. ADELE now has enough product and architecture direction to constrain
future profile, configuration, activation, provider-preference, and workbench
behavior without pretending those systems are implemented.

A single monolithic profile is insufficient for important intended uses. A user
may want a `Developer` operating mode that enables editors, diffs, terminals,
and source-control tooling, then compose it with either `Work` or `Personal`
identity/provider behavior. A `Vibe` profile may intentionally remove most
inspection-oriented tooling and its settings surface. Project-specific settings
may need to override broader defaults, while multiple windows over the same
project may need independent live UI arrangements.

These concerns share context, but they are not one kind of state and should not
be collapsed into one universal last-writer-wins plugin model.

## Decision

Profiles are sparse named composition layers. One window/context may use an
ordered stack of zero or more explicit profiles; the normal UX may optimize for
one or two, but the architecture imposes no arbitrary small stack limit. Where
a domain uses ordinary precedence semantics, later profiles have higher
precedence than earlier profiles.

Profiles remain flat and explicit. Profiles do not inherit from or include
other profiles, and a profile appears at most once in one active stack. If
repeated complex stacks eventually need a convenience abstraction, it should be
a separate named stack/preset that expands to an explicit ordered list rather
than another inheritance mechanism.

Profiles may contribute sparse plugin-activation decisions, ordinary
configuration overrides, configured-provider availability, and provider
preferences. Plugin installation/source/build versions belong to the ADELE
installation/toolchain environment rather than becoming profile-specific
cascade values.

Ordinary configuration may resolve through eligible layers such as host/plugin
defaults, user/all-profile configuration, the ordered active profile stack,
project configuration, and narrower resource-specific scopes when a setting
meaningfully supports them. Scopes are setting-dependent rather than universal.
Absence means inheritance/continued resolution; explicit null remains distinct
where null is a valid value. Effective values should retain provenance.

Shared context does not imply shared composition rules. Plugin activation,
ordinary configuration, provider availability/preference, security/policy,
workbench state, configured capability instances, and runtime resources remain
distinct domains. Security, permissions, approvals, and policy are not assumed
to use ordinary last-writer-wins semantics merely because a more specific scope
exists.

Plugin activation is sparse and conceptually tri-state: unspecified/inherit,
enabled, or disabled. Installing a plugin does not activate it globally. When a
plugin is effectively inactive in a context, its normal product surface,
commands, capabilities, and contributed settings/custom settings UI are absent
from that context. Persisted configuration is retained while inactive so
re-enabling the plugin can restore its prior configuration. Host-owned
installation/activation metadata remains available so ADELE can manage an
installed but inactive plugin.

Settings have stable technical identities/owners, but normal Settings UX should
be organized by product concepts rather than by plugin ownership. Common
settings should be declarative; plugins may provide custom editors for complex
configuration, but those editors must use ADELE-owned configuration,
validation, scope, provenance, and persistence semantics rather than establish a
parallel settings store.

Configured capability instances and credentials remain distinct from profiles.
Profiles may influence which configured instances are available and preferred,
while ADELE retains ownership of provider resolution. Secrets are not ordinary
serialized configuration values.

Workbench/window presentation state is not ordinary cascading configuration.
Open windows own independent live workbench state. Local remembered state may be
updated as a window changes and used to seed subsequently opened windows, but it
does not rearrange already-open windows. Persisted workbench writes should be
fine-grained enough that unrelated changes from different windows do not
silently overwrite one another through stale full-state snapshots.

A project's normally active profile stack is similarly remembered local state:
changing the stack in one window updates what future windows for that project
start with but does not mutate the active stack of already-open windows.

Execution-sensitive operations should be able to use stable resolved
configuration/context boundaries so semantically important behavior does not
change unpredictably halfway through an operation because another window edits
configuration.

The detailed directional model and deliberately deferred mechanics are recorded
in `docs/architecture/profiles-and-configuration.md`.

## Consequences

- ADR 0018's deferral served its original purpose, but simultaneous ordered
  profile composition and the rejection of profile inheritance are no longer
  undecided architectural questions.
- Future APIs must permit ordered multi-profile contexts even though the current
  maintained runtime still uses one implicit development profile.
- Profiles should remain sparse; composition should not require copying complete
  plugin/application configuration into each profile.
- A profile can deliberately simplify ADELE by deactivating plugins and removing
  their normal UI/settings surface without destroying dormant configuration.
- Ordinary settings, activation, provider selection, security/policy, workbench
  state, and runtime state may share contextual inputs while retaining separate
  resolution and lifecycle semantics.
- Profile-specific plugin versions and implicit profile-inheritance graphs are
  intentionally excluded from the normal model.
- Multiple windows can share underlying project/task/session/runtime data while
  retaining independent live presentation and active-profile context.
- The exact profile persistence format, directory/session scope semantics,
  security-policy composition, credential storage, schema migration APIs,
  provider suitability policy, workbench-state persistence key, and
  implementation staging remain deferred.
- ADR 0031 now defines Project as an abstract core identity and uses Environment,
  rather than a required separate Workspace concept, as the practical
  filesystem/source + process context for Task work.
