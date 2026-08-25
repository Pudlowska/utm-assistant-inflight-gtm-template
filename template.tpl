___INFO___

{
  "type": "TRANSFORMATION",
  "id": "cvt_temp_public_id",
  "version": 1,
  "securityGroups": [],
  "displayName": "Inflight – Real-Time UTM Correction",
  "categories": ["ANALYTICS", "UTILITY"],
  "brand": {
    "id": "utm_assistant",
    "displayName": "UTM Assistant",
    "thumbnail": ""
  },
  "description": "Calls the Inflight ingestion API with the incoming utm_ parameters and overwrites them with the corrected values before any tag reads them. Server-side only.",
  "containerContexts": [
    "SERVER"
  ]
}


___TEMPLATE_PARAMETERS___

[
  {
    "type": "TEXT",
    "name": "propertyId",
    "displayName": "Property ID",
    "simpleValueType": true,
    "help": "The Inflight property identifier for this client property (matches the id used in the heuristic ruleset owned by utm-assistant-app). Scopes which correction rules the ingestion API applies.",
    "valueValidators": [
      { "type": "NON_EMPTY" }
    ]
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
const Object = require('Object');
const Promise = require('Promise');
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
	return 'https://' + region + '.utm-assistant.ai/inflight?' + query.join('&');
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

	const cacheEnabled = !!data.enableCache;
	const cacheKey = cacheEnabled ? buildCacheKey(data.propertyId, utms) : null;

	if (cacheEnabled) {
		const cached = readCache(cacheKey, makeNumber(data.cacheTtlSeconds));
		if (cached) {
			applyCorrection(cached);
			return;
		}
	}

	return callIngestionApi(
		data.cloudRegion,
		data.propertyId,
		data.apiKey,
		utms,
		makeNumber(data.requestTimeoutMs)
	)
		.then((result) => {
			if (result.statusCode !== 200) {
				logToConsole('Inflight: ingestion API returned status ' + result.statusCode + ' — passing through uncorrected UTMs.');
				return;
			}
			let corrected;
			try {
				corrected = JSON.parse(result.body);
			} catch (parseError) {
				logToConsole('Inflight: could not parse ingestion API response — passing through uncorrected UTMs.');
				return;
			}
			applyCorrection(corrected);
			if (cacheEnabled) {
				writeCache(cacheKey, corrected);
			}
		})
		.catch((error) => {
			logToConsole('Inflight: ingestion API call failed — passing through uncorrected UTMs. ' + (error && error.reason));
		});
}

return runTransformation();


___SERVER_PERMISSIONS___

[
  {
    "instance": {
      "key": { "publicId": "read_event_data", "versionId": "1" },
      "param": [
        {
          "key": "keyPatterns",
          "value": {
            "type": 2,
            "listItem": [
              { "type": 1, "string": "utm_source" },
              { "type": 1, "string": "utm_medium" },
              { "type": 1, "string": "utm_campaign" },
              { "type": 1, "string": "utm_content" },
              { "type": 1, "string": "utm_term" }
            ]
          }
        }
      ]
    },
    "clientAnnotations": { "isEditedByUser": false },
    "isRequired": true
  },
  {
    "instance": {
      "key": { "publicId": "write_event_data", "versionId": "1" },
      "param": [
        {
          "key": "keyPatterns",
          "value": {
            "type": 2,
            "listItem": [
              { "type": 1, "string": "utm_source" },
              { "type": 1, "string": "utm_medium" },
              { "type": 1, "string": "utm_campaign" },
              { "type": 1, "string": "utm_content" },
              { "type": 1, "string": "utm_term" }
            ]
          }
        }
      ]
    },
    "clientAnnotations": { "isEditedByUser": false },
    "isRequired": true
  },
  {
    "instance": {
      "key": { "publicId": "send_http_request", "versionId": "1" },
      "param": [
        {
          "key": "allowedUrls",
          "value": { "type": 1, "string": "specific" }
        },
        {
          "key": "urls",
          "value": {
            "type": 2,
            "listItem": [
              { "type": 1, "string": "https://*.utm-assistant.ai/inflight*" }
            ]
          }
        }
      ]
    },
    "clientAnnotations": { "isEditedByUser": false },
    "isRequired": true
  },
  {
    "instance": {
      "key": { "publicId": "access_template_storage", "versionId": "1" },
      "param": []
    },
    "clientAnnotations": { "isEditedByUser": false },
    "isRequired": true
  },
  {
    "instance": {
      "key": { "publicId": "logging", "versionId": "1" },
      "param": [
        { "key": "environments", "value": { "type": 1, "string": "debug" } }
      ]
    },
    "clientAnnotations": { "isEditedByUser": false },
    "isRequired": false
  }
]


___TESTS___

scenarios.forEach((scenario) => {
	test(scenario.name, () => {
		mockData = scenario.mockData;
		runCode(mockData);
	});
});


___NOTES___

Server-side Transformation only — Transformations don't run in web/client
containers, so there's no client-side counterpart of this exact template.

Setup, per client property:
1. Property ID — the Inflight property identifier (see utm-assistant-app).
2. API Key — issued per account from the Inflight dashboard.
3. Cloud Region — MUST match the Cloud Run region this sGTM container runs
   in. See this repo's README for the full label → region-code mapping and
   the handful of labels that had to be disambiguated from the source list
   (flagged there — verify against your actual GTM region picker).

Before first use in a real container: open this template in the GTM
Template Editor and re-verify the Permissions tab against the "Required
permissions" list in the README. The permission JSON in this .tpl was
hand-authored (not exported from the GTM UI) and may not match the exact
schema GTM expects — treat it as a starting point, not a guarantee.

Behavior on any failure (timeout, non-200, bad response body): the
transformation fails open — original utm_ values pass through unmodified,
the event is never blocked or dropped.


___SCENARIOS___

[]
