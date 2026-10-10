-- ClearLedger PostgreSQL schema (idempotent, convergent).
--
-- Applied by deploy.sh on every run. Everything runs in one transaction under an
-- advisory lock; objects that already match their canonical definition are left
-- untouched (no churn under live traffic), anything missing, altered, weakened or
-- disabled is recreated.

\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET lock_timeout = '60s';
SET statement_timeout = '300s';

BEGIN;
SELECT pg_advisory_xact_lock(hashtext('clearledger-schema-convergence'));

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Helpers (session-local; they live in pg_temp and vanish with the session).
-- ---------------------------------------------------------------------------

-- Re-create a constraint unless it is present with exactly the canonical text.
CREATE FUNCTION pg_temp.ensure_constraint(tbl regclass, cname text, def text, cascade boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  cur   oid;
  have  text;
  valid boolean;
  want  text := md5(def);
BEGIN
  SELECT c.oid, obj_description(c.oid, 'pg_constraint'), c.convalidated
    INTO cur, have, valid
    FROM pg_constraint c WHERE c.conrelid = tbl AND c.conname = cname;

  IF cur IS NOT NULL AND valid
     AND have IS NOT DISTINCT FROM want || ':' || md5(pg_get_constraintdef(cur)) THEN
    RETURN;
  END IF;

  IF cur IS NOT NULL THEN
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I%s', tbl, cname,
                   CASE WHEN cascade THEN ' CASCADE' ELSE '' END);
  END IF;

  BEGIN
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s', tbl, cname, def);
  EXCEPTION WHEN check_violation OR unique_violation OR foreign_key_violation OR not_null_violation THEN
    -- Existing rows violate the canonical rule: still enforce it for all new writes.
    RAISE WARNING 'constraint % on % violated by existing rows; adding NOT VALID', cname, tbl;
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s NOT VALID', tbl, cname, def);
  END;

  SELECT c.oid INTO cur FROM pg_constraint c WHERE c.conrelid = tbl AND c.conname = cname;
  EXECUTE format('COMMENT ON CONSTRAINT %I ON %s IS %L', cname, tbl,
                 want || ':' || md5(pg_get_constraintdef(cur)));
END $f$;

-- Re-create a trigger unless present, enabled and identical to the canonical text.
CREATE FUNCTION pg_temp.ensure_trigger(tbl regclass, tname text, def text)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  cur  oid;
  have text;
  en   "char";
  want text := md5(def);
BEGIN
  SELECT t.oid, obj_description(t.oid, 'pg_trigger'), t.tgenabled
    INTO cur, have, en
    FROM pg_trigger t WHERE t.tgrelid = tbl AND t.tgname = tname AND NOT t.tgisinternal;

  IF cur IS NOT NULL AND en = 'O'
     AND have IS NOT DISTINCT FROM want || ':' || md5(pg_get_triggerdef(cur)) THEN
    RETURN;
  END IF;

  IF cur IS NOT NULL THEN
    EXECUTE format('DROP TRIGGER %I ON %s', tname, tbl);
  END IF;
  EXECUTE def;
  EXECUTE format('ALTER TABLE %s ENABLE TRIGGER %I', tbl, tname);

  SELECT t.oid INTO cur FROM pg_trigger t WHERE t.tgrelid = tbl AND t.tgname = tname AND NOT t.tgisinternal;
  EXECUTE format('COMMENT ON TRIGGER %I ON %s IS %L', tname, tbl, want || ':' || md5(pg_get_triggerdef(cur)));
END $f$;

-- Re-create an index unless present, valid and identical to the canonical text.
CREATE FUNCTION pg_temp.ensure_index(iname text, def text)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  cur   oid;
  have  text;
  ok    boolean;
  want  text := md5(def);
BEGIN
  SELECT c.oid, obj_description(c.oid, 'pg_class'), i.indisvalid AND i.indisready
    INTO cur, have, ok
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'clearledger'
    JOIN pg_index i ON i.indexrelid = c.oid
   WHERE c.relname = iname AND c.relkind = 'i';

  IF cur IS NOT NULL AND ok
     AND have IS NOT DISTINCT FROM want || ':' || md5(pg_get_indexdef(cur)) THEN
    RETURN;
  END IF;

  IF cur IS NOT NULL THEN
    EXECUTE format('DROP INDEX clearledger.%I', iname);
  ELSIF to_regclass('clearledger.' || quote_ident(iname)) IS NOT NULL THEN
    -- a non-index relation squatting on the name
    RAISE EXCEPTION 'clearledger.% exists but is not an index', iname;
  END IF;
  EXECUTE def;

  SELECT c.oid INTO cur FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'clearledger' AND c.relname = iname;
  EXECUTE format('COMMENT ON INDEX clearledger.%I IS %L', iname, want || ':' || md5(pg_get_indexdef(cur)));
END $f$;

-- Add a missing column and restore NOT NULL / DEFAULT.
CREATE FUNCTION pg_temp.ensure_column(tbl regclass, col text, typ text, not_null boolean, dflt text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  EXECUTE format('ALTER TABLE %s ADD COLUMN IF NOT EXISTS %I %s', tbl, col, typ);
  IF dflt IS NOT NULL THEN
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET DEFAULT %s', tbl, col, dflt);
  END IF;
  IF not_null THEN
    BEGIN
      EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET NOT NULL', tbl, col);
    EXCEPTION WHEN not_null_violation THEN
      RAISE WARNING 'column %.% contains NULLs; NOT NULL not restored', tbl, col;
    END;
  ELSE
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I DROP NOT NULL', tbl, col);
  END IF;
END $f$;

-- ---------------------------------------------------------------------------
-- Tables (columns only; every constraint is managed by name further below).
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
  last_memo      TEXT        NOT NULL,
  version        INTEGER     NOT NULL,
  entry_count    INTEGER     NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
  last_error        TEXT        NULL
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope           TEXT        NOT NULL,
  idempotency_key TEXT        NOT NULL,
  request_hash    TEXT        NOT NULL,
  status_code     INTEGER     NOT NULL,
  response_body   JSONB       NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Column drift (dropped columns, lost NOT NULL / DEFAULT).
SELECT pg_temp.ensure_column('clearledger.settlements', c.col, c.typ, c.nn, c.dflt)
FROM (VALUES
  ('settlement_id',  'UUID',        true,  NULL),
  ('account_id',     'TEXT',        true,  NULL),
  ('reference',      'TEXT',        true,  NULL),
  ('debit_party',    'TEXT',        true,  NULL),
  ('credit_party',   'TEXT',        true,  NULL),
  ('current_status', 'TEXT',        true,  NULL),
  ('current_stage',  'TEXT',        true,  NULL),
  ('last_entry_id',  'UUID',        false, NULL),
  ('last_memo',      'TEXT',        true,  NULL),
  ('version',        'INTEGER',     true,  NULL),
  ('entry_count',    'INTEGER',     true,  '0'),
  ('created_at',     'TIMESTAMPTZ', true,  'NOW()'),
  ('updated_at',     'TIMESTAMPTZ', true,  'NOW()')
) AS c(col, typ, nn, dflt);

SELECT pg_temp.ensure_column('clearledger.events', c.col, c.typ, c.nn, c.dflt)
FROM (VALUES
  ('event_id',          'UUID',        true, NULL),
  ('settlement_id',     'UUID',        true, NULL),
  ('aggregate_version', 'INTEGER',     true, NULL),
  ('event_type',        'TEXT',        true, NULL),
  ('correlation_id',    'TEXT',        true, NULL),
  ('idempotency_key',   'TEXT',        true, NULL),
  ('occurred_at',       'TIMESTAMPTZ', true, NULL),
  ('payload',           'JSONB',       true, NULL),
  ('created_at',        'TIMESTAMPTZ', true, 'NOW()')
) AS c(col, typ, nn, dflt);

SELECT pg_temp.ensure_column('clearledger.outbox', c.col, c.typ, c.nn, c.dflt)
FROM (VALUES
  ('event_id',          'UUID',        true,  NULL),
  ('settlement_id',     'UUID',        true,  NULL),
  ('aggregate_version', 'INTEGER',     true,  NULL),
  ('correlation_id',    'TEXT',        true,  NULL),
  ('payload',           'JSONB',       true,  NULL),
  ('created_at',        'TIMESTAMPTZ', true,  'NOW()'),
  ('published_at',      'TIMESTAMPTZ', false, NULL),
  ('archived_at',       'TIMESTAMPTZ', false, NULL),
  ('attempts',          'INTEGER',     true,  '0'),
  ('last_error',        'TEXT',        false, NULL)
) AS c(col, typ, nn, dflt);

SELECT pg_temp.ensure_column('clearledger.idempotency_keys', c.col, c.typ, c.nn, c.dflt)
FROM (VALUES
  ('scope',           'TEXT',        true, NULL),
  ('idempotency_key', 'TEXT',        true, NULL),
  ('request_hash',    'TEXT',        true, NULL),
  ('status_code',     'INTEGER',     true, NULL),
  ('response_body',   'JSONB',       true, NULL),
  ('created_at',      'TIMESTAMPTZ', true, 'NOW()')
) AS c(col, typ, nn, dflt);

-- ---------------------------------------------------------------------------
-- Pure helper functions used by CHECK constraints and triggers.
-- ---------------------------------------------------------------------------

-- Canonical text: non-null, no leading/trailing whitespace, bounded length.
CREATE OR REPLACE FUNCTION clearledger.is_canonical_text(t text, min_len integer, max_len integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT t IS NOT NULL
     AND t = btrim(t)
     AND t !~ '^\s|\s$'
     AND char_length(t) BETWEEN min_len AND max_len
$f$;

-- String value of a JSON field, NULL when absent, null or not a string.
CREATE OR REPLACE FUNCTION clearledger.jtext(j jsonb, k text)
RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN jsonb_typeof(j -> k) = 'string' THEN j ->> k END
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(t text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT t IS NOT NULL AND t ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$f$;

CREATE OR REPLACE FUNCTION clearledger.is_status(t text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT t IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')
$f$;

-- Rank of the linear clearing lifecycle; NULL for DISPUTED / unknown values.
CREATE OR REPLACE FUNCTION clearledger.status_rank(t text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE t
    WHEN 'INITIATED'  THEN 0
    WHEN 'VALIDATED'  THEN 1
    WHEN 'RESERVED'   THEN 2
    WHEN 'CLEARED'    THEN 3
    WHEN 'SETTLED'    THEN 4
    WHEN 'RECONCILED' THEN 5
  END
$f$;

-- Allowed status transition between two consecutive versions.
CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE
    WHEN old_status IS NULL OR new_status IS NULL OR NOT clearledger.is_status(old_status)
         OR NOT clearledger.is_status(new_status)                    THEN false
    WHEN old_status = 'RECONCILED'                                   THEN false
    WHEN old_status = 'DISPUTED'                                     THEN new_status IN ('DISPUTED', 'RECONCILED')
    WHEN new_status = 'DISPUTED'                                     THEN true
    ELSE clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
  END
$f$;

-- Strict structural validation of a ClearLedgerDomainEventEnvelope.
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p jsonb)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
DECLARE
  d     jsonb;
  ts    timestamptz;
  top   text[] := ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                        'aggregateVersion','occurredAt','correlationId','idempotencyKey','data'];
  dkeys text[] := ARRAY['kind','accountId','reference','debitParty','creditParty','entryId',
                        'status','clearingStage','memo'];
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p)) <> 10
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(p) k WHERE k <> ALL (top)) THEN
    RETURN false;
  END IF;

  IF clearledger.jtext(p, 'schemaVersion') IS DISTINCT FROM '1.0' THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_text(clearledger.jtext(p, 'eventId')) THEN RETURN false; END IF;
  IF clearledger.jtext(p, 'eventType') IS NULL
     OR clearledger.jtext(p, 'eventType') NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN
    RETURN false;
  END IF;
  IF clearledger.jtext(p, 'aggregateType') IS DISTINCT FROM 'settlement' THEN RETURN false; END IF;
  IF NOT clearledger.is_uuid_text(clearledger.jtext(p, 'aggregateId')) THEN RETURN false; END IF;
  IF jsonb_typeof(p -> 'aggregateVersion') <> 'number'
     OR (p ->> 'aggregateVersion') !~ '^[1-9][0-9]{0,8}$' THEN
    RETURN false;
  END IF;
  IF clearledger.jtext(p, 'occurredAt') IS NULL
     OR clearledger.jtext(p, 'occurredAt') !~
        '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
    RETURN false;
  END IF;
  ts := (p ->> 'occurredAt')::timestamptz;
  IF NOT clearledger.is_canonical_text(clearledger.jtext(p, 'correlationId'), 4, 128) THEN RETURN false; END IF;
  IF NOT clearledger.is_canonical_text(clearledger.jtext(p, 'idempotencyKey'), 8, 128) THEN RETURN false; END IF;

  d := p -> 'data';
  IF jsonb_typeof(d) <> 'object'
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(d) k WHERE k <> ALL (dkeys)) THEN
    RETURN false;
  END IF;
  IF clearledger.jtext(d, 'kind') IS NULL
     OR clearledger.jtext(d, 'kind') NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN
    RETURN false;
  END IF;
  IF NOT clearledger.is_canonical_text(clearledger.jtext(d, 'accountId'), 3, 64)    THEN RETURN false; END IF;
  IF NOT clearledger.is_canonical_text(clearledger.jtext(d, 'reference'), 3, 64)    THEN RETURN false; END IF;
  IF NOT clearledger.is_canonical_text(clearledger.jtext(d, 'debitParty'), 2, 64)   THEN RETURN false; END IF;
  IF NOT clearledger.is_canonical_text(clearledger.jtext(d, 'creditParty'), 2, 64)  THEN RETURN false; END IF;
  IF NOT clearledger.is_canonical_text(clearledger.jtext(d, 'clearingStage'), 2, 74) THEN RETURN false; END IF;
  IF NOT clearledger.is_status(clearledger.jtext(d, 'status')) THEN RETURN false; END IF;
  IF clearledger.jtext(d, 'debitParty') = clearledger.jtext(d, 'creditParty') THEN RETURN false; END IF;

  -- entryId: absent, null, or a UUID string
  IF d ? 'entryId' AND jsonb_typeof(d -> 'entryId') <> 'null'
     AND NOT clearledger.is_uuid_text(clearledger.jtext(d, 'entryId')) THEN
    RETURN false;
  END IF;
  -- memo: absent, null, or a canonical 1..256 character string
  IF d ? 'memo' AND jsonb_typeof(d -> 'memo') <> 'null'
     AND NOT clearledger.is_canonical_text(clearledger.jtext(d, 'memo'), 1, 256) THEN
    RETURN false;
  END IF;
  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

-- Column / envelope equality for an events row.
CREATE OR REPLACE FUNCTION clearledger.envelope_matches_event(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_event_type text,
  c_correlation_id text, c_idempotency_key text, c_occurred_at timestamptz)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
BEGIN
  RETURN clearledger.envelope_valid(p)
     AND (p ->> 'eventId')::uuid          = c_event_id
     AND (p ->> 'aggregateId')::uuid      = c_settlement_id
     AND (p ->> 'aggregateVersion')::int  = c_version
     AND (p ->> 'eventType')              = c_event_type
     AND (p ->> 'correlationId')          = c_correlation_id
     AND (p ->> 'idempotencyKey')         = c_idempotency_key
     AND (p ->> 'occurredAt')::timestamptz = c_occurred_at;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

-- Column / envelope equality for an outbox row.
CREATE OR REPLACE FUNCTION clearledger.envelope_matches_outbox(
  p jsonb, c_event_id uuid, c_settlement_id uuid, c_version integer, c_correlation_id text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
BEGIN
  RETURN clearledger.envelope_valid(p)
     AND (p ->> 'eventId')::uuid          = c_event_id
     AND (p ->> 'aggregateId')::uuid      = c_settlement_id
     AND (p ->> 'aggregateVersion')::int  = c_version
     AND (p ->> 'correlationId')          = c_correlation_id;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

-- Version / kind / status / entryId coupling of an event envelope.
CREATE OR REPLACE FUNCTION clearledger.event_coupling_ok(p jsonb, c_version integer, c_event_type text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
DECLARE
  d jsonb := p -> 'data';
BEGIN
  IF c_version = 1 THEN
    RETURN c_event_type = 'SettlementInitiated'
       AND clearledger.jtext(d, 'kind')   = 'settlementInitiated'
       AND clearledger.jtext(d, 'status') = 'INITIATED'
       AND clearledger.jtext(d, 'entryId') IS NULL
       AND clearledger.jtext(d, 'clearingStage') = 'INITIATED@' || clearledger.jtext(d, 'debitParty')
       AND clearledger.jtext(d, 'memo')   = 'Settlement initiated';
  END IF;
  RETURN c_version > 1
     AND c_event_type = 'LedgerEntryRecorded'
     AND clearledger.jtext(d, 'kind')   = 'ledgerEntryRecorded'
     AND clearledger.jtext(d, 'status') <> 'INITIATED'
     AND clearledger.is_uuid_text(clearledger.jtext(d, 'entryId'))
     AND char_length(clearledger.jtext(d, 'clearingStage')) <= 64;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

-- Closed-schema WriteAcceptedResponse stored with an idempotency key.
CREATE OR REPLACE FUNCTION clearledger.idempotency_body_ok(b jsonb, c_scope text, c_status integer)
RETURNS boolean LANGUAGE plpgsql STABLE AS $f$
DECLARE
  keys text[] := ARRAY['settlementId','eventId','version','accepted','idempotentReplay'];
  v    integer;
BEGIN
  IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(b)) <> 5
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(b) k WHERE k <> ALL (keys)) THEN
    RETURN false;
  END IF;
  IF NOT clearledger.is_uuid_text(clearledger.jtext(b, 'settlementId'))
     OR NOT clearledger.is_uuid_text(clearledger.jtext(b, 'eventId')) THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(b -> 'version') <> 'number' OR (b ->> 'version') !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  IF b -> 'accepted' IS DISTINCT FROM 'true'::jsonb OR b -> 'idempotentReplay' IS DISTINCT FROM 'false'::jsonb THEN
    RETURN false;
  END IF;
  v := (b ->> 'version')::integer;
  IF c_scope ~ '^create:' THEN
    IF c_status <> 201 OR v <> 1 THEN RETURN false; END IF;
  ELSIF c_scope ~ '^entry:' THEN
    IF c_status <> 202 OR v < 2 THEN RETURN false; END IF;
  ELSE
    RETURN false;
  END IF;
  RETURN lower(substr(c_scope, position(':' in c_scope) + 1)) = lower(b ->> 'settlementId');
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

-- ---------------------------------------------------------------------------
-- Trigger functions.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.reject_mutation()
RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION '% on %.% is forbidden: table is append-only', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'P0001';
END $f$;

CREATE OR REPLACE FUNCTION clearledger.settlements_before_update()
RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  -- An omitted memo keeps the previous one so last_memo is never NULL.
  NEW.last_memo := COALESCE(NEW.last_memo, OLD.last_memo);

  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and can no longer be updated', OLD.settlement_id
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.account_id   IS DISTINCT FROM OLD.account_id
     OR NEW.reference    IS DISTINCT FROM OLD.reference
     OR NEW.debit_party  IS DISTINCT FROM OLD.debit_party
     OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
     OR NEW.created_at   IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
    RAISE EXCEPTION 'settlement % version must advance from % by exactly 1', OLD.settlement_id, OLD.version
      USING ERRCODE = 'P0001';
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % entry_count must advance by exactly 1', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update requires a new last_entry_id', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF (NEW.updated_at > OLD.updated_at) IS NOT TRUE THEN
    RAISE EXCEPTION 'settlement % updated_at must strictly increase', OLD.settlement_id USING ERRCODE = 'P0001';
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % status transition % -> % is not allowed',
      OLD.settlement_id, OLD.current_status, NEW.current_status USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.events_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  s          clearledger.settlements%ROWTYPE;
  d          jsonb := NEW.payload -> 'data';
  last_ver   integer;
  prev_at    timestamptz;
  prev_state text;
  want_memo  text;
BEGIN
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT max(aggregate_version) INTO last_ver FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(last_ver, 0) + 1 THEN
    RAISE EXCEPTION 'settlement % aggregate_version must be contiguous: expected %, got %',
      NEW.settlement_id, COALESCE(last_ver, 0) + 1, NEW.aggregate_version USING ERRCODE = 'P0001';
  END IF;

  IF NEW.event_type = 'LedgerEntryRecorded' AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id
          AND e.event_type = 'LedgerEntryRecorded'
          AND e.payload -> 'data' ->> 'entryId' = d ->> 'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d ->> 'entryId', NEW.settlement_id
      USING ERRCODE = 'unique_violation';
  END IF;

  -- The event must describe the settlement row it was committed with.
  IF s.account_id   IS DISTINCT FROM d ->> 'accountId'
     OR s.reference    IS DISTINCT FROM d ->> 'reference'
     OR s.debit_party  IS DISTINCT FROM d ->> 'debitParty'
     OR s.credit_party IS DISTINCT FROM d ->> 'creditParty'
     OR s.current_status IS DISTINCT FROM d ->> 'status'
     OR s.current_stage  IS DISTINCT FROM d ->> 'clearingStage'
     OR s.last_entry_id  IS DISTINCT FROM NULLIF(d ->> 'entryId', '')::uuid
     OR s.version        IS DISTINCT FROM NEW.aggregate_version
     OR s.updated_at     IS DISTINCT FROM NEW.occurred_at
     OR (NEW.aggregate_version = 1 AND s.created_at IS DISTINCT FROM NEW.occurred_at) THEN
    RAISE EXCEPTION 'event % does not match settlement % row at version %',
      NEW.event_id, NEW.settlement_id, s.version USING ERRCODE = 'P0001';
  END IF;

  want_memo := d ->> 'memo';
  IF want_memo IS NULL THEN
    SELECT e.payload -> 'data' ->> 'memo' INTO want_memo
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id
       AND e.aggregate_version < NEW.aggregate_version
       AND e.payload -> 'data' ->> 'memo' IS NOT NULL
     ORDER BY e.aggregate_version DESC
     LIMIT 1;
  END IF;
  IF s.last_memo IS DISTINCT FROM want_memo THEN
    RAISE EXCEPTION 'event % memo does not match settlement % last_memo', NEW.event_id, NEW.settlement_id
      USING ERRCODE = 'P0001';
  END IF;

  IF NEW.aggregate_version >= 2 THEN
    SELECT e.occurred_at, e.payload -> 'data' ->> 'status' INTO prev_at, prev_state
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.aggregate_version = NEW.aggregate_version - 1;
    IF prev_at IS NULL OR (NEW.occurred_at > prev_at) IS NOT TRUE THEN
      RAISE EXCEPTION 'event % occurred_at must be strictly after the previous event', NEW.event_id
        USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_ok(prev_state, d ->> 'status') THEN
      RAISE EXCEPTION 'event % status transition % -> % is not allowed', NEW.event_id, prev_state, d ->> 'status'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.outbox_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  ev       clearledger.events%ROWTYPE;
  last_ver integer;
BEGIN
  SELECT * INTO ev FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF ev.settlement_id <> NEW.settlement_id
     OR ev.aggregate_version <> NEW.aggregate_version
     OR ev.correlation_id <> NEW.correlation_id
     OR ev.payload IS DISTINCT FROM NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % must mirror the events row', NEW.event_id USING ERRCODE = 'P0001';
  END IF;
  SELECT max(aggregate_version) INTO last_ver FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version IS DISTINCT FROM COALESCE(last_ver, 0) + 1 THEN
    RAISE EXCEPTION 'outbox aggregate_version for settlement % must be contiguous: expected %, got %',
      NEW.settlement_id, COALESCE(last_ver, 0) + 1, NEW.aggregate_version USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.outbox_before_update()
RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF NEW.seq IS DISTINCT FROM OLD.seq
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
     OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
     OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
     OR NEW.payload IS DISTINCT FROM OLD.payload
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'outbox envelope columns of event % are immutable', OLD.event_id USING ERRCODE = 'P0001';
  END IF;
  IF NEW.attempts < OLD.attempts THEN
    RAISE EXCEPTION 'outbox attempts of event % cannot decrease', OLD.event_id USING ERRCODE = 'P0001';
  END IF;

  IF OLD.published_at IS NULL THEN
    IF NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL) THEN
      RAISE EXCEPTION 'publishing outbox event % requires attempts to increase and archived_at to stay NULL',
        OLD.event_id USING ERRCODE = 'P0001';
    END IF;
  ELSE
    IF NEW.published_at IS NOT NULL THEN
      IF NEW.published_at IS DISTINCT FROM OLD.published_at
         OR NEW.attempts IS DISTINCT FROM OLD.attempts
         OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
        RAISE EXCEPTION 'published outbox event % delivery columns are immutable', OLD.event_id
          USING ERRCODE = 'P0001';
      END IF;
      IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
         AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
        RAISE EXCEPTION 'archived_at of outbox event % cannot change without being reset first', OLD.event_id
          USING ERRCODE = 'P0001';
      END IF;
    ELSE
      -- operational replay: published_at and archived_at are reset together
      IF NEW.archived_at IS NOT NULL
         OR NEW.attempts IS DISTINCT FROM OLD.attempts
         OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
        RAISE EXCEPTION 'replay reset of outbox event % must clear both published_at and archived_at', OLD.event_id
          USING ERRCODE = 'P0001';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_before_insert()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  b          jsonb := NEW.response_body;
  ev_id      uuid;
  s_id       uuid;
  ver        integer;
BEGIN
  BEGIN
    ev_id := (b ->> 'eventId')::uuid;
    s_id  := (b ->> 'settlementId')::uuid;
    ver   := (b ->> 'version')::integer;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'idempotency response_body is not a WriteAcceptedResponse' USING ERRCODE = 'P0001';
  END;

  IF NOT EXISTS (SELECT 1 FROM clearledger.events e
                  WHERE e.event_id = ev_id AND e.settlement_id = s_id
                    AND e.aggregate_version = ver AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency key % has no matching committed event', NEW.idempotency_key
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o
                  WHERE o.event_id = ev_id AND o.settlement_id = s_id AND o.aggregate_version = ver) THEN
    RAISE EXCEPTION 'idempotency key % has no matching outbox row', NEW.idempotency_key
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys k
              WHERE (k.response_body ->> 'eventId')::uuid = ev_id
                 OR ((k.response_body ->> 'settlementId')::uuid = s_id
                     AND (k.response_body ->> 'version')::integer = ver)) THEN
    RAISE EXCEPTION 'event % is already bound to an idempotency key', ev_id USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END $f$;

-- ---------------------------------------------------------------------------
-- Constraints: keys and uniqueness first (FKs depend on them), then CHECKs,
-- then foreign keys.
-- ---------------------------------------------------------------------------

-- settlements
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'pk_settlements', 'PRIMARY KEY (settlement_id)', true);

-- events
SELECT pg_temp.ensure_constraint('clearledger.events', 'pk_events', 'PRIMARY KEY (seq)', true);
SELECT pg_temp.ensure_constraint('clearledger.events', 'uq_events_event_id', 'UNIQUE (event_id)', true);
SELECT pg_temp.ensure_constraint('clearledger.events', 'uq_events_settlement_version', 'UNIQUE (settlement_id, aggregate_version)', true);
SELECT pg_temp.ensure_constraint('clearledger.events', 'uq_events_settlement_idempotency', 'UNIQUE (settlement_id, idempotency_key)', true);

-- outbox
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'pk_outbox', 'PRIMARY KEY (seq)', true);
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'uq_outbox_event_id', 'UNIQUE (event_id)', true);
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'uq_outbox_settlement_version', 'UNIQUE (settlement_id, aggregate_version)', true);

-- idempotency_keys
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'pk_idempotency_keys', 'PRIMARY KEY (scope, idempotency_key)', true);

-- settlements CHECKs
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_account_id',
  'CHECK (account_id = btrim(account_id) AND clearledger.is_canonical_text(account_id, 3, 64))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_reference',
  'CHECK (reference = btrim(reference) AND clearledger.is_canonical_text(reference, 3, 64))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_debit_party',
  'CHECK (debit_party = btrim(debit_party) AND clearledger.is_canonical_text(debit_party, 2, 64))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_credit_party',
  'CHECK (credit_party = btrim(credit_party) AND clearledger.is_canonical_text(credit_party, 2, 64))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_parties_differ',
  'CHECK (debit_party <> credit_party)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_current_stage',
  'CHECK (current_stage = btrim(current_stage) AND clearledger.is_canonical_text(current_stage, 2, 74))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_last_memo',
  'CHECK (last_memo = btrim(last_memo) AND clearledger.is_canonical_text(last_memo, 1, 256))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_status',
  'CHECK (clearledger.is_status(current_status))');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_version',
  'CHECK (version >= 1)');
SELECT pg_temp.ensure_constraint('clearledger.settlements', 'chk_settlements_lifecycle',
  $c$CHECK (
    CASE
      WHEN version = 1 THEN
            entry_count = 0
        AND current_status = 'INITIATED'
        AND current_stage = 'INITIATED@' || debit_party
        AND last_entry_id IS NULL
        AND last_memo = 'Settlement initiated'
        AND updated_at = created_at
      ELSE
            entry_count = version - 1
        AND current_status <> 'INITIATED'
        AND last_entry_id IS NOT NULL
        AND last_memo IS NOT NULL
        AND char_length(current_stage) <= 64
        AND updated_at > created_at
    END)$c$);

-- events CHECKs
SELECT pg_temp.ensure_constraint('clearledger.events', 'chk_events_version', 'CHECK (aggregate_version >= 1)');
SELECT pg_temp.ensure_constraint('clearledger.events', 'chk_events_event_type',
  $c$CHECK (event_type IN ('SettlementInitiated', 'LedgerEntryRecorded'))$c$);
SELECT pg_temp.ensure_constraint('clearledger.events', 'chk_events_correlation_id',
  'CHECK (correlation_id = btrim(correlation_id) AND clearledger.is_canonical_text(correlation_id, 4, 128))');
SELECT pg_temp.ensure_constraint('clearledger.events', 'chk_events_idempotency_key',
  'CHECK (idempotency_key = btrim(idempotency_key) AND clearledger.is_canonical_text(idempotency_key, 8, 128))');
SELECT pg_temp.ensure_constraint('clearledger.events', 'chk_events_payload_envelope',
  'CHECK (clearledger.envelope_valid(payload))');
SELECT pg_temp.ensure_constraint('clearledger.events', 'chk_events_payload_columns',
  'CHECK (clearledger.envelope_matches_event(payload, event_id, settlement_id, aggregate_version, event_type, correlation_id, idempotency_key, occurred_at))');
SELECT pg_temp.ensure_constraint('clearledger.events', 'chk_events_payload_coupling',
  'CHECK (clearledger.event_coupling_ok(payload, aggregate_version, event_type))');

-- outbox CHECKs
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_version', 'CHECK (aggregate_version >= 1)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_correlation_id',
  'CHECK (correlation_id = btrim(correlation_id) AND clearledger.is_canonical_text(correlation_id, 4, 128))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_payload_envelope',
  'CHECK (clearledger.envelope_valid(payload))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_payload_columns',
  'CHECK (clearledger.envelope_matches_outbox(payload, event_id, settlement_id, aggregate_version, correlation_id))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_attempts', 'CHECK (attempts >= 0)');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_unattempted',
  'CHECK (attempts > 0 OR (published_at IS NULL AND last_error IS NULL))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_published',
  'CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_failed',
  'CHECK (last_error IS NULL OR (published_at IS NULL AND attempts >= 1 AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'chk_outbox_archived',
  'CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))');

-- idempotency_keys CHECKs
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'chk_idempotency_scope',
  $c$CHECK (scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')$c$);
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'chk_idempotency_key',
  'CHECK (idempotency_key = btrim(idempotency_key) AND clearledger.is_canonical_text(idempotency_key, 8, 128))');
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'chk_idempotency_request_hash',
  $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$);
SELECT pg_temp.ensure_constraint('clearledger.idempotency_keys', 'chk_idempotency_response',
  'CHECK (clearledger.idempotency_body_ok(response_body, scope, status_code))');

-- foreign keys
SELECT pg_temp.ensure_constraint('clearledger.events', 'fk_events_settlement',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements (settlement_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'fk_outbox_event',
  'FOREIGN KEY (event_id) REFERENCES clearledger.events (event_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'fk_outbox_settlement',
  'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements (settlement_id) ON DELETE CASCADE');
SELECT pg_temp.ensure_constraint('clearledger.outbox', 'fk_outbox_event_version',
  'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events (settlement_id, aggregate_version) ON DELETE CASCADE');

-- Drop any constraint that is not part of the canonical set (weakened or
-- replaced CHECKs, stray UNIQUE / FOREIGN KEY definitions).
DO $f$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.conrelid::regclass AS tbl, c.conname
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'clearledger'
     WHERE t.relname IN ('settlements', 'events', 'outbox', 'idempotency_keys')
       AND c.contype IN ('c', 'u', 'p', 'f')
       AND c.conname NOT IN (
         'pk_settlements',
         'pk_events', 'uq_events_event_id', 'uq_events_settlement_version', 'uq_events_settlement_idempotency',
         'pk_outbox', 'uq_outbox_event_id', 'uq_outbox_settlement_version',
         'pk_idempotency_keys',
         'chk_settlements_account_id', 'chk_settlements_reference', 'chk_settlements_debit_party',
         'chk_settlements_credit_party', 'chk_settlements_parties_differ', 'chk_settlements_current_stage',
         'chk_settlements_last_memo', 'chk_settlements_status', 'chk_settlements_version',
         'chk_settlements_lifecycle',
         'chk_events_version', 'chk_events_event_type', 'chk_events_correlation_id',
         'chk_events_idempotency_key', 'chk_events_payload_envelope', 'chk_events_payload_columns',
         'chk_events_payload_coupling',
         'chk_outbox_version', 'chk_outbox_correlation_id', 'chk_outbox_payload_envelope',
         'chk_outbox_payload_columns', 'chk_outbox_attempts', 'chk_outbox_unattempted',
         'chk_outbox_published', 'chk_outbox_failed', 'chk_outbox_archived',
         'chk_idempotency_scope', 'chk_idempotency_key', 'chk_idempotency_request_hash',
         'chk_idempotency_response',
         'fk_events_settlement', 'fk_outbox_event', 'fk_outbox_settlement', 'fk_outbox_event_version')
  LOOP
    RAISE WARNING 'dropping non-canonical constraint % on %', r.conname, r.tbl;
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I CASCADE', r.tbl, r.conname);
  END LOOP;
END $f$;

-- ---------------------------------------------------------------------------
-- Triggers.
-- ---------------------------------------------------------------------------

SELECT pg_temp.ensure_trigger('clearledger.settlements', 'trg_settlements_before_update',
  'CREATE TRIGGER trg_settlements_before_update BEFORE UPDATE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlements_before_update()');
SELECT pg_temp.ensure_trigger('clearledger.settlements', 'trg_settlements_no_delete',
  'CREATE TRIGGER trg_settlements_no_delete BEFORE DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()');

SELECT pg_temp.ensure_trigger('clearledger.events', 'trg_events_before_insert',
  'CREATE TRIGGER trg_events_before_insert BEFORE INSERT ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.events_before_insert()');
SELECT pg_temp.ensure_trigger('clearledger.events', 'trg_events_append_only',
  'CREATE TRIGGER trg_events_append_only BEFORE UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()');

SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_before_insert',
  'CREATE TRIGGER trg_outbox_before_insert BEFORE INSERT ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_before_insert()');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_before_update',
  'CREATE TRIGGER trg_outbox_before_update BEFORE UPDATE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_before_update()');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_no_delete',
  'CREATE TRIGGER trg_outbox_no_delete BEFORE DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()');

SELECT pg_temp.ensure_trigger('clearledger.idempotency_keys', 'trg_idempotency_before_insert',
  'CREATE TRIGGER trg_idempotency_before_insert BEFORE INSERT ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_before_insert()');
SELECT pg_temp.ensure_trigger('clearledger.idempotency_keys', 'trg_idempotency_append_only',
  'CREATE TRIGGER trg_idempotency_append_only BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.reject_mutation()');

-- Remove user-defined triggers that are not part of the canonical set.
DO $f$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT t.tgrelid::regclass AS tbl, t.tgname
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'clearledger'
     WHERE NOT t.tgisinternal
       AND c.relname IN ('settlements', 'events', 'outbox', 'idempotency_keys')
       AND t.tgname NOT IN (
         'trg_settlements_before_update', 'trg_settlements_no_delete',
         'trg_events_before_insert', 'trg_events_append_only',
         'trg_outbox_before_insert', 'trg_outbox_before_update', 'trg_outbox_no_delete',
         'trg_idempotency_before_insert', 'trg_idempotency_append_only')
  LOOP
    RAISE WARNING 'dropping non-canonical trigger % on %', r.tgname, r.tbl;
    EXECUTE format('DROP TRIGGER %I ON %s', r.tgname, r.tbl);
  END LOOP;
END $f$;

-- ---------------------------------------------------------------------------
-- Required indexes.
-- ---------------------------------------------------------------------------

SELECT pg_temp.ensure_index('idx_clearledger_outbox_unpublished',
  'CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox (seq) WHERE published_at IS NULL');
SELECT pg_temp.ensure_index('idx_clearledger_outbox_unarchived',
  'CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL');
SELECT pg_temp.ensure_index('idx_clearledger_events_settlement_version',
  'CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events (settlement_id, aggregate_version)');
SELECT pg_temp.ensure_index('idx_clearledger_idempotency_event',
  $c$CREATE UNIQUE INDEX idx_clearledger_idempotency_event ON clearledger.idempotency_keys (((response_body ->> 'eventId')::uuid))$c$);
SELECT pg_temp.ensure_index('idx_clearledger_idempotency_version',
  $c$CREATE UNIQUE INDEX idx_clearledger_idempotency_version ON clearledger.idempotency_keys (((response_body ->> 'settlementId')::uuid), ((response_body ->> 'version')::integer))$c$);
SELECT pg_temp.ensure_index('idx_clearledger_entry_id',
  $c$CREATE UNIQUE INDEX idx_clearledger_entry_id ON clearledger.events (settlement_id, ((payload -> 'data' ->> 'entryId')::uuid)) WHERE event_type = 'LedgerEntryRecorded'$c$);

COMMIT;
