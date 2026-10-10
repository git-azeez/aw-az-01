-- ClearLedger PostgreSQL schema. Idempotent: safe to run on every deploy.
-- Existing objects (and all committed data) are preserved; missing constraints,
-- triggers and indexes are re-created; function bodies are refreshed in place.

SET client_min_messages = warning;
SELECT pg_advisory_xact_lock(hashtext('clearledger-schema-migration')) \gset

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.tlen(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $f$
  SELECT char_length(btrim(s, E' \t\r\n'))
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid(s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(s ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false)
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_rfc3339(s text) RETURNS boolean
LANGUAGE plpgsql STABLE AS $f$
BEGIN
  IF s IS NULL OR s !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN false;
  END IF;
  PERFORM s::timestamptz;
  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE s
    WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
    WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5
  END
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_status(s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(s IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'), false)
$f$;

-- Clearing lifecycle: RECONCILED is terminal, DISPUTED may only stay DISPUTED or
-- resolve to RECONCILED, everything else may dispute or advance monotonically.
CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_s text, new_s text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT coalesce(
    CASE
      WHEN old_s = 'RECONCILED' THEN false
      WHEN old_s = 'DISPUTED'   THEN new_s IN ('DISPUTED', 'RECONCILED')
      WHEN new_s = 'DISPUTED'   THEN clearledger.status_rank(old_s) IS NOT NULL
      ELSE clearledger.status_rank(new_s) >= clearledger.status_rank(old_s)
    END, false)
$f$;

-- Validates a domain event envelope (schemas/events.schema.json) including the
-- stricter requirements of the ledger (non-null header fields, trimmed bounds,
-- kind/version/status/entryId coupling).
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p jsonb) RETURNS boolean
LANGUAGE plpgsql STABLE AS $f$
DECLARE
  d jsonb;
  v integer;
  etype text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RETURN false; END IF;

  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p) AS k(key)
             WHERE k.key NOT IN ('schemaVersion','eventId','eventType','aggregateType','aggregateId',
                                 'aggregateVersion','occurredAt','correlationId','idempotencyKey','data')) THEN
    RETURN false;
  END IF;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
    RETURN false;
  END IF;

  IF NOT coalesce(
       jsonb_typeof(p->'schemaVersion') = 'string' AND p->>'schemaVersion' = '1.0'
       AND jsonb_typeof(p->'eventId') = 'string' AND clearledger.is_uuid(p->>'eventId')
       AND jsonb_typeof(p->'eventType') = 'string' AND p->>'eventType' IN ('SettlementInitiated','LedgerEntryRecorded')
       AND jsonb_typeof(p->'aggregateType') = 'string' AND p->>'aggregateType' = 'settlement'
       AND jsonb_typeof(p->'aggregateId') = 'string' AND clearledger.is_uuid(p->>'aggregateId')
       AND jsonb_typeof(p->'aggregateVersion') = 'number' AND (p->>'aggregateVersion') ~ '^[1-9][0-9]{0,8}$'
       AND jsonb_typeof(p->'occurredAt') = 'string' AND clearledger.is_rfc3339(p->>'occurredAt')
       AND jsonb_typeof(p->'correlationId') = 'string' AND clearledger.tlen(p->>'correlationId') BETWEEN 4 AND 128
       AND jsonb_typeof(p->'idempotencyKey') = 'string' AND clearledger.tlen(p->>'idempotencyKey') BETWEEN 8 AND 128
       AND jsonb_typeof(p->'data') = 'object', false) THEN
    RETURN false;
  END IF;

  v := (p->>'aggregateVersion')::integer;
  etype := p->>'eventType';
  d := p->'data';

  IF EXISTS (SELECT 1 FROM jsonb_object_keys(d) AS k(key)
             WHERE k.key NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo')) THEN
    RETURN false;
  END IF;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN
    RETURN false;
  END IF;

  IF NOT coalesce(
       jsonb_typeof(d->'kind') = 'string' AND d->>'kind' IN ('settlementInitiated','ledgerEntryRecorded')
       AND jsonb_typeof(d->'accountId') = 'string' AND clearledger.tlen(d->>'accountId') BETWEEN 3 AND 64
       AND jsonb_typeof(d->'reference') = 'string' AND clearledger.tlen(d->>'reference') BETWEEN 3 AND 64
       AND jsonb_typeof(d->'debitParty') = 'string' AND clearledger.tlen(d->>'debitParty') BETWEEN 2 AND 64
       AND jsonb_typeof(d->'creditParty') = 'string' AND clearledger.tlen(d->>'creditParty') BETWEEN 2 AND 64
       AND jsonb_typeof(d->'status') = 'string' AND clearledger.is_status(d->>'status')
       AND jsonb_typeof(d->'clearingStage') = 'string' AND clearledger.tlen(d->>'clearingStage') BETWEEN 2 AND 64
       AND (NOT d ? 'entryId' OR jsonb_typeof(d->'entryId') = 'null'
            OR (jsonb_typeof(d->'entryId') = 'string' AND clearledger.is_uuid(d->>'entryId')))
       AND (NOT d ? 'memo' OR jsonb_typeof(d->'memo') = 'null'
            OR (jsonb_typeof(d->'memo') = 'string' AND clearledger.tlen(d->>'memo') BETWEEN 1 AND 256)), false) THEN
    RETURN false;
  END IF;

  -- kind / version / status / entryId coupling
  IF etype = 'SettlementInitiated' THEN
    RETURN v = 1 AND d->>'kind' = 'settlementInitiated' AND d->>'status' = 'INITIATED'
           AND (d->>'entryId') IS NULL;
  ELSE
    RETURN v >= 2 AND d->>'kind' = 'ledgerEntryRecorded' AND d->>'status' <> 'INITIATED'
           AND (d->>'entryId') IS NOT NULL;
  END IF;
EXCEPTION WHEN others THEN
  RETURN false;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.event_row_ok(
  p_event_id uuid, p_settlement_id uuid, p_version integer, p_event_type text,
  p_correlation_id text, p_idempotency_key text, p_occurred_at timestamptz, p_payload jsonb
) RETURNS boolean
LANGUAGE plpgsql STABLE AS $f$
BEGIN
  RETURN clearledger.envelope_ok(p_payload)
    AND p_event_id = (p_payload->>'eventId')::uuid
    AND p_settlement_id = (p_payload->>'aggregateId')::uuid
    AND p_version = (p_payload->>'aggregateVersion')::integer
    AND p_event_type = p_payload->>'eventType'
    AND p_correlation_id = p_payload->>'correlationId'
    AND p_idempotency_key = p_payload->>'idempotencyKey'
    AND p_occurred_at = (p_payload->>'occurredAt')::timestamptz;
EXCEPTION WHEN others THEN
  RETURN false;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_row_ok(
  p_scope text, p_key text, p_hash text, p_status integer, p_body jsonb
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  v integer;
BEGIN
  IF p_body IS NULL OR jsonb_typeof(p_body) IS DISTINCT FROM 'object' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_body) AS k(key)
             WHERE k.key NOT IN ('settlementId','eventId','version','accepted','idempotentReplay')) THEN
    RETURN false;
  END IF;
  IF NOT (p_body ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF NOT coalesce(
       jsonb_typeof(p_body->'settlementId') = 'string' AND clearledger.is_uuid(p_body->>'settlementId')
       AND jsonb_typeof(p_body->'eventId') = 'string' AND clearledger.is_uuid(p_body->>'eventId')
       AND jsonb_typeof(p_body->'version') = 'number' AND (p_body->>'version') ~ '^[1-9][0-9]{0,8}$'
       AND p_body->'accepted' = 'true'::jsonb
       AND p_body->'idempotentReplay' = 'false'::jsonb, false) THEN
    RETURN false;
  END IF;
  v := (p_body->>'version')::integer;
  IF p_scope ~* '^create:' THEN
    RETURN v = 1 AND p_status = 201 AND lower(substr(p_scope, 8)) = lower(p_body->>'settlementId');
  ELSIF p_scope ~* '^entry:' THEN
    RETURN v >= 2 AND p_status = 202 AND lower(substr(p_scope, 7)) = lower(p_body->>'settlementId');
  END IF;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN false;
END
$f$;

-- ---------------------------------------------------------------------------
-- Tables (columns + primary keys; everything else is attached idempotently below)
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
-- Constraint / trigger helpers (session-local)
-- ---------------------------------------------------------------------------

CREATE FUNCTION pg_temp.ensure_constraint(tbl text, cname text, ddl text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = ('clearledger.' || quote_ident(tbl))::regclass AND conname = cname) THEN
    EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', tbl, cname, ddl);
  END IF;
END
$f$;

CREATE FUNCTION pg_temp.ensure_trigger(tbl text, tname text, ddl text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = ('clearledger.' || quote_ident(tbl))::regclass AND tgname = tname AND NOT tgisinternal) THEN
    EXECUTE format('CREATE TRIGGER %I %s', tname, ddl);
  END IF;
END
$f$;

-- ---------------------------------------------------------------------------
-- settlements
-- ---------------------------------------------------------------------------

SELECT pg_temp.ensure_constraint('settlements', 'settlements_account_id_len',
  $c$CHECK (clearledger.tlen(account_id) BETWEEN 3 AND 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_reference_len',
  $c$CHECK (clearledger.tlen(reference) BETWEEN 3 AND 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_debit_party_len',
  $c$CHECK (clearledger.tlen(debit_party) BETWEEN 2 AND 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_credit_party_len',
  $c$CHECK (clearledger.tlen(credit_party) BETWEEN 2 AND 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_parties_differ',
  $c$CHECK (btrim(debit_party, E' \t\r\n') <> btrim(credit_party, E' \t\r\n'))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_status_allowed',
  $c$CHECK (clearledger.is_status(current_status))$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_stage_len',
  $c$CHECK (clearledger.tlen(current_stage) BETWEEN 2 AND 64)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_memo_len',
  $c$CHECK (last_memo IS NULL OR clearledger.tlen(last_memo) BETWEEN 1 AND 256)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_version_positive',
  $c$CHECK (version >= 1)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_timestamps_monotonic',
  $c$CHECK (updated_at >= created_at)$c$);
SELECT pg_temp.ensure_constraint('settlements', 'settlements_initiation_state',
  $c$CHECK (
    (version = 1 AND entry_count = 0 AND current_status = 'INITIATED'
       AND last_entry_id IS NULL AND updated_at = created_at)
    OR
    (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED'
       AND last_entry_id IS NOT NULL)
  )$c$);

CREATE OR REPLACE FUNCTION clearledger.settlements_guard_update() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id IS DISTINCT FROM OLD.account_id
     OR NEW.reference IS DISTINCT FROM OLD.reference
     OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.updated_at < OLD.updated_at THEN
    RAISE EXCEPTION 'settlement updated_at must not move backwards' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 OR NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement version and entry_count must advance by exactly one (% -> %)', OLD.version, NEW.version
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
  END IF;
  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and can no longer change', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'illegal status transition % -> %', OLD.current_status, NEW.current_status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$f$;

SELECT pg_temp.ensure_trigger('settlements', 'trg_settlements_guard_update',
  $c$BEFORE UPDATE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlements_guard_update()$c$);

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------

SELECT pg_temp.ensure_constraint('events', 'events_event_id_key', $c$UNIQUE (event_id)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_settlement_fk',
  $c$FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements (settlement_id) ON DELETE CASCADE$c$);
SELECT pg_temp.ensure_constraint('events', 'events_settlement_version_key',
  $c$UNIQUE (settlement_id, aggregate_version)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_settlement_idempotency_key',
  $c$UNIQUE (settlement_id, idempotency_key)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_version_positive', $c$CHECK (aggregate_version >= 1)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_type_allowed',
  $c$CHECK (event_type IN ('SettlementInitiated', 'LedgerEntryRecorded'))$c$);
SELECT pg_temp.ensure_constraint('events', 'events_correlation_id_len',
  $c$CHECK (clearledger.tlen(correlation_id) BETWEEN 4 AND 128)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_idempotency_key_len',
  $c$CHECK (clearledger.tlen(idempotency_key) BETWEEN 8 AND 128)$c$);
SELECT pg_temp.ensure_constraint('events', 'events_envelope_valid',
  $c$CHECK (clearledger.event_row_ok(event_id, settlement_id, aggregate_version, event_type,
            correlation_id, idempotency_key, occurred_at, payload))$c$);

CREATE OR REPLACE FUNCTION clearledger.events_guard_insert() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  s clearledger.settlements%ROWTYPE;
  d jsonb := NEW.payload -> 'data';
  max_v integer;
  prev_occurred timestamptz;
  prev_status text;
BEGIN
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
  END IF;

  SELECT coalesce(max(aggregate_version), 0) INTO max_v
    FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <= max_v THEN
    -- duplicate version: let the UNIQUE constraint report the conflict
    RETURN NEW;
  END IF;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'aggregate_version % is not contiguous (expected %)', NEW.aggregate_version, max_v + 1
      USING ERRCODE = 'P0001';
  END IF;

  IF d ->> 'entryId' IS NOT NULL AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id
          AND e.payload -> 'data' ->> 'entryId' = d ->> 'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d ->> 'entryId', NEW.settlement_id
      USING ERRCODE = '23505';
  END IF;

  IF s.account_id IS DISTINCT FROM d ->> 'accountId'
     OR s.reference IS DISTINCT FROM d ->> 'reference'
     OR s.debit_party IS DISTINCT FROM d ->> 'debitParty'
     OR s.credit_party IS DISTINCT FROM d ->> 'creditParty'
     OR s.current_status IS DISTINCT FROM d ->> 'status'
     OR s.current_stage IS DISTINCT FROM d ->> 'clearingStage'
     OR s.last_entry_id IS DISTINCT FROM (d ->> 'entryId')::uuid
     OR s.last_memo IS DISTINCT FROM d ->> 'memo'
     OR s.version IS DISTINCT FROM NEW.aggregate_version
     OR s.updated_at IS DISTINCT FROM NEW.occurred_at
     OR (NEW.aggregate_version = 1 AND s.created_at IS DISTINCT FROM NEW.occurred_at) THEN
    RAISE EXCEPTION 'event does not match settlement % state', NEW.settlement_id USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version >= 2 THEN
    SELECT e.occurred_at, e.payload -> 'data' ->> 'status' INTO prev_occurred, prev_status
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'previous event of settlement % is missing', NEW.settlement_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.occurred_at < prev_occurred THEN
      RAISE EXCEPTION 'event occurred_at moves backwards' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev_status, d ->> 'status') THEN
      RAISE EXCEPTION 'illegal status transition % -> %', prev_status, d ->> 'status' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION '% on clearledger.% is not permitted (append-only)', TG_OP, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END
$f$;

SELECT pg_temp.ensure_trigger('events', 'trg_events_guard_insert',
  $c$BEFORE INSERT ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.events_guard_insert()$c$);
SELECT pg_temp.ensure_trigger('events', 'trg_events_reject_update',
  $c$BEFORE UPDATE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()$c$);
SELECT pg_temp.ensure_trigger('events', 'trg_events_reject_delete',
  $c$BEFORE DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()$c$);

-- ---------------------------------------------------------------------------
-- outbox
-- ---------------------------------------------------------------------------

SELECT pg_temp.ensure_constraint('outbox', 'outbox_event_id_key', $c$UNIQUE (event_id)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_event_fk',
  $c$FOREIGN KEY (event_id) REFERENCES clearledger.events (event_id) ON DELETE CASCADE$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_settlement_fk',
  $c$FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements (settlement_id) ON DELETE CASCADE$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_settlement_version_key',
  $c$UNIQUE (settlement_id, aggregate_version)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_event_version_fk',
  $c$FOREIGN KEY (settlement_id, aggregate_version)
     REFERENCES clearledger.events (settlement_id, aggregate_version) ON DELETE CASCADE$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_version_positive', $c$CHECK (aggregate_version >= 1)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_envelope_valid',
  $c$CHECK (clearledger.envelope_ok(payload))$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_attempts_nonnegative', $c$CHECK (attempts >= 0)$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_published_state',
  $c$CHECK (published_at IS NULL
            OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))$c$);
SELECT pg_temp.ensure_constraint('outbox', 'outbox_archived_state',
  $c$CHECK (archived_at IS NULL
            OR (published_at IS NOT NULL AND archived_at >= published_at))$c$);

CREATE OR REPLACE FUNCTION clearledger.outbox_guard_insert() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  e clearledger.events%ROWTYPE;
  max_v integer;
BEGIN
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % does not exist', NEW.event_id USING ERRCODE = '23503';
  END IF;

  SELECT coalesce(max(aggregate_version), 0) INTO max_v
    FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <= max_v THEN
    RETURN NEW; -- duplicate: UNIQUE (settlement_id, aggregate_version) reports it
  END IF;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'outbox aggregate_version % is not contiguous (expected %)', NEW.aggregate_version, max_v + 1
      USING ERRCODE = 'P0001';
  END IF;

  IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
     OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
     OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
     OR e.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row does not mirror event %', NEW.event_id USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.outbox_guard_update() RETURNS trigger
LANGUAGE plpgsql AS $f$
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

  IF OLD.published_at IS NULL THEN
    IF NEW.published_at IS NOT NULL THEN
      -- publishing: must count the attempt, cannot be archived in the same step
      IF NEW.attempts <= OLD.attempts THEN
        RAISE EXCEPTION 'publishing an outbox row must increment attempts' USING ERRCODE = 'P0001';
      END IF;
      IF NEW.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'an unpublished outbox row cannot be archived' USING ERRCODE = 'P0001';
      END IF;
    ELSIF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'an unpublished outbox row cannot be archived' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF NEW.published_at IS NULL THEN
      -- operational replay: reset published_at and archived_at together
      IF NEW.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'replay must reset archived_at together with published_at' USING ERRCODE = 'P0001';
      END IF;
    ELSE
      IF NEW.published_at IS DISTINCT FROM OLD.published_at
         OR NEW.attempts IS DISTINCT FROM OLD.attempts
         OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
        RAISE EXCEPTION 'published delivery fields are immutable' USING ERRCODE = 'P0001';
      END IF;
      IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
         AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
        RAISE EXCEPTION 'archived_at cannot change without being reset first' USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END
$f$;

CREATE OR REPLACE FUNCTION clearledger.reject_delete() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'DELETE on clearledger.% is not permitted', TG_TABLE_NAME USING ERRCODE = 'P0001';
END
$f$;

SELECT pg_temp.ensure_trigger('outbox', 'trg_outbox_guard_insert',
  $c$BEFORE INSERT ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard_insert()$c$);
SELECT pg_temp.ensure_trigger('outbox', 'trg_outbox_guard_update',
  $c$BEFORE UPDATE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard_update()$c$);
SELECT pg_temp.ensure_trigger('outbox', 'trg_outbox_reject_delete',
  $c$BEFORE DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.reject_delete()$c$);

-- ---------------------------------------------------------------------------
-- idempotency_keys
-- ---------------------------------------------------------------------------

SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_scope_format',
  $c$CHECK (scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_key_len',
  $c$CHECK (clearledger.tlen(idempotency_key) BETWEEN 8 AND 128)$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_hash_format',
  $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_status_code',
  $c$CHECK (status_code IN (201, 202))$c$);
SELECT pg_temp.ensure_constraint('idempotency_keys', 'idempotency_keys_row_valid',
  $c$CHECK (clearledger.idempotency_row_ok(scope, idempotency_key, request_hash, status_code, response_body))$c$);

CREATE OR REPLACE FUNCTION clearledger.idempotency_guard_insert() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  ev uuid := (NEW.response_body ->> 'eventId')::uuid;
BEGIN
  IF NOT EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.event_id = ev
          AND e.settlement_id = (NEW.response_body ->> 'settlementId')::uuid
          AND e.aggregate_version = (NEW.response_body ->> 'version')::integer
          AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency record references an unknown event %', ev USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o WHERE o.event_id = ev) THEN
    RAISE EXCEPTION 'idempotency record references event % without an outbox row', ev USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$f$;

SELECT pg_temp.ensure_trigger('idempotency_keys', 'trg_idempotency_guard_insert',
  $c$BEFORE INSERT ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard_insert()$c$);
SELECT pg_temp.ensure_trigger('idempotency_keys', 'trg_idempotency_reject_update',
  $c$BEFORE UPDATE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()$c$);
SELECT pg_temp.ensure_trigger('idempotency_keys', 'trg_idempotency_reject_delete',
  $c$BEFORE DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()$c$);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
  ON clearledger.outbox (seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
  ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
  ON clearledger.events (settlement_id, aggregate_version);
