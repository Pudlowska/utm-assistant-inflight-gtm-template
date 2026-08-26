# utm-assistant-inflight-gtm-template — CLAUDE.md

The GTM **server-side Custom Variable (MACRO)** template for **Inflight**,
the real-time UTM correction product (first product in the
utm-assistant.ai suite — see SYSTEM-OVERVIEW.md). This repo exists on its
own — not a subfolder of `utm-assistant-app` — because the GTM Community
Template Gallery requires it: `template.tpl`, `metadata.yaml`, and
`LICENSE` must sit at the repo root, one template per repo, and Google's
gallery tooling tracks specific commit SHAs referenced in `metadata.yaml`.
Don't add unrelated files here — anything that isn't the template risks
breaking the gallery's structure requirements.

## Architecture — read this before touching the correction logic
- **Custom Variable, server-side only, NOT a Transformation.** An earlier
  version of this template (through 2026-08-26) was built as a
  Transformation that called `setInEventData` directly — that does not
  work for this template type and was scrapped. The current design is a
  plain sGTM Custom Variable that resolves to a JSON object (see "Return
  shape" below); routing that value into destination tags is the
  container owner's job, done via each tag's Parameters/Fields to Set —
  see `___NOTES___` in `template.tpl` for the exact setup, including the
  companion per-field Custom JavaScript Variables this requires.
- **Async via a returned Promise, same as any sGTM variable.** Returning a
  `sendHttpGet(...).then(...)` chain tells sGTM to pause any tag this
  variable (or an extractor variable derived from it) is mapped into,
  until the promise resolves or the request times out. No manual tag
  sequencing/priority needed. Sync paths (no-op, cache hit) just `return`
  a plain value instead of a Promise — both are valid returns from the
  same function.
- **Per-event API call, not a cached ruleset.** Unlike the fast-path/
  slow-path design used elsewhere in the suite (ruleset fetched once per
  session and fuzzy-matched client-side — see SYSTEM-OVERVIEW.md), this
  template calls the ingestion API directly with the incoming utm_ values
  and resolves to whatever it returns, merged with fallbacks. This is the
  "Pro tier" server-side path referenced in SYSTEM-OVERVIEW's decided
  architecture, now being built.
- **Hash-keyed cache, TTL-checked manually.** Before calling the API, checks
  `templateDataStorage` for a cached correction keyed on
  `sha256(propertyId + utm_source + utm_medium + utm_campaign + utm_content
  + utm_term)`. This targets the dominant real-world case — one broken
  link/ad generating many identical hits from different visitors — not
  per-visitor session caching. `templateDataStorage` is per server instance
  only, not shared across instances; a real shared cache (Firestore/Redis)
  would need to live on the `utm-assistant-rt-function` side, not here.
- **Fail open, by resolving to the raw value — never `undefined`.** Any
  failure (timeout, non-200, unparseable body, no resolvable property id)
  resolves the merged object using the original utm_ value for whichever
  keys weren't corrected, rather than omitting them. This matters more
  here than it did under the old Transformation design: a tag field
  mapped to a variable that resolves to `undefined` is liable to just not
  get set, silently dropping a parameter the tag would otherwise have
  sent. Request timeout defaults to 400ms since this sits in the hot path
  before every tag fires. Separately, if the event has *no* utm_ keys at
  all, that's not a failure — there's nothing to correct — so `run()`
  short-circuits and resolves to whatever `readIncomingUtms()` returned
  (`null`) directly, without calling the API. Extractor variables already
  guard for this (`corrected ? corrected.utm_medium : undefined`).
- **Return shape.** Resolves to a plain object containing only the utm_
  keys that were present on the incoming event (never invents a key that
  wasn't there), each set to the corrected value if the API provided one,
  else the original raw value. See `mergeCorrection` in `template.tpl`.
- **Region must match the sGTM container's Cloud Run region.** The
  ingestion endpoint is `https://{cloud-region}.cr.utm-assistant.ai/inflight`
  — a per-account/property config field picks the region so the call stays
  in-region. See `README.md` for the full label → region-code table; a
  handful of entries were disambiguated from an initial source list and
  should be double-checked against the actual GTM region picker before
  relying on them.

## Property resolution — auto-detected, not configured
As of 2026-08-26, the property is not a required config field. It's read
per-event via `getEventData('x-ga-measurement_id')` — the GA4 Client
populates this once it parses the incoming hit — so one variable instance
covers every GA4 property flowing through a shared sGTM container.
`propertyIdOverride` (optional template field) takes priority over the
auto-detected value, for non-GA4 traffic or testing. No property id
resolvable (neither override nor `x-ga-measurement_id`) fails open
immediately, without an API call — resolves to the raw utms unchanged.

## Required permissions
`read_event_data` scoped to the five `utm_*` keys plus
`x-ga-measurement_id`, `send_http_request` scoped to
`https://*.cr.utm-assistant.ai/inflight*`, `access_template_storage`, and
`logging` (debug only). No `write_event_data` — this template no longer
writes event data at all; it only resolves to a value. The permission JSON
in `template.tpl` was hand-authored, not exported from the GTM Template
Editor — treat it as a starting point and re-verify the Permissions tab in
the actual editor before first real use.

## Consumes
The heuristic JSON schema owned by `utm-assistant-app`. If that schema
changes, this template's request/response handling needs to change with
it. The property identifier sent to the ingestion API is now a GA4
measurement ID (`G-XXXXXXXXXX`) in the common case, not a slug typed into
GTM — `utm-assistant-app`'s property lookup needs to key on that.

## Testing
Use GTM's built-in template testing/preview mode before publishing a new
version. Test against the actual sandboxed JS API restrictions — this
environment doesn't behave like normal browser JS (no arbitrary global
access, permission-gated APIs, no direct `fetch`). Confirm the fail-open
path explicitly: a forced timeout or a 500 response must leave utm_ values
unchanged, not throw.

## Commands
(fill in: how the .tpl is built/exported/re-imported for iteration, the
submission checklist for gallery updates — including adding a new
`versions` entry to `metadata.yaml` referencing the new commit SHA)
