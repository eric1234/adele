# Contract Codegen

`contract_codegen` is the internal deterministic generator for experimental
ADELE request/response contracts. It uses the pinned analyzer and
`AnalysisContextCollection` to resolve semantic elements, then extracts a
package-agnostic model, validates it, and emits the contract-owned generated
part. It does not parse source text as a schema and has no fixture templates.

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
path, line, and column diagnostics.

Phase II remains unary and local to one declaration library, with exactly one
non-empty service. Services may contain only abstract instance methods. Annotated
schema cannot be imported or recursively cycle through nullable values or lists.
Values require final fields and matching required named field-formal constructor
parameters with exact types. Failure constructors have the corresponding fixed
reconstructible shape. URI values must be absolute and parseable, and wire IDs
use ASCII alphanumeric segments separated by single dots, hyphens, or
underscores. Generic annotated declarations are rejected. The generated part URI
must be exactly `<source-basename>.g.dart`; output remains beside its source.
Every top-level declaration and every unconditional or conditional emitted
symbol share one collision namespace and derived generated identifiers are
validated before emission.

The extractor collects all `adele_contract` annotations before assigning a
class role. Repeated service, value, failure, method, or field annotations and
mixed class roles are rejected independent of annotation order. Legal Dart `$`
identifiers remain supported. Generated implementation members are reserved as
`this._adeleChannel` and `this._adeleService`; all generated temporaries use
indexed `_adele` names, and unavoidable `dispatch` API conflicts are rejected.
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
