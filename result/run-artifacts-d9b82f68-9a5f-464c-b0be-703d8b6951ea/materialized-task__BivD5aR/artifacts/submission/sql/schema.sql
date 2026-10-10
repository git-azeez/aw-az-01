-- ClearLedger PostgreSQL schema. Fully idempotent: safe to re-run against a live
-- database. Runs in a single transaction so constraint/trigger re-creation is
-- atomic (no window without enforcement) and never loses data.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout = '30s';
SET LOCAL client_min_messages = warning;

-- serialise concurrent deploys
SELECT pg_advisory_xact_lock(hashtext('clearledger-schema-migration'));

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
                WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5
                ELSE NULL END
$$;

CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_s text, new_s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(CASE
    WHEN old_s = 'RECONCILED' THEN false
    WHEN old_s = 'DISPUTED' THEN new_s IN ('DISPUTED', 'RECONCILED')
    WHEN clearledger.status_rank(old_s) IS NULL THEN false
    WHEN new_s = 'DISPUTED' THEN true
    WHEN clearledger.status_rank(new_s) IS NULL THEN false
    ELSE clearledger.status_rank(new_s) >= clearledger.status_rank(old_s)
  END, false)
$$;

-- jsonb string that is canonically trimmed with a length within [lo, hi]
CREATE OR REPLACE FUNCTION clearledger.j_canon(j jsonb, lo integer, hi integer) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(jsonb_typeof(j) = 'string'
         AND (j #>> '{}') = btrim(j #>> '{}')
         AND char_length(j #>> '{}') BETWEEN lo AND hi, false)
$$;

CREATE OR REPLACE FUNCTION clearledger.j_uuid(j jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(jsonb_typeof(j) = 'string'
         AND (j #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
$$;

-- Validates a ClearLedgerDomainEventEnvelope (schemas/events.schema.json) plus the
-- stricter rules from services/rds.md.
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
  d jsonb;
  v integer;
  etype text;
  status text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p) AS k
             WHERE k <> ALL (ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                                   'aggregateVersion','occurredAt','correlationId','idempotencyKey','data'])) THEN
    RETURN false;
  END IF;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN false;
  END IF;
  IF p->'schemaVersion' IS DISTINCT FROM '"1.0"'::jsonb THEN RETURN false; END IF;
  IF p->'aggregateType' IS DISTINCT FROM '"settlement"'::jsonb THEN RETURN false; END IF;
  IF NOT clearledger.j_uuid(p->'eventId') OR NOT clearledger.j_uuid(p->'aggregateId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]{0,8}$' THEN
    RETURN false;
  END IF;
  v := (p->>'aggregateVersion')::integer;
  IF jsonb_typeof(p->'eventType') <> 'string' THEN RETURN false; END IF;
  etype := p->>'eventType';
  IF etype NOT IN ('SettlementInitiated', 'LedgerEntryRecorded') THEN RETURN false; END IF;
  IF NOT clearledger.j_canon(p->'correlationId', 4, 128) THEN RETURN false; END IF;
  IF NOT clearledger.j_canon(p->'idempotencyKey', 8, 128) THEN RETURN false; END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string'
     OR (p->>'occurredAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN false;
  END IF;
  BEGIN
    PERFORM (p->>'occurredAt')::timestamptz;
  EXCEPTION WHEN others THEN
    RETURN false;
  END;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(d) AS k
             WHERE k <> ALL (ARRAY['kind','accountId','reference','debitParty','creditParty',
                                   'entryId','status','clearingStage','memo'])) THEN
    RETURN false;
  END IF;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN
    RETURN false;
  END IF;
  IF NOT clearledger.j_canon(d->'accountId', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.j_canon(d->'reference', 3, 64) THEN RETURN false; END IF;
  IF NOT clearledger.j_canon(d->'debitParty', 2, 64) THEN RETURN false; END IF;
  IF NOT clearledger.j_canon(d->'creditParty', 2, 64) THEN RETURN false; END IF;
  IF (d->>'debitParty') = (d->>'creditParty') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'status') <> 'string' THEN RETURN false; END IF;
  status := d->>'status';
  IF status NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN
    RETURN false;
  END IF;

  IF v = 1 THEN
    IF etype <> 'SettlementInitiated' THEN RETURN false; END IF;
    IF d->'kind' IS DISTINCT FROM '"settlementInitiated"'::jsonb THEN RETURN false; END IF;
    IF status <> 'INITIATED' THEN RETURN false; END IF;
    IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN RETURN false; END IF;
    IF d->'clearingStage' IS DISTINCT FROM to_jsonb('INITIATED@' || (d->>'debitParty')) THEN RETURN false; END IF;
    IF d->'memo' IS DISTINCT FROM '"Settlement initiated"'::jsonb THEN RETURN false; END IF;
  ELSE
    IF etype <> 'LedgerEntryRecorded' THEN RETURN false; END IF;
    IF d->'kind' IS DISTINCT FROM '"ledgerEntryRecorded"'::jsonb THEN RETURN false; END IF;
    IF status = 'INITIATED' THEN RETURN false; END IF;
    IF NOT clearledger.j_uuid(d->'entryId') THEN RETURN false; END IF;
    IF NOT clearledger.j_canon(d->'clearingStage', 2, 64) THEN RETURN false; END IF;
    IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' AND NOT clearledger.j_canon(d->'memo', 1, 256) THEN
      RETURN false;
    END IF;
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION clearledger.event_row_valid(
  p_event_id uuid, p_settlement_id uuid, p_version integer, p_type text,
  p_correlation text, p_idempotency text, p_occurred timestamptz, p_payload jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT clearledger.envelope_valid(p_payload) THEN RETURN false; END IF;
  RETURN (p_payload->>'eventId')::uuid = p_event_id
     AND (p_payload->>'aggregateId')::uuid = p_settlement_id
     AND (p_payload->>'aggregateVersion')::integer = p_version
     AND (p_payload->>'eventType') = p_type
     AND (p_payload->>'correlationId') = p_correlation
     AND (p_payload->>'idempotencyKey') = p_idempotency
     AND (p_payload->>'occurredAt')::timestamptz = p_occurred;
END;
$$;

CREATE OR REPLACE FUNCTION clearledger.outbox_row_valid(
  p_event_id uuid, p_settlement_id uuid, p_version integer, p_correlation text, p_payload jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT clearledger.envelope_valid(p_payload) THEN RETURN false; END IF;
  RETURN (p_payload->>'eventId')::uuid = p_event_id
     AND (p_payload->>'aggregateId')::uuid = p_settlement_id
     AND (p_payload->>'aggregateVersion')::integer = p_version
     AND (p_payload->>'correlationId') = p_correlation;
END;
$$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_body_valid(p_scope text, p_status integer, p_body jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v integer;
BEGIN
  IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_body) AS k
             WHERE k <> ALL (ARRAY['settlementId','eventId','version','accepted','idempotentReplay'])) THEN
    RETURN false;
  END IF;
  IF NOT (p_body ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF NOT clearledger.j_uuid(p_body->'settlementId') OR NOT clearledger.j_uuid(p_body->'eventId') THEN RETURN false; END IF;
  IF p_body->'accepted' IS DISTINCT FROM 'true'::jsonb OR p_body->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(p_body->'version') <> 'number' OR (p_body->>'version') !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  v := (p_body->>'version')::integer;
  IF lower(substring(p_scope FROM '^[a-z]+:(.*)$')) <> lower(p_body->>'settlementId') THEN RETURN false; END IF;
  RETURN (p_scope LIKE 'create:%' AND p_status = 201 AND v = 1)
      OR (p_scope LIKE 'entry:%' AND p_status = 202 AND v >= 2);
END;
$$;

-- ---------------------------------------------------------------------------
-- Tables (columns are re-asserted below so drift is repaired)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id UUID NOT NULL,
  account_id    TEXT NOT NULL,
  reference     TEXT NOT NULL,
  debit_party   TEXT NOT NULL,
  credit_party  TEXT NOT NULL,
  current_status TEXT NOT NULL,
  current_stage TEXT NOT NULL,
  last_entry_id UUID NULL,
  last_memo     TEXT NULL,
  version       INTEGER NOT NULL,
  entry_count   INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT settlements_pkey PRIMARY KEY (settlement_id)
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq            BIGSERIAL NOT NULL,
  event_id       UUID NOT NULL,
  settlement_id  UUID NOT NULL,
  aggregate_version INTEGER NOT NULL,
  event_type     TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at    TIMESTAMPTZ NOT NULL,
  payload        JSONB NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT events_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq            BIGSERIAL NOT NULL,
  event_id       UUID NOT NULL,
  settlement_id  UUID NOT NULL,
  aggregate_version INTEGER NOT NULL,
  correlation_id TEXT NOT NULL,
  payload        JSONB NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at   TIMESTAMPTZ NULL,
  archived_at    TIMESTAMPTZ NULL,
  attempts       INTEGER NOT NULL DEFAULT 0,
  last_error     TEXT NULL,
  CONSTRAINT outbox_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash    TEXT NOT NULL,
  status_code     INTEGER NOT NULL,
  response_body   JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT idempotency_keys_pkey PRIMARY KEY (scope, idempotency_key)
);

-- Re-assert NOT NULL / defaults on every column (repairs out-of-band ALTERs).
DO $$
DECLARE
  spec text[][] := ARRAY[
    ['settlements','account_id','TEXT',NULL],['settlements','reference','TEXT',NULL],
    ['settlements','debit_party','TEXT',NULL],['settlements','credit_party','TEXT',NULL],
    ['settlements','current_status','TEXT',NULL],['settlements','current_stage','TEXT',NULL],
    ['settlements','version','INTEGER',NULL],['settlements','entry_count','INTEGER','0'],
    ['settlements','created_at','TIMESTAMPTZ','NOW()'],['settlements','updated_at','TIMESTAMPTZ','NOW()'],
    ['events','event_id','UUID',NULL],['events','settlement_id','UUID',NULL],
    ['events','aggregate_version','INTEGER',NULL],['events','event_type','TEXT',NULL],
    ['events','correlation_id','TEXT',NULL],['events','idempotency_key','TEXT',NULL],
    ['events','occurred_at','TIMESTAMPTZ',NULL],['events','payload','JSONB',NULL],
    ['events','created_at','TIMESTAMPTZ','NOW()'],
    ['outbox','event_id','UUID',NULL],['outbox','settlement_id','UUID',NULL],
    ['outbox','aggregate_version','INTEGER',NULL],['outbox','correlation_id','TEXT',NULL],
    ['outbox','payload','JSONB',NULL],['outbox','created_at','TIMESTAMPTZ','NOW()'],
    ['outbox','attempts','INTEGER','0'],
    ['idempotency_keys','request_hash','TEXT',NULL],['idempotency_keys','status_code','INTEGER',NULL],
    ['idempotency_keys','response_body','JSONB',NULL],['idempotency_keys','created_at','TIMESTAMPTZ','NOW()']
  ];
  i integer;
BEGIN
  FOR i IN 1 .. array_length(spec, 1) LOOP
    EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET NOT NULL', spec[i][1], spec[i][2]);
    IF spec[i][4] IS NOT NULL THEN
      EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET DEFAULT %s', spec[i][1], spec[i][2], spec[i][4]);
    END IF;
  END LOOP;
END $$;

ALTER TABLE clearledger.settlements ADD COLUMN IF NOT EXISTS last_entry_id UUID NULL;
ALTER TABLE clearledger.settlements ADD COLUMN IF NOT EXISTS last_memo TEXT NULL;
ALTER TABLE clearledger.outbox ADD COLUMN IF NOT EXISTS published_at TIMESTAMPTZ NULL;
ALTER TABLE clearledger.outbox ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ NULL;
ALTER TABLE clearledger.outbox ADD COLUMN IF NOT EXISTS last_error TEXT NULL;

-- ---------------------------------------------------------------------------
-- Keys / unique / foreign keys (created only when missing or not validated)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.ensure_constraint(p_table text, p_name text, p_def text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint c
             WHERE c.conrelid = p_table::regclass AND c.conname = p_name AND c.convalidated) THEN
    RETURN;
  END IF;
  EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', p_table, p_name);
  EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', p_table, p_name, p_def);
END $$;

-- drop-and-recreate (inside this transaction) for CHECK constraints so that their
-- definition always matches the contract
CREATE OR REPLACE FUNCTION pg_temp.replace_check(p_table text, p_name text, p_expr text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', p_table, p_name);
  EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s)', p_table, p_name, p_expr);
END $$;

-- primary keys: only (re)create when no primary key exists
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['settlements','events','outbox','idempotency_keys'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = ('clearledger.' || t)::regclass AND contype = 'p') THEN
      IF t = 'settlements' THEN ALTER TABLE clearledger.settlements ADD CONSTRAINT settlements_pkey PRIMARY KEY (settlement_id);
      ELSIF t = 'events' THEN ALTER TABLE clearledger.events ADD CONSTRAINT events_pkey PRIMARY KEY (seq);
      ELSIF t = 'outbox' THEN ALTER TABLE clearledger.outbox ADD CONSTRAINT outbox_pkey PRIMARY KEY (seq);
      ELSE ALTER TABLE clearledger.idempotency_keys ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY (scope, idempotency_key);
      END IF;
    END IF;
  END LOOP;
END $$;

-- FKs must be dropped before the unique constraints they depend on could be rebuilt;
-- unique constraints are only rebuilt when missing, so order below is safe.
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_event_id_key', 'UNIQUE (event_id)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_settlement_version_key', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_settlement_idempotency_key', 'UNIQUE (settlement_id, idempotency_key)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');

SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_event_id_key', 'UNIQUE (event_id)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_settlement_version_key', 'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_event_id_fkey',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_settlement_version_fkey',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');

-- ---------------------------------------------------------------------------
-- CHECK constraints
-- ---------------------------------------------------------------------------
SELECT pg_temp.replace_check('clearledger.settlements', 'settlements_canonical_text_chk', $c$
  account_id = btrim(account_id) AND reference = btrim(reference)
  AND debit_party = btrim(debit_party) AND credit_party = btrim(credit_party)
  AND current_stage = btrim(current_stage)
  AND (last_memo IS NULL OR last_memo = btrim(last_memo))$c$);
SELECT pg_temp.replace_check('clearledger.settlements', 'settlements_bounds_chk', $c$
  char_length(account_id) BETWEEN 3 AND 64 AND char_length(reference) BETWEEN 3 AND 64
  AND char_length(debit_party) BETWEEN 2 AND 64 AND char_length(credit_party) BETWEEN 2 AND 64
  AND debit_party <> credit_party
  AND (last_memo IS NULL OR char_length(last_memo) BETWEEN 1 AND 256)$c$);
SELECT pg_temp.replace_check('clearledger.settlements', 'settlements_status_chk', $c$
  current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')$c$);
SELECT pg_temp.replace_check('clearledger.settlements', 'settlements_version_chk', 'version >= 1');
SELECT pg_temp.replace_check('clearledger.settlements', 'settlements_initiated_chk', $c$
  version <> 1 OR (entry_count = 0 AND current_status = 'INITIATED'
    AND current_stage = 'INITIATED@' || debit_party AND last_entry_id IS NULL
    AND last_memo = 'Settlement initiated' AND updated_at = created_at)$c$);
SELECT pg_temp.replace_check('clearledger.settlements', 'settlements_entries_chk', $c$
  version = 1 OR (entry_count = version - 1 AND current_status <> 'INITIATED'
    AND last_entry_id IS NOT NULL AND updated_at > created_at
    AND char_length(current_stage) BETWEEN 2 AND 64)$c$);

SELECT pg_temp.replace_check('clearledger.events', 'events_canonical_text_chk', $c$
  correlation_id = btrim(correlation_id) AND idempotency_key = btrim(idempotency_key)$c$);
SELECT pg_temp.replace_check('clearledger.events', 'events_bounds_chk', $c$
  char_length(correlation_id) BETWEEN 4 AND 128 AND char_length(idempotency_key) BETWEEN 8 AND 128
  AND aggregate_version >= 1 AND event_type IN ('SettlementInitiated','LedgerEntryRecorded')$c$);
SELECT pg_temp.replace_check('clearledger.events', 'events_envelope_chk', $c$
  clearledger.event_row_valid(event_id, settlement_id, aggregate_version, event_type,
                              correlation_id, idempotency_key, occurred_at, payload)$c$);

SELECT pg_temp.replace_check('clearledger.outbox', 'outbox_canonical_text_chk', 'correlation_id = btrim(correlation_id)');
SELECT pg_temp.replace_check('clearledger.outbox', 'outbox_envelope_chk', $c$
  aggregate_version >= 1 AND clearledger.outbox_row_valid(event_id, settlement_id, aggregate_version, correlation_id, payload)$c$);
SELECT pg_temp.replace_check('clearledger.outbox', 'outbox_attempts_chk', 'attempts >= 0');
SELECT pg_temp.replace_check('clearledger.outbox', 'outbox_unattempted_chk',
  'attempts <> 0 OR (published_at IS NULL AND last_error IS NULL)');
SELECT pg_temp.replace_check('clearledger.outbox', 'outbox_published_chk', $c$
  published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)$c$);
SELECT pg_temp.replace_check('clearledger.outbox', 'outbox_last_error_chk', $c$
  last_error IS NULL OR (published_at IS NULL AND attempts >= 1
    AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error))$c$);
SELECT pg_temp.replace_check('clearledger.outbox', 'outbox_archived_chk', $c$
  archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)$c$);

SELECT pg_temp.replace_check('clearledger.idempotency_keys', 'idempotency_scope_chk', $c$
  scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'$c$);
SELECT pg_temp.replace_check('clearledger.idempotency_keys', 'idempotency_key_chk', $c$
  idempotency_key = btrim(idempotency_key) AND char_length(idempotency_key) BETWEEN 8 AND 128$c$);
SELECT pg_temp.replace_check('clearledger.idempotency_keys', 'idempotency_hash_chk', $c$
  request_hash ~ '^[0-9a-f]{64}$'$c$);
SELECT pg_temp.replace_check('clearledger.idempotency_keys', 'idempotency_response_chk',
  'clearledger.idempotency_body_valid(scope, status_code, response_body)');

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% on %.% is not permitted (append-only)', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END $$;

CREATE OR REPLACE FUNCTION clearledger.settlements_before_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and immutable', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement version and entry_count must advance by exactly 1' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.updated_at <= OLD.updated_at THEN
    RAISE EXCEPTION 'settlement updated_at must strictly increase' USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'illegal status transition % -> %', OLD.current_status, NEW.current_status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION clearledger.events_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d jsonb := NEW.payload->'data';
  expected integer;
  prev_occurred timestamptz;
  prev_status text;
BEGIN
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT COALESCE(MAX(aggregate_version), 0) + 1 INTO expected
    FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version < expected THEN
    RAISE EXCEPTION 'aggregate_version % already exists for settlement %', NEW.aggregate_version, NEW.settlement_id
      USING ERRCODE = '23505';
  ELSIF NEW.aggregate_version > expected THEN
    RAISE EXCEPTION 'aggregate_version must be contiguous: expected %, got %', expected, NEW.aggregate_version
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version >= 2 AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id AND e.event_type = 'LedgerEntryRecorded'
          AND e.payload->'data'->>'entryId' = d->>'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d->>'entryId', NEW.settlement_id
      USING ERRCODE = '23505';
  END IF;

  IF (d->>'accountId') IS DISTINCT FROM s.account_id OR (d->>'reference') IS DISTINCT FROM s.reference
     OR (d->>'debitParty') IS DISTINCT FROM s.debit_party OR (d->>'creditParty') IS DISTINCT FROM s.credit_party
     OR (d->>'status') IS DISTINCT FROM s.current_status OR (d->>'clearingStage') IS DISTINCT FROM s.current_stage
     OR (d->>'memo') IS DISTINCT FROM s.last_memo
     OR (d->>'entryId')::uuid IS DISTINCT FROM s.last_entry_id
     OR s.version <> NEW.aggregate_version OR NEW.occurred_at <> s.updated_at THEN
    RAISE EXCEPTION 'event does not match settlement state for %', NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF NEW.occurred_at <> s.created_at THEN
      RAISE EXCEPTION 'initial event occurred_at must equal settlement created_at' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT e.occurred_at, e.payload->'data'->>'status' INTO prev_occurred, prev_status
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.aggregate_version = NEW.aggregate_version - 1;
    IF NEW.occurred_at <= prev_occurred THEN
      RAISE EXCEPTION 'occurred_at must strictly increase per settlement' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev_status, d->>'status') THEN
      RAISE EXCEPTION 'illegal status transition % -> %', prev_status, d->>'status' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION clearledger.outbox_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  ev clearledger.events%ROWTYPE;
  expected integer;
BEGIN
  SELECT * INTO ev FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox event % has no matching events row', NEW.event_id USING ERRCODE = '23503';
  END IF;
  IF ev.settlement_id <> NEW.settlement_id OR ev.aggregate_version <> NEW.aggregate_version
     OR ev.correlation_id <> NEW.correlation_id OR ev.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row must mirror events row %', NEW.event_id USING ERRCODE = 'P0001';
  END IF;
  SELECT COALESCE(MAX(aggregate_version), 0) + 1 INTO expected
    FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version < expected THEN
    RAISE EXCEPTION 'outbox aggregate_version % already exists', NEW.aggregate_version USING ERRCODE = '23505';
  ELSIF NEW.aggregate_version > expected THEN
    RAISE EXCEPTION 'outbox aggregate_version must be contiguous: expected %, got %', expected, NEW.aggregate_version
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION clearledger.outbox_before_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.seq IS DISTINCT FROM OLD.seq OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease' USING ERRCODE = 'P0001';
  END IF;

  IF OLD.published_at IS NULL THEN
    IF NEW.published_at IS NOT NULL THEN
      IF NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'publishing requires attempts to increase and archived_at to be NULL' USING ERRCODE = 'P0001';
      END IF;
    ELSIF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'unpublished outbox rows cannot be archived' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF NEW.published_at IS NULL THEN
      -- operational replay: published_at and archived_at are both reset
      IF NEW.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'replay reset must also clear archived_at' USING ERRCODE = 'P0001';
      END IF;
    ELSE
      IF NEW.published_at IS DISTINCT FROM OLD.published_at OR NEW.attempts IS DISTINCT FROM OLD.attempts
         OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
        RAISE EXCEPTION 'published_at, attempts and last_error of a published row are immutable' USING ERRCODE = 'P0001';
      END IF;
      IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
         AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
        RAISE EXCEPTION 'archived_at cannot change without first being reset to NULL' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_before_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  sid uuid := (NEW.response_body->>'settlementId')::uuid;
  eid uuid := (NEW.response_body->>'eventId')::uuid;
  ver integer := (NEW.response_body->>'version')::integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                  WHERE e.event_id = eid AND e.settlement_id = sid AND e.aggregate_version = ver
                    AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency key %/% does not reference a matching event', NEW.scope, NEW.idempotency_key
      USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                  WHERE o.event_id = eid AND o.settlement_id = sid AND o.aggregate_version = ver) THEN
    RAISE EXCEPTION 'idempotency key %/% has no outbox row', NEW.scope, NEW.idempotency_key USING ERRCODE = '23503';
  END IF;
  IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys k
              WHERE k.response_body->>'eventId' = NEW.response_body->>'eventId'
                 OR (k.response_body->>'settlementId' = NEW.response_body->>'settlementId'
                     AND (k.response_body->>'version')::integer = ver)) THEN
    RAISE EXCEPTION 'event % already has an idempotency key', eid USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- Triggers (dropped and re-created so out-of-band changes are repaired)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_settlements_before_update ON clearledger.settlements;
DROP TRIGGER IF EXISTS trg_settlements_no_delete ON clearledger.settlements;
CREATE TRIGGER trg_settlements_before_update BEFORE UPDATE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.settlements_before_update();
CREATE TRIGGER trg_settlements_no_delete BEFORE DELETE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation();

DROP TRIGGER IF EXISTS trg_events_before_insert ON clearledger.events;
DROP TRIGGER IF EXISTS trg_events_append_only ON clearledger.events;
CREATE TRIGGER trg_events_before_insert BEFORE INSERT ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.events_before_insert();
CREATE TRIGGER trg_events_append_only BEFORE UPDATE OR DELETE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation();

DROP TRIGGER IF EXISTS trg_outbox_before_insert ON clearledger.outbox;
DROP TRIGGER IF EXISTS trg_outbox_before_update ON clearledger.outbox;
DROP TRIGGER IF EXISTS trg_outbox_no_delete ON clearledger.outbox;
CREATE TRIGGER trg_outbox_before_insert BEFORE INSERT ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_before_insert();
CREATE TRIGGER trg_outbox_before_update BEFORE UPDATE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_before_update();
CREATE TRIGGER trg_outbox_no_delete BEFORE DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation();

DROP TRIGGER IF EXISTS trg_idempotency_before_insert ON clearledger.idempotency_keys;
DROP TRIGGER IF EXISTS trg_idempotency_immutable ON clearledger.idempotency_keys;
CREATE TRIGGER trg_idempotency_before_insert BEFORE INSERT ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_before_insert();
CREATE TRIGGER trg_idempotency_immutable BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation();

-- ---------------------------------------------------------------------------
-- Indexes (re-created only when missing or when the definition drifted)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  rec record;
  have text;
BEGIN
  FOR rec IN SELECT * FROM (VALUES
    ('idx_clearledger_outbox_unpublished',
     'CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox USING btree (seq) WHERE (published_at IS NULL)'),
    ('idx_clearledger_outbox_unarchived',
     'CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox USING btree (seq) WHERE ((published_at IS NOT NULL) AND (archived_at IS NULL))'),
    ('idx_clearledger_events_settlement_version',
     'CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events USING btree (settlement_id, aggregate_version)')
  ) AS t(name, def)
  LOOP
    SELECT indexdef INTO have FROM pg_indexes WHERE schemaname = 'clearledger' AND indexname = rec.name;
    IF have IS DISTINCT FROM rec.def THEN
      EXECUTE format('DROP INDEX IF EXISTS clearledger.%I', rec.name);
      EXECUTE rec.def;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Make sure every trigger on the four tables is enabled (tgenabled = 'O')
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['settlements','events','outbox','idempotency_keys'] LOOP
    BEGIN
      EXECUTE format('ALTER TABLE clearledger.%I ENABLE TRIGGER ALL', t);
    EXCEPTION WHEN insufficient_privilege THEN
      EXECUTE format('ALTER TABLE clearledger.%I ENABLE TRIGGER USER', t);
    END;
  END LOOP;
END $$;

COMMIT;
