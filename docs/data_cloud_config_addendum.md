## Real-time news trigger pipeline (added — real-time/streaming extra credit)

Not retrievable via standard Salesforce metadata — Data Cloud-specific
configuration, documented manually.

### Ingestion API Connector
- Name: Live_News_Trigger_Ingestion
- Type: Ingestion API
- Schema: uploaded via OpenAPI (OAS) YAML — see
  `agent-config/live_news_trigger_schema.yaml` in this repo (or regenerate
  from the field list below)
- Object: Live_News_Trigger
- Fields:
  - account_id (Text)
  - headline (Text)
  - trigger_type (Text) — e.g. "funding", "expansion", "leadership_change",
    "product_launch", "partnership"
  - published_timestamp (DateTime)
  - source (Text)

### Data Stream
- Source: Ingestion API — Live_News_Trigger_Ingestion / Live_News_Trigger
- Category: Engagement
- Primary Key: event_key (formula field —
  `CONCAT(sourceField['account_id'], sourceField['published_timestamp'])`)
- Event Time Field: published_timestamp
- Refresh Mode: Upsert
- Data Space: default
- Status: In Use

### Data Model Object
- Name: Live_News_Trigger_DMO (auto-mapped from the DLO, 1:1 field mapping)
- Category: Engagement
- Primary Key: event_key

### External Client App (OAuth — Client Credentials Flow)
- Name: Live_News_Trigger_API_Client
- OAuth Scopes: api, cdp_ingest_api, sfap_api
  (NOTE: cdp_ingest_api + sfap_api alone were NOT sufficient — the plain
  "api" scope was required for the CDP token exchange step to succeed.
  See docs/data_cloud_ingestion_auth_reference.md for the full troubleshooting
  history.)
- Client Credentials Flow: enabled in both App Settings AND the Policies tab
  (both are required — this tripped us up initially)
- Policies: Permitted Users = "Admin approved users are pre-authorized",
  Run As = admin user, System Administrator profile added to Selected Profiles
- Consumer Key/Secret: stored securely outside this repo, never committed

### Flow built on top of the DMO
- Get_Live_News_Trigger — queries Live_News_Trigger_DMO directly via Flow's
  Get Records (Data Cloud Object source), filtered by account_id, sorted by
  published_timestamp descending, first record only. Same "query the DMO
  directly" pattern used for Relationship_Signal_DMO, avoiding the
  Calculated-Insight-in-Flow restriction entirely since this is a DMO, not a CI.

### Verified live test pushes (for demo reference)
- Edge Communications (001gK00001FjoE1QAJ) — "funding" trigger — confirmed
  surfaced in agent response within ~2 minutes of the curl push
- GenePoint (001gK00001FjoEBQAZ) — "partnership" trigger — confirmed surfaced
  correctly, distinct from the account's existing batch news, demonstrating
  the live trigger and batch news coexist without one overwriting the other

### Known quirk
Agent Script's `datetime` type (and manually-typed `date` type) both failed
at runtime for the Flow's DateTime output variable, despite passing the
Problems validator with 0 errors — Preview would fail to load entirely with
"Something went wrong." The working fix was letting Canvas auto-detect the
type by reselecting the Reference Action, after several failed manual type
attempts. Root cause not fully understood — flagged as a platform quirk
worth further investigation, not a resolved root cause.
