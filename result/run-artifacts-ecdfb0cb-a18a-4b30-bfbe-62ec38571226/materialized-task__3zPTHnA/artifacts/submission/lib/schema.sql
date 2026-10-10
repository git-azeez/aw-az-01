-- ClearLedger PostgreSQL schema. Idempotent: safe to run on every deploy, also under live traffic.
-- Existing objects are only touched when they are missing, disabled or have a stale function body.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET lock_timeout = '30s';

BEGIN;
SELECT pg_advisory_xact_lock(727274001);

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helper functions (CREATE OR REPLACE does not lock the tables that use them)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.is_uuid(v text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS
$$ SELECT coalesce(v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false) $$;

CREATE OR REPLACE FUNCTION clearledger.tlen(v text) RETURNS integer
LANGUAGE sql IMMUTABLE AS
$$ SELECT char_length(btrim(v)) $$;

-- Rank of the linear clearing lifecycle; DISPUTED has no rank.
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE s
     WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
     WHEN 'CLEARED'   THEN 3 WHEN 'SETTLED'   THEN 4 WHEN 'RECONCILED' THEN 5
     ELSE NULL END $$;

CREATE OR REPLACE FUNCTION clearledger.status_known(s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS
$$ SELECT coalesce(s IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'), false) $$;

CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_s text, new_s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS
$$ SELECT CASE
     WHEN NOT (clearledger.status_known(old_s) AND clearledger.status_known(new_s)) THEN false
     WHEN old_s = 'RECONCILED' THEN false
     WHEN old_s = 'DISPUTED'   THEN new_s IN ('DISPUTED', 'RECONCILED')
     WHEN new_s = 'DISPUTED'   THEN true
     ELSE clearledger.status_rank(new_s) >= clearledger.status_rank(old_s)
   END $$;

-- Strict validation of ClearLedgerDomainEventEnvelope (closed schema) including the
-- version / kind / status / entryId coupling. Never raises: malformed input yields false.
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS
$$
DECLARE
  d jsonb;
  v integer;
  k text;
  ts_re constant text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$';
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k NOT IN ('schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
                 'occurredAt','correlationId','idempotencyKey','data') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
                     'occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN false;
  END IF;

  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid(p->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid(p->>'aggregateId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  v := (p->>'aggregateVersion')::integer;
  IF jsonb_typeof(p->'occurredAt') <> 'string' OR (p->>'occurredAt') !~ ts_re THEN RETURN false; END IF;
  PERFORM (p->>'occurredAt')::timestamptz;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR clearledger.tlen(p->>'correlationId') NOT BETWEEN 4 AND 128 THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR clearledger.tlen(p->>'idempotencyKey') NOT BETWEEN 8 AND 128 THEN RETURN false; END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF k NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'kind') <> 'string' OR d->>'kind' NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'accountId') <> 'string' OR clearledger.tlen(d->>'accountId') NOT BETWEEN 3 AND 64 THEN RETURN false; END IF;
  IF jsonb_typeof(d->'reference') <> 'string' OR clearledger.tlen(d->>'reference') NOT BETWEEN 3 AND 64 THEN RETURN false; END IF;
  IF jsonb_typeof(d->'debitParty') <> 'string' OR clearledger.tlen(d->>'debitParty') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  IF jsonb_typeof(d->'creditParty') <> 'string' OR clearledger.tlen(d->>'creditParty') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  IF jsonb_typeof(d->'status') <> 'string' OR NOT clearledger.status_known(d->>'status') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'clearingStage') <> 'string' OR clearledger.tlen(d->>'clearingStage') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') NOT IN ('null','string') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'memo') = 'string' AND clearledger.tlen(d->>'memo') NOT BETWEEN 1 AND 256 THEN RETURN false; END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') NOT IN ('null','string') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'entryId') = 'string' AND NOT clearledger.is_uuid(d->>'entryId') THEN RETURN false; END IF;
  IF btrim(d->>'debitParty') = btrim(d->>'creditParty') THEN RETURN false; END IF;

  IF v = 1 THEN
    IF p->>'eventType' <> 'SettlementInitiated' OR d->>'kind' <> 'settlementInitiated'
       OR d->>'status' <> 'INITIATED' OR jsonb_typeof(d->'entryId') = 'string' THEN
      RETURN false;
    END IF;
  ELSE
    IF p->>'eventType' <> 'LedgerEntryRecorded' OR d->>'kind' <> 'ledgerEntryRecorded'
       OR d->>'status' = 'INITIATED' OR jsonb_typeof(d->'entryId') <> 'string' THEN
      RETURN false;
    END IF;
  END IF;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

-- Column / envelope equality for clearledger.events rows.
CREATE OR REPLACE FUNCTION clearledger.event_row_matches(
  p_event_id uuid, p_settlement_id uuid, p_version integer, p_event_type text,
  p_correlation_id text, p_idempotency_key text, p_occurred_at timestamptz, p_payload jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS
$$
BEGIN
  RETURN clearledger.envelope_valid(p_payload)
     AND (p_payload->>'eventId')::uuid = p_event_id
     AND (p_payload->>'aggregateId')::uuid = p_settlement_id
     AND (p_payload->>'aggregateVersion')::integer = p_version
     AND p_payload->>'eventType' = p_event_type
     AND p_payload->>'correlationId' = p_correlation_id
     AND p_payload->>'idempotencyKey' = p_idempotency_key
     AND (p_payload->>'occurredAt')::timestamptz = p_occurred_at;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

-- Column / envelope equality for clearledger.outbox rows.
CREATE OR REPLACE FUNCTION clearledger.outbox_row_matches(
  p_event_id uuid, p_settlement_id uuid, p_version integer, p_correlation_id text, p_payload jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS
$$
BEGIN
  RETURN clearledger.envelope_valid(p_payload)
     AND (p_payload->>'eventId')::uuid = p_event_id
     AND (p_payload->>'aggregateId')::uuid = p_settlement_id
     AND (p_payload->>'aggregateVersion')::integer = p_version
     AND p_payload->>'correlationId' = p_correlation_id;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

-- Closed-schema WriteAcceptedResponse as stored in idempotency_keys.response_body.
CREATE OR REPLACE FUNCTION clearledger.write_accepted_valid(b jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS
$$
DECLARE k text;
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(b) LOOP
    IF k NOT IN ('settlementId','eventId','version','accepted','idempotentReplay') THEN RETURN false; END IF;
  END LOOP;
  IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  RETURN jsonb_typeof(b->'settlementId') = 'string' AND clearledger.is_uuid(b->>'settlementId')
     AND jsonb_typeof(b->'eventId') = 'string' AND clearledger.is_uuid(b->>'eventId')
     AND jsonb_typeof(b->'version') = 'number' AND (b->>'version') ~ '^[1-9][0-9]{0,8}$'
     AND b->'accepted' = 'true'::jsonb
     AND b->'idempotentReplay' = 'false'::jsonb;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_row_valid(
  p_scope text, p_key text, p_hash text, p_status integer, p_body jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS
$$
DECLARE v integer;
BEGIN
  IF NOT clearledger.write_accepted_valid(p_body) THEN RETURN false; END IF;
  v := (p_body->>'version')::integer;
  RETURN CASE
    WHEN p_scope ~* '^create:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN p_status = 201 AND v = 1
           AND lower(substr(p_scope, 8)) = lower(p_body->>'settlementId')
    WHEN p_scope ~* '^entry:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN p_status = 202 AND v >= 2
           AND lower(substr(p_scope, 7)) = lower(p_body->>'settlementId')
    ELSE false END;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id  UUID        NOT NULL,
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
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT settlements_pkey PRIMARY KEY (settlement_id)
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq               BIGSERIAL   NOT NULL,
  event_id          UUID        NOT NULL,
  settlement_id     UUID        NOT NULL,
  aggregate_version INTEGER     NOT NULL,
  event_type        TEXT        NOT NULL,
  correlation_id    TEXT        NOT NULL,
  idempotency_key   TEXT        NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT events_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq               BIGSERIAL   NOT NULL,
  event_id          UUID        NOT NULL,
  settlement_id     UUID        NOT NULL,
  aggregate_version INTEGER     NOT NULL,
  correlation_id    TEXT        NOT NULL,
  payload           JSONB       NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at      TIMESTAMPTZ NULL,
  archived_at       TIMESTAMPTZ NULL,
  attempts          INTEGER     NOT NULL DEFAULT 0,
  last_error        TEXT        NULL,
  CONSTRAINT outbox_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT        NOT NULL,
  idempotency_key TEXT        NOT NULL,
  request_hash    TEXT        NOT NULL,
  status_code     INTEGER     NOT NULL,
  response_body   JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT idempotency_keys_pkey PRIMARY KEY (scope, idempotency_key)
);

-- ---------------------------------------------------------------------------
-- Constraints (added only when missing)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _cl_constraints (tbl text, name text, ddl text) ON COMMIT DROP;
INSERT INTO _cl_constraints VALUES
  -- settlements
  ('settlements','settlements_account_id_len',   'CHECK (clearledger.tlen(account_id) BETWEEN 3 AND 64)'),
  ('settlements','settlements_reference_len',    'CHECK (clearledger.tlen(reference) BETWEEN 3 AND 64)'),
  ('settlements','settlements_debit_party_len',  'CHECK (clearledger.tlen(debit_party) BETWEEN 2 AND 64)'),
  ('settlements','settlements_credit_party_len', 'CHECK (clearledger.tlen(credit_party) BETWEEN 2 AND 64)'),
  ('settlements','settlements_parties_differ',   'CHECK (btrim(debit_party) <> btrim(credit_party))'),
  ('settlements','settlements_status_valid',     'CHECK (current_status IN (''INITIATED'',''VALIDATED'',''RESERVED'',''CLEARED'',''SETTLED'',''RECONCILED'',''DISPUTED''))'),
  ('settlements','settlements_stage_len',        'CHECK (clearledger.tlen(current_stage) BETWEEN 2 AND 64)'),
  ('settlements','settlements_memo_len',         'CHECK (last_memo IS NULL OR clearledger.tlen(last_memo) BETWEEN 1 AND 256)'),
  ('settlements','settlements_version_positive',  'CHECK (version >= 1)'),
  ('settlements','settlements_entry_count_nonneg','CHECK (entry_count >= 0)'),
  ('settlements','settlements_timestamps_monotonic','CHECK (updated_at >= created_at)'),
  ('settlements','settlements_initial_state',    'CHECK (version <> 1 OR (entry_count = 0 AND current_status = ''INITIATED'' AND last_entry_id IS NULL AND updated_at = created_at))'),
  ('settlements','settlements_entry_state',      'CHECK (version = 1 OR (entry_count = version - 1 AND current_status <> ''INITIATED'' AND last_entry_id IS NOT NULL))'),
  -- events
  ('events','events_event_id_key',               'UNIQUE (event_id)'),
  ('events','events_settlement_fkey',            'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
  ('events','events_settlement_version_key',     'UNIQUE (settlement_id, aggregate_version)'),
  ('events','events_settlement_idempotency_key', 'UNIQUE (settlement_id, idempotency_key)'),
  ('events','events_version_positive',           'CHECK (aggregate_version >= 1)'),
  ('events','events_event_type_valid',           'CHECK (event_type IN (''SettlementInitiated'',''LedgerEntryRecorded''))'),
  ('events','events_correlation_id_len',         'CHECK (clearledger.tlen(correlation_id) BETWEEN 4 AND 128)'),
  ('events','events_idempotency_key_len',        'CHECK (clearledger.tlen(idempotency_key) BETWEEN 8 AND 128)'),
  ('events','events_payload_envelope',           'CHECK (clearledger.event_row_matches(event_id, settlement_id, aggregate_version, event_type, correlation_id, idempotency_key, occurred_at, payload))'),
  -- outbox
  ('outbox','outbox_event_id_key',               'UNIQUE (event_id)'),
  ('outbox','outbox_event_fkey',                 'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE'),
  ('outbox','outbox_settlement_fkey',            'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
  ('outbox','outbox_settlement_version_key',     'UNIQUE (settlement_id, aggregate_version)'),
  ('outbox','outbox_settlement_version_fkey',    'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE'),
  ('outbox','outbox_version_positive',           'CHECK (aggregate_version >= 1)'),
  ('outbox','outbox_correlation_id_len',         'CHECK (clearledger.tlen(correlation_id) BETWEEN 4 AND 128)'),
  ('outbox','outbox_payload_envelope',           'CHECK (clearledger.outbox_row_matches(event_id, settlement_id, aggregate_version, correlation_id, payload))'),
  ('outbox','outbox_attempts_nonneg',            'CHECK (attempts >= 0)'),
  ('outbox','outbox_published_lifecycle',        'CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))'),
  ('outbox','outbox_archived_lifecycle',         'CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))'),
  -- idempotency_keys
  ('idempotency_keys','idempotency_keys_key_len',   'CHECK (clearledger.tlen(idempotency_key) BETWEEN 8 AND 128)'),
  ('idempotency_keys','idempotency_keys_hash_hex',  'CHECK (request_hash ~ ''^[0-9a-f]{64}$'')'),
  ('idempotency_keys','idempotency_keys_row_valid', 'CHECK (clearledger.idempotency_row_valid(scope, idempotency_key, request_hash, status_code, response_body))');

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM _cl_constraints LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = format('clearledger.%I', r.tbl)::regclass AND c.conname = r.name
    ) THEN
      EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', r.tbl, r.name, r.ddl);
    END IF;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
-- CREATE INDEX IF NOT EXISTS locks the table before checking existence, which can deadlock with
-- in-flight API transactions; only touch the tables when an index is really missing.
DO $$
BEGIN
  IF to_regclass('clearledger.idx_clearledger_outbox_unpublished') IS NULL THEN
    CREATE INDEX idx_clearledger_outbox_unpublished
      ON clearledger.outbox (seq) WHERE published_at IS NULL;
  END IF;
  IF to_regclass('clearledger.idx_clearledger_outbox_unarchived') IS NULL THEN
    CREATE INDEX idx_clearledger_outbox_unarchived
      ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
  END IF;
  IF to_regclass('clearledger.idx_clearledger_events_settlement_version') IS NULL THEN
    CREATE INDEX idx_clearledger_events_settlement_version
      ON clearledger.events (settlement_id, aggregate_version);
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.settlements_before_update() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and can no longer be updated', OLD.settlement_id;
  END IF;
  IF NEW.settlement_id <> OLD.settlement_id OR NEW.account_id <> OLD.account_id
     OR NEW.reference <> OLD.reference OR NEW.debit_party <> OLD.debit_party
     OR NEW.credit_party <> OLD.credit_party OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id;
  END IF;
  IF NEW.version <> OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement % version must step from % to %', OLD.settlement_id, OLD.version, OLD.version + 1;
  END IF;
  IF NEW.entry_count <> OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % entry_count must step by one', OLD.settlement_id;
  END IF;
  IF NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update must carry a new last_entry_id', OLD.settlement_id;
  END IF;
  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement % updated_at must not move backwards', OLD.settlement_id;
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % illegal status transition % -> %', OLD.settlement_id, OLD.current_status, NEW.current_status;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.events_before_insert() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d jsonb := NEW.payload->'data';
  max_version integer;
  prev clearledger.events%ROWTYPE;
BEGIN
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT max(aggregate_version) INTO max_version FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> coalesce(max_version, 0) + 1 THEN
    RAISE EXCEPTION 'settlement % aggregate_version must be contiguous (expected %, got %)',
      NEW.settlement_id, coalesce(max_version, 0) + 1, NEW.aggregate_version;
  END IF;

  IF d->>'kind' = 'ledgerEntryRecorded' AND EXISTS (
       SELECT 1 FROM clearledger.events e
       WHERE e.settlement_id = NEW.settlement_id AND e.event_type = 'LedgerEntryRecorded'
         AND e.payload->'data'->>'entryId' = d->>'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d->>'entryId', NEW.settlement_id;
  END IF;

  IF s.account_id <> d->>'accountId' OR s.reference <> d->>'reference'
     OR s.debit_party <> d->>'debitParty' OR s.credit_party <> d->>'creditParty' THEN
    RAISE EXCEPTION 'event % header does not match settlement %', NEW.event_id, NEW.settlement_id;
  END IF;
  IF s.current_status <> d->>'status' OR s.current_stage <> d->>'clearingStage' THEN
    RAISE EXCEPTION 'event % status/stage does not match settlement %', NEW.event_id, NEW.settlement_id;
  END IF;
  IF s.last_entry_id IS DISTINCT FROM (d->>'entryId')::uuid THEN
    RAISE EXCEPTION 'event % entryId does not match settlement %', NEW.event_id, NEW.settlement_id;
  END IF;
  IF s.last_memo IS DISTINCT FROM (d->>'memo') THEN
    RAISE EXCEPTION 'event % memo does not match settlement %', NEW.event_id, NEW.settlement_id;
  END IF;
  IF s.version <> NEW.aggregate_version OR NEW.occurred_at <> s.updated_at THEN
    RAISE EXCEPTION 'event % version/occurred_at does not match settlement %', NEW.event_id, NEW.settlement_id;
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF NEW.occurred_at <> s.created_at THEN
      RAISE EXCEPTION 'initial event % occurred_at must equal settlement created_at', NEW.event_id;
    END IF;
  ELSE
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'settlement % is missing version %', NEW.settlement_id, NEW.aggregate_version - 1;
    END IF;
    IF NEW.occurred_at < prev.occurred_at THEN
      RAISE EXCEPTION 'event % occurred_at precedes version %', NEW.event_id, prev.aggregate_version;
    END IF;
    IF NOT clearledger.status_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'event % illegal status transition % -> %', NEW.event_id, prev.payload->'data'->>'status', d->>'status';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.events_append_only() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
  RAISE EXCEPTION 'clearledger.events is append-only (% rejected)', TG_OP;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.outbox_before_insert() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
  e clearledger.events%ROWTYPE;
  max_version integer;
BEGIN
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id USING ERRCODE = '23503';
  END IF;
  IF e.settlement_id <> NEW.settlement_id OR e.aggregate_version <> NEW.aggregate_version
     OR e.correlation_id <> NEW.correlation_id OR e.payload <> NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % does not mirror clearledger.events', NEW.event_id;
  END IF;
  SELECT max(aggregate_version) INTO max_version FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> coalesce(max_version, 0) + 1 THEN
    RAISE EXCEPTION 'outbox aggregate_version for settlement % must be contiguous (expected %, got %)',
      NEW.settlement_id, coalesce(max_version, 0) + 1, NEW.aggregate_version;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.outbox_before_update() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
  IF NEW.seq <> OLD.seq OR NEW.event_id <> OLD.event_id OR NEW.settlement_id <> OLD.settlement_id
     OR NEW.aggregate_version <> OLD.aggregate_version OR NEW.correlation_id <> OLD.correlation_id
     OR NEW.payload <> OLD.payload OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns are immutable (event %)', OLD.event_id;
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease (event %)', OLD.event_id;
  END IF;

  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    -- publishing
    IF NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'publishing outbox event % requires attempts to increment and archived_at to stay NULL', OLD.event_id;
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    -- archival / re-archival
    IF NEW.published_at IS DISTINCT FROM OLD.published_at OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published_at, attempts and last_error of published outbox event % are immutable', OLD.event_id;
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at of outbox event % must be reset to NULL before it is changed', OLD.event_id;
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    -- operational replay: both markers are reset together
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'replaying outbox event % requires archived_at to be reset as well', OLD.event_id;
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.outbox_no_delete() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
  RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted';
END
$$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_before_insert() RETURNS trigger
LANGUAGE plpgsql AS
$$
DECLARE
  ev uuid;
  sid uuid;
  ver integer;
BEGIN
  ev  := (NEW.response_body->>'eventId')::uuid;
  sid := (NEW.response_body->>'settlementId')::uuid;
  ver := (NEW.response_body->>'version')::integer;
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                 WHERE e.event_id = ev AND e.settlement_id = sid AND e.aggregate_version = ver
                   AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency key % does not reference a committed event', NEW.idempotency_key USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                 WHERE o.event_id = ev AND o.settlement_id = sid AND o.aggregate_version = ver) THEN
    RAISE EXCEPTION 'idempotency key % does not reference an outbox row', NEW.idempotency_key USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_immutable() RETURNS trigger
LANGUAGE plpgsql AS
$$
BEGIN
  RAISE EXCEPTION 'clearledger.idempotency_keys is immutable (% rejected)', TG_OP;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers (created when missing, re-enabled when disabled out of band)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _cl_triggers (tbl text, name text, ddl text) ON COMMIT DROP;
INSERT INTO _cl_triggers VALUES
  ('settlements','trg_settlements_before_update',  'BEFORE UPDATE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlements_before_update()'),
  ('events','trg_events_before_insert',            'BEFORE INSERT ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.events_before_insert()'),
  ('events','trg_events_append_only',              'BEFORE UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.events_append_only()'),
  ('outbox','trg_outbox_before_insert',            'BEFORE INSERT ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_before_insert()'),
  ('outbox','trg_outbox_before_update',            'BEFORE UPDATE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_before_update()'),
  ('outbox','trg_outbox_no_delete',                'BEFORE DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_no_delete()'),
  ('idempotency_keys','trg_idempotency_before_insert', 'BEFORE INSERT ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_before_insert()'),
  ('idempotency_keys','trg_idempotency_immutable', 'BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_immutable()');

DO $$
DECLARE r record; st "char";
BEGIN
  FOR r IN SELECT * FROM _cl_triggers LOOP
    SELECT t.tgenabled INTO st FROM pg_trigger t
     WHERE t.tgrelid = format('clearledger.%I', r.tbl)::regclass AND t.tgname = r.name AND NOT t.tgisinternal;
    IF NOT FOUND THEN
      EXECUTE format('CREATE TRIGGER %I %s', r.name, r.ddl);
    ELSIF st <> 'O' THEN
      EXECUTE format('ALTER TABLE clearledger.%I ENABLE TRIGGER %I', r.tbl, r.name);
    END IF;
  END LOOP;
END
$$;

COMMIT;
