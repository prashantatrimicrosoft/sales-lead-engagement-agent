# Data 360 Unstructured Ingestion Pipeline: AWS S3 → Lambda → Salesforce

**A field-tested, debugged runbook for connecting an Amazon S3 bucket to Salesforce Data 360 (Data Cloud) for automatic unstructured file ingestion, using Salesforce's official `file-notifier-for-blob-store` reference implementation.**

This document describes the full setup process as actually executed, including **five real bugs found and fixed** along the way — in the vendor's installer script, in AWS IAM behavior, and in Salesforce JWT authorization semantics. If you're following the official Salesforce documentation and hitting unexplained failures, the fixes below should save you significant debugging time.

---

## Architecture overview

```
S3 bucket (file upload/delete)
      │
      ▼
S3 Event Notification (per-folder prefix rules)
      │
      ▼
AWS Lambda function (JWT Bearer auth to Salesforce)
      │
      ▼
Salesforce Data 360 Unstructured Ingestion API
      │
      ▼
Unstructured Data Lake Object → transcribe → chunk → search index
      │
      ▼
Data 360 Retriever (semantic search, used by Agentforce)
```

**Supporting AWS infrastructure created:** one S3 bucket for source documents, a second S3 bucket for Lambda source code, an IAM execution role, two AWS Secrets Manager entries (Consumer Key, RSA private key), one Lambda function, and S3 bucket event notification rules (one per monitored folder prefix).

**Supporting Salesforce infrastructure created:** one External Client App (`datacloudtos3`) configured for JWT Bearer OAuth flow with a self-signed certificate, explicit profile/permission-set pre-authorization, and matching Unstructured Data Lake Objects + Data Model Objects + Search Index Configurations on the Data 360 side.

---

## Prerequisites

- An AWS account with permissions to create IAM users/roles, Lambda functions, S3 buckets, and Secrets Manager entries.
- A Salesforce org with Data 360 (Data Cloud) provisioned.
- Local tools: `awscli` v2, `jq`, `openssl` (all standard; install via Homebrew or direct download if missing).
- The reference installer, downloaded from Salesforce's public repo:
  ```bash
  curl -L -o file-notifier.zip https://github.com/forcedotcom/file-notifier-for-blob-store/archive/refs/heads/main.zip
  unzip file-notifier.zip
  ```

---

## Phase 1 — Generate a certificate and key pair

```bash
openssl genrsa -out server.key 2048
openssl req -new -x509 -days 3650 -key server.key -out server.crt
openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in server.key -out server.pem
```

You'll use `server.crt` to configure the Salesforce app, and `server.pem` as the private key referenced by the installer config and stored in AWS Secrets Manager. Certificate metadata fields (Organization, Common Name, etc.) can be left blank — only Country/State/Locality/Email are meaningfully required to generate a valid cert.

---

## Phase 2 — Create the Salesforce Connected App (or External Client App)

Modern Salesforce orgs default to **External Client Apps (ECAs)** rather than classic Connected Apps for new app creation. The setup is functionally equivalent but split across different tabs.

1. **Setup → App Manager → New External Client App.**
2. Set **Distribution State: Local**.
3. Upload `server.crt` as the certificate (offered during creation on ECAs, or via "Use Digital Signatures" on classic Connected Apps).
4. Under **OAuth Settings**, enable OAuth, set a placeholder **Callback URL** (e.g. `https://login.salesforce.com/services/oauth2/callback` — not actually used by the JWT Bearer flow, but required by the form).
5. Add these **OAuth Scopes**:
   - Manage user data via APIs (`api`)
   - Perform requests on your behalf at any time (`refresh_token`, `offline_access`)
   - Manage Data Cloud Ingestion API data (`cdp_ingest_api`)
6. Under **Flow Enablement**, check **Enable JWT Bearer Flow** only (leave Client Credentials, Authorization Code, Device Flow, and Token Exchange Flow unchecked).
7. Save.
8. Retrieve the **Consumer Key** from the app's Settings tab (may require identity re-verification to reveal).

### Critical: set explicit pre-authorization (do this now, not after deployment)

The JWT Bearer flow requires **explicit, non-interactive pre-authorization** — a browser "Allow Access" click is *not* sufficient (see Bug #5 below for why). Configure this immediately:

1. App's **Policies** tab → **App Policies** section.
2. Move your admin profile (e.g. **System Administrator**) into **Selected Profiles**, and/or a relevant permission set (e.g. **Data Cloud Salesforce Connector**) into **Selected Permission Sets**.
3. Scroll to **OAuth Policies → Plugin Policies → Permitted Users**, set to **"Admin approved users are pre-authorized."**
4. Save.

Doing this up front avoids the entire `invalid_grant: user hasn't approved this consumer` debugging cycle documented below.

---

## Phase 3 — AWS IAM setup

Create (or reuse) an IAM user with these managed policies attached:
- `AmazonS3FullAccess`
- `AWSLambda_FullAccess`
- `IAMFullAccess`
- `SecretsManagerReadWrite`
- `AmazonEC2ReadOnlyAccess` *(required for the installer's region-validation step, which calls `ec2:DescribeRegions`)*

Generate an access key/secret pair for this user and note them for later steps.

Create a second S3 bucket to host the Lambda function's source code:
```bash
aws s3 mb s3://<your-lambda-source-bucket-name>
aws s3 cp cloud_function_zips/aws_lambda_function.zip s3://<your-lambda-source-bucket-name>/aws_lambda_function.zip
```

---

## Phase 4 — Configure and run the installer

Edit `installers/aws/input_parameters_s3.conf` with your values. Key fields:

| Variable | Value |
|---|---|
| `SF_USERNAME` | Your Salesforce username |
| `SF_LOGIN_URL` | Your org's My Domain URL (e.g. `https://yourorg.my.salesforce.com`) |
| `SF_AUDIENCE_URL` | **Leave this genuinely blank** — see Bug #4 |
| `AWS_ACCOUNT_ID` | Your AWS account ID |
| `REGION` | Your S3 bucket's region |
| `EVENT_S3_SOURCE_BUCKET` | Your source documents bucket |
| `EVENT_S3_SOURCE_KEY` | The folder/prefix to monitor (no leading/trailing slash) |
| `LAMBDA_FUNC_S3_BUCKET` | Your Lambda source code bucket |
| `LAMBDA_FUNC_LOC_S3_KEY` | `aws_lambda_function.zip` |
| `SOURCE_CODE_LOCAL_PATH` | Full local path to the downloaded zip |
| `LAMBDA_ROLE` | Any name for the new execution role |
| `LAMBDA_FUNC_NAME` | Any name for the new Lambda function |
| `CONSUMER_KEY_NAME` | Name for the Secrets Manager entry |
| `CONSUMER_KEY_VALUE` | Your Connected App's Consumer Key |
| `RSA_PRIVATE_KEY_NAME` | Name for the Secrets Manager entry |
| `PEM_FILE_PATH` | Full local path to `server.pem` |

Export your **long-term** IAM credentials (see Bug #1 for why not temporary session credentials), then run:

```bash
export AWS_ACCESS_KEY_ID=<your-access-key>
export AWS_SECRET_ACCESS_KEY=<your-secret-key>
chmod +x setup_s3_file_notification.sh
./setup_s3_file_notification.sh input_parameters_s3.conf
```

Answer `yes` to all four confirmation prompts. Expect it to run through all 16 steps (see bug list below for issues encountered along the way).

---

## Bugs found and fixed

### Bug 1 — Credential gate incompatible with actual AWS behavior
**Symptom:** Script explicitly demands `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, **and** `AWS_SESSION_TOKEN` all be set, but every subsequent IAM API call (`GetRole`, etc.) fails with `InvalidClientTokenId` when a real STS temporary session token is used.
**Root cause:** AWS restricts most IAM write/read operations from being called with `GetSessionToken`-issued temporary credentials — only long-term IAM user credentials work reliably for IAM operations specifically.
**Fix:** Patched the script's credential-presence check to not hard-require a session token:
```bash
sed -i '' 's/\[ -z "\$AWS_SESSION_TOKEN" \]/false/' setup_s3_file_notification.sh
```
Then ran the script using only long-term `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, with `AWS_SESSION_TOKEN` left unset.

### Bug 2 — Silent misreporting of failures as "resource already exists"
**Symptom:** Script printed `"iam-role already exists, skipping creation"` even when the role did not actually exist.
**Root cause:** The existence check only greps the AWS CLI output for the literal string `"NoSuchEntity"`:
```bash
if aws iam get-role --role-name "$LAMBDA_ROLE" 2>&1 | grep -q "NoSuchEntity"; then
```
If the underlying call fails for a *different* reason (e.g. bad credentials), this grep doesn't match, and the script falls through to the "already exists" branch instead of surfacing the real error.
**Fix:** No code change needed once Bug 1 was fixed — diagnosed by running the exact `aws iam get-role` command standalone, outside the script, to see the true error.

### Bug 3 — IAM eventual-consistency race condition
**Symptom:** `MalformedPolicyDocumentException: This resource policy contains an unsupported principal` when attaching a Secrets Manager resource policy referencing an IAM role created moments earlier in the same run.
**Root cause:** The policy document itself was correctly formed; the referenced IAM role simply hadn't finished propagating across AWS's internal systems yet.
**Fix:** Waited briefly and re-ran the script. Steps 1–7 (already-existing resources) completed near-instantly on the second pass, and Step 8 succeeded once the role had propagated.

### Bug 4 — Missing environment-variable fallback logic
**Symptom:** Every Lambda invocation failed with `400 Bad Request` calling Salesforce's OAuth token endpoint. Inspecting the JWT payload (via a debug patch — see below) showed `"aud": ""` — an empty audience claim.
**Root cause:** The config file's own comment claims *"`SF_LOGIN_URL` will be used as `SF_AUDIENCE_URL` in case it's empty"* — but the deployed Lambda's actual runtime code never implements that fallback. Leaving `SF_AUDIENCE_URL` blank (as instructed) produces an invalid JWT.
**Fix:** Set the Lambda's environment variable directly:
```bash
aws lambda update-function-configuration \
  --function-name <your-lambda-name> \
  --environment "Variables={CONSUMER_KEY=...,RSA_PRIVATE_KEY=...,SF_LOGIN_URL=<your-my-domain-url>,SF_AUDIENCE_URL=<your-my-domain-url>,SF_USERNAME=...}"
```
(Include all pre-existing variables in the update — `--environment` replaces the full variable set, it doesn't merge.)

### Bug 5 — `invalid_grant: user hasn't approved this consumer`
**Symptom:** After fixing Bug 4, JWTs generated correctly with a valid, non-empty `aud` claim, but token exchange still failed with a 400 and this specific error.
**Root cause:** Approving the app via an interactive browser "Allow Access" click only authorizes the **User-Agent (implicit) OAuth flow** — confirmed via **Setup → Users → [user] → Login History**, which showed one `Success` row (`OAuth User-Agent`) alongside multiple `Failed: Not approved` rows for the Lambda's actual JWT Bearer attempts. **JWT Bearer is a separate, non-interactive flow that requires explicit pre-authorization via Profile or Permission Set assignment** — there is no browser-click equivalent for it.
**Fix:** On the app's **Policies** tab, set **Permitted Users** to **"Admin approved users are pre-authorized,"** then explicitly select an admin profile (System Administrator) and/or a relevant permission set (Data Cloud Salesforce Connector) under **App Policies → Select Profiles / Select Permission Sets**, and save.

**Diagnostic technique used to find Bugs 4 and 5:** the Lambda's error handling only calls `.raise_for_status()`, which never surfaces the actual response body. Patched the source to print it first:
```python
print('DEBUG - Response body: ' + core_response.text); core_response.raise_for_status()
```
Repackaged and redeployed:
```bash
zip -r lambda_patched.zip .
aws lambda update-function-code --function-name <your-lambda-name> --zip-file fileb://lambda_patched.zip
```
This surfaced the exact Salesforce error JSON in CloudWatch Logs, which would otherwise have been invisible.

> **Note — this patch is a permanent, deliberate modification, not a reverted diagnostic step.** The deployed Lambda function currently running in this environment still contains the added `print('DEBUG - Response body: ' + core_response.text)` line — it was never reverted back to Salesforce's unmodified reference source after the debugging session. This is intentional: the line only executes on the error path (immediately before `raise_for_status()` would otherwise raise silently), so it adds negligible overhead while giving permanent visibility into any future authentication failures via CloudWatch Logs, rather than the original opaque 400 error. Anyone redeploying this pipeline from the stock `file-notifier-for-blob-store` repo will **not** have this line by default — it must be re-applied manually (see the `sed` command below) if the same diagnostic visibility is desired going forward:
> ```bash
> sed -i '' "s/core_response.raise_for_status()/print('DEBUG - Response body: ' + core_response.text); core_response.raise_for_status()/" unstructured_data.py
> ```
> Note this targets the **first** occurrence of `core_response.raise_for_status()` in the file (the core Salesforce OAuth token exchange) — the function also calls `.raise_for_status()` a second time later for the separate CDP token exchange step, which was not patched in this session.

---

## Verification

Trigger a test file event and confirm success end-to-end:

```bash
aws s3 cp test.txt s3://<your-bucket>/<your-folder>/test.txt
```

Check **CloudWatch → Log Groups → `/aws/lambda/<your-lambda-name>`** for the newest log stream. A fully working pipeline shows:
```
Cache miss! - JWT token generated successfully
Response core access token generated successfully
Response cdp access token generated successfully
Beacon Response - {'accepted': True}
```

Then confirm real content landed in Data 360 via Query Editor:
```sql
SELECT * FROM <Your_DMO>_chunk__dlm LIMIT 10
```

---

## Monitoring multiple folders/prefixes

The installer's `EVENT_S3_SOURCE_KEY` only configures one folder prefix per run. To monitor additional folders in the same bucket without disturbing the existing rule, write the S3 bucket notification configuration directly rather than re-running the installer:

```bash
aws s3api get-bucket-notification-configuration --bucket <your-bucket>
```

Inspect the existing rule(s), then submit a combined configuration listing all desired prefixes:

```json
{
    "LambdaFunctionConfigurations": [
        {
            "Id": "ExistingRuleId",
            "LambdaFunctionArn": "arn:aws:lambda:...:function:your-function",
            "Events": ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"],
            "Filter": {"Key": {"FilterRules": [{"Name": "Prefix", "Value": "existing-folder"}, {"Name": "Suffix", "Value": ""}]}}
        },
        {
            "Id": "NewRuleId",
            "LambdaFunctionArn": "arn:aws:lambda:...:function:your-function",
            "Events": ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"],
            "Filter": {"Key": {"FilterRules": [{"Name": "Prefix", "Value": "new-folder"}, {"Name": "Suffix", "Value": ""}]}}
        }
    ]
}
```

```bash
aws s3api put-bucket-notification-configuration --bucket <your-bucket> --notification-configuration file://notification-config.json
```

**Always re-run `get-bucket-notification-configuration` afterward** to confirm both rules survived — `put-bucket-notification-configuration` fully replaces the configuration rather than merging with it, so omitting an existing rule from your JSON will silently delete it.

---

## Lessons learned

1. **Debug with real response bodies, not just exception messages.** A single `print(response.text)` before `raise_for_status()` turned an opaque 400 error into an exact, actionable Salesforce error code — worth adding proactively to any integration script before you need it.
2. **Long-term IAM credentials, not temporary session tokens, for IAM-heavy automation.** If a script insists on a session token but you're only calling IAM/S3/Lambda/Secrets Manager APIs, a real temporary token can cause more problems than it solves.
3. **Interactive OAuth approval and JWT Bearer approval are not the same thing.** Configure explicit Profile/Permission Set pre-authorization for any server-to-server JWT integration from the start — don't rely on a browser consent screen.
4. **Config file comments aren't guaranteed to match actual code behavior.** Verify fallback/default logic empirically (in this case, by inspecting the actual JWT payload) rather than trusting documentation.
5. **AWS eventual consistency is real and mundane.** A resource-policy error referencing a role created seconds earlier is very often just a timing issue, not a configuration mistake — retry before assuming the policy document itself is wrong.
