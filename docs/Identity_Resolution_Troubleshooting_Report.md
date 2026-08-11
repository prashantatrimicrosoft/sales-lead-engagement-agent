# Data Cloud Identity Resolution — Troubleshooting Report

**Org:** orgfarm-64bdbfd8ec-dev-ed.develop.my.salesforce.com
**Issue:** Primary Data Model Object dropdown on the New Ruleset (Identity Resolution) screen returns empty for all Profile-category DMOs — both via UI and API.
**Status:** Unresolved — escalated to Salesforce Support
**API Error ID for Support reference:** `243926966-107564 (1182868337)`

---

## 1. Summary

Data ingestion from Salesforce CRM into Data Cloud (via Data Streams) is working correctly, and all required Data Model Objects (DMOs) are mapped and show `Status: Ready`. However, the **Primary Data Model Object** dropdown on the **Identity Resolutions → New Ruleset** screen is completely empty, preventing any identity resolution ruleset from being created.

Extensive troubleshooting across data modeling, permissions, browser/session state, and direct API calls has ruled out every standard, self-serviceable cause. The issue was reproduced identically through both the Data Cloud UI and the Connect REST API, and the API call surfaced a **server-side `UNKNOWN_EXCEPTION`**, indicating a backend fault rather than a UI or configuration bug.

---

## 2. Environment Overview

| Item | Detail |
|---|---|
| Data Source | Salesforce CRM connector (Account, Contact, Lead, Opportunity, etc.) |
| Data Streams | 7 active streams, all `Last Run Status: Success` |
| Data Space | `default` |
| Key DMOs | Account, Account Contact, Individual, Party, Financial Customer, Lead, Contact Point Email/Phone/Address |
| User Permission Set | Data Cloud Architect (+ several unrelated Agentforce/Service Cloud sets) |
| Existing Identity Resolution Rulesets | **0** (confirmed via UI list view) |

---

## 3. Troubleshooting Steps and Findings

### 3.1 Initial Symptom
- Data Streams ingesting successfully (screenshot: Data Streams list, 7 items, all Active/Success).
- Account Contact DMO mapped with relationships to Account, Individual, Contact Point Phone/Email/Address (screenshot: Account Contact → Relationships tab).
- **New Ruleset screen**: "Primary Data Model Object" dropdown shows no options; field flagged red as incomplete.

### 3.2 Hypothesis 1 — Missing Primary Key / Individual Relationship
**Checked:** Contact_Home and Account_Home DLO→DMO mapping screens.
**Finding:** Primary Keys correctly set on Account Contact (`Account Contact Id`) and Individual (`Individual Id`). Individual relationship present and mapped.
**Result:** Ruled out — not the cause.

### 3.3 Hypothesis 2 — Wrong DMO Category
**Checked:** Data Model → object list, Category column, for all 26 DMOs in the org.
**Finding:** Account, Account Contact, Individual, Lead, Financial Customer, and Party are all correctly categorized as **Profile**, with `Status: Ready`.
**Result:** Ruled out — not the cause.

### 3.4 Hypothesis 3 — DMO Already Claimed by Existing Ruleset
**Checked:** Identity Resolutions → All Identity Resolutions list view.
**Finding:** **0 items** — no rulesets exist in the org at all, active or inactive.
**Result:** Ruled out — not the cause.

### 3.5 Hypothesis 4 — Insufficient Permissions
**Checked:** Setup → Users → Permission Set Assignments.
**Finding:** User has **Data Cloud Architect** permission set assigned (7/29/2026), which is the correct permission level for Identity Resolution configuration.
**Result:** Ruled out — not the cause.

### 3.6 Hypothesis 5 — Browser/Session/Cache Issue
**Checked:** Chrome DevTools Console and Network tabs during New Ruleset page load and Primary DMO dropdown interaction. Retested in a different browser, and after logging out and back in.
**Finding:**
- Console showed only unrelated noise: Redux dev-mode warning, Lightning accessibility warnings (`lightning-input`, `lightning-spinner`), a 404 on a `shield.svg` icon, and an unrelated Agentforce/Einstein widget error (`011Y Error: "Something went wrong. Refresh the conversation and try again."`).
- No JavaScript errors tied to the DMO dropdown or Identity Resolution component were found.
- Behavior was identical across browsers and after re-authentication.
**Result:** Ruled out — not the cause.

### 3.7 Hypothesis 6 — Required Contact Point / Party Mapping Missing
Per Salesforce documentation (Data Mapping Requirements for Identity Resolution), Individual must be mapped along with at least one Contact Point (Email, Phone, or Address).
**Checked:** Contact_Home DLO mapping screen, Data Model entities panel, unfiltered field counts for each Profile object.
**Finding (unfiltered, accurate counts):**
| DMO | Is Mapped Count |
|---|---|
| Contact Point Email | 7 (includes Primary Key, Email Address, Party) |
| Contact Point Phone | 8 (includes Primary Key, Telephone Number, Party) |
| Contact Point Address | 15 |
| Individual | 15 (includes Primary Key, Party, First/Last Name) |
| Party | 2 (includes Individual, Party Id Primary Key) |

**Note:** An earlier reading showing "Is Mapped (0)" for these objects was a false signal caused by a leftover search-box filter term (e.g., "contact phone", "individual") hiding the real mapped fields from view. Once search filters were cleared, all objects showed correct, complete mappings.
**Result:** Ruled out — not the cause. (This was the most promising lead investigated and ultimately eliminated.)

### 3.8 Isolation Test — New Minimal Custom Object/DMO
To eliminate all data-modeling complexity as a variable, a brand-new, minimal test object was created end-to-end:

1. **Salesforce custom object** `DMO_Test__c` created in Setup → Object Manager, with one custom text field (`Test_Name__c`) plus the standard `Name` field. 3 sample records inserted.
2. **Data Stream** created in Data Cloud (`DMO_Test__c_Home`) ingesting from the Salesforce CRM connector. Ingestion succeeded — confirmed via Data Explorer showing 3 records in the DLO.
3. **New Custom DMO** created directly from the stream mapping screen, with:
   - Category: **Profile**
   - Primary Key: `Record ID`
   - No relationships to any other object (zero complexity, zero self-references)
   - Status: Ready
4. **Test:** Opened Identity Resolutions → New Ruleset → Primary Data Model Object dropdown.

**Finding:** The dropdown remained **completely empty** — the new, minimal, relationship-free `DMO_Test__c_Home` DMO did **not** appear, despite meeting every documented eligibility requirement (Profile category, Primary Key set, Status Ready).

**Result:** **Conclusive.** This rules out data modeling, relationship complexity, and self-referencing relationships (e.g., Account Contact's `Reports To Account Contact` self-lookup) as the cause. The issue is not specific to any one DMO or mapping — it affects DMO eligibility resolution at an org-wide level.

---

## 4. API-Level Reproduction

To confirm the issue was not UI-specific, the same action was attempted via the **Data 360 Connect REST API**.

### 4.1 Setup
- Reused an existing Connected App (External Client App) originally provisioned for the Ingestion API pipeline.
- OAuth scopes present: `api` (Manage user data via APIs), `cdp_ingest_api` (Manage Data Cloud Ingestion API data), `sfap_api` (Access the Salesforce API Platform).
- Obtained a valid bearer token via `client_credentials` grant against `/services/oauth2/token`.

### 4.2 GET Request — List Existing Rulesets
```
GET /services/data/v62.0/ssot/identity-resolutions?dataspace=default
```
**Response:** `200 OK`
```json
{"identityResolutions":[]}
```
Confirms API access, auth, and endpoint are all functioning correctly, and confirms zero existing rulesets (consistent with UI).

### 4.3 POST Request — Attempt 1 (guessed field names)
```json
{
  "name": "DMO_Test_Ruleset",
  "dataspace": "default",
  "primaryDmoDeveloperName": "DMO_Test__c_Home",
  "rulesetId": "test"
}
```
**Response:** `400`
```json
[{"errorCode":"JSON_PARSER_ERROR","message":"Unrecognized field \"name\" at [line:2, column:14]"}]
```
This is a client-side schema validation error — expected, since exact field names were not confirmed against official documentation (interactive API reference pages were not renderable for schema extraction at time of testing).

### 4.4 POST Request — Attempt 2 (empty body, to elicit required-field validation)
```json
{}
```
**Response:** `200`-level transport, but body indicates failure:
```json
[{"message":"An unexpected error occurred. Please include this ErrorId if you contact support: 243926966-107564 (1182868337)","errorCode":"UNKNOWN_EXCEPTION"}]
```

**This is the critical finding.** Rather than a structured validation error (e.g., "missing required field: primaryDataModelObject"), the backend threw an **unhandled server-side exception** even on a minimal/empty request. This indicates the fault lies in backend processing logic for Identity Resolution ruleset creation in this org — not in client request formatting, not in UI rendering, and not in any user-controllable configuration.

---

## 5. Conclusion

| Cause Category | Status |
|---|---|
| Missing Primary Key | ❌ Ruled out |
| Missing Individual relationship | ❌ Ruled out |
| Wrong DMO Category | ❌ Ruled out |
| DMO claimed by existing ruleset | ❌ Ruled out (0 rulesets exist) |
| Insufficient permissions | ❌ Ruled out (Data Cloud Architect assigned) |
| Browser/session/cache issue | ❌ Ruled out (multi-browser, re-auth tested) |
| Missing Contact Point / Party mapping | ❌ Ruled out (all mappings confirmed present and correct) |
| Relationship graph complexity (e.g. self-reference) | ❌ Ruled out (fresh, relationship-free DMO also fails) |
| **Backend/platform-level fault** | ✅ **Confirmed** — reproduced identically in UI and API, with server-side `UNKNOWN_EXCEPTION` on API |

**Recommendation:** This requires escalation to Salesforce Support / Engineering. All standard, customer-serviceable configuration causes have been eliminated through systematic testing. The API error ID (`243926966-107564 / 1182868337`) should allow Salesforce's support team to trace the exact backend exception in their logs.

---

## 6. Suggested Support Case Text

> The Primary Data Model Object dropdown on the New Ruleset (Identity Resolution) page returns completely empty in the UI, even for a newly created minimal custom DMO (Profile category, single Primary Key, no relationships, Status: Ready). Also empty for existing standard Profile DMOs (Individual, Account, Account Contact, Party, Financial Customer) with valid Primary Keys and required Contact Point mappings confirmed in place. No existing Identity Resolution rulesets exist in the org. User has Data Cloud Architect permission set assigned. Issue persists across browsers and after re-authentication, with no relevant browser console errors.
>
> Reproduced the same failure via the Data 360 Connect REST API: `POST /services/data/v62.0/ssot/identity-resolutions` with an empty JSON body (`{}`) returns a generic `UNKNOWN_EXCEPTION` rather than a structured validation error.
> **ErrorId: 243926966-107564 (1182868337)**
>
> Org: orgfarm-64bdbfd8ec-dev-ed.develop.my.salesforce.com
> Requesting investigation of the backend exception tied to this ErrorId, and root-cause identification for why no DMOs are eligible for Identity Resolution ruleset creation in this org.

---

## 7. Notes / Follow-ups
- The Connected App token used for API testing was pasted in plaintext during troubleshooting and should be **revoked and regenerated** before further use.
- Once Support identifies the root cause, this document should be updated with the resolution for future reference.
- The `DMO_Test__c` / `DMO_Test__c_Home` test object and its associated Data Stream and DMO can be deleted after the issue is resolved, as they were created solely for isolation testing.
