# Zero-Copy Data Federation: Snowflake → Salesforce Data Cloud (Data360)

## What this demonstrates

A real, working Zero-Copy integration extending the Sales Lead Engagement
Agent with a genuinely new signal type — **equipment telemetry data that
lives in Snowflake and stays there.** Nothing is copied, duplicated, or
ETL'd into Salesforce. Data Cloud queries Snowflake live, on demand.

This isn't a conceptual diagram — every step below was built and
independently verified, including five real debugging hypotheses tested in
order until the actual root cause was found, and a data-persistence
regression that was caught and fixed rather than assumed away.

---

## Why this specific data, and why Snowflake

The Sales Lead Engagement Agent sells backup power and generator systems.
Existing customers already have physical units installed at their
facilities — equipment that reports operational telemetry (runtime hours,
fuel level, fault codes, maintenance schedules). This is exactly the kind
of data that belongs in a data warehouse, not a CRM: high-volume,
operational, and never something you'd want duplicated into Salesforce's
own database just to reference occasionally.

This also gives the agent a genuinely new capability it didn't have
before: **equipment health as a "Why Now" signal**, distinct from and
additive to the news/relationship signals it already used. A generator
reporting fault codes with overdue maintenance is a stronger, more
concrete outreach trigger than a news article — and it can only exist by
federating real operational data live, not by copying a stale snapshot.

---

## Architecture

| Layer | Component | Role |
|---|---|---|
| **Snowflake** | `GENERATOR_TELEMETRY` (table, live data) | Source of truth — never copied, queried live |
| **Data Cloud (Data360)** | Data Stream (Direct Access, Accelerated) | Zero-Copy connection into Snowflake |
| **Data Cloud (Data360)** | `Generator_Telemetry` DLO | Raw ingested representation |
| **Data Cloud (Data360)** | `Generator_Telemetry_DMO` | Modeled object — Category: Engagement, Primary Key: `UNIT_ID`, Event Time: `LAST_REPORTED_AT` |
| **Agentforce** | `Get_Generator_Telemetry` (Flow, Data Cloud Object source, With Sharing) | Queries the DMO by `ACCOUNT_ID` |
| **Agentforce** | `Research_Agent` | Calls the Flow, gathers the signal alongside news/case study/relationship data |
| **Agentforce** | `Outreach_Agent` | Weights the signal by `UNIT_STATUS` severity in the final brief |

**Flow of data:** Snowflake → Data Stream → DLO → DMO → Flow → Research_Agent → Outreach_Agent → seller-facing brief. Data is queried live at each step, never duplicated into a new store along the way.

Join key throughout: **`ACCOUNT_ID`** — Salesforce's real, immutable
Account.Id (not Account Number, which is editable text and confirmed
blank on some real records in this org's data).

---

## Part 1 — Snowflake setup

### Sample data

A single table, `GENERATOR_TELEMETRY`, seeded with 5 rows across 4 real
accounts already used elsewhere in this build — 3 healthy units, 2
flagged as "Needs Attention" (one exactly at a data boundary worth testing
deliberately: Grand Hotels at precisely the same revenue threshold used by
a separate approval-gate feature in this build).

```sql
CREATE WAREHOUSE IF NOT EXISTS SALES_LEAD_DEMO_WH
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;

CREATE TABLE GENERATOR_TELEMETRY (
    ACCOUNT_ID VARCHAR(18) NOT NULL,        -- join key -> Salesforce Account.Id
    ACCOUNT_NAME VARCHAR(200) NOT NULL,
    UNIT_ID VARCHAR(20) NOT NULL,
    INSTALL_DATE DATE NOT NULL,
    LAST_REPORTED_AT TIMESTAMP_NTZ NOT NULL,
    RUNTIME_HOURS_30D NUMBER(8,1) NOT NULL,
    FUEL_LEVEL_PCT NUMBER(5,1) NOT NULL,
    FAULT_CODES_30D NUMBER(3,0) NOT NULL,
    LAST_FAULT_DESCRIPTION VARCHAR(500),
    NEXT_MAINTENANCE_DUE DATE NOT NULL,
    UNIT_STATUS VARCHAR(30) NOT NULL
);
```

### Scoped integration user — least privilege, not broad admin

```sql
CREATE ROLE SALES_LEAD_INTEGRATION_ROLE;
CREATE USER SALES_LEAD_INTEGRATION_USER
    DEFAULT_ROLE = SALES_LEAD_INTEGRATION_ROLE
    DEFAULT_WAREHOUSE = SALES_LEAD_DEMO_WH;
GRANT ROLE SALES_LEAD_INTEGRATION_ROLE TO USER SALES_LEAD_INTEGRATION_USER;
GRANT USAGE ON WAREHOUSE SALES_LEAD_DEMO_WH TO ROLE SALES_LEAD_INTEGRATION_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA SALES_LEAD_DEMO.PUBLIC TO ROLE SALES_LEAD_INTEGRATION_ROLE;
```

Authenticated via RSA key pair, not password. Verified both directions:

**Positive test** — the role can read exactly what it should:
```sql
SELECT COUNT(*) FROM GENERATOR_TELEMETRY;  -- returned 5
```

**Negative test** — the role cannot read anything else, confirmed by a
real permissions error, not just an assumption:
```sql
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.USERS;
-- 002003 (02000): Schema 'SNOWFLAKE.ACCOUNT_USAGE' does not exist or not authorized.
```

---

## Part 2 — The connection: a real debugging chain, not a clean setup

Salesforce's Test Connection passed early using the account's plain
hostname (`<account>.snowflakecomputing.com`). But the Data Stream screen
consistently failed with:

```
Unable to get external objects using connectorName - Sales_Lead_Snowflake_Connection,
database - SALES_LEAD_DEMO and schema - PUBLIC
```

Five distinct, individually reasonable hypotheses were tested, in order,
before finding the real cause:

| # | Hypothesis | Result |
|---|---|---|
| 1 | Warehouse not selected on the connection | Ruled out — warehouse was correctly set |
| 2 | Private key format (PEM headers included where only base64 body was expected) | Real, separate bug — fixed, but didn't resolve this error |
| 3 | Missing `DEFAULT_NAMESPACE` on the Snowflake user | Ruled out — set correctly, no change |
| 4 | Network policy blocking Salesforce's IPs | Ruled out — no policy assigned at all |
| 5 | **Wrong hostname format** — using the regionless hostname instead of the region-qualified one | **Confirmed root cause** |

The fix came from asking Snowflake itself for the authoritative answer
rather than guessing further:

```sql
SELECT SYSTEM$ALLOWLIST();
```

This returned the real, region-qualified hostname
(`<locator>.<region>.<cloud>.snowflakecomputing.com`) — distinct from the
simpler regionless hostname that had passed every basic connectivity test
but silently couldn't support table enumeration. Switching to this exact
hostname fixed the Region auto-detection and the Data Stream error
simultaneously, confirming they shared one root cause.

**Why this matters more than a clean setup would:** four wrong-but-reasonable
hypotheses were tested and eliminated with evidence before finding the real
one — the same debugging discipline used everywhere else in this build,
applied to a completely different problem domain (Snowflake connectivity,
not agent behavior).

---

## Part 3 — Data Cloud modeling

### Data Lake Object → Data Model Object

Data Cloud requires a proper **DMO**, not the raw ingested DLO, to be
queryable from Flow — the same constraint already discovered earlier in
this build's real-time news trigger pipeline. `Generator_Telemetry_DMO`
was mapped from the DLO with:
- **Category:** Engagement (time-based operational signal, not a static profile attribute)
- **Primary Key:** `UNIT_ID` (not `ACCOUNT_ID` — one account can have multiple units)
- **Event Time Field:** `LAST_REPORTED_AT`

### A regression, caught and fixed — not just assumed away

After initially selecting only 2 of 11 available fields, 9 more fields
(including `ACCOUNT_ID`, the entire join key) were added via a "New Source
Fields" dialog. This appeared to work — until the next scheduled hourly
refresh **silently reverted the DLO back to only the original 2 fields**,
because the add-on dialog applied only to that one manual pull, not to the
stream's own persistent field definition.

**Fix:** re-selected all fields through the primary field-mapping screen
(not the add-on dialog), confirmed via **"No New Fields Available"** on a
second check, then triggered a fresh refresh and re-verified all 14 fields
held real data afterward — closing the loop rather than trusting the first
apparent success.

---

## Part 4 — The Flow

`Get_Generator_Telemetry`, sourced from **Data Cloud Object** (not
Salesforce Object — the key structural difference from every other Flow in
this build), filtered by `ACCOUNT_ID = {!AccountId}`, running **With
Sharing** rather than propagating this build's existing "Without Sharing"
default (see the sibling finding on systemic sharing bypass).

**Known, deliberate scope limit:** built as "only the first record," not a
full collection — Data Cloud Objects aren't selectable as a native Record
type in Flow's Resource Manager, and building genuine multi-record
collection support hit enough platform friction that it was scoped out
rather than forced through. For the one account with two units in this
sample data, only one unit's telemetry surfaces. Documented here rather
than hidden.

**Tested at three distinct real states, not just pass/fail:**

| Account | Unit status | Result |
|---|---|---|
| Grand Hotels & Resorts | Needs Attention (2 fault codes, overdue maintenance) | Returns full detail |
| Edge Communications | Operational (healthy) | Returns full detail |
| Dickenson plc | No unit installed | Returns clean nulls |

---

## Part 5 — Wired into the agent, and the result

Added as a new action on `Research_Agent`, with an instruction on
`Outreach_Agent` that **weights the signal by severity, not just
presence/absence**:

```
If equipment telemetry shows a unit with fault codes or overdue
maintenance (UNIT_STATUS is "Needs Attention"), treat this as a
higher-priority trigger than routine news — mention it specifically,
including the unit ID and issue if known. If no unit is installed (all
telemetry fields are null), say nothing about equipment status rather
than inventing one — this is not the same as an error, it simply means
this account has no installed unit yet.
```

**Live results, all three states, through the real agent:**

- **Grand Hotels (flagged unit):** *"Equipment alert: Generator unit GEN-1042 is flagged as 'Needs Attention' due to a low coolant pressure warning... This is a high-priority service need..."* — elevated above the existing news trigger, exactly as instructed.
- **Edge Communications (healthy unit):** *"Equipment status: Generator unit GEN-2031 is operational with no fault codes..."* — mentioned as plain fact, correctly **not** elevated to urgent framing.
- **Dickenson plc (no unit):** Zero mention of equipment anywhere in the response — no fabricated "no unit found" statement, matching the same honest-silence pattern already used for the Case Study section elsewhere in this build.

**Composed cleanly with a pre-existing, unrelated feature (the revenue-based
approval gate)** with zero interference across all three test accounts —
confirming the new capability didn't destabilize anything already built.

---

## Status

✅ Snowflake source: built, scoped, positive and negative access tested
✅ Connection: working, via a real 5-hypothesis debugging chain
✅ DMO: correctly modeled, a real regression caught and fixed
✅ Flow: built, tested at 3 distinct real states
✅ Agent integration: live, tested at 3 distinct real states, composes cleanly with existing features
⏳ Known scope limit: single-record only, not a full multi-unit collection — documented, not hidden
