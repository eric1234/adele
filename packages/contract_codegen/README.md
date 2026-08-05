# Contract Codegen

`contract_codegen` is the internal deterministic generator for experimental
ADELE request/response contracts. It uses the pinned analyzer and
`AnalysisContextCollection` to resolve semantic elements, then extracts a
package-agnostic model, validates it, and emits the contract-owned generated
part. It does not parse source text as a schema and has no fixture templates.

Contract sources import `package:adele_contract/adele_contract.dart` exactly
once, unprefixed and without combinators or configurations. They do the same for
`package:adele_plugin_api/adele_plugin_api.dart` exactly when the extracted
schema semantically uses the canonical `ResourceRef`; prefixed plugin API
imports alone do not require it. Every additional import from either package,
including a repeated canonical URI with `show` or `hide`, and every unrelated
import must be prefixed. Conditional imports whose default or configured URI is
in either package are rejected.

Run generation from the repository root:

```sh
dart tools/adele.dart generate
dart tools/adele.dart generate --check
```

Sources are listed in `contract_codegen.yaml` or passed with repeated `--source`
options. Output is formatted, deterministic, and atomically replaced. Check
mode reports stale output without writing.

The generated part owns stable identifiers, codecs, typed clients, and backend
dispatcher interfaces/implementations. Supported values are strings, booleans,
integers, finite doubles, nullable forms, lists, enums, annotated values, and the
experimental `ResourceRef` scalar. Unsupported declarations fail with source
path and one-based line and column `ContractDiagnostic` locations attached to
the most precise relevant import, declaration, member, parameter, or type node.

Phase II is a deliberately constrained IDL embedded in Dart. It remains unary
and local to one declaration library, with exactly one
non-empty service. Services may contain only abstract instance methods. Annotated
schema cannot be imported or recursively cycle through nullable values or lists.
Values require final fields and matching required named field-formal constructor
parameters with exact types. Failure constructors have the corresponding fixed
reconstructible shape. URI values must be absolute and parseable, and wire IDs
use ASCII alphanumeric segments separated by single dots, hyphens, or
underscores. Generic annotated declarations are rejected. The generated part URI
must be exactly `<source-basename>.g.dart`; output remains beside its source.
Every top-level declaration and every unconditional or conditional emitted
symbol share one collision namespace. Import prefixes and unqualified ADELE and
SDK names used by generated code are reserved there; `ResourceRef` is reserved
only when emitted. Derived generated identifiers are
validated before emission. Schema Dart names must match
`[A-Za-z][A-Za-z0-9_]*`: annotated services, values, failures and their validated
members use public ASCII names, as do enums and enum values reachable through
the transported schema. Unrelated unreachable private helpers and enums are not
part of the IDL and remain allowed. These restrictions are contract boundaries,
not temporary parser omissions, and may remain permanent.

Transported types are a closed semantic set. `String`, `bool`, `int`, `double`,
`List`, `Map`, `Uri`, and `Object` must be exact `dart:core` declarations; the
outer method `Future` must be the exact `dart:async` declaration; and
`ResourceRef` must resolve to its canonical plugin API declaration. Same-named
lookalikes are rejected. Analyzer aliases are rejected recursively at every
transported type position, including the outer `Future`, while unrelated aliases
outside the schema remain allowed. Service parameters must be explicitly typed
required positionals; optional, named, covariant, initializing-formal,
super-formal, function-typed, and implicitly dynamic parameters are rejected.
Identifier and type diagnostics retain the referencing declaration node.

The extractor collects all `adele_contract` annotations before assigning a
class role. Repeated service, value, failure, method, or field annotations and
mixed class roles are rejected independent of annotation order. Generated
implementation members are accessed as `this._adeleChannel` and
`this._adeleService`; all generated temporaries use indexed `_adele` names.
Ordinary schema methods, including `dispatch`, coexist with the generated client
and dispatcher APIs without a schema-wide scope allocator.
One single-quoted Dart literal escaper handles every emitted source- or
schema-derived string, including quotes, backslashes, dollar signs, and control
characters.

Generated dispatch separates envelope/method decoding, argument decoding,
service invocation, and result encoding so backend exceptions cannot be mistaken
for malformed requests. Field decoding occurs before an opaque constructor
boundary that catches every constructor exception; declared-failure
reconstruction is contained the same way. Recursive JSON maps use identity-based
active-path cycle detection, allowing shared acyclic references, and a
conservative maximum container depth of 64.
