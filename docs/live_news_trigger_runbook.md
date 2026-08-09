# Live News Trigger — Full Build Runbook (Ingestion API → Agent)

Consolidated, correct-path sequence. This took many debugging iterations to
discover; this document skips the dead ends and gives only what actually
worked.

---

## Phase 1 — Data Cloud: Ingestion API Connector

1. **Data Cloud → More → Ingestion API** (or wherever it's surfaced in your
   org's nav)
2. Click **New** (or "Connect an Ingestion API Source")
3. **Connector Name:** `Live_News_Trigger_Ingestion`
4. Click **Save**, then **Connect**
5. Status will show **"Schema Required"**

## Phase 2 — Upload the Schema

1. Build an OpenAPI (OAS) YAML file defining the object and fields:
   ```yaml
   openapi: 3.0.3
   info:
     title: Live News Trigger Schema
     version: 1.0.0
   components:
     schemas:
       Live_News_Trigger:
         type: object
         properties:
           account_id:
             type: string
           headline:
             type: string
           trigger_type:
             type: string
           published_timestamp:
             type: string
             format: date-time
           source:
             type: string
   ```
2. On the connector's detail page, click **Upload Files** under Schema,
   select this YAML
3. Confirm the field list appears with correct types (account_id: Text,
   headline: Text, trigger_type: Text, published_timestamp: DateTime,
   source: Text)
4. Status changes to **"Needs Data Stream"**

## Phase 3 — Create the Data Stream

1. **Data Cloud → Data Streams → New**
2. **Source:** Ingestion API
3. **Connector:** `Live_News_Trigger_Ingestion`
4. **Object:** `Live_News_Trigger`
5. Click **Next** to reach object configuration
6. **Category:** Engagement (this is time-stamped event data)
7. **Primary Key:** none of the raw fields are unique alone — click
   **New Formula Field**, create one:
   - Formula: `CONCAT(sourceField['account_id'], sourceField['published_timestamp'])`
   - Name it `event_key`
   - Set this as the Primary Key
8. **Event Time Field:** `published_timestamp`
9. Skip the optional row-level filter screen (click Back/skip — you want
   all records to flow through unfiltered)
10. **Refresh Mode:** Upsert
11. **Data Space:** default
12. **Deploy**
13. Confirm the connector status back on the Ingestion API page now shows
    **"In Use"**

## Phase 4 — Map the DLO to a DMO

Calculated Insight objects are blocked from Flow's Get Records, but Data
Model Objects are not — this step is what makes the data queryable later.

1. Find the new Data Lake Object (search Data Explorer or navigate from the
   Data Stream) — it will have an auto-generated name like
   `Live_News_Trigger_Ingestion-Live_News_Tr`. Ignore the sibling
   `PR_...` object (that's the auto-generated Problem Records object, not
   your data).
2. Click into it → **Create Data Model Object** (or similar mapping action)
3. **DMO Target:** New Data Model Object
4. **Object Label:** `Live_News_Trigger_DMO`
5. **Category:** Engagement (match the Data Stream)
6. Confirm all 6 fields (including `event_key` as Primary Key) auto-mapped
   correctly
7. **Save**

## Phase 5 — Build the Flow

1. **New Flow → Autolaunched Flow (No Trigger)**
2. New Resource → Variable: `AccountId` (Text, Available for input)
3. **Get Records** element:
   - **Data Source:** Data Cloud Object (not Salesforce Object — this is a
     DMO)
   - **Object:** `Live_News_Trigger_DMO`
   - **Filter:** `account_id` Equals `{!AccountId}`
   - **Sort:** `published_timestamp` Descending
   - **How many:** Only the first record
   - **Store:** Choose fields and assign variables (advanced) → map
     `headline` → `varTriggerHeadline` (Text), `trigger_type` →
     `varTriggerType` (Text)
   - For the timestamp field specifically: **known platform quirk** — hand-
     typing either `date` or `datetime` for this output broke Agentforce
     Preview entirely with no useful error. The working fix was deleting
     the field from the action's Script view entirely, then reselecting the
     Flow as Reference Action in Canvas view to force it to auto-detect the
     type fresh. Expect to need this same recovery step if you hit
     "Something went wrong" after adding a DateTime output.
4. **Flow Properties → Advanced → How to Run the Flow:** System Context
   Without Sharing — Access All Data (required; without this, the action
   fails with `UNKNOWN_EXCEPTION` when called from Agentforce, even though
   manual Debug runs succeed)
5. Save as `Get_Live_News_Trigger`, **Activate**
6. **Debug test:** run with a real AccountId, confirm it returns real data

## Phase 6 — Build the Agentforce Action

1. In your Research Agent (or wherever this belongs), add a new action via
   Canvas, selecting the Flow as Reference Action
2. Let Canvas auto-populate Inputs/Outputs from the Flow
3. Fill in label, description, and descriptions on each input/output
4. If any output shows type `Object` instead of the expected type, this is
   the same quirk from Phase 5 — try reselecting the Reference Action to
   force a fresh re-read

## Phase 7 — Set Up OAuth (Client Credentials Flow)

1. **Setup → App Manager → New External Client App**
2. Fill in name, contact email, **Distribution State: Local**
3. Enable OAuth Settings, Callback URL: `https://localhost.com`
4. **OAuth Scopes — select all three:**
   - Manage user data via APIs (`api`)
   - Manage Data Cloud Ingestion API data (`cdp_ingest_api`)
   - Access the Salesforce API Platform (`sfap_api`)
   - (The plain `api` scope is easy to miss but is required for the later
     CDP token exchange step — `cdp_ingest_api` + `sfap_api` alone are NOT
     sufficient)
5. Check **Enable Client Credentials Flow** in this screen
6. Create the app
7. Go to the app's **Policies** tab:
   - Check **Enable Client Credentials Flow** here too (it must be set in
     both places)
   - **Permitted Users:** Admin approved users are pre-authorized
   - **Run As (Username):** your admin username
   - Under **Select Profiles**, move **System Administrator** into
     Selected Profiles
   - Save
8. Get Consumer Key and Secret from **Manage Consumer Details** on the
   app's main page (requires email verification code)

## Phase 8 — Get Tokens and Test the Push

Full working curl sequence (see `docs/data_cloud_ingestion_auth_reference.md`
for the complete version with troubleshooting table):

```bash
# Step 1: core token
curl 'https://YOUR_ORG.my.salesforce.com/services/oauth2/token' \
  -d 'grant_type=client_credentials' \
  -d 'client_id=YOUR_CONSUMER_KEY' \
  -d 'client_secret=YOUR_CONSUMER_SECRET'

# Step 2: exchange for CDP token (use --data-urlencode, not -d,
# to safely handle the "!" character in the token)
curl 'https://YOUR_ORG.my.salesforce.com/services/a360/token' \
  --data-urlencode 'grant_type=urn:salesforce:grant-type:external:cdp' \
  --data-urlencode 'subject_token=CORE_TOKEN_FROM_STEP_1' \
  --data-urlencode 'subject_token_type=urn:ietf:params:oauth:token-type:access_token'

# Step 3: push
curl 'https://YOUR_CDP_TENANT.c360a.salesforce.com/api/v1/ingest/sources/Live_News_Trigger_Ingestion/Live_News_Trigger' \
  -H 'Authorization: Bearer CDP_TOKEN_FROM_STEP_2' \
  -H 'Content-Type: application/json' \
  -d '{"data": [{"account_id": "REAL_ID", "headline": "...", "trigger_type": "funding", "published_timestamp": "2026-08-05T04:30:00Z", "source": "simulated_news_monitor"}]}'
```

Expect `HTTP 202` and `{"accepted": true}` on success.

## Phase 9 — Verify and Wire Into the Agent

1. Wait ~1-2 minutes
2. **Data Cloud → Data Explorer → Data Lake Object → search
   `Live_News_Trigger`** — confirm the record landed
3. Add the new action to Research Agent's reasoning instructions (as a step
   between account resolution and case study search), and to Outreach
   Agent's formatting instructions (a "Live Trigger Alert" section)
4. Test end to end: **"Research [account name] for me"** — confirm the
   Live Trigger Alert section shows the pushed record

## Phase 10 — Automate for Demo Day

Use `push_live_trigger.sh` (see repo root) to chain all of Phase 8's steps
into a single command with no manual token copy-pasting:

```bash
export SF_ORG_DOMAIN="your-org-domain"
export SF_CONSUMER_KEY="..."
export SF_CONSUMER_SECRET="..."
export SF_CDP_TENANT_DOMAIN="your-tenant.c360a.salesforce.com"

./push_live_trigger.sh 001gK00001FjoE1QAJ "Custom headline" funding
```
