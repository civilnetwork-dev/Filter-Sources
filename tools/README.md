# tools

The Zig checker behind Filter-Sources. `zig build test` for the unit suite,
`zig build run -- check --civil-dir <path>` to run it for real (needs
network access to each extension's update endpoint).

| File | Job |
|---|---|
| `version.zig` | Chrome's dotted-integer version comparison (not semver — see its doc comment for why that distinction matters) |
| `omaha.zig` | Chrome's extension-autoupdate protocol — request construction and XML response parsing, scoped to the requested app's own `<updatecheck>` (not just the first one in the document — see its doc comment), verified against real live queries |
| `crx.zig` | Unpacks a downloaded `.crx` (CRX2 and CRX3 header formats) |
| `deobfuscator.zig` | Vendored from Civil Proxy's `misc/deobfuscator` — keep in sync manually if it changes there |
| `signatures.zig` | Extracts distinctive string-literal signatures from Civil's `filterBlockerMiddleware.ts` |
| `patchDetect.zig` | Orchestrates one extension's check cycle; `scanDiffForSignatures` is the actual detection logic, kept pure and separately tested |
| `main.zig` | CLI entry point and `CHANGES_NEEDED.md` maintenance |

## Deliberately out of scope (ponytail: add when a real case needs it)

- **CRX signature verification.** The download's integrity is checked
  against the `hash_sha256` Chrome's own update server reports (real,
  verified against a live response) — not against the CRX's embedded
  developer signature. That signature proves *who signed it*, which this
  tool has no reason to care about; the hash already proves *the bytes
  weren't corrupted in transit*.
- **The broader `misc/filters/**/*.ts` tree as a signature source.**
  Tried first; produced real, confirmed false positives (`"application/json"`,
  `"arraybuffer"`, a vendor's own category labels like `"gambling"`) because
  those files are mostly ordinary HTTP client code. `signatures.collect`
  still exists for a caller that deliberately wants that wider, noisier net
  — see its doc comment — but `main.zig` doesn't use it by default.
- **Ports (`runtime.connect`-shaped long-lived connections)** — not
  applicable here; this tool never runs extension code, only diffs it.
