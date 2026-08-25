# Inflight — Real-Time UTM Correction (sGTM Transformation)

A Google Tag Manager **server-side Transformation** template. It reads the
incoming `utm_source` / `utm_medium` / `utm_campaign` / `utm_content` /
`utm_term` event parameters, calls the Inflight ingestion API for the
corrected values, and overwrites them via `setInEventData` before any Tag
sees the event. Transformations only exist in server GTM containers — this
template has no client-side/web-container equivalent.

## Setup (per client property)

| Field | Description |
|---|---|
| Property ID | Inflight property identifier for this client property (owned by `utm-assistant-app`'s heuristic schema). |
| API Key | Issued per account from the Inflight dashboard. Sent as the `X-Api-Key` header. |
| Cloud Region | Must match the Cloud Run region this sGTM container runs in. See table below. |
| Cache corrections on this server instance | On by default. See "Caching" below. |
| Cache TTL (seconds) | Default 21600 (6h). Lower if correction rulesets change often. |
| Request timeout (ms) | Default 400. This call sits in the hot path before every tag fires — keep it tight. |

## Endpoint

```
GET https://{cloud-region}.cr.utm-assistant.ai/inflight?property_id=...&utm_source=...&utm_medium=...&utm_campaign=...&utm_content=...&utm_term=...
X-Api-Key: {apiKey}
```

Expects a `200` JSON response with any subset of the five `utm_*` keys —
only keys present in the response are written back via `setInEventData`.
Any other status, a timeout, or an unparseable body leaves the original
values untouched (fail open — this never blocks or drops the event).

## Cloud Region mapping

The Cloud Region dropdown's `displayValue` uses the label style from the
original source list; the underlying `value` is the real Cloud Run region
code used in the endpoint subdomain. Cross-checked against Google's current
Cloud Run region list. Most resolve unambiguously (only one region exists
in that country); a handful didn't and were disambiguated — **verify these
against your actual GTM region picker before relying on them**:

| Display label | Region code | Note |
|---|---|---|
| SA West (Chile) | `southamerica-west1` | |
| JP Center (Japan) | `asia-northeast1` | ⚠ Defaulted to Tokyo over Osaka (`asia-northeast2`) — no region is officially "center". |
| ME Center (Qatar) | `me-central1` | |
| CA East (Canada) | `northamerica-northeast1` | ⚠ Defaulted to Montreal over Toronto (`northamerica-northeast2`). |
| US Center (Iowa) | `us-central1` | |
| US East (South Carolina) | `us-east1` | |
| US West (Oregon) | `us-west1` | |
| EU West (England) | `europe-west2` | ⚠ Source list said "EU North (England)" — no Cloud Run region matches north+England. London is `europe-west2`; relabeled. |
| EU West (Belgium) | `europe-west1` | |
| EU West (Germany) | `europe-west3` | ⚠ Source list said "EU Center (Germany)" — GCP's actual central-Europe region is Warsaw, not Germany. Frankfurt is `europe-west3`; relabeled. |
| EU North (Finland) | `europe-north1` | |
| AP South (India) | `asia-south1` | ⚠ Defaulted to Mumbai over Delhi (`asia-south2`). |
| AU East (Australia) | `australia-southeast1` | ⚠ Defaulted to Sydney over Melbourne (`australia-southeast2`). |
| SA East (Brazil) | `southamerica-east1` | |
| AP East (Singapore) | `asia-southeast1` | |
| EU East (Poland) | `europe-central2` | |
| EU Center (France) | `europe-west9` | Unambiguous — only one France region exists, despite the code/label naming mismatch. |
| EU North (Netherlands) | `europe-west4` | Unambiguous — only one Netherlands region exists. |
| EU South (Italy) | `europe-west8` | ⚠ Defaulted to Milan over Turin (`europe-west12`). |

If any ⚠ default is wrong, it's a one-line edit to the `selectItems` array
in `template.tpl`.

## Caching

Corrections are cached per server instance, keyed on
`sha256(propertyId + utm_source + utm_medium + utm_campaign + utm_content +
utm_term)` via `templateDataStorage`, with a manually-checked TTL (no native
expiry in that API). This targets the common real-world case — one broken
link or ad generating many identical hits from different visitors — rather
than per-visitor session caching. It's per-instance only, not shared across
a fleet of autoscaled server instances; a real shared cache would need to
live in `utm-assistant-rt-function`, not here. Still worth having: it's
zero-cost and meaningfully cuts calls for the dominant case. Disable via the
"Cache corrections on this server instance" checkbox if it's ever suspect
during rollout of a ruleset change.

## Required permissions

`read_event_data` and `write_event_data`, both scoped to the five `utm_*`
keys; `send_http_request` scoped to `https://*.cr.utm-assistant.ai/inflight*`;
`access_template_storage`; `logging` (debug only). The permission block in
`template.tpl` was hand-authored, not exported from the GTM Template Editor
— re-verify the Permissions tab there before first real use.

## Testing

`template.tpl`'s `___TESTS___` box covers, with mocked `getEventData` /
`setInEventData` / `sendHttpGet` / `templateDataStorage`: no-op when no
utm_ params are present, request URL/header construction, applying a
corrected response, cache write-then-hit across two calls, cache
expiry after the TTL, and fail-open on a non-200 response, an
unparseable body, and a rejected/timed-out request.

`___TESTS___` content is a YAML document — `scenarios:`, a list of
`{name, code}` entries, each `code` a `|-` literal block scalar (confirmed
against a real working template: matomo-org/google-tag-manager-matomo-template).
Ordinary JS with colons/object literals is fine *inside* a `code: |-` block
(YAML treats block-scalar content as opaque text), but nothing outside one
may contain a bare `identifier:` or it gets misread as a YAML mapping key —
that includes an earlier `___SCENARIOS___` section (not a real section at
all, removed) and, before this file matched the real format, plain
top-level JS with `test()`/`mock()` calls. Each scenario is fully
self-contained (its own `require()`s, its own mocks) since there's no
shared preamble across list entries in this format.

The test DSL's exact API (`mock`, `assertThat`, `runCode`, `Promise.create`)
was written from memory, not validated against a live Template Editor —
open this template there and run the Tests tab before trusting the suite
green.
