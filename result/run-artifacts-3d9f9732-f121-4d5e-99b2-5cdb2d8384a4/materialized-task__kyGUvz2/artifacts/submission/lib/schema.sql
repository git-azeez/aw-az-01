-- ClearLedger PostgreSQL schema. Idempotent: safe to run on every deploy, on empty or populated databases.
-- Applied with: psql -v ON_ERROR_STOP=1 -1 -f schema.sql   (single transaction)

SELECT pg_advisory_xact_lock(hashtext('clearledger-schema-migration'));

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helper: add a named constraint only when it does not exist yet.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.ensure_constraint(p_table regclass, p_name text, p_ddl text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = p_table AND conname = p_name) THEN
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', p_table, p_name, p_ddl);
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Tables (columns + primary keys). Other constraints are added below by name.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Validation helper functions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(t text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
$$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_json(j jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(jsonb_typeof(j) = 'string' AND clearledger.is_uuid_text(j #>> '{}'), false)
$$;

-- jsonb string whose trimmed length is within [lo, hi]
CREATE OR REPLACE FUNCTION clearledger.json_str_between(j jsonb, lo integer, hi integer) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(jsonb_typeof(j) = 'string' AND char_length(btrim(j #>> '{}')) BETWEEN lo AND hi, false)
$$;

CREATE OR REPLACE FUNCTION clearledger.is_status(s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(s IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'), false)
$$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
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

-- Clearing lifecycle: RECONCILED is terminal, DISPUTED only resolves to DISPUTED/RECONCILED,
-- everything else is rank-monotonic (non-decreasing) or may move to DISPUTED.
CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_status text, new_status text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    CASE
      WHEN old_status = 'RECONCILED' THEN false
      WHEN old_status = 'DISPUTED'   THEN new_status IN ('DISPUTED', 'RECONCILED')
      WHEN NOT clearledger.is_status(old_status) OR NOT clearledger.is_status(new_status) THEN false
      WHEN new_status = 'DISPUTED'   THEN true
      ELSE clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
    END, false)
$$;

-- ClearLedgerDomainEventEnvelope (events.schema.json) with the stricter bounds from openapi.yaml.
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d jsonb;
  v integer;
  v_text text;
  ts_re constant text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$';
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;

  -- additionalProperties:false + required on the envelope
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
                     'occurredAt','correlationId','idempotencyKey','data']) THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p) k
             WHERE k NOT IN ('schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
                             'occurredAt','correlationId','idempotencyKey','data')) THEN RETURN false; END IF;

  IF p->'schemaVersion' IS DISTINCT FROM to_jsonb('1.0'::text) THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_json(p->'eventId') THEN RETURN false; END IF;
  IF NOT (jsonb_typeof(p->'eventType') = 'string'
          AND (p->>'eventType') IN ('SettlementInitiated','LedgerEntryRecorded')) THEN RETURN false; END IF;
  IF p->'aggregateType' IS DISTINCT FROM to_jsonb('settlement'::text) THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_json(p->'aggregateId') THEN RETURN false; END IF;

  v_text := p->>'aggregateVersion';
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR v_text !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  v := v_text::integer;

  IF NOT (jsonb_typeof(p->'occurredAt') = 'string' AND (p->>'occurredAt') ~ ts_re) THEN RETURN false; END IF;
  IF NOT clearledger.json_str_between(p->'correlationId', 4, 128) THEN RETURN false; END IF;
  IF NOT clearledger.json_str_between(p->'idempotencyKey', 8, 128) THEN RETURN false; END IF;
  -- idempotencyKey is also trimmed-length bounded in the column; the envelope must not be shorter than 8 raw chars
  IF char_length(p->>'idempotencyKey') < 8 OR char_length(p->>'correlationId') < 4 THEN RETURN false; END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(d) k
             WHERE k NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo'))
  THEN RETURN false; END IF;

  IF NOT (jsonb_typeof(d->'kind') = 'string' AND (d->>'kind') IN ('settlementInitiated','ledgerEntryRecorded')) THEN RETURN false; END IF;
  IF NOT clearledger.json_str_between(d->'accountId', 3, 64)    THEN RETURN false; END IF;
  IF NOT clearledger.json_str_between(d->'reference', 3, 64)    THEN RETURN false; END IF;
  IF NOT clearledger.json_str_between(d->'debitParty', 2, 64)   THEN RETURN false; END IF;
  IF NOT clearledger.json_str_between(d->'creditParty', 2, 64)  THEN RETURN false; END IF;
  IF btrim(d->>'debitParty') = btrim(d->>'creditParty')         THEN RETURN false; END IF;
  IF NOT clearledger.json_str_between(d->'clearingStage', 2, 64) THEN RETURN false; END IF;
  IF NOT (jsonb_typeof(d->'status') = 'string' AND clearledger.is_status(d->>'status')) THEN RETURN false; END IF;

  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null'
     AND NOT clearledger.json_str_between(d->'memo', 1, 256) THEN RETURN false; END IF;
  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null'
     AND NOT clearledger.is_uuid_json(d->'entryId') THEN RETURN false; END IF;

  -- version / kind / status / entryId coupling
  IF v = 1 THEN
    IF (p->>'eventType') <> 'SettlementInitiated' OR (d->>'kind') <> 'settlementInitiated' THEN RETURN false; END IF;
    IF (d->>'status') <> 'INITIATED' THEN RETURN false; END IF;
    IF (d->>'entryId') IS NOT NULL THEN RETURN false; END IF;
  ELSE
    IF (p->>'eventType') <> 'LedgerEntryRecorded' OR (d->>'kind') <> 'ledgerEntryRecorded' THEN RETURN false; END IF;
    IF (d->>'status') = 'INITIATED' THEN RETURN false; END IF;
    IF (d->>'entryId') IS NULL THEN RETURN false; END IF;
  END IF;

  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Column-to-envelope equality for events.
CREATE OR REPLACE FUNCTION clearledger.event_columns_match(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_event_type text,
  c_correlation_id text, c_idempotency_key text, c_occurred_at timestamptz) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (p->>'eventId')::uuid = c_event_id
     AND (p->>'aggregateId')::uuid = c_settlement_id
     AND (p->>'aggregateVersion')::integer = c_version
     AND (p->>'eventType') = c_event_type
     AND (p->>'correlationId') = c_correlation_id
     AND (p->>'idempotencyKey') = c_idempotency_key
     AND (p->>'occurredAt')::timestamptz = c_occurred_at;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Column-to-envelope equality for outbox rows.
CREATE OR REPLACE FUNCTION clearledger.outbox_columns_match(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation_id text) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN (p->>'eventId')::uuid = c_event_id
     AND (p->>'aggregateId')::uuid = c_settlement_id
     AND (p->>'aggregateVersion')::integer = c_version
     AND (p->>'correlationId') = c_correlation_id;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Idempotency response body (WriteAcceptedResponse, closed schema) coupled to scope and status code.
CREATE OR REPLACE FUNCTION clearledger.idempotency_row_valid(p_scope text, p_status integer, b jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v integer;
  v_text text;
  kind text;
  scope_id text;
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(b) k
             WHERE k NOT IN ('settlementId','eventId','version','accepted','idempotentReplay')) THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_json(b->'settlementId') OR NOT clearledger.is_uuid_json(b->'eventId') THEN RETURN false; END IF;
  v_text := b->>'version';
  IF jsonb_typeof(b->'version') <> 'number' OR v_text !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  v := v_text::integer;
  IF b->'accepted' IS DISTINCT FROM 'true'::jsonb OR b->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb THEN RETURN false; END IF;

  kind := split_part(p_scope, ':', 1);
  scope_id := split_part(p_scope, ':', 2);
  IF NOT clearledger.is_uuid_text(scope_id) OR lower(scope_id) <> lower(b->>'settlementId') THEN RETURN false; END IF;
  IF kind = 'create' THEN
    RETURN p_status = 201 AND v = 1;
  ELSIF kind = 'entry' THEN
    RETURN p_status = 202 AND v >= 2;
  END IF;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- ---------------------------------------------------------------------------
-- settlements: constraints
-- ---------------------------------------------------------------------------
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_account_id_len_chk',
  'CHECK (char_length(btrim(account_id)) BETWEEN 3 AND 64)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_reference_len_chk',
  'CHECK (char_length(btrim(reference)) BETWEEN 3 AND 64)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_debit_party_len_chk',
  'CHECK (char_length(btrim(debit_party)) BETWEEN 2 AND 64)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_credit_party_len_chk',
  'CHECK (char_length(btrim(credit_party)) BETWEEN 2 AND 64)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_parties_distinct_chk',
  'CHECK (btrim(debit_party) <> btrim(credit_party))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_status_chk',
  'CHECK (current_status IN (''INITIATED'',''VALIDATED'',''RESERVED'',''CLEARED'',''SETTLED'',''RECONCILED'',''DISPUTED''))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_stage_len_chk',
  'CHECK (char_length(btrim(current_stage)) BETWEEN 2 AND 64)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_memo_len_chk',
  'CHECK (last_memo IS NULL OR char_length(btrim(last_memo)) BETWEEN 1 AND 256)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_version_chk',
  'CHECK (version >= 1)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_entry_count_chk',
  'CHECK (entry_count >= 0)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_timestamps_chk',
  'CHECK (updated_at >= created_at)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_initial_state_chk',
  'CHECK (version <> 1 OR (entry_count = 0 AND current_status = ''INITIATED'' AND last_entry_id IS NULL AND updated_at = created_at))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'settlements_progressed_state_chk',
  'CHECK (version = 1 OR (entry_count = version - 1 AND current_status <> ''INITIATED'' AND last_entry_id IS NOT NULL))');

-- ---------------------------------------------------------------------------
-- events: constraints
-- ---------------------------------------------------------------------------
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_event_id_key',
  'UNIQUE (event_id)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements (settlement_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_settlement_version_key',
  'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_settlement_idempotency_key',
  'UNIQUE (settlement_id, idempotency_key)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_version_chk',
  'CHECK (aggregate_version >= 1)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_event_type_chk',
  'CHECK (event_type IN (''SettlementInitiated'',''LedgerEntryRecorded''))');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_correlation_id_len_chk',
  'CHECK (char_length(btrim(correlation_id)) BETWEEN 4 AND 128)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_idempotency_key_len_chk',
  'CHECK (char_length(btrim(idempotency_key)) BETWEEN 8 AND 128)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_payload_envelope_chk',
  'CHECK (clearledger.envelope_valid(payload))');
SELECT pg_temp.ensure_constraint('clearledger.events', 'events_payload_columns_chk',
  'CHECK (clearledger.event_columns_match(payload, event_id, settlement_id, aggregate_version, event_type, correlation_id, idempotency_key, occurred_at))');

-- ---------------------------------------------------------------------------
-- outbox: constraints
-- ---------------------------------------------------------------------------
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_event_id_key',
  'UNIQUE (event_id)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_event_id_fkey',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events (event_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_settlement_id_fkey',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements (settlement_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_settlement_version_key',
  'UNIQUE (settlement_id, aggregate_version)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_settlement_version_fkey',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events (settlement_id, aggregate_version) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_version_chk',
  'CHECK (aggregate_version >= 1)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_correlation_id_len_chk',
  'CHECK (char_length(btrim(correlation_id)) BETWEEN 4 AND 128)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_payload_envelope_chk',
  'CHECK (clearledger.envelope_valid(payload))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_payload_columns_chk',
  'CHECK (clearledger.outbox_columns_match(payload, event_id, settlement_id, aggregate_version, correlation_id))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_attempts_chk',
  'CHECK (attempts >= 0)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_published_chk',
  'CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'outbox_archived_chk',
  'CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))');

-- ---------------------------------------------------------------------------
-- idempotency_keys: constraints
-- ---------------------------------------------------------------------------
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'idempotency_scope_chk',
  'CHECK (scope ~ ''^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'')');
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'idempotency_key_len_chk',
  'CHECK (char_length(btrim(idempotency_key)) BETWEEN 8 AND 128)');
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'idempotency_request_hash_chk',
  'CHECK (request_hash ~ ''^[0-9a-f]{64}$'')');
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'idempotency_status_code_chk',
  'CHECK (status_code IN (201, 202))');
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'idempotency_response_body_chk',
  'CHECK (clearledger.idempotency_row_valid(scope, status_code, response_body))');

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

-- settlements: header immutability, +1 stepping, lifecycle progression.
CREATE OR REPLACE FUNCTION clearledger.settlements_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.updated_at < NEW.created_at THEN
      RAISE EXCEPTION 'settlement % updated_at must not precede created_at', NEW.settlement_id USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and can no longer be updated', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement % version must advance by exactly 1 (% -> %)', OLD.settlement_id, OLD.version, NEW.version
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % entry_count must advance by exactly 1', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update must carry a new last_entry_id', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement % updated_at must be monotonic', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % illegal status transition % -> %', OLD.settlement_id, OLD.current_status, NEW.current_status
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

-- events: append-only, contiguous, consistent with the settlement row.
CREATE OR REPLACE FUNCTION clearledger.events_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  s clearledger.settlements%ROWTYPE;
  prev clearledger.events%ROWTYPE;
  max_version integer;
  d jsonb;
  entry text;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    RAISE EXCEPTION 'clearledger.events is append-only (% rejected)', TG_OP USING ERRCODE = 'P0001';
  END IF;

  d := NEW.payload->'data';

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT COALESCE(MAX(aggregate_version), 0) INTO max_version FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> max_version + 1 THEN
    RAISE EXCEPTION 'event version for settlement % must be contiguous (expected %, got %)',
      NEW.settlement_id, max_version + 1, NEW.aggregate_version USING ERRCODE = 'P0001';
  END IF;

  entry := d->>'entryId';
  IF entry IS NOT NULL AND NEW.event_type = 'LedgerEntryRecorded' AND EXISTS (
       SELECT 1 FROM clearledger.events e
       WHERE e.settlement_id = NEW.settlement_id
         AND e.event_type = 'LedgerEntryRecorded'
         AND lower(e.payload->'data'->>'entryId') = lower(entry)) THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', entry, NEW.settlement_id USING ERRCODE = '23505';
  END IF;

  -- the event must describe the parent settlement row exactly
  IF (d->>'accountId') IS DISTINCT FROM s.account_id
     OR (d->>'reference') IS DISTINCT FROM s.reference
     OR (d->>'debitParty') IS DISTINCT FROM s.debit_party
     OR (d->>'creditParty') IS DISTINCT FROM s.credit_party
     OR (d->>'status') IS DISTINCT FROM s.current_status
     OR (d->>'clearingStage') IS DISTINCT FROM s.current_stage
     OR (d->>'memo') IS DISTINCT FROM s.last_memo
     OR lower(d->>'entryId') IS DISTINCT FROM lower(s.last_entry_id::text)
     OR NEW.aggregate_version IS DISTINCT FROM s.version
     OR NEW.occurred_at IS DISTINCT FROM s.updated_at THEN
    RAISE EXCEPTION 'event % does not match settlement % state', NEW.event_id, NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.aggregate_version = 1 AND NEW.occurred_at IS DISTINCT FROM s.created_at THEN
    RAISE EXCEPTION 'initial event % must occur at settlement creation time', NEW.event_id USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version >= 2 THEN
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'missing predecessor event for settlement % version %', NEW.settlement_id, NEW.aggregate_version
        USING ERRCODE = 'P0001';
    END IF;
    IF NEW.occurred_at < prev.occurred_at THEN
      RAISE EXCEPTION 'event occurred_at must not precede the previous event of settlement %', NEW.settlement_id
        USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'illegal status transition % -> % for settlement %',
        prev.payload->'data'->>'status', d->>'status', NEW.settlement_id USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

-- outbox: mirrors events, contiguous, delivery lifecycle.
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  e clearledger.events%ROWTYPE;
  max_version integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted' USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id USING ERRCODE = '23503';
    END IF;
    IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
       OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
       OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
       OR e.payload IS DISTINCT FROM NEW.payload THEN
      RAISE EXCEPTION 'outbox row for event % must mirror the event row', NEW.event_id USING ERRCODE = 'P0001';
    END IF;
    SELECT COALESCE(MAX(aggregate_version), 0) INTO max_version FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version <> max_version + 1 THEN
      RAISE EXCEPTION 'outbox version for settlement % must be contiguous (expected %, got %)',
        NEW.settlement_id, max_version + 1, NEW.aggregate_version USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE
  IF NEW.seq IS DISTINCT FROM OLD.seq
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns are immutable (event %)', OLD.event_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease (event %)', OLD.event_id USING ERRCODE = 'P0001';
  END IF;

  IF OLD.published_at IS NULL THEN
    IF NEW.published_at IS NOT NULL THEN
      IF NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'publishing outbox event % requires attempts to increase and archived_at to stay NULL', OLD.event_id
          USING ERRCODE = 'P0001';
      END IF;
    END IF;
  ELSIF NEW.published_at IS NULL THEN
    -- operational replay: published_at and archived_at are reset together
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'resetting published_at requires archived_at to be reset as well (event %)', OLD.event_id
        USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox event % delivery columns are immutable', OLD.event_id USING ERRCODE = 'P0001';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at of event % must be reset to NULL before it can change', OLD.event_id USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

-- idempotency_keys: immutable, and bound to an existing event + outbox row.
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  body jsonb;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    RAISE EXCEPTION 'clearledger.idempotency_keys is immutable (% rejected)', TG_OP USING ERRCODE = 'P0001';
  END IF;

  body := NEW.response_body;
  IF NOT EXISTS (
       SELECT 1 FROM clearledger.events e
       WHERE e.event_id = (body->>'eventId')::uuid
         AND e.settlement_id = (body->>'settlementId')::uuid
         AND e.aggregate_version = (body->>'version')::integer
         AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency key % does not reference an existing event', NEW.idempotency_key USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM clearledger.outbox o
       WHERE o.event_id = (body->>'eventId')::uuid
         AND o.settlement_id = (body->>'settlementId')::uuid
         AND o.aggregate_version = (body->>'version')::integer) THEN
    RAISE EXCEPTION 'idempotency key % does not reference an existing outbox row', NEW.idempotency_key USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers (dropped + recreated so function wiring is always canonical)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_settlements_guard ON clearledger.settlements;
CREATE TRIGGER trg_settlements_guard BEFORE INSERT OR UPDATE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.settlements_guard();

DROP TRIGGER IF EXISTS trg_events_guard ON clearledger.events;
CREATE TRIGGER trg_events_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.events_guard();

DROP TRIGGER IF EXISTS trg_outbox_guard ON clearledger.outbox;
CREATE TRIGGER trg_outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();

DROP TRIGGER IF EXISTS trg_idempotency_guard ON clearledger.idempotency_keys;
CREATE TRIGGER trg_idempotency_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);
