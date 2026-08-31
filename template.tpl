___TERMS_OF_SERVICE___

By creating or modifying this file you agree to Google Tag Manager's Community
Template Gallery Developer Terms of Service available at
https://developers.google.com/tag-manager/gallery-tos (or such other URL as
Google may provide), as modified from time to time.

___INFO___

{
  "type": "MACRO",
  "id": "cvt_ua1",
  "version": 1,
  "securityGroups": [],
  "displayName": "Inflight - UTM Assistant – Real-Time UTM Correction",
  "categories": ["ANALYTICS", "UTILITY"],
  "brand": {
    "id": "utm_assistant",
    "displayName": "UTM Assistant",
    "thumbnail": ""
  },
  "description": "Fetches corrected utm_id/utm_source/utm_medium/utm_campaign/utm_source_platform/utm_term/utm_content values from the Inflight ingestion API for the current event, and resolves to a JSON object of them for use in a native Augment Event Transformation, which writes the corrected values into event data for all downstream tags (GA4, Meta, Google Ads, etc). Server-side only.",
  "containerContexts": [
    "SERVER"
  ]
}


___TEMPLATE_PARAMETERS___

[
  {
    "type": "TEXT",
    "name": "propertyIdOverride",
    "displayName": "Property ID override (optional)",
    "simpleValueType": true,
    "help": "Leave blank in the normal case — the property is auto-detected per event from the GA4 Client's x-ga-measurement_id. Only set this for sGTM containers that receive non-GA4 traffic (no GA4 Client in the request path), or for testing."
  },
  {
    "type": "TEXT",
    "name": "apiKey",
    "displayName": "API Key",
    "simpleValueType": true,
    "help": "Inflight ingestion API key for this account. Sent as the X-Api-Key request header. Visible to anyone with edit access to this container — treat it like any other GTM server-side credential.",
    "valueValidators": [
      { "type": "NON_EMPTY" }
    ]
  },
  {
    "type": "SELECT",
    "name": "cloudRegion",
    "displayName": "Cloud Region",
    "macrosInSelect": false,
    "selectItems": [
      { "value": "northamerica-northeast1", "displayValue": "CA East (Canada)" },
      { "value": "us-central1", "displayValue": "US Center (Iowa)" },
      { "value": "us-east1", "displayValue": "US East (South Carolina)" },
      { "value": "us-west1", "displayValue": "US West (Oregon)" },
      { "value": "southamerica-east1", "displayValue": "SA East (Brazil)" },
      { "value": "southamerica-west1", "displayValue": "SA West (Chile)" },
      { "value": "europe-west2", "displayValue": "EU West (England)" },
      { "value": "europe-west1", "displayValue": "EU West (Belgium)" },
      { "value": "europe-west3", "displayValue": "EU West (Germany)" },
      { "value": "europe-north1", "displayValue": "EU North (Finland)" },
      { "value": "europe-west4", "displayValue": "EU North (Netherlands)" },
      { "value": "europe-central2", "displayValue": "EU East (Poland)" },
      { "value": "europe-west9", "displayValue": "EU Center (France)" },
      { "value": "europe-west8", "displayValue": "EU South (Italy)" },
      { "value": "me-central1", "displayValue": "ME Center (Qatar)" },
      { "value": "asia-northeast1", "displayValue": "JP Center (Japan)" },
      { "value": "asia-south1", "displayValue": "AP South (India)" },
      { "value": "asia-southeast1", "displayValue": "AP East (Singapore)" },
      { "value": "australia-southeast1", "displayValue": "AU East (Australia)" }
    ],
    "simpleValueType": true,
    "help": "Must match the Cloud Run region this sGTM container runs in — a mismatched region adds cross-region latency and defeats the point of this setting. See this repo's README's \"Cloud Region mapping\" section for disambiguation notes on a handful of these labels.",
    "valueValidators": [
      { "type": "NON_EMPTY" }
    ]
  },
  {
    "type": "CHECKBOX",
    "name": "enableCache",
    "checkboxText": "Cache corrections on this server instance",
    "simpleValueType": true,
    "defaultValue": true,
    "help": "Recommended. Caches a correction by a hash of (property + utm_ values) so repeated hits from the same broken link don't each call the API. Cache is per server instance only, not shared across instances."
  },
  {
    "type": "TEXT",
    "name": "cacheTtlSeconds",
    "displayName": "Cache TTL (seconds)",
    "simpleValueType": true,
    "defaultValue": "21600",
    "help": "How long a cached correction is trusted before this instance calls the API again. Default 21600 (6 hours). Lower this if correction rulesets change frequently for your accounts.",
    "enablingConditions": [
      { "paramName": "enableCache", "paramValue": true, "type": "EQUALS" }
    ]
  },
  {
    "type": "TEXT",
    "name": "requestTimeoutMs",
    "displayName": "Request timeout (ms)",
    "simpleValueType": true,
    "defaultValue": "400",
    "help": "This variable sits in the hot path before tags fire — keep it tight. On timeout or any error, the resolved value falls back to the original, uncorrected utm_ values; the tag is never blocked beyond this timeout."
  }
]


___SANDBOXED_JS_FOR_SERVER___

const getEventData = require('getEventData');
const sendHttpGet = require('sendHttpGet');
const sha256Sync = require('sha256Sync');
const encodeUriComponent = require('encodeUriComponent');
const templateDataStorage = require('templateDataStorage');
const logToConsole = require('logToConsole');
const getTimestampMillis = require('getTimestampMillis');
const JSON = require('JSON');
const makeNumber = require('makeNumber');

// Mirrors utm-assistant-app/packages/heuristic-engine/src/types.ts's
// UTM_KEYS by hand (GTM sandboxed JS can't import an npm package) — the
// full set GA4 reports on, minus utm_creative_format/utm_marketing_tactic
// (GA4 accepts but doesn't report on either, so there's nothing to
// correct against). Keep this, read_event_data's keyPatterns below, and
// that file's UTM_KEYS in sync.
const UTM_KEYS = ['utm_id', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_source_platform', 'utm_term', 'utm_content'];

// Only the utm_ keys actually present on this event — nothing to correct if none are set.
function readIncomingUtms() {
  const values = {};
  let hasAny = false;
  for (let i = 0; i < UTM_KEYS.length; i++) {
    const key = UTM_KEYS[i];
    const value = getEventData(key);
    if (value !== undefined && value !== null && value !== '') {
      values[key] = value;
      hasAny = true;
    }
  }
  return hasAny ? values : null;
}

// Auto-detected from the GA4 Client's parsed measurement ID unless a manual
// override is set. Lets one variable instance cover every GA4 stream in a
// shared sGTM container, instead of one instance per property.
function resolvePropertyId() {
  if (data.propertyIdOverride) {
    return data.propertyIdOverride;
  }
  return getEventData('x-ga-measurement_id');
}

// Deliberately scoped to property + utm_ values only, not full event data —
// this is meant to dedupe the SAME broken link across many different hits/visitors.
function buildCacheKey(propertyId, utms) {
  const parts = [propertyId];
  for (let i = 0; i < UTM_KEYS.length; i++) {
    const key = UTM_KEYS[i];
    parts.push(key + '=' + (utms[key] || ''));
  }
  return sha256Sync(parts.join('&'), { outputEncoding: 'hex' });
}

function readCache(cacheKey, ttlSeconds) {
  const entry = templateDataStorage.getItemCopy(cacheKey);
  if (!entry) return null;
  const ageSeconds = (getTimestampMillis() - entry.cachedAt) / 1000;
  if (ageSeconds > ttlSeconds) return null;
  return entry.corrected;
}

function writeCache(cacheKey, corrected) {
  templateDataStorage.setItemCopy(cacheKey, {
    corrected: corrected,
    cachedAt: getTimestampMillis()
  });
}

// Only the utm_ keys present on the incoming event are included — never
// invent a key the event didn't have. Each included key uses the API's
// corrected value if present, otherwise falls back to the raw incoming
// value, so a downstream tag field mapping never resolves to undefined and
// silently drops a parameter it would otherwise have sent.
function mergeCorrection(utms, corrected) {
  const merged = {};
  for (let i = 0; i < UTM_KEYS.length; i++) {
    const key = UTM_KEYS[i];
    if (utms[key] === undefined) continue;
    merged[key] = (corrected[key] !== undefined && corrected[key] !== null) ? corrected[key] : utms[key];
  }
  return merged;
}

function buildRequestUrl(region, propertyId, utms) {
  const query = ['property_id=' + encodeUriComponent(propertyId)];
  for (let i = 0; i < UTM_KEYS.length; i++) {
    const key = UTM_KEYS[i];
    if (utms[key] !== undefined) {
      query.push(key + '=' + encodeUriComponent(utms[key]));
    }
  }
  return 'https://' + region + '.cr.utm-assistant.ai/inflight?' + query.join('&');
}

function callIngestionApi(region, propertyId, apiKey, utms, timeoutMs) {
  const url = buildRequestUrl(region, propertyId, utms);
  return sendHttpGet(url, {
    headers: { 'X-Api-Key': apiKey },
    timeout: timeoutMs
  });
}

// Resolves to a plain object of the incoming utm_ keys, corrected where
// possible. Returns synchronously on a no-op or cache hit; returns a
// Promise (which sGTM awaits, pausing any tag this variable is mapped
// into, before resolving the field) when the ingestion API needs to be
// called. Fail-open on purpose: any error here (timeout, non-200, bad
// body) resolves to the original utm_ values untouched rather than
// blocking the tag or dropping the parameter.
function run() {
  const utms = readIncomingUtms();
  if (!utms) {
    return utms;
  }

  const propertyId = resolvePropertyId();
  if (!propertyId) {
    logToConsole('Inflight: no property id available (no x-ga-measurement_id on this event and no override set) — returning uncorrected UTMs.');
    return utms;
  }

  const cacheEnabled = !!data.enableCache;
  const cacheKey = cacheEnabled ? buildCacheKey(propertyId, utms) : null;

  if (cacheEnabled) {
    const cached = readCache(cacheKey, makeNumber(data.cacheTtlSeconds));
    if (cached) {
      return mergeCorrection(utms, cached);
    }
  }

  return callIngestionApi(
    data.cloudRegion,
    propertyId,
    data.apiKey,
    utms,
    makeNumber(data.requestTimeoutMs)
  ).then(
    (result) => {
      if (result.statusCode !== 200) {
        logToConsole('Inflight: ingestion API returned status ' + result.statusCode + ' — returning uncorrected UTMs.');
        return utms;
      }
      const corrected = JSON.parse(result.body);
      if (corrected === undefined) {
        logToConsole('Inflight: could not parse ingestion API response — returning uncorrected UTMs.');
        return utms;
      }
      if (cacheEnabled) {
        writeCache(cacheKey, corrected);
      }
      return mergeCorrection(utms, corrected);
    },
    (error) => {
      logToConsole('Inflight: ingestion API call failed — returning uncorrected UTMs. ' + (error && error.reason));
      return utms;
    }
  );
}

return run();

___SERVER_PERMISSIONS___

[
  {
    "instance": {
      "key": {
        "publicId": "logging",
        "versionId": "1"
      },
      "param": [
        {
          "key": "environments",
          "value": {
            "type": 1,
            "string": "debug"
          }
        }
      ]
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "access_template_storage",
        "versionId": "1"
      },
      "param": []
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "read_event_data",
        "versionId": "1"
      },
      "param": [
        {
          "key": "keyPatterns",
          "value": {
            "type": 2,
            "listItem": [
              {
                "type": 1,
                "string": "utm_id"
              },
              {
                "type": 1,
                "string": "utm_source"
              },
              {
                "type": 1,
                "string": "utm_medium"
              },
              {
                "type": 1,
                "string": "utm_campaign"
              },
              {
                "type": 1,
                "string": "utm_source_platform"
              },
              {
                "type": 1,
                "string": "utm_term"
              },
              {
                "type": 1,
                "string": "utm_content"
              },
              {
                "type": 1,
                "string": "x-ga-measurement_id"
              }
            ]
          }
        },
        {
          "key": "eventDataAccess",
          "value": {
            "type": 1,
            "string": "specific"
          }
        }
      ]
    },
    "clientAnnotations": {
      "isEditedByUser": true
    },
    "isRequired": true
  },
  {
    "instance": {
      "key": {
        "publicId": "send_http",
        "versionId": "1"
      },
      "param": [
        {
          "key": "allowedUrls",
          "value": {
            "type": 1,
            "string": "specific"
          }
        }
      ]
    },
    "isRequired": true
  }
]


___TESTS___

scenarios:
- name: no utm params - resolves the incoming (empty) payload directly, does not call the API
  code: |-
    const Promise = require('Promise');
    mock('logToConsole', () => {});
    mock('getEventData', () => undefined);
    let httpCallCount = 0;
    mock('sendHttpGet', () => {
      httpCallCount++;
      return Promise.create((resolve) => resolve({statusCode: 200, body: '{}'}));
    });
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    const result = runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: true, cacheTtlSeconds: '21600', requestTimeoutMs: '400'});
    assertThat(httpCallCount).isEqualTo(0);
    assertThat(result).isEqualTo(null);

- name: cache disabled - resolves corrected values from a 200 response
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'faceboook', utm_medium: 'social', utm_campaign: 'summer-sale', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    const correctedBody = JSON.stringify({utm_source: 'facebook', utm_medium: 'social', utm_campaign: 'summer-sale'});
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 200, body: correctedBody})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then((result) => {
      assertThat(result.utm_source).isEqualTo('facebook');
      assertThat(result.utm_medium).isEqualTo('social');
      assertThat(result.utm_campaign).isEqualTo('summer-sale');
    });

- name: request URL and headers are built from region, auto-detected property id, and api key
  code: |-
    const Promise = require('Promise');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'ig', utm_medium: 'paid', 'x-ga-measurement_id': 'G-PROP42'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    let capturedUrl;
    let capturedOptions;
    mock('sendHttpGet', (url, options) => {
      capturedUrl = url;
      capturedOptions = options;
      return Promise.create((resolve) => resolve({statusCode: 200, body: '{}'}));
    });
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'europe-west1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then(() => {
      assertThat(capturedUrl.indexOf('https://europe-west1.cr.utm-assistant.ai/inflight?') === 0).isEqualTo(true);
      assertThat(capturedUrl.indexOf('property_id=G-PROP42') > -1).isEqualTo(true);
      assertThat(capturedUrl.indexOf('utm_source=ig') > -1).isEqualTo(true);
      assertThat(capturedOptions.headers['X-Api-Key']).isEqualTo('demo-api-key');
    });

- name: propertyIdOverride takes priority over the auto-detected measurement id
  code: |-
    const Promise = require('Promise');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'ig', 'x-ga-measurement_id': 'G-FROMEVENT'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    let capturedUrl;
    mock('sendHttpGet', (url) => {
      capturedUrl = url;
      return Promise.create((resolve) => resolve({statusCode: 200, body: '{}'}));
    });
    return runCode({propertyIdOverride: 'manual-override', apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then(() => {
      assertThat(capturedUrl.indexOf('property_id=manual-override') > -1).isEqualTo(true);
      assertThat(capturedUrl.indexOf('G-FROMEVENT') > -1).isEqualTo(false);
    });

- name: no property id resolvable - resolves the raw utms unchanged and does not call the API
  code: |-
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    let httpCallCount = 0;
    mock('sendHttpGet', () => {
      httpCallCount++;
      return { then: () => {} };
    });
    const result = runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'});
    assertThat(httpCallCount).isEqualTo(0);
    assertThat(result.utm_source).isEqualTo('x');

- name: repeat identical hit is served from cache, not a second API call
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'broken-source', utm_medium: 'cpc', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const store = {};
    mock('templateDataStorage', {
      getItemCopy: (key) => (store[key] !== undefined ? store[key] : null),
      setItemCopy: (key, value) => {
        store[key] = value;
      },
      removeItem: (key) => {
        delete store[key];
      },
      clear: () => {}
    });
    let httpCallCount = 0;
    const correctedBody = JSON.stringify({utm_source: 'fixed-source', utm_medium: 'cpc'});
    mock('sendHttpGet', () => {
      httpCallCount++;
      return Promise.create((resolve) => resolve({statusCode: 200, body: correctedBody}));
    });
    const fieldData = {apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: true, cacheTtlSeconds: '21600', requestTimeoutMs: '400'};
    return runCode(fieldData)
      .then(() => runCode(fieldData))
      .then((result) => {
        assertThat(httpCallCount).isEqualTo(1);
        assertThat(result.utm_source).isEqualTo('fixed-source');
      });

- name: cache entry older than its TTL triggers a fresh API call
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'broken-source', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const store = {};
    mock('templateDataStorage', {
      getItemCopy: (key) => (store[key] !== undefined ? store[key] : null),
      setItemCopy: (key, value) => {
        store[key] = value;
      },
      removeItem: (key) => {
        delete store[key];
      },
      clear: () => {}
    });
    let httpCallCount = 0;
    const correctedBody = JSON.stringify({utm_source: 'fixed-source'});
    mock('sendHttpGet', () => {
      httpCallCount++;
      return Promise.create((resolve) => resolve({statusCode: 200, body: correctedBody}));
    });
    let now = 0;
    mock('getTimestampMillis', () => now);
    const fieldData = {apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: true, cacheTtlSeconds: '10', requestTimeoutMs: '400'};
    return runCode(fieldData)
      .then(() => {
        now = 11 * 1000;
        return runCode(fieldData);
      })
      .then(() => {
        assertThat(httpCallCount).isEqualTo(2);
      });

- name: non-200 response fails open and resolves the raw utms unchanged
  code: |-
    const Promise = require('Promise');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 500, body: ''})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then((result) => {
      assertThat(result.utm_source).isEqualTo('x');
    });

- name: unparseable response body fails open and resolves the raw utms unchanged
  code: |-
    const Promise = require('Promise');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 200, body: 'not json'})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then((result) => {
      assertThat(result.utm_source).isEqualTo('x');
    });

- name: a rejected request fails open and resolves the raw utms unchanged
  code: |-
    const Promise = require('Promise');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    mock('sendHttpGet', () => Promise.create((resolve, reject) => reject({reason: 'timeout'})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then((result) => {
      assertThat(result.utm_source).isEqualTo('x');
    });

- name: partial correction overrides the corrected key, falls back to raw for the rest
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', utm_medium: 'y', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    const correctedBody = JSON.stringify({utm_source: 'x-fixed'});
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 200, body: correctedBody})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then((result) => {
      assertThat(result.utm_source).isEqualTo('x-fixed');
      assertThat(result.utm_medium).isEqualTo('y');
    });

- name: resolved object never includes a key absent from the incoming event
  code: |-
    const Promise = require('Promise');
    const Object = require('Object');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    const correctedBody = JSON.stringify({utm_source: 'x-fixed', utm_medium: 'sneaky-extra-key'});
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 200, body: correctedBody})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then((result) => {
      assertThat(Object.keys(result).length).isEqualTo(1);
      assertThat(result.utm_medium).isUndefined();
    });


___NOTES___

Custom Variable (MACRO) only — server-side sGTM. Resolves to a JSON object
of the incoming utm_ keys, corrected where the ingestion API has a
correction, falling back to the original value otherwise. It does NOT
write event data itself; sGTM Custom Variables can't do that (no
setInEventData equivalent for this template type — the earlier version of
this template attempted that and it does not work). Instead:

Setup, per sGTM container:
1. Import this template once, instantiate one variable from it (e.g. named
   "Inflight - Correction Data"). Fill in API Key, Cloud Region, and the
   cache/timeout options. Leave "Property ID override" blank unless this
   container receives non-GA4 traffic — see "Property resolution" below.
2. Create a native **Augment Event Transformation** (Transformations ->
   New -> Augment Event). Under Parameters to Augment, map each utm_ key
   you want corrected to its property path on the resolved object, e.g.
   `utm_medium` -> `{{Inflight - Correction Data}}.utm_medium`. Set
   Matching Conditions to All Events (or narrower), and Affected Tags to
   empty (applies globally) or a specific tag selection.
   This is GTM's own write mechanism for Augment Event — it is not this
   template calling setInEventData itself, which does not work. No
   per-field extractor variables and no per-tag Parameters/Fields to Set
   mapping are needed: every downstream tag reads the corrected utm_
   values from event data automatically, same as any other event
   parameter.

Property resolution: the property is auto-detected per event from the GA4
Client's `x-ga-measurement_id` (requires the `read_event_data` permission
for that key, declared in this template). One variable instance covers
every GA4 property flowing through a shared container. Set the "Property
ID override" field only for non-GA4 traffic or testing.

Cloud Region: MUST match the Cloud Run region this sGTM container runs in.
See this repo's README for the full label → region-code mapping and the
handful of labels that had to be disambiguated from the source list
(flagged there — verify against your actual GTM region picker).

Because this variable can return a Promise, sGTM automatically pauses any
tag it's mapped into until the ingestion API call resolves (or the request
timeout is hit) — no manual tag sequencing/priority needed, same as any
other async sGTM variable.

Before first use in a real container: open this template in the GTM
Template Editor and re-verify the Permissions tab directly. The permission
JSON in this .tpl was hand-authored (not exported from the GTM UI) and may
not match the exact schema GTM expects — treat it as a starting point, not
a guarantee.

Behavior on any failure (timeout, non-200, bad response body, no
resolvable property id): fails open — resolves to the original,
uncorrected utm_ values rather than undefined, so the Augment Event
Transformation never silently drops a parameter a tag would otherwise
have sent.
