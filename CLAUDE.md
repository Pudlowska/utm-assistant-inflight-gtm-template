# utm-assistant-inflight-gtm-template — CLAUDE.md

The GTM **server-side Transformation** template for **Inflight**, the
real-time UTM correction product (first product in the utm-assistant.ai
suite — see SYSTEM-OVERVIEW.md). This repo exists on its own — not a
subfolder of `utm-assistant-app` — because the GTM Community Template
Gallery requires it: `template.tpl`, `metadata.yaml`, and `LICENSE` must sit
at the repo root, one template per repo, and Google's gallery tooling tracks
specific commit SHAs referenced in `metadata.yaml`. Don't add unrelated
files here — anything that isn't the template risks breaking the gallery's
structure requirements.

## Architecture — read this before touching the correction logic
- **Transformation, server-side only.** Transformations only exist in
  server GTM containers — there's no web-container equivalent. It runs
  after the Client parses the event and before any Tag fires, mutating
  event data via `setInEventData`/`getEventData` in the same way a Tag
  would, but completing via a returned Promise rather than
  `data.gtmOnSuccess()`.
- **Per-event API call, not a cached ruleset.** Unlike the fast-path/
  slow-path design used elsewhere in the suite (ruleset fetched once per
  session and fuzzy-matched client-side — see SYSTEM-OVERVIEW.md), this
  template calls the ingestion API directly with the incoming utm_ values
  and applies whatever it returns. This is the "Pro tier" server-side path
  referenced in SYSTEM-OVERVIEW's decided architecture, now being built.
- **Hash-keyed cache, TTL-checked manually.** Before calling the API, checks
  `templateDataStorage` for a cached correction keyed on
  `sha256(propertyId + utm_source + utm_medium + utm_campaign + utm_content
  + utm_term)`. This targets the dominant real-world case — one broken
  link/ad generating many identical hits from different visitors — not
  per-visitor session caching. `templateDataStorage` is per server instance
  only, not shared across instances; a real shared cache (Firestore/Redis)
  would need to live on the `utm-assistant-rt-function` side, not here.
- **Fail open.** Any failure — timeout, non-200, unparseable body — leaves
  the original utm_ values untouched. The event is never blocked or
  dropped because the correction call failed. Request timeout defaults to
  400ms since this sits in the hot path before every tag fires.
- **Region must match the sGTM container's Cloud Run region.** The
  ingestion endpoint is `https://{cloud-region}.cr.utm-assistant.ai/inflight`
  — a per-account/property config field picks the region so the call stays
  in-region. See `README.md` for the full label → region-code table; a
  handful of entries were disambiguated from an initial source list and
  should be double-checked against the actual GTM region picker before
  relying on them.

## Property resolution — auto-detected, not configured
As of 2026-08-26, the property is no longer a required config field. It's
read per-event via `getEventData('x-ga-measurement_id')` — the GA4 Client
populates this once it parses the incoming hit — so one Transformation
instance now covers every GA4 property flowing through a shared sGTM
container. `propertyIdOverride` (optional template field) takes priority
over the auto-detected value, for non-GA4 traffic or testing. No property
id resolvable (neither override nor `x-ga-measurement_id`) fails open
immediately, without an API call.

## Required permissions
`read_event_data` scoped to the five `utm_*` keys plus
`x-ga-measurement_id`, `send_http_request` scoped to
`https://*.cr.utm-assistant.ai/inflight*`, `access_template_storage`, and
`logging` (debug only). **Known gap**: `template.tpl` does not currently
declare a `write_event_data` permission block despite `setInEventData`
being used in `applyCorrection` — unclear whether GTM enforces this at
runtime for MACRO-type templates the way it does for Tags. Verify in the
Permissions tab of a real GTM Template Editor before relying on it. The
permission JSON in `template.tpl` was hand-authored, not exported from the
GTM Template Editor — treat it as a starting point, not a guarantee.

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
submission checklist for gallery updates — including regenerating
`metadata.yaml`'s `sha256_hash`)
