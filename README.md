# Inflight — Real-Time UTM Correction (sGTM Custom Variable)

A Google Tag Manager **server-side Custom Variable** template. It reads the
incoming `utm_id` / `utm_source` / `utm_medium` / `utm_campaign` /
`utm_source_platform` / `utm_term` / `utm_content` event parameters — GA4's
full reported set per Google's own Analytics Help Center URL-builder
documentation, minus `utm_creative_format`/`utm_marketing_tactic`, which
GA4 accepts but doesn't report on — calls the Inflight ingestion API for the
corrected values, and resolves to a JSON object of them — one call per
event, corrected where possible, falling back to the original value
otherwise. The template itself never writes event data (no
`setInEventData` equivalent for this template type — an earlier version
tried that and it does not work). Instead, routing the resolved values
into event data is done with sGTM's native **Augment Event Transformation**,
which reads properties straight off the resolved object — see Installation
below. Server-side only; no client-side/web-container equivalent.

## Installation

The `.tpl` imports as a **Variable Template** (its declared `type` is
`MACRO`). It resolves to a JSON object, not a single value, so it's routed
into event data via a native **Augment Event Transformation** rather than
being referenced directly in a tag field.

### Step 1: Import the Variable Template from the Gallery

1. In your sGTM container, go to **Templates** in the left menu.
2. Under **Variable Templates**, click **Search Gallery**.
3. Search for **"Inflight - UTM Assistant – Real-Time UTM Correction"**.
4. Click the template and select **Add to workspace**.
5. Review the requested permissions (`read_event_data` — scoped to the 7
   `utm_*` keys plus `x-ga-measurement_id`, `send_http_request`,
   `access_template_storage`, `logging`) and click **Add**.

### Step 2: Instantiate the Variable

1. Go to **Variables** in the left menu.
2. Under **User-Defined Variables**, click **New**.
3. Open **Variable Configuration** and select the template under *Custom*.
4. Fill in API Key, Cloud Region, and the cache/timeout options (see the
   field table below). Leave **Property ID override** blank — see
   "Property resolution" below.
5. Name the variable (e.g. `Inflight - Correction Data`) and **Save**.

### Step 3: Create an Augment Event Transformation

This is a native sGTM feature — no companion template needed. It reads
each field straight off the variable's resolved object and writes it into
event data, before any tag evaluates it.

1. In the sGTM left-hand menu, click **Transformations** → **New**.
2. Choose **Augment Event** as the transformation type.
3. Under **Parameters to Augment**, map each `utm_*` key you want
   corrected to its property path on the resolved object:

   | Parameter name | Value |
   |---|---|
   | `utm_id` | `{{Inflight - Correction Data}}.utm_id` |
   | `utm_source` | `{{Inflight - Correction Data}}.utm_source` |
   | `utm_medium` | `{{Inflight - Correction Data}}.utm_medium` |
   | `utm_campaign` | `{{Inflight - Correction Data}}.utm_campaign` |
   | `utm_source_platform` | `{{Inflight - Correction Data}}.utm_source_platform` |
   | `utm_term` | `{{Inflight - Correction Data}}.utm_term` |
   | `utm_content` | `{{Inflight - Correction Data}}.utm_content` |

   You don't need all seven rows — only include the fields you want
   corrected. A path for a key that wasn't on the incoming event (and so
   isn't in the resolved object) resolves to `undefined`; the
   Transformation leaves that parameter alone rather than clearing it.
4. Under **Matching Conditions**, set it to trigger on **All Events** (or
   narrow it, e.g. to events where `utm_source` is populated).
5. Under **Affected Tags**, leave it empty to apply globally to every tag,
   or select specific destination tags (GA4, Meta, Google Ads, ...).
6. Name it (e.g. `Transform - Inflight UTM Correction`) and **Save**.

No per-field extractor variables and no per-tag Parameters/Fields to Set
mapping are needed — every tag downstream of this Transformation reads the
corrected `utm_*` values from event data automatically, the same way it
would read any other event parameter.

### Data flow

1. An incoming event reaches the Transformation Engine. The
   `Transform - Inflight UTM Correction` rule evaluates
   `{{Inflight - Correction Data}}`.
2. That variable reads `getEventData()`, checks the cache (see "Caching"
   below), and on a cache miss calls the ingestion API via
   `sendHttpGet()`. Because it returns a Promise on that path, **sGTM
   automatically pauses transformation processing** (and every tag it
   feeds into) until the request resolves or times out — no manual
   sequencing needed.
3. The variable resolves to a JSON object; the Augment Event rule writes
   each mapped `utm_*` path into event data, globally, in memory. This is
   GTM's own native write mechanism for Augment Event — distinct from
   (and unaffected by) the `setInEventData` limitation mentioned above,
   which only applies to a template calling it directly from its own
   sandboxed JS.
4. Downstream tags fire and read the corrected (or, on any failure, the
   original) `utm_*` values straight from event data, with no per-tag
   configuration required.

## Setup (per sGTM container)

| Field | Required / Default | Description |
|---|---|---|
| API Key | Required | Issued per account from the Inflight dashboard. Sent as the `X-Api-Key` header. |
| Cloud Region | Required | Must match the Cloud Run region this sGTM container runs in. See table below. |
| Property ID override | Optional — default: blank | Leave blank — see "Property resolution" below. Only set this for containers that receive non-GA4 traffic, or for testing. |
| Cache corrections on this server instance | Optional — default: true | See "Caching" below. |
| Cache TTL (seconds) | Optional — default: 21600 (6h) | Lower if correction rulesets change often. |
| Request timeout (ms) | Optional — default: 400 | This call sits in the hot path before every tag fires — keep it tight. |

## Property resolution

The property is auto-detected per event, not typed into the template. The
GA4 Client populates `x-ga-measurement_id` in event data once it parses an
incoming hit; this template reads it via `getEventData('x-ga-measurement_id')`
and sends it as `property_id` to the ingestion API. On the backend, an
account admin links a given measurement ID to a heuristic ruleset under
their API key — see `utm-assistant-app`.

This means **one variable instance covers every GA4 property** routed
through a shared sGTM container — no per-property variable instances or
manual property ID entry needed.

If **Property ID override** is set, it always takes priority over the
auto-detected measurement ID. Use it for sGTM containers that receive
non-GA4 traffic (no GA4 Client in the request path, so
`x-ga-measurement_id` is never populated), or while testing. If neither the
override nor `x-ga-measurement_id` is available on an event, the variable
fails open immediately without calling the ingestion API — it resolves to
the raw, uncorrected `utm_*` values instead.

## Endpoint

```
GET https://{cloud-region}.cr.utm-assistant.ai/inflight?property_id=...&utm_id=...&utm_source=...&utm_medium=...&utm_campaign=...&utm_source_platform=...&utm_term=...&utm_content=...
X-Api-Key: {apiKey}
```

`property_id` is the auto-detected GA4 measurement ID (`G-XXXXXXXXXX`) in
the common case, or the **Property ID override** value if one is set — see
"Property resolution" above. Either way it arrives as a plain string; the
ingestion API doesn't need to know which source it came from.

Expects a `200` JSON response with any subset of the five `utm_*` keys —
only keys present on the incoming event are included in the variable's
resolved object, and only the ones the response actually corrects get
overridden there; the rest fall back to their raw incoming value. Any
other status, a timeout, or an unparseable body leaves every key at its
raw value (fail open — this never blocks a tag or drops a parameter it
would otherwise have sent).

## Cloud Region mapping

The Cloud Region dropdown's `displayValue` uses the label style from the
original source list; the underlying `value` is the real Cloud Run region
code used in the endpoint subdomain. Cross-checked against Google's current
Cloud Run region list. Most resolve unambiguously (only one region exists
in that country); a handful didn't and were disambiguated — **verify these
against your actual GTM region picker before relying on them**.

**Region availability: only 5 of these 19 are selectable in the dropdown
today.** `utm-assistant-cr-inflight`'s load balancer currently only routes
to `us-central1`, `us-west1`, `europe-west3`, `europe-north1`, and
`europe-central2` — the rest are blocked on a pending Cloud Run
region-count quota increase (GCP case
`622fd189-13ec-4c20-810d-03eef3b987f5`, filed 2026-08-29, Google's own ETA
2-3 weeks). The tables below list the full 19-region target — kept as
reference (including the disambiguation notes, still relevant once a
region goes live) rather than trimmed down — with a **Status** column
marking what's actually usable right now. A region marked "Pending quota"
isn't in the dropdown yet; selecting it isn't possible until it's added
back once the quota clears.

### Americas

| Display label | Region code | Status | Note |
|---|---|---|---|
| CA East (Canada) | `northamerica-northeast1` | Pending quota | ⚠ Defaulted to Montreal over Toronto (`northamerica-northeast2`). |
| US Center (Iowa) | `us-central1` | **Live** | |
| US East (South Carolina) | `us-east1` | Pending quota | |
| US West (Oregon) | `us-west1` | **Live** | |
| SA East (Brazil) | `southamerica-east1` | Pending quota | |
| SA West (Chile) | `southamerica-west1` | Pending quota | |

### Europe

| Display label | Region code | Status | Note |
|---|---|---|---|
| EU West (England) | `europe-west2` | Pending quota | ⚠ Source list said "EU North (England)" — no Cloud Run region matches north+England. London is `europe-west2`; relabeled. |
| EU West (Belgium) | `europe-west1` | Pending quota | |
| EU West (Germany) | `europe-west3` | **Live** | ⚠ Source list said "EU Center (Germany)" — GCP's actual central-Europe region is Warsaw, not Germany. Frankfurt is `europe-west3`; relabeled. |
| EU North (Finland) | `europe-north1` | **Live** | |
| EU North (Netherlands) | `europe-west4` | Pending quota | |
| EU East (Poland) | `europe-central2` | **Live** | |
| EU Center (France) | `europe-west9` | Pending quota | |
| EU South (Italy) | `europe-west8` | Pending quota | ⚠ Defaulted to Milan over Turin (`europe-west12`). |

### Middle East

| Display label | Region code | Status | Note |
|---|---|---|---|
| ME Center (Qatar) | `me-central1` | Pending quota | |

### Asia-Pacific

| Display label | Region code | Status | Note |
|---|---|---|---|
| JP Center (Japan) | `asia-northeast1` | Pending quota | ⚠ Defaulted to Tokyo over Osaka (`asia-northeast2`) — no region is officially "center". |
| AP South (India) | `asia-south1` | Pending quota | ⚠ Defaulted to Mumbai over Delhi (`asia-south2`). |
| AP East (Singapore) | `asia-southeast1` | Pending quota | |
| AU East (Australia) | `australia-southeast1` | Pending quota | ⚠ Defaulted to Sydney over Melbourne (`australia-southeast2`). |

If any ⚠ default is wrong, it's a one-line edit to the `selectItems` array
in `template.tpl` (for a **Live** region only — a **Pending quota** region
isn't in `selectItems` at all right now, see above).

## Finding your sGTM container's region

How you check the region depends on whether your tagging server was set up
via automatic or manual provisioning (Cloud Run / App Engine).

### Method 1: Google Cloud Console (Cloud Run / App Engine)

If you manage your own GCP infrastructure or used standard setup:

1. Log into the [Google Cloud Console](https://console.cloud.google.com/).
2. Select the GCP project associated with your sGTM deployment.
3. Open **Cloud Run** from the main menu.
4. Look at the **Region** column next to your sGTM services (e.g.
   `us-central1`, `europe-west1`, `asia-northeast1`).

(If your container predates late 2023 and uses App Engine instead of Cloud
Run, go to **App Engine → Settings** to see the region instead.)

### Method 2: Check the Cloud Run URL

Every default Cloud Run service endpoint contains the deployment region
directly inside its domain name:

```
https://gtm-xxxxxx-xxxx.<region>.run.app
```

Example: `https://gtm-abc123-xyz.europe-west1.run.app` → region is
`europe-west1`.

### Method 3: Inspect network response headers (quick check)

If your sGTM container is attached to a custom domain (e.g.
`metrics.yourdomain.com`):

1. Open your website in a browser.
2. Open Developer Tools (F12) → **Network** tab.
3. Reload the page and select an incoming request sent to your sGTM domain.
4. Check the response headers for Google Cloud routing headers — look for
   `x-cloud-trace-context` or similar Google infrastructure headers, which
   often include datacenter location codes (e.g. `fra` for Frankfurt, `iad`
   for Iowa).

## Caching

Corrections are cached per server instance, keyed on
`sha256(propertyId + <all 7 utm_* values, in the same order as UTM_KEYS in
template.tpl>)` via `templateDataStorage`, with a manually-checked TTL (no native
expiry in that API). This targets the common real-world case — one broken
link or ad generating many identical hits from different visitors — rather
than per-visitor session caching. It's per-instance only, not shared across
a fleet of autoscaled server instances; a real shared cache would need to
live in `utm-assistant-rt-function`, not here. Still worth having: it's
zero-cost and meaningfully cuts calls for the dominant case. Disable via the
"Cache corrections on this server instance" checkbox if it's ever suspect
during rollout of a ruleset change.

