# Filter-Sources

Tracks the school content-filter browser extensions [Civil Proxy](https://github.com/civilnetwork-dev/Civil)
has to work around, and watches for the moment one of their developers ships
a change that specifically reacts to Civil.

## How it works

`extensions.json` lists every tracked extension: its Chrome Web Store (or
vendor-hosted) id, its update endpoint, and the last version this repo has
seen. A [scheduled workflow](.github/workflows/check-filter-patches.yml)
(Monday and Thursday) asks each endpoint what's current using Chrome's own
extension-autoupdate protocol. When a version has moved:

1. Downloads the new `.crx` and unpacks it.
2. Runs every `.js`/`.tmp` file through [the same Zig deobfuscator Civil
   Proxy uses](tools/src/deobfuscator.zig) — string-array inlining, constant
   folding, dead-branch pruning — so the diff in the next step is a diff of
   readable code, not two different obfuscator outputs that happen to be
   semantically identical.
3. Diffs each changed file against the last snapshot (`extensions/<name>/deobfuscated/`)
   and scans the *added* lines for anything that matches a signature pulled
   from Civil's own `misc/filters/filterBlockerMiddleware.ts` — a vendor
   telemetry domain Civil blocks, or a header/event name Civil defined.
4. If anything matches, [`CHANGES_NEEDED.md`](CHANGES_NEEDED.md) gets a
   section for that extension: what changed, and where in Civil's source it
   matters. A section disappears on its own once a later release stops
   tripping the signature that flagged it.

There's no separate first-run/bootstrap step. The first time an extension is
checked, there's nothing to diff against yet, so step 3 just records the
baseline — nothing is flagged, which is correct: a vendor's code referencing
its own domain for the first time you look isn't news. Real detection starts
on the *next* check, once there's an actual change to compare.

## Scope, honestly

21 of the 28 tracked extensions resolve to a real extension id automatically
(from the Chrome Web Store's own `_metadata/verified_contents.json`, present
in any extension actually installed from the store). The other 7 use a
vendor-hosted, non-Web-Store update endpoint — their `id` is `null` in
`extensions.json`, and the checker skips them with a clear log line rather
than guess. See `tools/README.md` for the rest of what's deliberately out of
scope and why.

## Running it locally

```sh
cd tools
zig build test   # unit tests — no network needed
zig build
zig build run -- check --civil-dir /path/to/a/Civil/checkout
```

Needs [Zig 0.16.0](https://ziglang.org/download/) specifically — the
toolchain snapshot this was built against had a parser regression that broke
on `Type{val} ** N` syntax; 0.16.0 stable does not have it.
