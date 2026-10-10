-- ClearLedger PostgreSQL schema: idempotent (safe to re-run under live traffic).
\set ON_ERROR_STOP on
\o /dev/null
SET lock_timeout = '15s';
SET client_min_messages = warning;
BEGIN;

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------- helpers
CREATE OR REPLACE FUNCTION clearledger.is_canonical(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(t IS NOT NULL AND t = btrim(t) AND t !~ '^\s' AND t !~ '\s$', false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.str_ok(t text, minlen int, maxlen int) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(clearledger.is_canonical(t) AND char_length(t) BETWEEN minlen AND maxlen, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_status(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(t IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'), false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
                WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 END
$f$;

CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_s text, new_s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT COALESCE(CASE
    WHEN old_s = 'RECONCILED' THEN false
    WHEN old_s = 'DISPUTED' THEN new_s IN ('DISPUTED', 'RECONCILED')
    WHEN clearledger.status_rank(old_s) IS NULL THEN false
    WHEN new_s = 'DISPUTED' THEN true
    WHEN clearledger.status_rank(new_s) IS NULL THEN false
    ELSE clearledger.status_rank(new_s) >= clearledger.status_rank(old_s)
  END, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.safe_ts(t text) RETURNS timestamptz
LANGUAGE plpgsql STABLE AS $f$
BEGIN
  IF t IS NULL OR t !~ '^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$' THEN
    RETURN NULL;
  END IF;
  RETURN t::timestamptz;
EXCEPTION WHEN others THEN
  RETURN NULL;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.safe_uuid(t text) RETURNS uuid
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN clearledger.is_uuid(t) THEN t::uuid END
$f$;

-- Strict structural validation of ClearLedgerDomainEventEnvelope (events.schema.json).
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $f$
DECLARE
  k text; d jsonb; v integer; et text; kind text; st text; stage text; debit text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k <> ALL (ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                       'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid(p->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid(p->>'aggregateId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string' OR clearledger.safe_ts(p->>'occurredAt') IS NULL THEN RETURN false; END IF;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR NOT clearledger.str_ok(p->>'correlationId', 4, 128) THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR NOT clearledger.str_ok(p->>'idempotencyKey', 8, 128) THEN RETURN false; END IF;

  v := (p->>'aggregateVersion')::integer;
  et := p->>'eventType';
  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF k <> ALL (ARRAY['kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo']) THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN false; END IF;
  FOR k IN SELECT unnest(ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) LOOP
    IF jsonb_typeof(d->k) <> 'string' THEN RETURN false; END IF;
  END LOOP;
  kind := d->>'kind'; st := d->>'status'; stage := d->>'clearingStage'; debit := d->>'debitParty';
  IF kind NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(d->>'accountId', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(d->>'reference', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(debit, 2, 64) THEN RETURN false; END IF;
  IF NOT clearledger.str_ok(d->>'creditParty', 2, 64) THEN RETURN false; END IF;
  IF debit = d->>'creditParty' THEN RETURN false; END IF;
  IF NOT clearledger.is_status(st) THEN RETURN false; END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
    IF jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.str_ok(d->>'memo', 1, 256) THEN RETURN false; END IF;
  END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN
    IF jsonb_typeof(d->'entryId') <> 'string' OR NOT clearledger.is_uuid(d->>'entryId') THEN RETURN false; END IF;
  END IF;

  IF v = 1 THEN
    IF et <> 'SettlementInitiated' OR kind <> 'settlementInitiated' OR st <> 'INITIATED' THEN RETURN false; END IF;
    IF d->>'entryId' IS NOT NULL THEN RETURN false; END IF;
    IF stage <> 'INITIATED@' || debit THEN RETURN false; END IF;
    IF d->>'memo' IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
  ELSE
    IF et <> 'LedgerEntryRecorded' OR kind <> 'ledgerEntryRecorded' OR st = 'INITIATED' THEN RETURN false; END IF;
    IF d->>'entryId' IS NULL THEN RETURN false; END IF;
    IF NOT clearledger.str_ok(stage, 2, 64) THEN RETURN false; END IF;
  END IF;
  RETURN true;
END
$f$;

-- Column <-> envelope equality (shared by events and outbox).
CREATE OR REPLACE FUNCTION clearledger.envelope_matches(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation text) RETURNS boolean
LANGUAGE sql STABLE AS $f$
  SELECT COALESCE(
    clearledger.safe_uuid(p->>'eventId') = c_event_id
    AND clearledger.safe_uuid(p->>'aggregateId') = c_settlement_id
    AND CASE WHEN (p->>'aggregateVersion') ~ '^[0-9]{1,9}$' THEN (p->>'aggregateVersion')::integer END = c_version
    AND p->>'correlationId' = c_correlation, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.event_matches(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_type text,
  c_correlation text, c_idem text, c_occurred timestamptz) RETURNS boolean
LANGUAGE sql STABLE AS $f$
  SELECT COALESCE(
    clearledger.envelope_matches(p, c_event_id, c_settlement_id, c_version, c_correlation)
    AND p->>'eventType' = c_type
    AND p->>'idempotencyKey' = c_idem
    AND clearledger.safe_ts(p->>'occurredAt') = c_occurred, false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.write_response_ok(b jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE k text;
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(b) LOOP
    IF k <> ALL (ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  END LOOP;
  IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  RETURN COALESCE(
    jsonb_typeof(b->'settlementId') = 'string' AND clearledger.is_uuid(b->>'settlementId')
    AND jsonb_typeof(b->'eventId') = 'string' AND clearledger.is_uuid(b->>'eventId')
    AND jsonb_typeof(b->'version') = 'number' AND (b->>'version') ~ '^[1-9][0-9]{0,8}$'
    AND b->'accepted' = 'true'::jsonb
    AND b->'idempotentReplay' = 'false'::jsonb, false);
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.idem_row_ok(scope text, code integer, b jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE ver integer;
BEGIN
  IF scope IS NULL OR code IS NULL OR NOT clearledger.write_response_ok(b) THEN RETURN false; END IF;
  ver := (b->>'version')::integer;
  IF scope ~* '^create:[0-9a-f-]{36}$' THEN
    RETURN lower(substr(scope, 8)) = lower(b->>'settlementId') AND code = 201 AND ver = 1;
  ELSIF scope ~* '^entry:[0-9a-f-]{36}$' THEN
    RETURN lower(substr(scope, 7)) = lower(b->>'settlementId') AND code = 202 AND ver >= 2;
  END IF;
  RETURN false;
END
$f$;

-- ---------------------------------------------------------------- tables
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id UUID NOT NULL PRIMARY KEY,
  account_id    TEXT NOT NULL,
  reference     TEXT NOT NULL,
  debit_party   TEXT NOT NULL,
  credit_party  TEXT NOT NULL,
  current_status TEXT NOT NULL,
  current_stage  TEXT NOT NULL,
  last_entry_id UUID NULL,
  last_memo     TEXT NULL,
  version       INTEGER NOT NULL,
  entry_count   INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq            BIGSERIAL NOT NULL PRIMARY KEY,
  event_id       UUID NOT NULL,
  settlement_id  UUID NOT NULL,
  aggregate_version INTEGER NOT NULL,
  event_type     TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at    TIMESTAMPTZ NOT NULL,
  payload        JSONB NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq            BIGSERIAL NOT NULL PRIMARY KEY,
  event_id       UUID NOT NULL,
  settlement_id  UUID NOT NULL,
  aggregate_version INTEGER NOT NULL,
  correlation_id TEXT NOT NULL,
  payload        JSONB NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at   TIMESTAMPTZ NULL,
  archived_at    TIMESTAMPTZ NULL,
  attempts       INTEGER NOT NULL DEFAULT 0,
  last_error     TEXT NULL
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash    TEXT NOT NULL,
  status_code     INTEGER NOT NULL,
  response_body   JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (scope, idempotency_key)
);

-- ---------------------------------------------------------------- constraints (added only when missing)
CREATE FUNCTION pg_temp.add_con(tbl regclass, cname text, def text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = tbl AND conname = cname) THEN
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', tbl, cname, def);
  END IF;
END
$f$;

-- settlements
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_canonical', $d$CHECK (
  clearledger.str_ok(account_id, 3, 64) AND clearledger.str_ok(reference, 3, 64)
  AND clearledger.str_ok(debit_party, 2, 64) AND clearledger.str_ok(credit_party, 2, 64)
  AND clearledger.is_canonical(current_stage)
  AND (last_memo IS NULL OR clearledger.str_ok(last_memo, 1, 256))
  AND debit_party <> credit_party)$d$);
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_status', $d$CHECK (clearledger.is_status(current_status))$d$);
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_version', $d$CHECK (version >= 1 AND entry_count >= 0 AND entry_count = version - 1)$d$);
SELECT pg_temp.add_con('clearledger.settlements', 'ck_settlements_lifecycle', $d$CHECK (
  CASE WHEN version = 1 THEN
         entry_count = 0 AND current_status = 'INITIATED'
         AND current_stage = 'INITIATED@' || debit_party
         AND last_entry_id IS NULL AND last_memo = 'Settlement initiated'
         AND updated_at = created_at
       ELSE
         entry_count = version - 1 AND current_status <> 'INITIATED'
         AND char_length(current_stage) BETWEEN 2 AND 64
         AND last_entry_id IS NOT NULL AND updated_at > created_at
  END)$d$);

-- events
SELECT pg_temp.add_con('clearledger.events', 'uq_events_event_id', 'UNIQUE (event_id)');
SELECT pg_temp.add_con('clearledger.events', 'uq_events_settlement_version', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.add_con('clearledger.events', 'uq_events_settlement_idempotency', 'UNIQUE (settlement_id, idempotency_key)');
SELECT pg_temp.add_con('clearledger.events', 'fk_events_settlement',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.events', 'ck_events_columns', $d$CHECK (
  aggregate_version >= 1 AND event_type IN ('SettlementInitiated', 'LedgerEntryRecorded')
  AND clearledger.str_ok(correlation_id, 4, 128) AND clearledger.str_ok(idempotency_key, 8, 128))$d$);
SELECT pg_temp.add_con('clearledger.events', 'ck_events_envelope', $d$CHECK (clearledger.envelope_ok(payload))$d$);
SELECT pg_temp.add_con('clearledger.events', 'ck_events_envelope_columns', $d$CHECK (
  clearledger.event_matches(payload, event_id, settlement_id, aggregate_version, event_type,
                            correlation_id, idempotency_key, occurred_at))$d$);

-- outbox
SELECT pg_temp.add_con('clearledger.outbox', 'uq_outbox_event_id', 'UNIQUE (event_id)');
SELECT pg_temp.add_con('clearledger.outbox', 'uq_outbox_settlement_version', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.add_con('clearledger.outbox', 'fk_outbox_event',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.outbox', 'fk_outbox_settlement',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.outbox', 'fk_outbox_event_version',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_columns', $d$CHECK (
  aggregate_version >= 1 AND clearledger.str_ok(correlation_id, 4, 128))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_envelope', $d$CHECK (
  clearledger.envelope_ok(payload)
  AND clearledger.envelope_matches(payload, event_id, settlement_id, aggregate_version, correlation_id))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_attempts', $d$CHECK (
  attempts >= 0 AND (attempts > 0 OR (published_at IS NULL AND last_error IS NULL)))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_published', $d$CHECK (
  published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_last_error', $d$CHECK (
  last_error IS NULL OR (published_at IS NULL AND attempts >= 1
                         AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))$d$);
SELECT pg_temp.add_con('clearledger.outbox', 'ck_outbox_archived', $d$CHECK (
  archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))$d$);

-- idempotency_keys
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_scope', $d$CHECK (
  scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')$d$);
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_key', $d$CHECK (clearledger.str_ok(idempotency_key, 8, 128))$d$);
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_hash', $d$CHECK (request_hash ~ '^[0-9a-f]{64}$')$d$);
SELECT pg_temp.add_con('clearledger.idempotency_keys', 'ck_idem_response', $d$CHECK (
  clearledger.idem_row_ok(scope, status_code, response_body))$d$);

-- ---------------------------------------------------------------- trigger functions
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.settlements is append-only: DELETE rejected';
  ELSIF TG_OP = 'INSERT' THEN
    IF NEW.version <> 1 THEN
      RAISE EXCEPTION 'settlement % must be created at version 1 (got %)', NEW.settlement_id, NEW.version;
    END IF;
    RETURN NEW;
  END IF;
  -- UPDATE
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and terminal', OLD.settlement_id;
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id;
  END IF;
  IF NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % must advance version and entry_count by exactly 1', OLD.settlement_id;
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update requires a new last_entry_id', OLD.settlement_id;
  END IF;
  IF NEW.updated_at <= OLD.updated_at THEN
    RAISE EXCEPTION 'settlement % updated_at must strictly increase', OLD.settlement_id;
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % illegal status transition % -> %', OLD.settlement_id, OLD.current_status, NEW.current_status;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_events_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d jsonb := NEW.payload->'data';
  cnt bigint; mx integer;
  prev_at timestamptz; prev_status text;
BEGIN
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id;
  END IF;

  SELECT count(*), COALESCE(max(aggregate_version), 0) INTO cnt, mx
    FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> mx + 1 OR cnt <> mx THEN
    RAISE EXCEPTION 'event version % for settlement % is not contiguous (latest %)', NEW.aggregate_version, NEW.settlement_id, mx;
  END IF;

  IF d->>'entryId' IS NOT NULL AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id AND e.event_type = 'LedgerEntryRecorded'
          AND e.payload->'data'->>'entryId' = d->>'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d->>'entryId', NEW.settlement_id;
  END IF;

  IF s.account_id IS DISTINCT FROM d->>'accountId' OR s.reference IS DISTINCT FROM d->>'reference'
     OR s.debit_party IS DISTINCT FROM d->>'debitParty' OR s.credit_party IS DISTINCT FROM d->>'creditParty'
     OR s.current_status IS DISTINCT FROM d->>'status' OR s.current_stage IS DISTINCT FROM d->>'clearingStage'
     OR s.last_entry_id IS DISTINCT FROM clearledger.safe_uuid(d->>'entryId')
     OR s.last_memo IS DISTINCT FROM d->>'memo' OR s.version <> NEW.aggregate_version
     OR s.updated_at <> NEW.occurred_at THEN
    RAISE EXCEPTION 'event % does not match settlement % state', NEW.event_id, NEW.settlement_id;
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF s.created_at <> NEW.occurred_at THEN
      RAISE EXCEPTION 'initial event % must occur at settlement creation time', NEW.event_id;
    END IF;
  ELSE
    SELECT e.occurred_at, e.payload->'data'->>'status' INTO prev_at, prev_status
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.aggregate_version = NEW.aggregate_version - 1;
    IF prev_at IS NULL OR NEW.occurred_at <= prev_at THEN
      RAISE EXCEPTION 'event % occurred_at must be after the preceding event', NEW.event_id;
    END IF;
    IF NOT clearledger.status_transition_ok(prev_status, d->>'status') THEN
      RAISE EXCEPTION 'event % illegal status transition % -> %', NEW.event_id, prev_status, d->>'status';
    END IF;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_append_only() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION '%.% is append-only: % rejected', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  e clearledger.events%ROWTYPE;
  cnt bigint; mx integer;
BEGIN
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id;
  END IF;
  IF e.settlement_id <> NEW.settlement_id OR e.aggregate_version <> NEW.aggregate_version
     OR e.correlation_id <> NEW.correlation_id OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % does not mirror the event', NEW.event_id;
  END IF;
  SELECT count(*), COALESCE(max(aggregate_version), 0) INTO cnt, mx
    FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> mx + 1 OR cnt <> mx THEN
    RAISE EXCEPTION 'outbox version % for settlement % is not contiguous (latest %)', NEW.aggregate_version, NEW.settlement_id, mx;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_change_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted';
  END IF;
  IF NEW.seq <> OLD.seq OR NEW.event_id <> OLD.event_id OR NEW.settlement_id <> OLD.settlement_id
     OR NEW.aggregate_version <> OLD.aggregate_version OR NEW.correlation_id <> OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns of event % are immutable', OLD.event_id;
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts of event % cannot decrease', OLD.event_id;
  END IF;
  IF OLD.published_at IS NULL THEN
    IF NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL) THEN
      RAISE EXCEPTION 'publishing outbox event % requires attempts to increment and archived_at to be NULL', OLD.event_id;
    END IF;
  ELSIF NEW.published_at IS NULL THEN
    -- operational replay: reset published_at and archived_at together
    IF NEW.archived_at IS NOT NULL OR NEW.attempts <> OLD.attempts OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'outbox replay reset of event % may only clear published_at and archived_at', OLD.event_id;
    END IF;
  ELSE
    IF NEW.published_at <> OLD.published_at OR NEW.attempts <> OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox event % cannot change published_at, attempts or last_error', OLD.event_id;
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at of outbox event % cannot change without resetting it to NULL first', OLD.event_id;
    END IF;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.trg_idem_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  b jsonb := NEW.response_body;
  eid uuid := clearledger.safe_uuid(b->>'eventId');
  sid uuid := clearledger.safe_uuid(b->>'settlementId');
  ver integer := (b->>'version')::integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                  WHERE e.event_id = eid AND e.settlement_id = sid AND e.aggregate_version = ver
                    AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency record references no matching event %', eid;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                  WHERE o.event_id = eid AND o.settlement_id = sid AND o.aggregate_version = ver) THEN
    RAISE EXCEPTION 'idempotency record references no matching outbox row for event %', eid;
  END IF;
  IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys k
              WHERE k.response_body->>'eventId' = b->>'eventId'
                 OR (k.response_body->>'settlementId' = b->>'settlementId'
                     AND (k.response_body->>'version')::integer = ver)) THEN
    RAISE EXCEPTION 'event % is already bound to another idempotency record', eid;
  END IF;
  RETURN NEW;
END
$f$;

-- ---------------------------------------------------------------- triggers
CREATE FUNCTION pg_temp.add_trg(tbl regclass, tname text, def text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = tbl AND tgname = tname AND NOT tgisinternal) THEN
    EXECUTE format('CREATE TRIGGER %I %s', tname, def);
  END IF;
END
$f$;

SELECT pg_temp.add_trg('clearledger.settlements', 'trg_settlements_guard',
  'BEFORE INSERT OR UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_guard()');
SELECT pg_temp.add_trg('clearledger.events', 'trg_events_insert_guard',
  'BEFORE INSERT ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_insert_guard()');
SELECT pg_temp.add_trg('clearledger.events', 'trg_events_append_only',
  'BEFORE UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only()');
SELECT pg_temp.add_trg('clearledger.outbox', 'trg_outbox_insert_guard',
  'BEFORE INSERT ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_insert_guard()');
SELECT pg_temp.add_trg('clearledger.outbox', 'trg_outbox_change_guard',
  'BEFORE UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_change_guard()');
SELECT pg_temp.add_trg('clearledger.idempotency_keys', 'trg_idem_insert_guard',
  'BEFORE INSERT ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idem_insert_guard()');
SELECT pg_temp.add_trg('clearledger.idempotency_keys', 'trg_idem_append_only',
  'BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only()');

-- Re-enable anything disabled out-of-band (user triggers only; system FK triggers need superuser).
ALTER TABLE clearledger.settlements ENABLE TRIGGER USER;
ALTER TABLE clearledger.events ENABLE TRIGGER USER;
ALTER TABLE clearledger.outbox ENABLE TRIGGER USER;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER USER;

-- ---------------------------------------------------------------- indexes
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);

COMMIT;
\o
