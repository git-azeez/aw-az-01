-- ClearLedger PostgreSQL schema (idempotent).
-- Applied by deploy.sh on every run: safe to re-run, never drops data.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;
SELECT pg_advisory_xact_lock(724011);

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ===========================================================================
-- Helper functions
-- ===========================================================================

CREATE OR REPLACE FUNCTION clearledger.cl_is_uuid(v text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL
     AND v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_len_ok(v text, lo integer, hi integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL AND char_length(btrim(v)) BETWEEN lo AND hi
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_is_timestamp(v text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  t timestamptz;
BEGIN
  IF v IS NULL OR v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN false;
  END IF;
  t := v::timestamptz;
  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_status_rank(s text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s
    WHEN 'INITIATED'  THEN 0
    WHEN 'VALIDATED'  THEN 1
    WHEN 'RESERVED'   THEN 2
    WHEN 'CLEARED'    THEN 3
    WHEN 'SETTLED'    THEN 4
    WHEN 'RECONCILED' THEN 5
    ELSE NULL
  END
$$;

-- Clearing lifecycle transition rule shared by the settlements UPDATE
-- trigger and the events INSERT trigger.
CREATE OR REPLACE FUNCTION clearledger.cl_transition_ok(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN old_status IS NULL OR new_status IS NULL THEN false
    WHEN old_status = 'RECONCILED' THEN false
    WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED', 'RECONCILED')
    WHEN clearledger.cl_status_rank(old_status) IS NULL THEN false
    WHEN new_status = 'DISPUTED' THEN true
    WHEN clearledger.cl_status_rank(new_status) IS NULL THEN false
    ELSE clearledger.cl_status_rank(new_status) >= clearledger.cl_status_rank(old_status)
  END
$$;

-- Returns NULL when the envelope conforms to ClearLedgerDomainEventEnvelope
-- (schemas/events.schema.json + openapi.yaml bounds), otherwise a reason.
CREATE OR REPLACE FUNCTION clearledger.cl_envelope_error(p jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d       jsonb;
  k       text;
  ver     bigint;
  et      text;
  kind    text;
  st      text;
  env_keys  text[] := ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                            'aggregateVersion','occurredAt','correlationId','idempotencyKey','data'];
  data_keys text[] := ARRAY['kind','accountId','reference','debitParty','creditParty','entryId',
                            'status','clearingStage','memo'];
  data_req  text[] := ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'];
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RETURN 'envelope must be a JSON object';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF NOT (k = ANY (env_keys)) THEN
      RETURN format('unexpected envelope property %s', k);
    END IF;
  END LOOP;
  FOREACH k IN ARRAY env_keys LOOP
    IF NOT (p ? k) OR jsonb_typeof(p->k) = 'null' THEN
      RETURN format('missing envelope property %s', k);
    END IF;
  END LOOP;

  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN
    RETURN 'schemaVersion must be "1.0"';
  END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.cl_is_uuid(p->>'eventId') THEN
    RETURN 'eventId must be a uuid';
  END IF;
  IF jsonb_typeof(p->'eventType') <> 'string'
     OR p->>'eventType' NOT IN ('SettlementInitiated', 'LedgerEntryRecorded') THEN
    RETURN 'invalid eventType';
  END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN
    RETURN 'aggregateType must be "settlement"';
  END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.cl_is_uuid(p->>'aggregateId') THEN
    RETURN 'aggregateId must be a uuid';
  END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[0-9]{1,10}$' THEN
    RETURN 'aggregateVersion must be a positive integer';
  END IF;
  ver := (p->>'aggregateVersion')::bigint;
  IF ver < 1 OR ver > 2147483647 THEN
    RETURN 'aggregateVersion out of range';
  END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string' OR NOT clearledger.cl_is_timestamp(p->>'occurredAt') THEN
    RETURN 'occurredAt must be an RFC3339 date-time';
  END IF;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR NOT clearledger.cl_len_ok(p->>'correlationId', 4, 128)
     OR char_length(p->>'correlationId') > 128 THEN
    RETURN 'correlationId must be 4..128 characters';
  END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR NOT clearledger.cl_len_ok(p->>'idempotencyKey', 8, 128)
     OR char_length(p->>'idempotencyKey') > 128 THEN
    RETURN 'idempotencyKey must be 8..128 characters';
  END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN
    RETURN 'data must be a JSON object';
  END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF NOT (k = ANY (data_keys)) THEN
      RETURN format('unexpected data property %s', k);
    END IF;
  END LOOP;
  FOREACH k IN ARRAY data_req LOOP
    IF NOT (d ? k) OR jsonb_typeof(d->k) <> 'string' THEN
      RETURN format('data.%s must be a non-null string', k);
    END IF;
  END LOOP;

  kind := d->>'kind';
  st   := d->>'status';
  et   := p->>'eventType';
  IF kind NOT IN ('settlementInitiated', 'ledgerEntryRecorded') THEN
    RETURN 'invalid data.kind';
  END IF;
  IF NOT clearledger.cl_len_ok(d->>'accountId', 3, 64) OR char_length(d->>'accountId') > 64 THEN
    RETURN 'data.accountId must be 3..64 characters';
  END IF;
  IF NOT clearledger.cl_len_ok(d->>'reference', 3, 64) OR char_length(d->>'reference') > 64 THEN
    RETURN 'data.reference must be 3..64 characters';
  END IF;
  IF NOT clearledger.cl_len_ok(d->>'debitParty', 2, 64) OR char_length(d->>'debitParty') > 64 THEN
    RETURN 'data.debitParty must be 2..64 characters';
  END IF;
  IF NOT clearledger.cl_len_ok(d->>'creditParty', 2, 64) OR char_length(d->>'creditParty') > 64 THEN
    RETURN 'data.creditParty must be 2..64 characters';
  END IF;
  IF btrim(d->>'debitParty') = btrim(d->>'creditParty') THEN
    RETURN 'data.debitParty and data.creditParty must differ';
  END IF;
  IF st NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN
    RETURN 'invalid data.status';
  END IF;
  IF NOT clearledger.cl_len_ok(d->>'clearingStage', 2, 64) OR char_length(d->>'clearingStage') > 64 THEN
    RETURN 'data.clearingStage must be 2..64 characters';
  END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null'
     AND (jsonb_typeof(d->'entryId') <> 'string' OR NOT clearledger.cl_is_uuid(d->>'entryId')) THEN
    RETURN 'data.entryId must be a uuid or null';
  END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null'
     AND (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.cl_len_ok(d->>'memo', 1, 256)
          OR char_length(d->>'memo') > 256) THEN
    RETURN 'data.memo must be 1..256 characters or null';
  END IF;

  IF et = 'SettlementInitiated' THEN
    IF kind <> 'settlementInitiated' THEN RETURN 'SettlementInitiated requires kind settlementInitiated'; END IF;
    IF ver <> 1 THEN RETURN 'SettlementInitiated requires aggregateVersion 1'; END IF;
    IF st <> 'INITIATED' THEN RETURN 'SettlementInitiated requires status INITIATED'; END IF;
    IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN
      RETURN 'SettlementInitiated must not carry an entryId';
    END IF;
  ELSE
    IF kind <> 'ledgerEntryRecorded' THEN RETURN 'LedgerEntryRecorded requires kind ledgerEntryRecorded'; END IF;
    IF ver < 2 THEN RETURN 'LedgerEntryRecorded requires aggregateVersion >= 2'; END IF;
    IF st = 'INITIATED' THEN RETURN 'LedgerEntryRecorded must not carry status INITIATED'; END IF;
    IF NOT (d ? 'entryId') OR jsonb_typeof(d->'entryId') <> 'string' THEN
      RETURN 'LedgerEntryRecorded requires an entryId';
    END IF;
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN 'malformed envelope: ' || SQLERRM;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.cl_envelope_valid(p jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT clearledger.cl_envelope_error(p) IS NULL
$$;

-- Column-to-envelope equality for clearledger.events.
CREATE OR REPLACE FUNCTION clearledger.cl_event_columns_match(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_event_type text,
  c_correlation_id text, c_idempotency_key text, c_occurred_at timestamptz)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.cl_envelope_valid(p) THEN
    RETURN false;
  END IF;
  RETURN (p->>'eventId')::uuid = c_event_id
     AND (p->>'aggregateId')::uuid = c_settlement_id
     AND (p->>'aggregateVersion')::integer = c_version
     AND p->>'eventType' = c_event_type
     AND p->>'correlationId' = c_correlation_id
     AND p->>'idempotencyKey' = c_idempotency_key
     AND (p->>'occurredAt')::timestamptz = c_occurred_at;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Column-to-envelope equality for clearledger.outbox.
CREATE OR REPLACE FUNCTION clearledger.cl_outbox_columns_match(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation_id text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.cl_envelope_valid(p) THEN
    RETURN false;
  END IF;
  RETURN (p->>'eventId')::uuid = c_event_id
     AND (p->>'aggregateId')::uuid = c_settlement_id
     AND (p->>'aggregateVersion')::integer = c_version
     AND p->>'correlationId' = c_correlation_id;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Closed-schema WriteAcceptedResponse check for clearledger.idempotency_keys.
CREATE OR REPLACE FUNCTION clearledger.cl_idempotency_row_valid(
  c_scope text, c_status integer, b jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  k    text;
  kind text;
  sid  text;
  ver  bigint;
BEGIN
  IF c_scope IS NULL OR c_scope !~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN false;
  END IF;
  kind := split_part(c_scope, ':', 1);
  sid  := split_part(c_scope, ':', 2);
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN
    RETURN false;
  END IF;
  FOR k IN SELECT jsonb_object_keys(b) LOOP
    IF NOT (k = ANY (ARRAY['settlementId','eventId','version','accepted','idempotentReplay'])) THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(b->'settlementId') <> 'string' OR NOT clearledger.cl_is_uuid(b->>'settlementId')
     OR (b->>'settlementId')::uuid <> sid::uuid THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(b->'eventId') <> 'string' OR NOT clearledger.cl_is_uuid(b->>'eventId') THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(b->'version') <> 'number' OR (b->>'version') !~ '^[0-9]{1,10}$' THEN
    RETURN false;
  END IF;
  ver := (b->>'version')::bigint;
  IF jsonb_typeof(b->'accepted') <> 'boolean' OR (b->>'accepted')::boolean IS DISTINCT FROM true THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(b->'idempotentReplay') <> 'boolean' OR (b->>'idempotentReplay')::boolean IS DISTINCT FROM false THEN
    RETURN false;
  END IF;
  IF kind = 'create' THEN
    RETURN c_status = 201 AND ver = 1;
  ELSIF kind = 'entry' THEN
    RETURN c_status = 202 AND ver >= 2 AND ver <= 2147483647;
  END IF;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Generic helper: (re)create a named CHECK constraint so the latest
-- definition is always in force.
CREATE OR REPLACE FUNCTION clearledger.cl_ensure_check(tbl regclass, cname text, expr text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = tbl AND conname = cname) THEN
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', tbl, cname);
  END IF;
  EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s)', tbl, cname, expr);
END
$$;

-- Add a UNIQUE / FOREIGN KEY constraint only when it is missing.
CREATE OR REPLACE FUNCTION clearledger.cl_ensure_constraint(tbl regclass, cname text, ddl text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = tbl AND conname = cname) THEN
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', tbl, cname, ddl);
  END IF;
END
$$;

-- ===========================================================================
-- Tables
-- ===========================================================================

CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id  UUID        NOT NULL PRIMARY KEY,
  account_id     TEXT        NOT NULL,
  reference      TEXT        NOT NULL,
  debit_party    TEXT        NOT NULL,
  credit_party   TEXT        NOT NULL,
  current_status TEXT        NOT NULL,
  current_stage  TEXT        NOT NULL,
  last_entry_id  UUID        NULL,
  last_memo      TEXT        NULL,
  version        INTEGER     NOT NULL,
  entry_count    INTEGER     NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq               BIGSERIAL   NOT NULL PRIMARY KEY,
  event_id          UUID        NOT NULL,
  settlement_id     UUID        NOT NULL,
  aggregate_version INTEGER     NOT NULL,
  event_type        TEXT        NOT NULL,
  correlation_id    TEXT        NOT NULL,
  idempotency_key   TEXT        NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq               BIGSERIAL   NOT NULL PRIMARY KEY,
  event_id          UUID        NOT NULL,
  settlement_id     UUID        NOT NULL,
  aggregate_version INTEGER     NOT NULL,
  correlation_id    TEXT        NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at      TIMESTAMPTZ NULL,
  archived_at       TIMESTAMPTZ NULL,
  attempts          INTEGER     NOT NULL DEFAULT 0,
  last_error        TEXT        NULL
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT        NOT NULL,
  idempotency_key TEXT        NOT NULL,
  request_hash    TEXT        NOT NULL,
  status_code     INTEGER     NOT NULL,
  response_body   JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (scope, idempotency_key)
);

-- ===========================================================================
-- UNIQUE / FOREIGN KEY constraints
-- ===========================================================================

SELECT clearledger.cl_ensure_constraint('clearledger.events', 'events_event_id_key',
  'UNIQUE (event_id)');
SELECT clearledger.cl_ensure_constraint('clearledger.events', 'events_settlement_version_key',
  'UNIQUE (settlement_id, aggregate_version)');
SELECT clearledger.cl_ensure_constraint('clearledger.events', 'events_settlement_idempotency_key',
  'UNIQUE (settlement_id, idempotency_key)');
SELECT clearledger.cl_ensure_constraint('clearledger.events', 'events_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');

SELECT clearledger.cl_ensure_constraint('clearledger.outbox', 'outbox_event_id_key',
  'UNIQUE (event_id)');
SELECT clearledger.cl_ensure_constraint('clearledger.outbox', 'outbox_settlement_version_key',
  'UNIQUE (settlement_id, aggregate_version)');
SELECT clearledger.cl_ensure_constraint('clearledger.outbox', 'outbox_event_id_fkey',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT clearledger.cl_ensure_constraint('clearledger.outbox', 'outbox_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT clearledger.cl_ensure_constraint('clearledger.outbox', 'outbox_settlement_version_fkey',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');

-- ===========================================================================
-- CHECK constraints
-- ===========================================================================

-- settlements
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_account_id_len',
  $$clearledger.cl_len_ok(account_id, 3, 64) AND char_length(account_id) <= 64$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_reference_len',
  $$clearledger.cl_len_ok(reference, 3, 64) AND char_length(reference) <= 64$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_debit_party_len',
  $$clearledger.cl_len_ok(debit_party, 2, 64) AND char_length(debit_party) <= 64$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_credit_party_len',
  $$clearledger.cl_len_ok(credit_party, 2, 64) AND char_length(credit_party) <= 64$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_parties_distinct',
  $$btrim(debit_party) <> btrim(credit_party)$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_status_valid',
  $$current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_stage_len',
  $$clearledger.cl_len_ok(current_stage, 2, 64) AND char_length(current_stage) <= 64$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_last_memo_len',
  $$last_memo IS NULL OR (clearledger.cl_len_ok(last_memo, 1, 256) AND char_length(last_memo) <= 256)$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_version_positive',
  $$version >= 1$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_entry_count_nonnegative',
  $$entry_count >= 0$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_timestamps_monotonic',
  $$updated_at >= created_at$$);
SELECT clearledger.cl_ensure_check('clearledger.settlements', 'settlements_lifecycle_shape',
  $$(version = 1 AND entry_count = 0 AND current_status = 'INITIATED'
       AND last_entry_id IS NULL AND updated_at = created_at)
    OR (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED'
       AND last_entry_id IS NOT NULL)$$);

-- events
SELECT clearledger.cl_ensure_check('clearledger.events', 'events_version_positive',
  $$aggregate_version >= 1$$);
SELECT clearledger.cl_ensure_check('clearledger.events', 'events_event_type_valid',
  $$event_type IN ('SettlementInitiated', 'LedgerEntryRecorded')$$);
SELECT clearledger.cl_ensure_check('clearledger.events', 'events_kind_version_coupling',
  $$(event_type = 'SettlementInitiated' AND aggregate_version = 1)
    OR (event_type = 'LedgerEntryRecorded' AND aggregate_version >= 2)$$);
SELECT clearledger.cl_ensure_check('clearledger.events', 'events_correlation_id_len',
  $$clearledger.cl_len_ok(correlation_id, 4, 128) AND char_length(correlation_id) <= 128$$);
SELECT clearledger.cl_ensure_check('clearledger.events', 'events_idempotency_key_len',
  $$clearledger.cl_len_ok(idempotency_key, 8, 128) AND char_length(idempotency_key) <= 128$$);
SELECT clearledger.cl_ensure_check('clearledger.events', 'events_payload_envelope',
  $$clearledger.cl_envelope_valid(payload)$$);
SELECT clearledger.cl_ensure_check('clearledger.events', 'events_payload_matches_columns',
  $$clearledger.cl_event_columns_match(payload, event_id, settlement_id, aggregate_version, event_type,
                                       correlation_id, idempotency_key, occurred_at)$$);

-- outbox
SELECT clearledger.cl_ensure_check('clearledger.outbox', 'outbox_version_positive',
  $$aggregate_version >= 1$$);
SELECT clearledger.cl_ensure_check('clearledger.outbox', 'outbox_correlation_id_len',
  $$clearledger.cl_len_ok(correlation_id, 4, 128) AND char_length(correlation_id) <= 128$$);
SELECT clearledger.cl_ensure_check('clearledger.outbox', 'outbox_payload_envelope',
  $$clearledger.cl_envelope_valid(payload)$$);
SELECT clearledger.cl_ensure_check('clearledger.outbox', 'outbox_payload_matches_columns',
  $$clearledger.cl_outbox_columns_match(payload, event_id, settlement_id, aggregate_version, correlation_id)$$);
SELECT clearledger.cl_ensure_check('clearledger.outbox', 'outbox_attempts_nonnegative',
  $$attempts >= 0$$);
SELECT clearledger.cl_ensure_check('clearledger.outbox', 'outbox_published_lifecycle',
  $$published_at IS NULL
    OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)$$);
SELECT clearledger.cl_ensure_check('clearledger.outbox', 'outbox_archived_lifecycle',
  $$archived_at IS NULL
    OR (published_at IS NOT NULL AND archived_at >= published_at)$$);

-- idempotency_keys
SELECT clearledger.cl_ensure_check('clearledger.idempotency_keys', 'idempotency_scope_format',
  $$scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'$$);
SELECT clearledger.cl_ensure_check('clearledger.idempotency_keys', 'idempotency_key_len',
  $$clearledger.cl_len_ok(idempotency_key, 8, 128) AND char_length(idempotency_key) <= 128$$);
SELECT clearledger.cl_ensure_check('clearledger.idempotency_keys', 'idempotency_request_hash_sha256',
  $$request_hash ~ '^[0-9a-f]{64}$'$$);
SELECT clearledger.cl_ensure_check('clearledger.idempotency_keys', 'idempotency_status_code_scope',
  $$(scope LIKE 'create:%' AND status_code = 201) OR (scope LIKE 'entry:%' AND status_code = 202)$$);
SELECT clearledger.cl_ensure_check('clearledger.idempotency_keys', 'idempotency_response_body_schema',
  $$clearledger.cl_idempotency_row_valid(scope, status_code, response_body)$$);

-- ===========================================================================
-- Trigger functions
-- ===========================================================================

-- settlements: a new aggregate always starts at version 1.
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.version IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'settlement % must be initiated at version 1 (got %)', NEW.settlement_id, NEW.version
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

-- settlements: immutable header, +1 version stepping, clearing lifecycle.
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and terminal', OLD.settlement_id;
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id;
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement % version must step from % to %', OLD.settlement_id, OLD.version, OLD.version + 1;
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % entry_count must step by +1', OLD.settlement_id;
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update requires a new last_entry_id', OLD.settlement_id;
  END IF;
  IF NOT clearledger.cl_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % illegal status transition % -> %',
      OLD.settlement_id, OLD.current_status, NEW.current_status;
  END IF;
  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement % updated_at must not move backwards', OLD.settlement_id;
  END IF;
  RETURN NEW;
END
$$;

-- events: contiguous versions, entryId uniqueness, parent coherence, ordering.
CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  err   text;
  s     clearledger.settlements%ROWTYPE;
  d     jsonb;
  prev  clearledger.events%ROWTYPE;
  maxv  integer;
  eid   uuid;
BEGIN
  err := clearledger.cl_envelope_error(NEW.payload);
  IF err IS NOT NULL THEN
    RAISE EXCEPTION 'invalid event envelope: %', err USING ERRCODE = 'check_violation';
  END IF;
  IF NOT clearledger.cl_event_columns_match(NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version,
        NEW.event_type, NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
    RAISE EXCEPTION 'event columns do not match the envelope' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT COALESCE(MAX(aggregate_version), 0) INTO maxv
    FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> maxv + 1 THEN
    RAISE EXCEPTION 'event version % for settlement % is not contiguous (expected %)',
      NEW.aggregate_version, NEW.settlement_id, maxv + 1;
  END IF;

  d := NEW.payload->'data';
  IF d->>'accountId' IS DISTINCT FROM s.account_id
     OR d->>'reference' IS DISTINCT FROM s.reference
     OR d->>'debitParty' IS DISTINCT FROM s.debit_party
     OR d->>'creditParty' IS DISTINCT FROM s.credit_party THEN
    RAISE EXCEPTION 'event header does not match settlement %', NEW.settlement_id;
  END IF;
  IF d->>'status' IS DISTINCT FROM s.current_status
     OR d->>'clearingStage' IS DISTINCT FROM s.current_stage THEN
    RAISE EXCEPTION 'event status/stage does not match settlement %', NEW.settlement_id;
  END IF;
  eid := CASE WHEN jsonb_typeof(d->'entryId') = 'string' THEN (d->>'entryId')::uuid END;
  IF eid IS DISTINCT FROM s.last_entry_id THEN
    RAISE EXCEPTION 'event entryId does not match settlement % last_entry_id', NEW.settlement_id;
  END IF;
  IF (CASE WHEN jsonb_typeof(d->'memo') = 'string' THEN d->>'memo' END) IS DISTINCT FROM s.last_memo THEN
    RAISE EXCEPTION 'event memo does not match settlement % last_memo', NEW.settlement_id;
  END IF;
  IF NEW.aggregate_version IS DISTINCT FROM s.version THEN
    RAISE EXCEPTION 'event version % does not match settlement version %', NEW.aggregate_version, s.version;
  END IF;
  IF NEW.occurred_at IS DISTINCT FROM s.updated_at THEN
    RAISE EXCEPTION 'event occurred_at must equal settlement updated_at';
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF NEW.occurred_at IS DISTINCT FROM s.created_at THEN
      RAISE EXCEPTION 'initiation event occurred_at must equal settlement created_at';
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM clearledger.events e
                WHERE e.settlement_id = NEW.settlement_id
                  AND e.event_type = 'LedgerEntryRecorded'
                  AND e.payload->'data'->>'entryId' IS NOT NULL
                  AND lower(e.payload->'data'->>'entryId') = lower(d->>'entryId')) THEN
      RAISE EXCEPTION 'entryId % already recorded for settlement %', d->>'entryId', NEW.settlement_id
        USING ERRCODE = 'unique_violation';
    END IF;
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'previous event % missing for settlement %', NEW.aggregate_version - 1, NEW.settlement_id;
    END IF;
    IF NEW.occurred_at < prev.occurred_at THEN
      RAISE EXCEPTION 'event occurred_at must not precede the previous event';
    END IF;
    IF NOT clearledger.cl_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'illegal status transition % -> %', prev.payload->'data'->>'status', d->>'status';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%.% is append-only: % is not permitted', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP;
END
$$;

-- outbox: must exactly mirror the committed event, in contiguous order.
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  e    clearledger.events%ROWTYPE;
  maxv integer;
  err  text;
BEGIN
  err := clearledger.cl_envelope_error(NEW.payload);
  IF err IS NOT NULL THEN
    RAISE EXCEPTION 'invalid outbox envelope: %', err USING ERRCODE = 'check_violation';
  END IF;
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox event % has no committed event', NEW.event_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
     OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
     OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
     OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % does not mirror clearledger.events', NEW.event_id;
  END IF;
  SELECT COALESCE(MAX(aggregate_version), 0) INTO maxv
    FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> maxv + 1 THEN
    RAISE EXCEPTION 'outbox version % for settlement % is not contiguous (expected %)',
      NEW.aggregate_version, NEW.settlement_id, maxv + 1;
  END IF;
  IF NEW.attempts < 0 THEN
    RAISE EXCEPTION 'outbox attempts must be >= 0' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.archived_at IS NOT NULL AND NEW.published_at IS NULL THEN
    RAISE EXCEPTION 'outbox row cannot be archived before it is published' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$$;

-- outbox: delivery / archival lifecycle.
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.seq IS DISTINCT FROM OLD.seq
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns are immutable (seq %)', OLD.seq;
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease (seq %)', OLD.seq;
  END IF;

  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    -- publishing
    IF NEW.attempts <= OLD.attempts THEN
      RAISE EXCEPTION 'publishing outbox seq % requires incrementing attempts', OLD.seq;
    END IF;
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox seq % cannot be archived while being published', OLD.seq;
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    -- archival / re-archival of a published row
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox seq % delivery columns are immutable', OLD.seq;
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'outbox seq % archived_at cannot be rewritten without first resetting it', OLD.seq;
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    -- operational replay
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox seq % replay must also reset archived_at', OLD.seq;
    END IF;
  ELSE
    -- still unpublished (e.g. a failed attempt recording last_error)
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'unpublished outbox seq % cannot be archived', OLD.seq;
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted (seq %)', OLD.seq;
END
$$;

-- idempotency_keys: must reference a committed event + outbox row.
CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  sid uuid;
  eid uuid;
  ver integer;
BEGIN
  IF NOT clearledger.cl_idempotency_row_valid(NEW.scope, NEW.status_code, NEW.response_body) THEN
    RAISE EXCEPTION 'invalid idempotency record for scope %', NEW.scope USING ERRCODE = 'check_violation';
  END IF;
  sid := (NEW.response_body->>'settlementId')::uuid;
  eid := (NEW.response_body->>'eventId')::uuid;
  ver := (NEW.response_body->>'version')::integer;
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                  WHERE e.event_id = eid AND e.settlement_id = sid
                    AND e.aggregate_version = ver AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency record references no committed event %', eid
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                  WHERE o.event_id = eid AND o.settlement_id = sid AND o.aggregate_version = ver) THEN
    RAISE EXCEPTION 'idempotency record references no outbox row for event %', eid
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END
$$;

-- ===========================================================================
-- Triggers
-- ===========================================================================

CREATE OR REPLACE TRIGGER trg_settlements_before_insert
  BEFORE INSERT ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_insert();

CREATE OR REPLACE TRIGGER trg_settlements_before_update
  BEFORE UPDATE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_update();

CREATE OR REPLACE TRIGGER trg_events_before_insert
  BEFORE INSERT ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_before_insert();

CREATE OR REPLACE TRIGGER trg_events_append_only
  BEFORE UPDATE OR DELETE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

CREATE OR REPLACE TRIGGER trg_outbox_before_insert
  BEFORE INSERT ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_insert();

CREATE OR REPLACE TRIGGER trg_outbox_before_update
  BEFORE UPDATE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_update();

CREATE OR REPLACE TRIGGER trg_outbox_before_delete
  BEFORE DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_delete();

CREATE OR REPLACE TRIGGER trg_idempotency_before_insert
  BEFORE INSERT ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert();

CREATE OR REPLACE TRIGGER trg_idempotency_append_only
  BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

-- ===========================================================================
-- Indexes
-- ===========================================================================

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);

COMMIT;
