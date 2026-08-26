# Inflight — Real-Time UTM Correction (sGTM Transformation)

A Google Tag Manager **server-side Transformation** template. It reads the
incoming `utm_source` / `utm_medium` / `utm_campaign` / `utm_content` /
`utm_term` event parameters, calls the Inflight ingestion API for the
corrected values, and overwrites them via `setInEventData` before any Tag
sees the event. Transformations only exist in server GTM containers — this
template has no client-side/web-container equivalent.

## Installation

The `.tpl` imports as a **Variable Template** (its declared `type` is
`MACRO`); it becomes an active Transformation by wiring that variable into
sGTM's Transformations engine. Three steps:

### Step 1: Import the Variable Template from the Gallery

1. In your sGTM container, go to **Templates** in the left menu.
2. Under **Variable Templates**, click **Search Gallery**.
3. Search for **"Inflight - UTM Assistant – Real-Time UTM Correction"**.
4. Click the template and select **Add to workspace**.
5. Review the requested permissions (`read_event_data` — scoped to the
   `utm_*` keys plus `x-ga-measurement_id`, `send_http_request`,
   `access_template_storage`, `logging`) and click **Add**.

### Step 2: Instantiate the Variable

1. Go to **Variables** in the left menu.
2. Under **User-Defined Variables**, click **New**.
3. Open **Variable Configuration** and select the template under *Custom*.
4. Fill in API Key, Cloud Region, and the cache/timeout options (see the
   field table below). Leave **Property ID override** blank — see
   "Property resolution" below.
5. Name the variable (e.g. `UTM - Real-Time Taxonomy Corrector`) and
   **Save**.

### Step 3: Attach it to the Transformations engine

1. Go to **Transformations** in the left sidebar.
2. Click **New** → choose **Augment Event** as the transformation type.
3. Under **Field to Augment**, select or enter the target `utm_*`
   parameters (or the broader event data scope).
4. Under **Value**, select the variable instantiated in Step 2 (e.g.
   `{{UTM - Real-Time Taxonomy Corrector}}`).
5. Under **Matching Rules**, set the trigger condition to **All Events**
   (or filter to specific incoming client requests).
6. Name the transformation (e.g. `Transform - Real-Time UTM Taxonomy`) and
   **Save**.

### Data flow

1. sGTM's Transformation engine catches the incoming request first.
2. It executes the variable, which reads `getEventData()` and calls the
   ingestion API via `sendHttpGet()` (through the cache first — see
   "Caching" below).
3. The variable calls `setInEventData()` to rewrite `utm_source`,
   `utm_medium`, etc. with the corrected values.
4. The transformation finishes, and every outgoing tag (GA4, Meta, Ads,
   ...) reads the corrected UTMs from event data with no per-tag override
   needed.

## Setup (per sGTM container)

| Field | Description |
|---|---|
| Property ID override | Optional. Leave blank — see "Property resolution" below. Only set this for containers that receive non-GA4 traffic, or for testing. |
| API Key | Issued per account from the Inflight dashboard. Sent as the `X-Api-Key` header. |
| Cloud Region | Must match the Cloud Run region this sGTM container runs in. See table below. |
| Cache corrections on this server instance | On by default. See "Caching" below. |
| Cache TTL (seconds) | Default 21600 (6h). Lower if correction rulesets change often. |
| Request timeout (ms) | Default 400. This call sits in the hot path before every tag fires — keep it tight. |

## Property resolution

The property is auto-detected per event, not typed into the template. The
GA4 Client populates `x-ga-measurement_id` in event data once it parses an
incoming hit; this template reads it via `getEventData('x-ga-measurement_id')`
and sends it as `property_id` to the ingestion API. On the backend, an
account admin links a given measurement ID to a heuristic ruleset under
their API key — see `utm-assistant-app`.

This means **one Transformation instance covers every GA4 property** routed
through a shared sGTM container — no per-property variable instances or
manual property ID entry needed.

If **Property ID override** is set, it always takes priority over the
auto-detected measurement ID. Use it for sGTM containers that receive
non-GA4 traffic (no GA4 Client in the request path, so
`x-ga-measurement_id` is never populated), or while testing. If neither the
override nor `x-ga-measurement_id` is available on an event, the
transformation fails open immediately without calling the ingestion API.

## Endpoint

```
GET https://{cloud-region}.cr.utm-assistant.ai/inflight?property_id=...&utm_source=...&utm_medium=...&utm_campaign=...&utm_content=...&utm_term=...
X-Api-Key: {apiKey}
```

`property_id` is the auto-detected GA4 measurement ID (`G-XXXXXXXXXX`) in
the common case, or the **Property ID override** value if one is set — see
"Property resolution" above. Either way it arrives as a plain string; the
ingestion API doesn't need to know which source it came from.

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

### Americas

| Display label | Region code | Note |
|---|---|---|
| CA East (Canada) | `northamerica-northeast1` | ⚠ Defaulted to Montreal over Toronto (`northamerica-northeast2`). |
| US Center (Iowa) | `us-central1` | |
| US East (South Carolina) | `us-east1` | |
| US West (Oregon) | `us-west1` | |
| SA East (Brazil) | `southamerica-east1` | |
| SA West (Chile) | `southamerica-west1` | |

### Europe

| Display label | Region code | Note |
|---|---|---|
| EU West (England) | `europe-west2` | ⚠ Source list said "EU North (England)" — no Cloud Run region matches north+England. London is `europe-west2`; relabeled. |
| EU West (Belgium) | `europe-west1` | |
| EU West (Germany) | `europe-west3` | ⚠ Source list said "EU Center (Germany)" — GCP's actual central-Europe region is Warsaw, not Germany. Frankfurt is `europe-west3`; relabeled. |
| EU North (Finland) | `europe-north1` | |
| EU North (Netherlands) | `europe-west4` | |
| EU East (Poland) | `europe-central2` | |
| EU Center (France) | `europe-west9` | |
| EU South (Italy) | `europe-west8` | ⚠ Defaulted to Milan over Turin (`europe-west12`). |

### Middle East

| Display label | Region code | Note |
|---|---|---|
| ME Center (Qatar) | `me-central1` | |

### Asia-Pacific

| Display label | Region code | Note |
|---|---|---|
| JP Center (Japan) | `asia-northeast1` | ⚠ Defaulted to Tokyo over Osaka (`asia-northeast2`) — no region is officially "center". |
| AP South (India) | `asia-south1` | ⚠ Defaulted to Mumbai over Delhi (`asia-south2`). |
| AP East (Singapore) | `asia-southeast1` | |
| AU East (Australia) | `australia-southeast1` | ⚠ Defaulted to Sydney over Melbourne (`australia-southeast2`). |

If any ⚠ default is wrong, it's a one-line edit to the `selectItems` array
in `template.tpl`.

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

