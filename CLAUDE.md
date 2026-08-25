# gtm-template — CLAUDE.md

The GTM tag + variable template for **Inflight**, the real-time UTM
correction product (first product in the utm-assistant.ai suite — see
SYSTEM-OVERVIEW.md). This repo exists on its own — not a subfolder of
`main-app` — because
the GTM Community Template Gallery requires it: `template.tpl`,
`metadata.yaml`, and `LICENSE` must sit at the repo root, one template per
repo, and Google's gallery tooling tracks specific commit SHAs referenced in
`metadata.yaml`. Don't add unrelated files here — anything that isn't the
template risks breaking the gallery's structure requirements.

## Architecture — read this before touching the correction logic
- **Not a Variable.** Client-side GTM Variable templates resolve
  synchronously — no network calls inside them. This must be a **Tag**,
  given top firing priority and tag sequencing ("fire before" the
  analytics/ads tags), so it runs before anything else fires.
- **Fast path / slow path.** On the first hit in a session: fetch the
  account's ruleset once from `efficiency-endpoint`, cache it in
  `sessionStorage`, and write it to `dataLayer`. From then on, fuzzy-match
  incoming UTM params **against the cached ruleset, in this tag's sandboxed
  JS** — no network call. Only call the API again for a value that doesn't
  fuzzy-match anything in the cached ruleset (feeds the learning loop
  server-side; not latency-sensitive).
- Matching algorithm: short-string edit distance, Myers bit-parallel style
  (same approach as the `fastest-levenshtein` npm package) — fast enough in
  sandboxed JS that this never needs to be a network call, even on the
  server, let alone the client.

## Consumes
The heuristic JSON schema owned by `main-app`. If that schema changes, this
repo's parsing logic needs to change with it.

## Testing
Use GTM's built-in template testing/preview mode before publishing a new
version. Test against the actual sandboxed JS API restrictions — this
environment doesn't behave like normal browser JS (no arbitrary global
access, permission-gated APIs, no direct `fetch`).

## Commands
(fill in: how the .tpl is built/exported, the submission checklist for
gallery updates)
