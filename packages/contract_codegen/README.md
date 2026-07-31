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
integers, doubles, nullable forms, lists, enums, annotated values, and the
experimental `ResourceRef` scalar. Unsupported declarations fail with source
path, line, and column diagnostics.
