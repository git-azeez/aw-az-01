-- ClearLedger PostgreSQL schema (idempotent).
-- Applied by deploy.sh on every run inside a single transaction.

\set ON_ERROR_STOP on

BEGIN;

SELECT pg_advisory_xact_lock(4242424242);

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.tlen(v text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT char_length(btrim(v))
$$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(v text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT v IS NOT NULL
     AND v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text)
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

-- Clearing lifecycle transition rule shared by settlements and events.
CREATE OR REPLACE FUNCTION clearledger.valid_transition(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN old_status IS NULL OR new_status IS NULL THEN false
    WHEN old_status = 'RECONCILED' THEN false
    WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED', 'RECONCILED')
    WHEN new_status = 'DISPUTED' THEN clearledger.status_rank(old_status) IS NOT NULL
    WHEN clearledger.status_rank(old_status) IS NULL
      OR clearledger.status_rank(new_status) IS NULL THEN false
    ELSE clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
  END
$$;

-- Strict validation of ClearLedgerDomainEventEnvelope (events.schema.json).
CREATE OR REPLACE FUNCTION clearledger.valid_envelope(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  d jsonb;
  k text;
  v numeric;
  ts_re constant text :=
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$';
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RETURN false;
  END IF;

  -- additionalProperties: false + all ten keys required
  FOR k IN SELECT jsonb_object_keys(p) LOOP
    IF k NOT IN ('schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId',
                 'aggregateVersion', 'occurredAt', 'correlationId', 'idempotencyKey', 'data') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (p ?& ARRAY['schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId',
                     'aggregateVersion', 'occurredAt', 'correlationId', 'idempotencyKey', 'data']) THEN
    RETURN false;
  END IF;

  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string'
     OR p->>'eventType' NOT IN ('SettlementInitiated', 'LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'aggregateId') THEN RETURN false; END IF;

  IF jsonb_typeof(p->'aggregateVersion') <> 'number' THEN RETURN false; END IF;
  v := (p->>'aggregateVersion')::numeric;
  IF v <> trunc(v) OR v < 1 OR v > 2147483647 THEN RETURN false; END IF;

  IF jsonb_typeof(p->'occurredAt') <> 'string' OR (p->>'occurredAt') !~ ts_re THEN RETURN false; END IF;
  PERFORM (p->>'occurredAt')::timestamptz;

  IF jsonb_typeof(p->'correlationId') <> 'string'
     OR char_length(p->>'correlationId') < 4
     OR clearledger.tlen(p->>'correlationId') NOT BETWEEN 4 AND 128 THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string'
     OR char_length(p->>'idempotencyKey') < 8
     OR clearledger.tlen(p->>'idempotencyKey') NOT BETWEEN 8 AND 128 THEN RETURN false; END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(d) LOOP
    IF k NOT IN ('kind', 'accountId', 'reference', 'debitParty', 'creditParty',
                 'entryId', 'status', 'clearingStage', 'memo') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (d ?& ARRAY['kind', 'accountId', 'reference', 'debitParty', 'creditParty', 'status', 'clearingStage']) THEN
    RETURN false;
  END IF;

  IF jsonb_typeof(d->'kind') <> 'string'
     OR d->>'kind' NOT IN ('settlementInitiated', 'ledgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'accountId') <> 'string' OR clearledger.tlen(d->>'accountId') NOT BETWEEN 3 AND 64 THEN RETURN false; END IF;
  IF jsonb_typeof(d->'reference') <> 'string' OR clearledger.tlen(d->>'reference') NOT BETWEEN 3 AND 64 THEN RETURN false; END IF;
  IF jsonb_typeof(d->'debitParty') <> 'string' OR clearledger.tlen(d->>'debitParty') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  IF jsonb_typeof(d->'creditParty') <> 'string' OR clearledger.tlen(d->>'creditParty') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  IF btrim(d->>'debitParty') = btrim(d->>'creditParty') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'status') <> 'string'
     OR d->>'status' NOT IN ('INITIATED', 'VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED', 'RECONCILED', 'DISPUTED') THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(d->'clearingStage') <> 'string' OR clearledger.tlen(d->>'clearingStage') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;

  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN
    IF jsonb_typeof(d->'entryId') <> 'string' OR NOT clearledger.is_uuid_text(d->>'entryId') THEN RETURN false; END IF;
  END IF;
  IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
    IF jsonb_typeof(d->'memo') <> 'string' OR clearledger.tlen(d->>'memo') NOT BETWEEN 1 AND 256 THEN RETURN false; END IF;
  END IF;

  -- version / kind / status / entryId coupling
  IF p->>'eventType' = 'SettlementInitiated' THEN
    IF v <> 1 OR d->>'kind' <> 'settlementInitiated' OR d->>'status' <> 'INITIATED'
       OR (d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null') THEN
      RETURN false;
    END IF;
  ELSE
    IF v < 2 OR d->>'kind' <> 'ledgerEntryRecorded' OR d->>'status' = 'INITIATED'
       OR NOT (d ? 'entryId') OR jsonb_typeof(d->'entryId') <> 'string' THEN
      RETURN false;
    END IF;
  END IF;

  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Column-to-envelope equality for clearledger.events.
CREATE OR REPLACE FUNCTION clearledger.event_matches_envelope(
  p jsonb, e_event_id uuid, e_settlement_id uuid, e_version integer, e_type text,
  e_correlation text, e_idem text, e_occurred timestamptz)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.valid_envelope(p) THEN
    RETURN false;
  END IF;
  RETURN (p->>'eventId')::uuid = e_event_id
     AND (p->>'aggregateId')::uuid = e_settlement_id
     AND (p->>'aggregateVersion')::integer = e_version
     AND p->>'eventType' = e_type
     AND p->>'correlationId' = e_correlation
     AND p->>'idempotencyKey' = e_idem
     AND (p->>'occurredAt')::timestamptz = e_occurred;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Column-to-envelope equality for clearledger.outbox.
CREATE OR REPLACE FUNCTION clearledger.outbox_matches_envelope(
  p jsonb, o_event_id uuid, o_settlement_id uuid, o_version integer, o_correlation text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF NOT clearledger.valid_envelope(p) THEN
    RETURN false;
  END IF;
  RETURN (p->>'eventId')::uuid = o_event_id
     AND (p->>'aggregateId')::uuid = o_settlement_id
     AND (p->>'aggregateVersion')::integer = o_version
     AND p->>'correlationId' = o_correlation;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- WriteAcceptedResponse closed-schema validation for idempotency_keys.
CREATE OR REPLACE FUNCTION clearledger.valid_write_response(scope text, status_code integer, b jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  k text;
  v numeric;
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(b) LOOP
    IF k NOT IN ('settlementId', 'eventId', 'version', 'accepted', 'idempotentReplay') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (b ?& ARRAY['settlementId', 'eventId', 'version', 'accepted', 'idempotentReplay']) THEN RETURN false; END IF;
  IF jsonb_typeof(b->'settlementId') <> 'string' OR NOT clearledger.is_uuid_text(b->>'settlementId') THEN RETURN false; END IF;
  IF jsonb_typeof(b->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(b->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(b->'version') <> 'number' THEN RETURN false; END IF;
  v := (b->>'version')::numeric;
  IF v <> trunc(v) OR v < 1 THEN RETURN false; END IF;
  IF b->'accepted' <> 'true'::jsonb THEN RETURN false; END IF;
  IF b->'idempotentReplay' <> 'false'::jsonb THEN RETURN false; END IF;
  IF (b->>'settlementId')::uuid <> substr(scope, strpos(scope, ':') + 1)::uuid THEN RETURN false; END IF;
  IF scope LIKE 'create:%' THEN
    RETURN status_code = 201 AND v = 1;
  ELSIF scope LIKE 'entry:%' THEN
    RETURN status_code = 202 AND v >= 2;
  END IF;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Adds a named constraint only when it does not already exist.
CREATE OR REPLACE FUNCTION clearledger.ensure_constraint(tbl regclass, cname text, ddl text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = tbl AND conname = cname) THEN
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', tbl, cname, ddl);
  END IF;
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
  seq              BIGSERIAL   NOT NULL,
  event_id         UUID        NOT NULL,
  settlement_id    UUID        NOT NULL,
  aggregate_version INTEGER    NOT NULL,
  event_type       TEXT        NOT NULL,
  correlation_id   TEXT        NOT NULL,
  idempotency_key  TEXT        NOT NULL,
  occurred_at      TIMESTAMPTZ NOT NULL,
  payload          JSONB       NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
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
-- settlements constraints
-- ---------------------------------------------------------------------------
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_account_id_len_chk',
  $c$CHECK (clearledger.tlen(account_id) BETWEEN 3 AND 64)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_reference_len_chk',
  $c$CHECK (clearledger.tlen(reference) BETWEEN 3 AND 64)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_debit_party_len_chk',
  $c$CHECK (clearledger.tlen(debit_party) BETWEEN 2 AND 64)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_credit_party_len_chk',
  $c$CHECK (clearledger.tlen(credit_party) BETWEEN 2 AND 64)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_parties_distinct_chk',
  $c$CHECK (btrim(debit_party) <> btrim(credit_party))$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_status_chk',
  $c$CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_stage_len_chk',
  $c$CHECK (clearledger.tlen(current_stage) BETWEEN 2 AND 64)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_last_memo_len_chk',
  $c$CHECK (last_memo IS NULL OR clearledger.tlen(last_memo) BETWEEN 1 AND 256)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_version_chk',
  $c$CHECK (version >= 1)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_timestamps_chk',
  $c$CHECK (updated_at >= created_at)$c$);
SELECT clearledger.ensure_constraint('clearledger.settlements', 'settlements_lifecycle_chk',
  $c$CHECK (
    (version = 1 AND entry_count = 0 AND current_status = 'INITIATED'
       AND last_entry_id IS NULL AND updated_at = created_at)
    OR
    (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED'
       AND last_entry_id IS NOT NULL)
  )$c$);

-- ---------------------------------------------------------------------------
-- events constraints
-- ---------------------------------------------------------------------------
SELECT clearledger.ensure_constraint('clearledger.events', 'events_event_id_key',
  $c$UNIQUE (event_id)$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_settlement_id_fkey',
  $c$FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_settlement_version_key',
  $c$UNIQUE (settlement_id, aggregate_version)$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_settlement_idempotency_key',
  $c$UNIQUE (settlement_id, idempotency_key)$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_version_chk',
  $c$CHECK (aggregate_version >= 1)$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_type_chk',
  $c$CHECK (
    (event_type = 'SettlementInitiated' AND aggregate_version = 1)
    OR (event_type = 'LedgerEntryRecorded' AND aggregate_version >= 2)
  )$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_correlation_id_len_chk',
  $c$CHECK (clearledger.tlen(correlation_id) BETWEEN 4 AND 128)$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_idempotency_key_len_chk',
  $c$CHECK (clearledger.tlen(idempotency_key) BETWEEN 8 AND 128)$c$);
SELECT clearledger.ensure_constraint('clearledger.events', 'events_payload_envelope_chk',
  $c$CHECK (clearledger.event_matches_envelope(payload, event_id, settlement_id, aggregate_version,
                                                event_type, correlation_id, idempotency_key, occurred_at))$c$);

-- ---------------------------------------------------------------------------
-- outbox constraints
-- ---------------------------------------------------------------------------
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_event_id_key',
  $c$UNIQUE (event_id)$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_event_id_fkey',
  $c$FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_settlement_id_fkey',
  $c$FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_settlement_version_key',
  $c$UNIQUE (settlement_id, aggregate_version)$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_event_version_fkey',
  $c$FOREIGN KEY (settlement_id, aggregate_version)
     REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_version_chk',
  $c$CHECK (aggregate_version >= 1)$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_correlation_id_len_chk',
  $c$CHECK (clearledger.tlen(correlation_id) BETWEEN 4 AND 128)$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_attempts_chk',
  $c$CHECK (attempts >= 0)$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_published_chk',
  $c$CHECK (published_at IS NULL
            OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_archived_chk',
  $c$CHECK (archived_at IS NULL
            OR (published_at IS NOT NULL AND archived_at >= published_at))$c$);
SELECT clearledger.ensure_constraint('clearledger.outbox', 'outbox_payload_envelope_chk',
  $c$CHECK (clearledger.outbox_matches_envelope(payload, event_id, settlement_id, aggregate_version, correlation_id))$c$);

-- ---------------------------------------------------------------------------
-- idempotency_keys constraints
-- ---------------------------------------------------------------------------
SELECT clearledger.ensure_constraint('clearledger.idempotency_keys', 'idempotency_keys_scope_chk',
  $c$CHECK (scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')$c$);
SELECT clearledger.ensure_constraint('clearledger.idempotency_keys', 'idempotency_keys_key_len_chk',
  $c$CHECK (clearledger.tlen(idempotency_key) BETWEEN 8 AND 128)$c$);
SELECT clearledger.ensure_constraint('clearledger.idempotency_keys', 'idempotency_keys_request_hash_chk',
  $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$);
SELECT clearledger.ensure_constraint('clearledger.idempotency_keys', 'idempotency_keys_status_code_chk',
  $c$CHECK ((scope LIKE 'create:%' AND status_code = 201) OR (scope LIKE 'entry:%' AND status_code = 202))$c$);
SELECT clearledger.ensure_constraint('clearledger.idempotency_keys', 'idempotency_keys_response_body_chk',
  $c$CHECK (clearledger.valid_write_response(scope, status_code, response_body))$c$);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

-- settlements: header immutability, +1 stepping and lifecycle progression.
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED (terminal) and cannot be modified', OLD.settlement_id;
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement header columns are immutable';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement version must step by +1 (old %, new %)', OLD.version, NEW.version;
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement entry_count must step by +1';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement update requires a new last_entry_id';
  END IF;
  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement updated_at must be monotonic';
  END IF;
  IF NOT clearledger.valid_transition(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'invalid settlement status transition % -> %', OLD.current_status, NEW.current_status;
  END IF;
  RETURN NEW;
END
$$;

-- events: contiguity, entryId uniqueness, parent consistency, ordering.
CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d jsonb;
  max_version integer;
  prev clearledger.events%ROWTYPE;
  new_entry text;
  new_memo text;
BEGIN
  IF NOT clearledger.event_matches_envelope(NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version,
                                            NEW.event_type, NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
    RAISE EXCEPTION 'event payload does not conform to ClearLedgerDomainEventEnvelope or mismatches columns'
      USING ERRCODE = '23514';
  END IF;

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT max(aggregate_version) INTO max_version FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM coalesce(max_version, 0) + 1 THEN
    RAISE EXCEPTION 'event aggregate_version % is not contiguous (expected %)',
      NEW.aggregate_version, coalesce(max_version, 0) + 1;
  END IF;

  d := NEW.payload->'data';
  new_entry := CASE WHEN jsonb_typeof(d->'entryId') = 'string' THEN d->>'entryId' END;
  new_memo := CASE WHEN jsonb_typeof(d->'memo') = 'string' THEN d->>'memo' END;

  IF new_entry IS NOT NULL AND EXISTS (
      SELECT 1 FROM clearledger.events e
       WHERE e.settlement_id = NEW.settlement_id
         AND e.event_type = 'LedgerEntryRecorded'
         AND jsonb_typeof(e.payload->'data'->'entryId') = 'string'
         AND (e.payload->'data'->>'entryId')::uuid = new_entry::uuid) THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', new_entry, NEW.settlement_id;
  END IF;

  IF d->>'accountId' IS DISTINCT FROM s.account_id
     OR d->>'reference' IS DISTINCT FROM s.reference
     OR d->>'debitParty' IS DISTINCT FROM s.debit_party
     OR d->>'creditParty' IS DISTINCT FROM s.credit_party
     OR d->>'status' IS DISTINCT FROM s.current_status
     OR d->>'clearingStage' IS DISTINCT FROM s.current_stage
     OR new_entry::uuid IS DISTINCT FROM s.last_entry_id
     OR new_memo IS DISTINCT FROM s.last_memo
     OR NEW.aggregate_version IS DISTINCT FROM s.version
     OR NEW.occurred_at IS DISTINCT FROM s.updated_at THEN
    RAISE EXCEPTION 'event does not match settlement % state', NEW.settlement_id;
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF NEW.occurred_at IS DISTINCT FROM s.created_at THEN
      RAISE EXCEPTION 'initiation event occurred_at must equal settlement created_at';
    END IF;
  ELSE
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'previous event missing for settlement %', NEW.settlement_id;
    END IF;
    IF NEW.occurred_at < prev.occurred_at THEN
      RAISE EXCEPTION 'event occurred_at must not precede the previous event';
    END IF;
    IF NOT clearledger.valid_transition(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'invalid event status transition % -> %', prev.payload->'data'->>'status', d->>'status';
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

-- outbox: must mirror events, contiguous per settlement.
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  e clearledger.events%ROWTYPE;
  max_version integer;
BEGIN
  IF NOT clearledger.outbox_matches_envelope(NEW.payload, NEW.event_id, NEW.settlement_id,
                                             NEW.aggregate_version, NEW.correlation_id) THEN
    RAISE EXCEPTION 'outbox payload does not conform to ClearLedgerDomainEventEnvelope or mismatches columns'
      USING ERRCODE = '23514';
  END IF;

  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox event % does not exist in clearledger.events', NEW.event_id USING ERRCODE = '23503';
  END IF;
  IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
     OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
     OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
     OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row must exactly mirror clearledger.events row %', NEW.event_id;
  END IF;

  SELECT max(aggregate_version) INTO max_version FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM coalesce(max_version, 0) + 1 THEN
    RAISE EXCEPTION 'outbox aggregate_version % is not contiguous (expected %)',
      NEW.aggregate_version, coalesce(max_version, 0) + 1;
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
    RAISE EXCEPTION 'outbox envelope columns are immutable';
  END IF;

  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease';
  END IF;

  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    -- publishing an unpublished row
    IF NEW.attempts <= OLD.attempts THEN
      RAISE EXCEPTION 'publishing an outbox row requires incrementing attempts';
    END IF;
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'an outbox row cannot be archived in the same step it is published';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    -- archival / re-archival of a published row
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published_at, attempts and last_error are immutable once published';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at cannot be changed without first resetting it to NULL';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    -- operational replay reset
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'replay reset requires archived_at = NULL';
    END IF;
  ELSE
    -- still unpublished (e.g. failed attempt bookkeeping)
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'unpublished outbox rows cannot be archived';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

-- idempotency_keys: referenced event must exist in events and outbox.
CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b jsonb := NEW.response_body;
BEGIN
  IF NOT clearledger.valid_write_response(NEW.scope, NEW.status_code, b) THEN
    RAISE EXCEPTION 'idempotency response_body is not a valid WriteAcceptedResponse' USING ERRCODE = '23514';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM clearledger.events e
       WHERE e.event_id = (b->>'eventId')::uuid
         AND e.settlement_id = (b->>'settlementId')::uuid
         AND e.aggregate_version = (b->>'version')::integer
         AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency record references an unknown event' USING ERRCODE = '23503';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM clearledger.outbox o
       WHERE o.event_id = (b->>'eventId')::uuid
         AND o.settlement_id = (b->>'settlementId')::uuid
         AND o.aggregate_version = (b->>'version')::integer) THEN
    RAISE EXCEPTION 'idempotency record references an event missing from the outbox' USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
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

CREATE OR REPLACE TRIGGER trg_outbox_no_delete
  BEFORE DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

CREATE OR REPLACE TRIGGER trg_idempotency_before_insert
  BEFORE INSERT ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert();

CREATE OR REPLACE TRIGGER trg_idempotency_append_only
  BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

COMMIT;
