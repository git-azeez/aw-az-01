-- ClearLedger PostgreSQL schema (idempotent).
-- Applied by deploy.sh on every run inside a single transaction.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

BEGIN;

-- Serialise concurrent migrations.
SELECT pg_advisory_xact_lock(724153901);

CREATE SCHEMA IF NOT EXISTS clearledger;

------------------------------------------------------------------------------
-- Pure helper functions (never raise; safe for CHECK constraints)
------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(v text)
RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT v IS NOT NULL
     AND v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$$;

CREATE OR REPLACE FUNCTION clearledger.trimmed_len_between(v text, lo int, hi int)
RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT v IS NOT NULL
     AND char_length(v) <= hi
     AND char_length(btrim(v)) BETWEEN lo AND hi
$$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text)
RETURNS integer LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
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
CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN old_status IS NULL OR new_status IS NULL THEN false
    WHEN old_status = 'RECONCILED' THEN false
    WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED', 'RECONCILED')
    WHEN clearledger.status_rank(old_status) IS NULL THEN false
    WHEN new_status = 'DISPUTED' THEN true
    WHEN clearledger.status_rank(new_status) IS NULL THEN false
    ELSE clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
  END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_rfc3339(v text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  ts timestamptz;
BEGIN
  IF v IS NULL OR v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN false;
  END IF;
  ts := v::timestamptz;
  RETURN ts IS NOT NULL;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Strict validation of ClearLedgerDomainEventEnvelope (schemas/events.schema.json).
CREATE OR REPLACE FUNCTION clearledger.is_valid_envelope(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  d        jsonb;
  k        text;
  v        integer;
  etype    text;
  kind     text;
  status   text;
  entry_id jsonb;
  memo     jsonb;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
    RETURN false;
  END IF;

  -- envelope: closed schema, all keys required
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
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'aggregateId') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated', 'LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[0-9]{1,9}$' THEN RETURN false; END IF;
  v := (p->>'aggregateVersion')::integer;
  IF v < 1 THEN RETURN false; END IF;
  IF jsonb_typeof(p->'occurredAt') <> 'string' OR NOT clearledger.is_rfc3339(p->>'occurredAt') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR NOT clearledger.trimmed_len_between(p->>'correlationId', 4, 128) THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR NOT clearledger.trimmed_len_between(p->>'idempotencyKey', 8, 128) THEN RETURN false; END IF;

  -- data: closed schema
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

  IF jsonb_typeof(d->'kind') <> 'string' OR d->>'kind' NOT IN ('settlementInitiated', 'ledgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'accountId') <> 'string' OR NOT clearledger.trimmed_len_between(d->>'accountId', 3, 64) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'reference') <> 'string' OR NOT clearledger.trimmed_len_between(d->>'reference', 3, 64) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'debitParty') <> 'string' OR NOT clearledger.trimmed_len_between(d->>'debitParty', 2, 64) THEN RETURN false; END IF;
  IF jsonb_typeof(d->'creditParty') <> 'string' OR NOT clearledger.trimmed_len_between(d->>'creditParty', 2, 64) THEN RETURN false; END IF;
  IF btrim(d->>'debitParty') = btrim(d->>'creditParty') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'status') <> 'string'
     OR d->>'status' NOT IN ('INITIATED', 'VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED', 'RECONCILED', 'DISPUTED') THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(d->'clearingStage') <> 'string' OR NOT clearledger.trimmed_len_between(d->>'clearingStage', 2, 64) THEN RETURN false; END IF;

  entry_id := d->'entryId';
  IF entry_id IS NOT NULL AND jsonb_typeof(entry_id) <> 'null' THEN
    IF jsonb_typeof(entry_id) <> 'string' OR NOT clearledger.is_uuid_text(d->>'entryId') THEN RETURN false; END IF;
  END IF;

  memo := d->'memo';
  IF memo IS NOT NULL AND jsonb_typeof(memo) <> 'null' THEN
    IF jsonb_typeof(memo) <> 'string' OR NOT clearledger.trimmed_len_between(d->>'memo', 1, 256) THEN RETURN false; END IF;
  END IF;

  -- version / kind / status / entryId coupling
  etype  := p->>'eventType';
  kind   := d->>'kind';
  status := d->>'status';
  IF etype = 'SettlementInitiated' THEN
    IF v <> 1 OR kind <> 'settlementInitiated' OR status <> 'INITIATED' THEN RETURN false; END IF;
    IF entry_id IS NOT NULL AND jsonb_typeof(entry_id) <> 'null' THEN RETURN false; END IF;
  ELSE
    IF v < 2 OR kind <> 'ledgerEntryRecorded' OR status = 'INITIATED' THEN RETURN false; END IF;
    IF entry_id IS NULL OR jsonb_typeof(entry_id) <> 'string' THEN RETURN false; END IF;
  END IF;

  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

-- Closed-schema WriteAcceptedResponse (openapi.yaml) stored with idempotency keys.
CREATE OR REPLACE FUNCTION clearledger.is_valid_write_response(p_scope text, p_status integer, b jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  k text;
  v integer;
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  FOR k IN SELECT jsonb_object_keys(b) LOOP
    IF k NOT IN ('settlementId', 'eventId', 'version', 'accepted', 'idempotentReplay') THEN
      RETURN false;
    END IF;
  END LOOP;
  IF NOT (b ?& ARRAY['settlementId', 'eventId', 'version', 'accepted', 'idempotentReplay']) THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(b->'settlementId') <> 'string' OR NOT clearledger.is_uuid_text(b->>'settlementId') THEN RETURN false; END IF;
  IF jsonb_typeof(b->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(b->>'eventId') THEN RETURN false; END IF;
  IF jsonb_typeof(b->'version') <> 'number' OR (b->>'version') !~ '^[0-9]{1,9}$' THEN RETURN false; END IF;
  IF jsonb_typeof(b->'accepted') <> 'boolean' OR (b->'accepted') <> 'true'::jsonb THEN RETURN false; END IF;
  IF jsonb_typeof(b->'idempotentReplay') <> 'boolean' OR (b->'idempotentReplay') <> 'false'::jsonb THEN RETURN false; END IF;
  v := (b->>'version')::integer;
  IF p_scope IS NULL OR lower(split_part(p_scope, ':', 2)) <> lower(b->>'settlementId') THEN RETURN false; END IF;
  IF p_scope LIKE 'create:%' THEN
    RETURN p_status = 201 AND v = 1;
  ELSIF p_scope LIKE 'entry:%' THEN
    RETURN p_status = 202 AND v >= 2;
  END IF;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;

------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------

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

------------------------------------------------------------------------------
-- Declarative constraints (added only when missing, in dependency order)
------------------------------------------------------------------------------

DO $migrate$
DECLARE
  c record;
BEGIN
  FOR c IN
    SELECT * FROM (VALUES
      -- settlements ------------------------------------------------------
      (1, 'clearledger.settlements', 'settlements_status_chk',
       $c$CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$),
      (2, 'clearledger.settlements', 'settlements_account_id_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(account_id, 3, 64))$c$),
      (3, 'clearledger.settlements', 'settlements_reference_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(reference, 3, 64))$c$),
      (4, 'clearledger.settlements', 'settlements_debit_party_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(debit_party, 2, 64))$c$),
      (5, 'clearledger.settlements', 'settlements_credit_party_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(credit_party, 2, 64))$c$),
      (6, 'clearledger.settlements', 'settlements_parties_distinct_chk',
       $c$CHECK (btrim(debit_party) <> btrim(credit_party))$c$),
      (7, 'clearledger.settlements', 'settlements_stage_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(current_stage, 2, 64))$c$),
      (8, 'clearledger.settlements', 'settlements_last_memo_len_chk',
       $c$CHECK (last_memo IS NULL OR clearledger.trimmed_len_between(last_memo, 1, 256))$c$),
      (9, 'clearledger.settlements', 'settlements_version_chk',
       $c$CHECK (version >= 1 AND entry_count >= 0)$c$),
      (10, 'clearledger.settlements', 'settlements_timestamps_chk',
       $c$CHECK (updated_at >= created_at)$c$),
      (11, 'clearledger.settlements', 'settlements_lifecycle_chk',
       $c$CHECK (
          (version = 1 AND entry_count = 0 AND current_status = 'INITIATED'
             AND last_entry_id IS NULL AND updated_at = created_at)
          OR
          (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED'
             AND last_entry_id IS NOT NULL)
       )$c$),

      -- events -----------------------------------------------------------
      (20, 'clearledger.events', 'events_event_id_key',
       $c$UNIQUE (event_id)$c$),
      (21, 'clearledger.events', 'events_settlement_fk',
       $c$FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE$c$),
      (22, 'clearledger.events', 'events_settlement_version_key',
       $c$UNIQUE (settlement_id, aggregate_version)$c$),
      (23, 'clearledger.events', 'events_settlement_idempotency_key',
       $c$UNIQUE (settlement_id, idempotency_key)$c$),
      (24, 'clearledger.events', 'events_version_chk',
       $c$CHECK (aggregate_version >= 1)$c$),
      (25, 'clearledger.events', 'events_event_type_chk',
       $c$CHECK (event_type IN ('SettlementInitiated', 'LedgerEntryRecorded'))$c$),
      (26, 'clearledger.events', 'events_correlation_id_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(correlation_id, 4, 128))$c$),
      (27, 'clearledger.events', 'events_idempotency_key_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(idempotency_key, 8, 128))$c$),
      (28, 'clearledger.events', 'events_payload_envelope_chk',
       $c$CHECK (clearledger.is_valid_envelope(payload))$c$),
      (29, 'clearledger.events', 'events_kind_version_chk',
       $c$CHECK ((event_type = 'SettlementInitiated' AND aggregate_version = 1)
              OR (event_type = 'LedgerEntryRecorded' AND aggregate_version >= 2))$c$),

      -- outbox -----------------------------------------------------------
      (40, 'clearledger.outbox', 'outbox_event_id_key',
       $c$UNIQUE (event_id)$c$),
      (41, 'clearledger.outbox', 'outbox_event_fk',
       $c$FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE$c$),
      (42, 'clearledger.outbox', 'outbox_settlement_fk',
       $c$FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE$c$),
      (43, 'clearledger.outbox', 'outbox_settlement_version_key',
       $c$UNIQUE (settlement_id, aggregate_version)$c$),
      (44, 'clearledger.outbox', 'outbox_event_version_fk',
       $c$FOREIGN KEY (settlement_id, aggregate_version)
          REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE$c$),
      (45, 'clearledger.outbox', 'outbox_version_chk',
       $c$CHECK (aggregate_version >= 1)$c$),
      (46, 'clearledger.outbox', 'outbox_correlation_id_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(correlation_id, 4, 128))$c$),
      (47, 'clearledger.outbox', 'outbox_payload_envelope_chk',
       $c$CHECK (clearledger.is_valid_envelope(payload))$c$),
      (48, 'clearledger.outbox', 'outbox_attempts_chk',
       $c$CHECK (attempts >= 0)$c$),
      (49, 'clearledger.outbox', 'outbox_published_chk',
       $c$CHECK (published_at IS NULL
              OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))$c$),
      (50, 'clearledger.outbox', 'outbox_archived_chk',
       $c$CHECK (archived_at IS NULL
              OR (published_at IS NOT NULL AND archived_at >= published_at))$c$),

      -- idempotency_keys -------------------------------------------------
      (60, 'clearledger.idempotency_keys', 'idempotency_scope_chk',
       $c$CHECK (scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')$c$),
      (61, 'clearledger.idempotency_keys', 'idempotency_key_len_chk',
       $c$CHECK (clearledger.trimmed_len_between(idempotency_key, 8, 128))$c$),
      (62, 'clearledger.idempotency_keys', 'idempotency_request_hash_chk',
       $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$),
      (63, 'clearledger.idempotency_keys', 'idempotency_status_code_chk',
       $c$CHECK ((scope LIKE 'create:%' AND status_code = 201)
              OR (scope LIKE 'entry:%' AND status_code = 202))$c$),
      (64, 'clearledger.idempotency_keys', 'idempotency_response_body_chk',
       $c$CHECK (clearledger.is_valid_write_response(scope, status_code, response_body))$c$)
    ) AS t(ord, tbl, name, def)
    ORDER BY ord
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
      WHERE conname = c.name AND conrelid = c.tbl::regclass
    ) THEN
      EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', c.tbl, c.name, c.def);
    END IF;
  END LOOP;
END
$migrate$;

------------------------------------------------------------------------------
-- Trigger functions
------------------------------------------------------------------------------

-- settlements: header immutability, +1 stepping, lifecycle transitions.
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED (terminal) and cannot be modified', OLD.settlement_id
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id   IS DISTINCT FROM OLD.account_id
     OR NEW.reference    IS DISTINCT FROM OLD.reference
     OR NEW.debit_party  IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at   IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement version must advance by exactly 1 (old %, new %)', OLD.version, NEW.version
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement entry_count must advance by exactly 1' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement updated_at cannot move backwards' USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'illegal settlement status transition % -> %', OLD.current_status, NEW.current_status
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

-- events: append-only, contiguous, consistent with envelope and parent row.
CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  p        jsonb := NEW.payload;
  d        jsonb;
  s        clearledger.settlements%ROWTYPE;
  max_v    integer;
  prev     clearledger.events%ROWTYPE;
  ev_entry uuid;
  ev_memo  text;
BEGIN
  IF NOT clearledger.is_valid_envelope(p) THEN
    RAISE EXCEPTION 'event payload does not conform to ClearLedgerDomainEventEnvelope' USING ERRCODE = 'P0001';
  END IF;
  d := p->'data';

  IF (p->>'eventId')::uuid IS DISTINCT FROM NEW.event_id
     OR (p->>'aggregateId')::uuid IS DISTINCT FROM NEW.settlement_id
     OR (p->>'aggregateVersion')::integer IS DISTINCT FROM NEW.aggregate_version
     OR (p->>'eventType') IS DISTINCT FROM NEW.event_type
     OR (p->>'correlationId') IS DISTINCT FROM NEW.correlation_id
     OR (p->>'idempotencyKey') IS DISTINCT FROM NEW.idempotency_key
     OR (p->>'occurredAt')::timestamptz IS DISTINCT FROM NEW.occurred_at THEN
    RAISE EXCEPTION 'event columns do not match envelope payload' USING ERRCODE = 'P0001';
  END IF;

  -- serialise appends per settlement
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v
    FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'non-contiguous aggregate_version % (expected %)', NEW.aggregate_version, max_v + 1
      USING ERRCODE = 'P0001';
  END IF;

  ev_entry := NULLIF(d->>'entryId', '')::uuid;
  ev_memo  := d->>'memo';

  IF NEW.event_type = 'LedgerEntryRecorded' AND EXISTS (
       SELECT 1 FROM clearledger.events e
       WHERE e.settlement_id = NEW.settlement_id
         AND e.event_type = 'LedgerEntryRecorded'
         AND (e.payload->'data'->>'entryId')::uuid = ev_entry) THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', ev_entry, NEW.settlement_id
      USING ERRCODE = 'P0001';
  END IF;

  IF d->>'accountId'     IS DISTINCT FROM s.account_id
     OR d->>'reference'   IS DISTINCT FROM s.reference
     OR d->>'debitParty'  IS DISTINCT FROM s.debit_party
     OR d->>'creditParty' IS DISTINCT FROM s.credit_party
     OR d->>'status'      IS DISTINCT FROM s.current_status
     OR d->>'clearingStage' IS DISTINCT FROM s.current_stage
     OR ev_entry          IS DISTINCT FROM s.last_entry_id
     OR ev_memo           IS DISTINCT FROM s.last_memo
     OR NEW.aggregate_version IS DISTINCT FROM s.version
     OR NEW.occurred_at   IS DISTINCT FROM s.updated_at THEN
    RAISE EXCEPTION 'event does not match settlement % state', NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version = 1 THEN
    IF NEW.occurred_at IS DISTINCT FROM s.created_at THEN
      RAISE EXCEPTION 'initiation event occurred_at must equal settlement created_at' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    SELECT * INTO prev FROM clearledger.events
      WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'previous event version % missing', NEW.aggregate_version - 1 USING ERRCODE = 'P0001';
    END IF;
    IF NEW.occurred_at < prev.occurred_at THEN
      RAISE EXCEPTION 'event occurred_at precedes previous event' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'illegal event status transition % -> %', prev.payload->'data'->>'status', d->>'status'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_append_only()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '%.% is append-only: % rejected', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'P0001';
END
$$;

-- outbox: insert must mirror the event log contiguously.
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  e     clearledger.events%ROWTYPE;
  max_v integer;
BEGIN
  IF NOT clearledger.is_valid_envelope(NEW.payload) THEN
    RAISE EXCEPTION 'outbox payload does not conform to ClearLedgerDomainEventEnvelope' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox event % not found in event log', NEW.event_id USING ERRCODE = '23503';
  END IF;
  IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
     OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
     OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
     OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row does not mirror event %', NEW.event_id USING ERRCODE = 'P0001';
  END IF;
  PERFORM 1 FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
  SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v
    FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'non-contiguous outbox aggregate_version % (expected %)', NEW.aggregate_version, max_v + 1
      USING ERRCODE = 'P0001';
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
    RAISE EXCEPTION 'outbox envelope columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts cannot decrease' USING ERRCODE = 'P0001';
  END IF;

  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
    -- publish
    IF NEW.attempts <= OLD.attempts THEN
      RAISE EXCEPTION 'publishing an outbox row requires incrementing attempts' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'outbox row cannot be archived while being published' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
    -- archival / re-archival of a published row
    IF NEW.published_at IS DISTINCT FROM OLD.published_at
       OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published outbox delivery columns are immutable' USING ERRCODE = 'P0001';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at cannot be changed without first resetting it' USING ERRCODE = 'P0001';
    END IF;
  ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
    -- operational replay
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'replay requires resetting archived_at' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'unpublished outbox row cannot be archived' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

-- idempotency_keys: referenced write must exist in events and outbox.
CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  b jsonb := NEW.response_body;
BEGIN
  IF NOT clearledger.is_valid_write_response(NEW.scope, NEW.status_code, b) THEN
    RAISE EXCEPTION 'idempotency response_body is not a valid WriteAcceptedResponse' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM clearledger.events e
    WHERE e.event_id = (b->>'eventId')::uuid
      AND e.settlement_id = (b->>'settlementId')::uuid
      AND e.aggregate_version = (b->>'version')::integer
      AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency key references an unknown event' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM clearledger.outbox o
    WHERE o.event_id = (b->>'eventId')::uuid
      AND o.settlement_id = (b->>'settlementId')::uuid
      AND o.aggregate_version = (b->>'version')::integer) THEN
    RAISE EXCEPTION 'idempotency key references an event missing from the outbox' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$$;

------------------------------------------------------------------------------
-- Triggers (CREATE OR REPLACE keeps the swap atomic)
------------------------------------------------------------------------------

CREATE OR REPLACE TRIGGER settlements_before_update
  BEFORE UPDATE ON clearledger.settlements
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_update();

CREATE OR REPLACE TRIGGER events_before_insert
  BEFORE INSERT ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_before_insert();

CREATE OR REPLACE TRIGGER events_append_only
  BEFORE UPDATE OR DELETE ON clearledger.events
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

CREATE OR REPLACE TRIGGER outbox_before_insert
  BEFORE INSERT ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_insert();

CREATE OR REPLACE TRIGGER outbox_before_update
  BEFORE UPDATE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_update();

CREATE OR REPLACE TRIGGER outbox_no_delete
  BEFORE DELETE ON clearledger.outbox
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

CREATE OR REPLACE TRIGGER idempotency_before_insert
  BEFORE INSERT ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert();

CREATE OR REPLACE TRIGGER idempotency_immutable
  BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys
  FOR EACH ROW EXECUTE FUNCTION clearledger.trg_append_only();

------------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);

COMMIT;
