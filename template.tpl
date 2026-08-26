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
  "description": "Calls the Inflight ingestion API by UTM Assistant with the incoming utm_ parameters and overwrites them with the corrected values before any tag reads them. Server-side only.",
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
      { "value": "southamerica-west1", "displayValue": "SA West (Chile)" },
      { "value": "asia-northeast1", "displayValue": "JP Center (Japan)" },
      { "value": "me-central1", "displayValue": "ME Center (Qatar)" },
      { "value": "northamerica-northeast1", "displayValue": "CA East (Canada)" },
      { "value": "us-central1", "displayValue": "US Center (Iowa)" },
      { "value": "us-east1", "displayValue": "US East (South Carolina)" },
      { "value": "us-west1", "displayValue": "US West (Oregon)" },
      { "value": "europe-west2", "displayValue": "EU West (England)" },
      { "value": "europe-west1", "displayValue": "EU West (Belgium)" },
      { "value": "europe-west3", "displayValue": "EU West (Germany)" },
      { "value": "europe-north1", "displayValue": "EU North (Finland)" },
      { "value": "asia-south1", "displayValue": "AP South (India)" },
      { "value": "australia-southeast1", "displayValue": "AU East (Australia)" },
      { "value": "southamerica-east1", "displayValue": "SA East (Brazil)" },
      { "value": "asia-southeast1", "displayValue": "AP East (Singapore)" },
      { "value": "europe-central2", "displayValue": "EU East (Poland)" },
      { "value": "europe-west9", "displayValue": "EU Center (France)" },
      { "value": "europe-west4", "displayValue": "EU North (Netherlands)" },
      { "value": "europe-west8", "displayValue": "EU South (Italy)" }
    ],
    "simpleValueType": true,
    "help": "Must match the Cloud Run region this sGTM container runs in — a mismatched region adds cross-region latency and defeats the point of this setting. See this repo's README for the full mapping and a few labels that were disambiguated from the source list.",
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
    "help": "This call sits in the hot path before tags fire — keep it tight. On timeout or any error, the original utm_ values pass through unmodified (fail open); the event is never dropped or delayed beyond this timeout."
  }
]


___SANDBOXED_JS_FOR_SERVER___

const getEventData = require('getEventData');
const setInEventData = require('setInEventData');
const sendHttpGet = require('sendHttpGet');
const sha256Sync = require('sha256Sync');
const encodeUriComponent = require('encodeUriComponent');
const templateDataStorage = require('templateDataStorage');
const logToConsole = require('logToConsole');
const getTimestampMillis = require('getTimestampMillis');
const JSON = require('JSON');
const makeNumber = require('makeNumber');

const UTM_KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];

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
// override is set. Lets one Transformation instance cover every GA4 stream
// in a shared sGTM container, instead of one instance per property.
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

function applyCorrection(corrected) {
  for (let i = 0; i < UTM_KEYS.length; i++) {
    const key = UTM_KEYS[i];
    if (corrected[key] !== undefined && corrected[key] !== null) {
      setInEventData(key, corrected[key], true);
    }
  }
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

// Fail-open on purpose: any error here (timeout, non-200, bad body) leaves the
// original utm_ values untouched rather than blocking or dropping the event.
function runTransformation() {
  const utms = readIncomingUtms();
  if (!utms) {
    return;
  }

  const propertyId = resolvePropertyId();
  if (!propertyId) {
    logToConsole('Inflight: no property id available (no x-ga-measurement_id on this event and no override set) — passing through uncorrected UTMs.');
    return;
  }

  const cacheEnabled = !!data.enableCache;
  const cacheKey = cacheEnabled ? buildCacheKey(propertyId, utms) : null;

  if (cacheEnabled) {
    const cached = readCache(cacheKey, makeNumber(data.cacheTtlSeconds));
    if (cached) {
      applyCorrection(cached);
      return;
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
        logToConsole('Inflight: ingestion API returned status ' + result.statusCode + ' — passing through uncorrected UTMs.');
        return;
      }
      const corrected = JSON.parse(result.body);
      if (corrected === undefined) {
        logToConsole('Inflight: could not parse ingestion API response — passing through uncorrected UTMs.');
        return;
      }
      applyCorrection(corrected);
      if (cacheEnabled) {
        writeCache(cacheKey, corrected);
      }
    },
    (error) => {
      logToConsole('Inflight: ingestion API call failed — passing through uncorrected UTMs. ' + (error && error.reason));
    }
  );
}

return runTransformation();

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
                "string": "utm_content"
              },
              {
                "type": 1,
                "string": "utm_term"
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
        "publicId": "write_event_data",
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
                "string": "utm_content"
              },
              {
                "type": 1,
                "string": "utm_term"
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
- name: no utm params - does not call the API or write event data
  code: |-
    const Promise = require('Promise');
    const Object = require('Object');
    mock('logToConsole', () => {});
    mock('getEventData', () => undefined);
    let httpCallCount = 0;
    mock('sendHttpGet', () => {
      httpCallCount++;
      return Promise.create((resolve) => resolve({statusCode: 200, body: '{}'}));
    });
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: true, cacheTtlSeconds: '21600', requestTimeoutMs: '400'});
    assertThat(httpCallCount).isEqualTo(0);
    assertThat(Object.keys(writes).length).isEqualTo(0);

- name: cache disabled - applies all corrected values from a 200 response
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'faceboook', utm_medium: 'social', utm_campaign: 'summer-sale', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    const correctedBody = JSON.stringify({utm_source: 'facebook', utm_medium: 'social', utm_campaign: 'summer-sale'});
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 200, body: correctedBody})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then(() => {
      assertThat(writes.utm_source).isEqualTo('facebook');
      assertThat(writes.utm_medium).isEqualTo('social');
      assertThat(writes.utm_campaign).isEqualTo('summer-sale');
    });

- name: request URL and headers are built from region, auto-detected property id, and api key
  code: |-
    const Promise = require('Promise');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'ig', utm_medium: 'paid', 'x-ga-measurement_id': 'G-PROP42'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('setInEventData', () => {});
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
    mock('setInEventData', () => {});
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

- name: no property id resolvable - no measurement id and no override - fails open
  code: |-
    const Object = require('Object');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
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
    runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'});
    assertThat(httpCallCount).isEqualTo(0);
    assertThat(Object.keys(writes).length).isEqualTo(0);

- name: repeat identical hit is served from cache, not a second API call
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'broken-source', utm_medium: 'cpc', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
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
      .then(() => {
        assertThat(httpCallCount).isEqualTo(1);
        assertThat(writes.utm_source).isEqualTo('fixed-source');
      });

- name: cache entry older than its TTL triggers a fresh API call
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'broken-source', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    mock('setInEventData', () => {});
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

- name: non-200 response fails open and does not write event data
  code: |-
    const Promise = require('Promise');
    const Object = require('Object');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 500, body: ''})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then(() => {
      assertThat(Object.keys(writes).length).isEqualTo(0);
    });

- name: unparseable response body fails open and does not write event data
  code: |-
    const Promise = require('Promise');
    const Object = require('Object');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 200, body: 'not json'})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then(() => {
      assertThat(Object.keys(writes).length).isEqualTo(0);
    });

- name: a rejected request fails open and does not throw
  code: |-
    const Promise = require('Promise');
    const Object = require('Object');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    mock('sendHttpGet', () => Promise.create((resolve, reject) => reject({reason: 'timeout'})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then(() => {
      assertThat(Object.keys(writes).length).isEqualTo(0);
    });

- name: partial correction only writes the keys present in the response
  code: |-
    const Promise = require('Promise');
    const JSON = require('JSON');
    mock('logToConsole', () => {});
    const eventValues = {utm_source: 'x', utm_medium: 'y', 'x-ga-measurement_id': 'G-DEMO123'};
    mock('getEventData', (key) => (eventValues[key] !== undefined ? eventValues[key] : undefined));
    const writes = {};
    mock('setInEventData', (key, value) => {
      writes[key] = value;
    });
    mock('templateDataStorage', {
      getItemCopy: () => null,
      setItemCopy: () => {},
      removeItem: () => {},
      clear: () => {}
    });
    const correctedBody = JSON.stringify({utm_source: 'x-fixed'});
    mock('sendHttpGet', () => Promise.create((resolve) => resolve({statusCode: 200, body: correctedBody})));
    return runCode({apiKey: 'demo-api-key', cloudRegion: 'us-central1', enableCache: false, cacheTtlSeconds: '21600', requestTimeoutMs: '400'}).then(() => {
      assertThat(writes.utm_source).isEqualTo('x-fixed');
      assertThat(writes.utm_medium).isUndefined();
    });


___NOTES___

Server-side Transformation only — Transformations don't run in web/client
containers, so there's no client-side counterpart of this exact template.

Setup, per sGTM container:
1. Property ID — auto-detected per event from the GA4 Client's
   `x-ga-measurement_id` (requires the `read_event_data` permission for
   that key, declared in this template). One Transformation instance now
   covers every GA4 property flowing through a shared container. Set the
   "Property ID override" field only for non-GA4 traffic or testing.
2. API Key — issued per account from the Inflight dashboard. On the
   backend, an admin enables a given measurement ID under that API key
   against a specific heuristic ruleset — see utm-assistant-app.
3. Cloud Region — MUST match the Cloud Run region this sGTM container runs
   in. See this repo's README for the full label → region-code mapping and
   the handful of labels that had to be disambiguated from the source list
   (flagged there — verify against your actual GTM region picker).

Before first use in a real container: open this template in the GTM
Template Editor and re-verify the Permissions tab directly. The permission
JSON in this .tpl was hand-authored (not exported from the GTM UI) and may
not match the exact schema GTM expects — treat it as a starting point, not
a guarantee.

Behavior on any failure (timeout, non-200, bad response body): the
transformation fails open — original utm_ values pass through unmodified,
the event is never blocked or dropped.
