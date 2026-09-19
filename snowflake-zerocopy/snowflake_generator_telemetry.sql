-- ============================================================
-- Sample data: GENERATOR_TELEMETRY
-- Purpose: demonstrate Zero-Copy federation from Snowflake into
-- Salesforce Data Cloud (Data360), extending the Sales Lead
-- Engagement Agent with a genuinely new signal type — equipment
-- health data that has never lived in Salesforce and never should.
--
-- Join key: ACCOUNT_ID, matching Salesforce's real, immutable Account.Id
-- (the 18-char 001... value) — not Account Number, which is a plain
-- editable text field and isn't guaranteed to be populated (confirmed:
-- "Sample Account for Entitlements" and "sForce" both have it blank).
-- ============================================================

-- Warehouse: smallest available size, with auto-suspend/auto-resume
-- so it doesn't burn trial credits sitting idle between demo runs.
CREATE WAREHOUSE IF NOT EXISTS SALES_LEAD_DEMO_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

USE WAREHOUSE SALES_LEAD_DEMO_WH;

CREATE DATABASE IF NOT EXISTS SALES_LEAD_DEMO;
CREATE SCHEMA IF NOT EXISTS SALES_LEAD_DEMO.PUBLIC;
USE SCHEMA SALES_LEAD_DEMO.PUBLIC;

CREATE OR REPLACE TABLE GENERATOR_TELEMETRY (
    ACCOUNT_ID              VARCHAR(18)   NOT NULL,   -- join key -> Salesforce Account.Id
    ACCOUNT_NAME            VARCHAR(200)  NOT NULL,   -- for human readability only, not the join key
    UNIT_ID                 VARCHAR(20)   NOT NULL,
    INSTALL_DATE            DATE          NOT NULL,
    LAST_REPORTED_AT        TIMESTAMP_NTZ NOT NULL,
    RUNTIME_HOURS_30D       NUMBER(8,1)   NOT NULL,
    FUEL_LEVEL_PCT          NUMBER(5,1)   NOT NULL,
    FAULT_CODES_30D         NUMBER(3,0)   NOT NULL,
    LAST_FAULT_DESCRIPTION  VARCHAR(500),
    NEXT_MAINTENANCE_DUE    DATE          NOT NULL,
    UNIT_STATUS             VARCHAR(30)   NOT NULL     -- Operational | Needs Attention | Offline
);

INSERT INTO GENERATOR_TELEMETRY VALUES
-- Edge Communications: healthy, expanding facility (matches existing "Why Now" live trigger)
('001gK00001FjoE1QAJ', 'Edge Communications', 'GEN-2031', '2022-03-10', '2026-08-08 06:00:00',
 410.5, 88.0, 0, NULL, '2026-09-15', 'Operational'),

-- Grand Hotels & Resorts Ltd: flagged unit — a genuinely new, strong "Why Now" signal,
-- distinct from and additive to the existing expansion news trigger already in the demo
('001gK00001FjoE5QAJ', 'Grand Hotels & Resorts Ltd', 'GEN-1042', '2021-07-01', '2026-08-08 05:30:00',
 512.0, 42.0, 2, 'Low coolant pressure warning, intermittent', '2026-07-28', 'Needs Attention'),

-- Burlington Textiles Corp of America: healthy, routine
('001gK00001FjoE2QAJ', 'Burlington Textiles Corp of America', 'GEN-3087', '2023-01-20', '2026-08-08 06:15:00',
 300.0, 95.0, 0, NULL, '2026-10-02', 'Operational'),

-- United Oil & Gas Corp: large account, two units, one flagged
('001gK00001FjoE6QAJ', 'United Oil & Gas Corp.', 'GEN-5001', '2020-11-05', '2026-08-08 05:45:00',
 1204.0, 61.0, 0, NULL, '2026-09-01', 'Operational'),
('001gK00001FjoE6QAJ', 'United Oil & Gas Corp.', 'GEN-5002', '2020-11-05', '2026-08-08 05:45:00',
 980.0, 30.0, 1, 'Fuel sensor irregularity, needs inspection', '2026-08-20', 'Needs Attention');

-- Quick sanity check
SELECT ACCOUNT_NAME, UNIT_ID, UNIT_STATUS, FAULT_CODES_30D, NEXT_MAINTENANCE_DUE
FROM GENERATOR_TELEMETRY
ORDER BY ACCOUNT_NAME, UNIT_ID;
