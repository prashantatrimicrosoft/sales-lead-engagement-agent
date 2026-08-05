# Data Cloud Ingestion API — Full Auth + Push Sequence (Verified Working)

Prerequisites:
- External Client App created with OAuth scopes: api, cdp_ingest_api, sfap_api
- Client Credentials Flow enabled (both in App Settings AND the Policies tab)
- Policies tab: Permitted Users = "Admin approved users are pre-authorized",
  Run As = your username, System Administrator profile added to Selected Profiles
- Consumer Key + Consumer Secret copied from the app
- Ingestion API connector created, schema uploaded, Data Stream deployed (status: In Use)

Replace these placeholders throughout:
  YOUR_ORG_DOMAIN        e.g. orgfarm-64bdbfd8ec-dev-ed.develop
  YOUR_CONSUMER_KEY
  YOUR_CONSUMER_SECRET
  YOUR_CDP_TENANT_DOMAIN e.g. g0zt9mdfmrtdq9jvgy3t0njsgq.c360a.salesforce.com
  YOUR_CONNECTOR_NAME    e.g. Live_News_Trigger_Ingestion
  YOUR_OBJECT_NAME       e.g. Live_News_Trigger


## Step 1 — Get a core Salesforce access token (Client Credentials Flow)

URL:
  https://YOUR_ORG_DOMAIN.my.salesforce.com/services/oauth2/token

Command:
  curl 'https://YOUR_ORG_DOMAIN.my.salesforce.com/services/oauth2/token' \
    -d 'grant_type=client_credentials' \
    -d 'client_id=YOUR_CONSUMER_KEY' \
    -d 'client_secret=YOUR_CONSUMER_SECRET'

Expect back:
  {
    "access_token": "00Dxx0000...!AQEA...",
    "scope": "api cdp_ingest_api sfap_api",
    "instance_url": "https://YOUR_ORG_DOMAIN.my.salesforce.com",
    "token_type": "Bearer"
  }

Save the access_token value as CORE_TOKEN.

NOTE: the "!" character in this token can trigger zsh history expansion.
Always wrap values in single quotes, or run `set +H` once per terminal session
before using tokens on the command line.


## Step 2 — Exchange the core token for a Data Cloud (CDP) token

URL:
  https://YOUR_ORG_DOMAIN.my.salesforce.com/services/a360/token

Command (use --data-urlencode, not -d, to safely handle special characters
like "!" in the token):
  curl 'https://YOUR_ORG_DOMAIN.my.salesforce.com/services/a360/token' \
    --data-urlencode 'grant_type=urn:salesforce:grant-type:external:cdp' \
    --data-urlencode 'subject_token=CORE_TOKEN' \
    --data-urlencode 'subject_token_type=urn:ietf:params:oauth:token-type:access_token'

Expect back:
  {
    "access_token": "eyJ...",
    "instance_url": "YOUR_CDP_TENANT_DOMAIN",
    "token_type": "Bearer",
    "issued_token_type": "urn:ietf:params:oauth:token-type:jwt",
    "expires_in": 7149
  }

Save the access_token value as CDP_TOKEN.

IMPORTANT: this step fails with "invalid subject token" if the core token's
scope doesn't include the plain "api" scope (Manage user data via APIs) —
cdp_ingest_api and sfap_api alone were NOT sufficient. All three scopes
must be selected on the External Client App.

CDP_TOKEN is short-lived (~2 hours per expires_in). Repeat Steps 1-2 to
refresh it when it expires.


## Step 3 — Push a record via the Ingestion API

URL:
  https://YOUR_CDP_TENANT_DOMAIN/api/v1/ingest/sources/YOUR_CONNECTOR_NAME/YOUR_OBJECT_NAME

Command:
  curl 'https://YOUR_CDP_TENANT_DOMAIN/api/v1/ingest/sources/YOUR_CONNECTOR_NAME/YOUR_OBJECT_NAME' \
    -H 'Authorization: Bearer CDP_TOKEN' \
    -H 'Content-Type: application/json' \
    -d '{
      "data": [
        {
          "account_id": "001gK00001FjoE1QAJ",
          "headline": "Edge Communications announces new funding round",
          "trigger_type": "funding",
          "published_timestamp": "2026-08-04T20:00:00Z",
          "source": "simulated_news_monitor"
        }
      ]
    }'

Expect back:
  HTTP/2 202
  {"accepted": true}

Add -v to any of the three commands above to see full request/response
headers if something fails and you need to debug it (e.g., wrong domain,
malformed payload, expired token).


## Verify the record landed

Data Cloud → Data Explorer → Data Lake Object → search for YOUR_OBJECT_NAME.
Allow 1-2 minutes after a successful 202 response before checking — streaming
ingestion is fast but not instantaneous.


## Quick troubleshooting reference

| Error                                  | Cause                                              | Fix                                                            |
|-----------------------------------------|-----------------------------------------------------|-----------------------------------------------------------------|
| unsupported_grant_type                  | Client Credentials Flow not enabled/propagated       | Check both App Settings AND Policies tab; wait a few minutes    |
| invalid_app_access                      | Run As user not pre-authorized                       | Add their Profile/Permission Set under Selected Profiles         |
| invalid_request / invalid subject token  | Core token missing the "api" scope                    | Add "Manage user data via APIs (api)" scope, get a fresh token   |
| Empty 400 with no body                  | Wrong token type used against Ingestion API endpoint  | Confirm you're using CDP_TOKEN (Step 2 output), not CORE_TOKEN   |
| zsh: event not found                     | "!" in token triggering history expansion             | Use single quotes, or run `set +H` for the terminal session      |
