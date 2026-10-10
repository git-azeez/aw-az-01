-- ClearLedger PostgreSQL schema, relational invariants, triggers and indexes.
--
-- Idempotent: safe to run on an empty database, on a healthy database under
-- live traffic, and on a database whose constraints / triggers / indexes /
-- functions were altered or removed out-of-band.  Every object is compared with
-- its canonical definition and only (re)created when it differs, so a healthy
-- run takes no table-level locks.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
SET search_path = pg_catalog, public;
SET lock_timeout = '20s';

SELECT pg_advisory_lock(7203041985);

CREATE SCHEMA IF NOT EXISTS clearledger;

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id UUID NOT NULL PRIMARY KEY,
  account_id    TEXT NOT NULL,
  reference     TEXT NOT NULL,
  debit_party   TEXT NOT NULL,
  credit_party  TEXT NOT NULL,
  current_status TEXT NOT NULL,
  current_stage TEXT NOT NULL,
  last_entry_id UUID NULL,
  last_memo     TEXT NOT NULL,
  version       INTEGER NOT NULL,
  entry_count   INTEGER NOT NULL DEFAULT 0,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS clearledger.events (
  seq BIGSERIAL NOT NULL PRIMARY KEY,
  event_id UUID NOT NULL UNIQUE,
  settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
  aggregate_version INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (settlement_id, aggregate_version),
  UNIQUE (settlement_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq BIGSERIAL NOT NULL PRIMARY KEY,
  event_id UUID NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
  settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
  aggregate_version INTEGER NOT NULL,
  correlation_id TEXT NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at TIMESTAMPTZ NULL,
  archived_at TIMESTAMPTZ NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_error TEXT NULL,
  UNIQUE (settlement_id, aggregate_version),
  FOREIGN KEY (settlement_id, aggregate_version)
    REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status_code INTEGER NOT NULL,
  response_body JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (scope, idempotency_key)
);

---------------------------------------------------------------------------
-- Temporary reconciliation helpers (dropped automatically at session end)
---------------------------------------------------------------------------
-- Ensure a column exists, is NOT NULL (when requested) and has its default.
CREATE FUNCTION pg_temp.ensure_column(tbl text, col text, coltype text, not_null boolean, dflt text)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  cur_notnull boolean;
  cur_default text;
  exists_ boolean;
BEGIN
  SELECT true, a.attnotnull, pg_get_expr(d.adbin, d.adrelid)
    INTO exists_, cur_notnull, cur_default
    FROM pg_attribute a
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE a.attrelid = tbl::regclass AND a.attname = col AND NOT a.attisdropped;
  IF NOT FOUND THEN
    BEGIN
      EXECUTE format('ALTER TABLE %s ADD COLUMN %I %s%s%s', tbl, col, coltype,
                     CASE WHEN dflt IS NOT NULL THEN ' DEFAULT ' || dflt ELSE '' END,
                     CASE WHEN not_null THEN ' NOT NULL' ELSE '' END);
    EXCEPTION WHEN others THEN
      RAISE WARNING 'cannot restore column %.%: %', tbl, col, SQLERRM;
    END;
    RETURN;
  END IF;
  IF dflt IS NOT NULL AND cur_default IS NULL THEN
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET DEFAULT %s', tbl, col, dflt);
  END IF;
  IF not_null AND NOT cur_notnull THEN
    BEGIN
      EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET NOT NULL', tbl, col);
    EXCEPTION WHEN others THEN
      RAISE WARNING 'cannot restore NOT NULL on %.%: %', tbl, col, SQLERRM;
    END;
  END IF;
END $f$;

CREATE FUNCTION pg_temp.constraint_cols(rel regclass, keys smallint[]) RETURNS text[]
LANGUAGE sql AS $f$
  SELECT array_agg(a.attname::text ORDER BY k.ord)
    FROM unnest(keys) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = rel AND a.attnum = k.attnum
$f$;

-- UNIQUE / PRIMARY KEY on the given column list (matched by columns, not by name).
CREATE FUNCTION pg_temp.ensure_key(tbl text, kind "char", cname text, cols text[])
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  found_ boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conrelid = tbl::regclass AND c.contype = kind AND c.convalidated
       AND pg_temp.constraint_cols(c.conrelid, c.conkey) = cols
  ) INTO found_;
  IF NOT found_ THEN
    IF kind = 'p' THEN
      EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', tbl, cname);
      EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I PRIMARY KEY (%s)', tbl, cname, array_to_string(cols, ', '));
    ELSE
      EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', tbl, cname);
      EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I UNIQUE (%s)', tbl, cname, array_to_string(cols, ', '));
    END IF;
  END IF;
END $f$;

-- FOREIGN KEY ... ON DELETE CASCADE
CREATE FUNCTION pg_temp.ensure_fk(tbl text, cname text, cols text[], reftbl text, refcols text[])
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  found_ boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conrelid = tbl::regclass AND c.contype = 'f' AND c.confrelid = reftbl::regclass
       AND c.confdeltype = 'c' AND c.convalidated
       AND pg_temp.constraint_cols(c.conrelid, c.conkey) = cols
       AND pg_temp.constraint_cols(c.confrelid, c.confkey) = refcols
  ) INTO found_;
  IF NOT found_ THEN
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', tbl, cname);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES %s (%s) ON DELETE CASCADE',
                   tbl, cname, array_to_string(cols, ', '), reftbl, array_to_string(refcols, ', '));
  END IF;
END $f$;

-- CHECK constraint: compared (deparsed) with a shadow copy built on a temp table;
-- replaced when missing or altered, validated when not yet validated.
CREATE FUNCTION pg_temp.ensure_check(tbl text, cname text, expr text)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  want text;
  have text;
  is_valid boolean;
BEGIN
  EXECUTE format('CREATE TEMP TABLE shadow_chk (LIKE %s)', tbl);
  EXECUTE format('ALTER TABLE pg_temp.shadow_chk ADD CONSTRAINT %I CHECK (%s)', cname, expr);
  SELECT pg_get_constraintdef(c.oid) INTO want
    FROM pg_constraint c WHERE c.conrelid = 'pg_temp.shadow_chk'::regclass AND c.conname = cname;
  DROP TABLE pg_temp.shadow_chk;

  SELECT pg_get_constraintdef(c.oid), c.convalidated INTO have, is_valid
    FROM pg_constraint c
   WHERE c.conrelid = tbl::regclass AND c.conname = cname AND c.contype = 'c';

  IF NOT FOUND OR replace(have, ' NOT VALID', '') IS DISTINCT FROM want THEN
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', tbl, cname);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I CHECK (%s) NOT VALID', tbl, cname, expr);
    is_valid := false;
  END IF;
  IF NOT is_valid THEN
    BEGIN
      EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', tbl, cname);
    EXCEPTION WHEN check_violation THEN
      RAISE WARNING 'constraint % on % is enforced for new rows but existing rows violate it', cname, tbl;
    END;
  END IF;
END $f$;

-- Index: compared with a shadow copy on a temp table; recreated when differing.
CREATE FUNCTION pg_temp.ensure_index(tbl text, iname text, ddl_tail text, is_unique boolean)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  want text;
  have text;
  ok boolean;
BEGIN
  EXECUTE format('CREATE TEMP TABLE shadow_idx (LIKE %s)', tbl);
  EXECUTE format('CREATE %s INDEX %I ON pg_temp.shadow_idx %s', CASE WHEN is_unique THEN 'UNIQUE' ELSE '' END, iname, ddl_tail);
  SELECT regexp_replace(pg_get_indexdef(i.indexrelid), ' ON [^ ]+ USING', ' ON T USING') INTO want
    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
   WHERE i.indrelid = 'pg_temp.shadow_idx'::regclass AND ic.relname = iname;
  DROP TABLE pg_temp.shadow_idx;

  SELECT regexp_replace(pg_get_indexdef(i.indexrelid), ' ON [^ ]+ USING', ' ON T USING'),
         i.indisvalid AND i.indisready AND i.indrelid = tbl::regclass
    INTO have, ok
    FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
   WHERE ic.relname = iname AND ic.relnamespace = 'clearledger'::regnamespace;

  IF NOT FOUND OR NOT ok OR have IS DISTINCT FROM want THEN
    EXECUTE format('DROP INDEX IF EXISTS clearledger.%I', iname);
    EXECUTE format('CREATE %s INDEX %I ON %s %s', CASE WHEN is_unique THEN 'UNIQUE' ELSE '' END, iname, tbl, ddl_tail);
  END IF;
END $f$;

-- Row trigger: (re)created only when missing or different; always left enabled.
CREATE FUNCTION pg_temp.ensure_trigger(tbl text, tname text, timing_events int, fn text)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  ok boolean;
  ev text;
BEGIN
  -- timing_events: tgtype bit mask (ROW=1, BEFORE=2, INSERT=4, DELETE=8, UPDATE=16)
  SELECT t.tgtype = timing_events AND t.tgfoid = fn::regproc AND t.tgenabled = 'O'
         AND t.tgqual IS NULL AND t.tgnargs = 0
    INTO ok
    FROM pg_trigger t
   WHERE t.tgrelid = tbl::regclass AND t.tgname = tname AND NOT t.tgisinternal;
  IF NOT FOUND OR NOT ok THEN
    ev := concat_ws(' OR ',
            CASE WHEN timing_events & 4  <> 0 THEN 'INSERT' END,
            CASE WHEN timing_events & 16 <> 0 THEN 'UPDATE' END,
            CASE WHEN timing_events & 8  <> 0 THEN 'DELETE' END);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', tname, tbl);
    EXECUTE format('CREATE TRIGGER %I BEFORE %s ON %s FOR EACH ROW EXECUTE FUNCTION %s()', tname, ev, tbl, fn);
  END IF;
END $f$;

---------------------------------------------------------------------------
-- Column, key and foreign-key convergence
---------------------------------------------------------------------------
SELECT pg_temp.ensure_column('clearledger.settlements', c.n, c.t, c.nn, c.d)
  FROM (VALUES
    ('settlement_id','UUID',true,NULL), ('account_id','TEXT',true,NULL), ('reference','TEXT',true,NULL),
    ('debit_party','TEXT',true,NULL), ('credit_party','TEXT',true,NULL), ('current_status','TEXT',true,NULL),
    ('current_stage','TEXT',true,NULL), ('last_entry_id','UUID',false,NULL), ('last_memo','TEXT',true,NULL),
    ('version','INTEGER',true,NULL), ('entry_count','INTEGER',true,'0'),
    ('created_at','TIMESTAMPTZ',true,'NOW()'), ('updated_at','TIMESTAMPTZ',true,'NOW()')
  ) AS c(n,t,nn,d);

SELECT pg_temp.ensure_column('clearledger.events', c.n, c.t, c.nn, c.d)
  FROM (VALUES
    ('event_id','UUID',true,NULL), ('settlement_id','UUID',true,NULL), ('aggregate_version','INTEGER',true,NULL),
    ('event_type','TEXT',true,NULL), ('correlation_id','TEXT',true,NULL), ('idempotency_key','TEXT',true,NULL),
    ('occurred_at','TIMESTAMPTZ',true,NULL), ('payload','JSONB',true,NULL), ('created_at','TIMESTAMPTZ',true,'NOW()')
  ) AS c(n,t,nn,d);

SELECT pg_temp.ensure_column('clearledger.outbox', c.n, c.t, c.nn, c.d)
  FROM (VALUES
    ('event_id','UUID',true,NULL), ('settlement_id','UUID',true,NULL), ('aggregate_version','INTEGER',true,NULL),
    ('correlation_id','TEXT',true,NULL), ('payload','JSONB',true,NULL), ('created_at','TIMESTAMPTZ',true,'NOW()'),
    ('published_at','TIMESTAMPTZ',false,NULL), ('archived_at','TIMESTAMPTZ',false,NULL),
    ('attempts','INTEGER',true,'0'), ('last_error','TEXT',false,NULL)
  ) AS c(n,t,nn,d);

SELECT pg_temp.ensure_column('clearledger.idempotency_keys', c.n, c.t, c.nn, c.d)
  FROM (VALUES
    ('scope','TEXT',true,NULL), ('idempotency_key','TEXT',true,NULL), ('request_hash','TEXT',true,NULL),
    ('status_code','INTEGER',true,NULL), ('response_body','JSONB',true,NULL), ('created_at','TIMESTAMPTZ',true,'NOW()')
  ) AS c(n,t,nn,d);

SELECT pg_temp.ensure_key('clearledger.settlements', 'p', 'settlements_pkey', ARRAY['settlement_id']);
SELECT pg_temp.ensure_key('clearledger.events', 'p', 'events_pkey', ARRAY['seq']);
SELECT pg_temp.ensure_key('clearledger.events', 'u', 'events_event_id_key', ARRAY['event_id']);
SELECT pg_temp.ensure_key('clearledger.events', 'u', 'events_settlement_version_key', ARRAY['settlement_id','aggregate_version']);
SELECT pg_temp.ensure_key('clearledger.events', 'u', 'events_settlement_idempotency_key', ARRAY['settlement_id','idempotency_key']);
SELECT pg_temp.ensure_key('clearledger.outbox', 'p', 'outbox_pkey', ARRAY['seq']);
SELECT pg_temp.ensure_key('clearledger.outbox', 'u', 'outbox_event_id_key', ARRAY['event_id']);
SELECT pg_temp.ensure_key('clearledger.outbox', 'u', 'outbox_settlement_version_key', ARRAY['settlement_id','aggregate_version']);
SELECT pg_temp.ensure_key('clearledger.idempotency_keys', 'p', 'idempotency_keys_pkey', ARRAY['scope','idempotency_key']);

SELECT pg_temp.ensure_fk('clearledger.events', 'events_settlement_id_fkey', ARRAY['settlement_id'],
                         'clearledger.settlements', ARRAY['settlement_id']);
SELECT pg_temp.ensure_fk('clearledger.outbox', 'outbox_event_id_fkey', ARRAY['event_id'],
                         'clearledger.events', ARRAY['event_id']);
SELECT pg_temp.ensure_fk('clearledger.outbox', 'outbox_settlement_id_fkey', ARRAY['settlement_id'],
                         'clearledger.settlements', ARRAY['settlement_id']);
SELECT pg_temp.ensure_fk('clearledger.outbox', 'outbox_settlement_version_fkey',
                         ARRAY['settlement_id','aggregate_version'],
                         'clearledger.events', ARRAY['settlement_id','aggregate_version']);

---------------------------------------------------------------------------
-- Domain functions (always replaced, so tampered bodies are repaired)
---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE s
    WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
    WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5
    ELSE NULL END
$f$;

CREATE OR REPLACE FUNCTION clearledger.status_transition_ok(old_status text, new_status text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE
    WHEN old_status IS NULL OR new_status IS NULL THEN false
    WHEN old_status = 'RECONCILED' THEN false
    WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED', 'RECONCILED')
    WHEN new_status = 'DISPUTED' THEN clearledger.status_rank(old_status) IS NOT NULL
    ELSE COALESCE(clearledger.status_rank(new_status) >= clearledger.status_rank(old_status), false)
  END
$f$;

-- Strict structural validation of a ClearLedgerDomainEventEnvelope (events.schema.json)
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  d jsonb;
  v integer;
  uuid_re constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  ts_re   constant text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$';
  statuses constant text[] := ARRAY['INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'];
  s text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
                     'occurredAt','correlationId','idempotencyKey','data']) THEN RETURN false; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p)) <> 10 THEN RETURN false; END IF;

  IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventId') <> 'string' OR p->>'eventId' !~ uuid_re THEN RETURN false; END IF;
  IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateId') <> 'string' OR p->>'aggregateId' !~ uuid_re THEN RETURN false; END IF;
  IF jsonb_typeof(p->'aggregateVersion') <> 'number' OR p->>'aggregateVersion' !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  v := (p->>'aggregateVersion')::integer;
  IF jsonb_typeof(p->'occurredAt') <> 'string' OR p->>'occurredAt' !~ ts_re THEN RETURN false; END IF;
  PERFORM (p->>'occurredAt')::timestamptz;
  IF jsonb_typeof(p->'correlationId') <> 'string' OR p->>'correlationId' <> btrim(p->>'correlationId')
     OR char_length(p->>'correlationId') NOT BETWEEN 4 AND 128 THEN RETURN false; END IF;
  IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR p->>'idempotencyKey' <> btrim(p->>'idempotencyKey')
     OR char_length(p->>'idempotencyKey') NOT BETWEEN 8 AND 128 THEN RETURN false; END IF;

  d := p->'data';
  IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
  IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(d) k
              WHERE k NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo'))
  THEN RETURN false; END IF;

  FOREACH s IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
    IF jsonb_typeof(d->s) <> 'string' OR d->>s <> btrim(d->>s) THEN RETURN false; END IF;
  END LOOP;

  IF d->>'kind' NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN false; END IF;
  IF char_length(d->>'accountId') NOT BETWEEN 3 AND 64 THEN RETURN false; END IF;
  IF char_length(d->>'reference') NOT BETWEEN 3 AND 64 THEN RETURN false; END IF;
  IF char_length(d->>'debitParty') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  IF char_length(d->>'creditParty') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  IF d->>'debitParty' = d->>'creditParty' THEN RETURN false; END IF;
  IF NOT (d->>'status' = ANY (statuses)) THEN RETURN false; END IF;

  IF d ? 'entryId' AND jsonb_typeof(d->'entryId') NOT IN ('null','string') THEN RETURN false; END IF;
  IF jsonb_typeof(d->'entryId') = 'string' AND d->>'entryId' !~ uuid_re THEN RETURN false; END IF;
  IF d ? 'memo' THEN
    IF jsonb_typeof(d->'memo') NOT IN ('null','string') THEN RETURN false; END IF;
    IF jsonb_typeof(d->'memo') = 'string' AND (d->>'memo' <> btrim(d->>'memo') OR char_length(d->>'memo') NOT BETWEEN 1 AND 256) THEN RETURN false; END IF;
  END IF;

  IF v = 1 THEN
    IF p->>'eventType' <> 'SettlementInitiated' OR d->>'kind' <> 'settlementInitiated'
       OR d->>'status' <> 'INITIATED'
       OR (d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null')
       OR d->>'clearingStage' <> 'INITIATED@' || (d->>'debitParty')
       OR d->>'memo' IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
  ELSE
    IF p->>'eventType' <> 'LedgerEntryRecorded' OR d->>'kind' <> 'ledgerEntryRecorded'
       OR d->>'status' = 'INITIATED'
       OR jsonb_typeof(d->'entryId') IS DISTINCT FROM 'string'
       OR char_length(d->>'clearingStage') NOT BETWEEN 2 AND 64 THEN RETURN false; END IF;
  END IF;
  RETURN true;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.event_row_valid(
  p_event_id uuid, p_settlement_id uuid, p_version integer, p_event_type text,
  p_correlation_id text, p_idempotency_key text, p_occurred_at timestamptz, p_payload jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
BEGIN
  RETURN clearledger.envelope_valid(p_payload)
     AND p_payload->>'eventId' = p_event_id::text
     AND p_payload->>'aggregateId' = p_settlement_id::text
     AND (p_payload->>'aggregateVersion')::integer = p_version
     AND p_payload->>'eventType' = p_event_type
     AND p_payload->>'correlationId' = p_correlation_id
     AND p_payload->>'idempotencyKey' = p_idempotency_key
     AND (p_payload->>'occurredAt')::timestamptz = p_occurred_at;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.outbox_row_valid(
  p_event_id uuid, p_settlement_id uuid, p_version integer, p_correlation_id text, p_payload jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
BEGIN
  RETURN clearledger.envelope_valid(p_payload)
     AND p_payload->>'eventId' = p_event_id::text
     AND p_payload->>'aggregateId' = p_settlement_id::text
     AND (p_payload->>'aggregateVersion')::integer = p_version
     AND p_payload->>'correlationId' = p_correlation_id;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

-- Closed-schema WriteAcceptedResponse + scope / status code coupling
CREATE OR REPLACE FUNCTION clearledger.idempotency_response_valid(p_scope text, p_status integer, p_body jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE
  v integer;
  sid text;
BEGIN
  IF p_body IS NULL OR jsonb_typeof(p_body) <> 'object' THEN RETURN false; END IF;
  IF NOT (p_body ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p_body)) <> 5 THEN RETURN false; END IF;
  IF jsonb_typeof(p_body->'settlementId') <> 'string' OR jsonb_typeof(p_body->'eventId') <> 'string'
     OR jsonb_typeof(p_body->'version') <> 'number' OR jsonb_typeof(p_body->'accepted') <> 'boolean'
     OR jsonb_typeof(p_body->'idempotentReplay') <> 'boolean' THEN RETURN false; END IF;
  IF (p_body->>'accepted')::boolean IS NOT TRUE OR (p_body->>'idempotentReplay')::boolean IS NOT FALSE THEN RETURN false; END IF;
  IF p_body->>'version' !~ '^[1-9][0-9]{0,8}$' THEN RETURN false; END IF;
  v := (p_body->>'version')::integer;
  PERFORM (p_body->>'settlementId')::uuid;
  PERFORM (p_body->>'eventId')::uuid;
  sid := split_part(p_scope, ':', 2);
  IF lower(p_body->>'settlementId') <> sid THEN RETURN false; END IF;
  IF p_scope LIKE 'create:%' THEN
    RETURN p_status = 201 AND v = 1;
  ELSIF p_scope LIKE 'entry:%' THEN
    RETURN p_status = 202 AND v >= 2;
  END IF;
  RETURN false;
EXCEPTION WHEN others THEN
  RETURN false;
END $f$;

---------------------------------------------------------------------------
-- Trigger functions
---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.settlements_enforce_update() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  -- Omitted memo on an entry keeps the previous non-null memo.
  NEW.last_memo := COALESCE(NEW.last_memo, OLD.last_memo);

  IF OLD.current_status = 'RECONCILED' THEN
    RAISE EXCEPTION 'settlement % is RECONCILED and can no longer be updated', OLD.settlement_id;
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
    RAISE EXCEPTION 'settlement % version must advance from % to %', OLD.settlement_id, OLD.version, OLD.version + 1;
  END IF;
  IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
    RAISE EXCEPTION 'settlement % entry_count must advance by one', OLD.settlement_id;
  END IF;
  IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
    RAISE EXCEPTION 'settlement % update requires a new last_entry_id', OLD.settlement_id;
  END IF;
  IF NEW.updated_at IS NULL OR NEW.updated_at <= OLD.updated_at THEN
    RAISE EXCEPTION 'settlement % updated_at must strictly increase', OLD.settlement_id;
  END IF;
  IF NOT clearledger.status_transition_ok(OLD.current_status, NEW.current_status) THEN
    RAISE EXCEPTION 'settlement % cannot transition from % to %', OLD.settlement_id, OLD.current_status, NEW.current_status;
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.settlements_forbid_delete() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'clearledger.settlements is append-only: DELETE is not permitted';
END $f$;

CREATE OR REPLACE FUNCTION clearledger.events_enforce_insert() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  s clearledger.settlements%ROWTYPE;
  prev clearledger.events%ROWTYPE;
  d jsonb;
  max_v integer;
  prior_memo text;
BEGIN
  IF NOT clearledger.event_row_valid(NEW.event_id, NEW.settlement_id, NEW.aggregate_version, NEW.event_type,
                                     NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at, NEW.payload) THEN
    RAISE EXCEPTION 'event % payload is not a valid ClearLedgerDomainEventEnvelope', NEW.event_id;
  END IF;
  d := NEW.payload->'data';

  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'settlement % event versions must be contiguous: expected %, got %',
      NEW.settlement_id, max_v + 1, NEW.aggregate_version;
  END IF;

  IF d->>'accountId' IS DISTINCT FROM s.account_id OR d->>'reference' IS DISTINCT FROM s.reference
     OR d->>'debitParty' IS DISTINCT FROM s.debit_party OR d->>'creditParty' IS DISTINCT FROM s.credit_party
     OR d->>'status' IS DISTINCT FROM s.current_status OR d->>'clearingStage' IS DISTINCT FROM s.current_stage THEN
    RAISE EXCEPTION 'event % does not match settlement % header, status or stage', NEW.event_id, s.settlement_id;
  END IF;
  IF s.version <> NEW.aggregate_version THEN
    RAISE EXCEPTION 'event % version % does not match settlement version %', NEW.event_id, NEW.aggregate_version, s.version;
  END IF;
  IF NEW.occurred_at <> s.updated_at THEN
    RAISE EXCEPTION 'event % occurred_at must equal settlement updated_at', NEW.event_id;
  END IF;
  IF NEW.aggregate_version = 1 AND NEW.occurred_at <> s.created_at THEN
    RAISE EXCEPTION 'initial event % occurred_at must equal settlement created_at', NEW.event_id;
  END IF;
  IF (d->>'entryId')::uuid IS DISTINCT FROM s.last_entry_id THEN
    RAISE EXCEPTION 'event % entryId does not match settlement last_entry_id', NEW.event_id;
  END IF;
  IF NEW.event_type = 'LedgerEntryRecorded' AND EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.settlement_id = NEW.settlement_id AND e.event_type = 'LedgerEntryRecorded'
          AND e.payload->'data'->>'entryId' = d->>'entryId') THEN
    RAISE EXCEPTION 'entryId % already recorded for settlement %', d->>'entryId', NEW.settlement_id
      USING ERRCODE = 'unique_violation';
  END IF;

  IF d->>'memo' IS NOT NULL THEN
    IF s.last_memo IS DISTINCT FROM d->>'memo' THEN
      RAISE EXCEPTION 'event % memo does not match settlement last_memo', NEW.event_id;
    END IF;
  ELSE
    SELECT e.payload->'data'->>'memo' INTO prior_memo
      FROM clearledger.events e
     WHERE e.settlement_id = NEW.settlement_id AND e.payload->'data'->>'memo' IS NOT NULL
     ORDER BY e.aggregate_version DESC LIMIT 1;
    IF s.last_memo IS DISTINCT FROM prior_memo THEN
      RAISE EXCEPTION 'event % without memo must retain the previous memo on settlement %', NEW.event_id, s.settlement_id;
    END IF;
  END IF;

  IF NEW.aggregate_version >= 2 THEN
    SELECT * INTO prev FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'settlement % is missing event version %', NEW.settlement_id, NEW.aggregate_version - 1;
    END IF;
    IF NEW.occurred_at <= prev.occurred_at THEN
      RAISE EXCEPTION 'event % occurred_at must be after the preceding event', NEW.event_id;
    END IF;
    IF NOT clearledger.status_transition_ok(prev.payload->'data'->>'status', d->>'status') THEN
      RAISE EXCEPTION 'event % status transition % -> % is not permitted',
        NEW.event_id, prev.payload->'data'->>'status', d->>'status';
    END IF;
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.events_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'clearledger.events is append-only: % is not permitted', TG_OP;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.outbox_enforce_insert() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  e clearledger.events%ROWTYPE;
  max_v integer;
BEGIN
  IF NOT clearledger.outbox_row_valid(NEW.event_id, NEW.settlement_id, NEW.aggregate_version, NEW.correlation_id, NEW.payload) THEN
    RAISE EXCEPTION 'outbox payload for event % is not a valid ClearLedgerDomainEventEnvelope', NEW.event_id;
  END IF;
  SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF e.settlement_id <> NEW.settlement_id OR e.aggregate_version <> NEW.aggregate_version
     OR e.correlation_id <> NEW.correlation_id OR e.payload <> NEW.payload THEN
    RAISE EXCEPTION 'outbox row for event % must mirror the events row', NEW.event_id;
  END IF;
  SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> max_v + 1 THEN
    RAISE EXCEPTION 'settlement % outbox versions must be contiguous: expected %, got %',
      NEW.settlement_id, max_v + 1, NEW.aggregate_version;
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.outbox_enforce_update() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  IF NEW.seq IS DISTINCT FROM OLD.seq OR NEW.event_id IS DISTINCT FROM OLD.event_id
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

  IF OLD.published_at IS NULL THEN
    IF NEW.archived_at IS NOT NULL THEN
      RAISE EXCEPTION 'an unpublished outbox row cannot be archived';
    END IF;
    IF NEW.published_at IS NOT NULL AND NEW.attempts <= OLD.attempts THEN
      RAISE EXCEPTION 'publishing an outbox row requires incrementing attempts';
    END IF;
  ELSIF NEW.published_at IS NULL THEN
    -- operational replay: published_at and archived_at are reset together
    IF NEW.archived_at IS NOT NULL OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'resetting an outbox row for replay must clear published_at and archived_at only';
    END IF;
  ELSE
    IF NEW.published_at IS DISTINCT FROM OLD.published_at OR NEW.attempts IS DISTINCT FROM OLD.attempts
       OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
      RAISE EXCEPTION 'published_at, attempts and last_error of a published outbox row are immutable';
    END IF;
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
       AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
      RAISE EXCEPTION 'archived_at must be reset to NULL before it can change';
    END IF;
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.outbox_forbid_delete() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted';
END $f$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_enforce_insert() RETURNS trigger
LANGUAGE plpgsql AS $f$
DECLARE
  b jsonb;
BEGIN
  IF NOT clearledger.idempotency_response_valid(NEW.scope, NEW.status_code, NEW.response_body) THEN
    RAISE EXCEPTION 'idempotency response for scope % is not a valid WriteAcceptedResponse', NEW.scope;
  END IF;
  b := NEW.response_body;
  IF NOT EXISTS (
       SELECT 1 FROM clearledger.events e
        WHERE e.event_id = (b->>'eventId')::uuid AND e.settlement_id = (b->>'settlementId')::uuid
          AND e.aggregate_version = (b->>'version')::integer AND e.idempotency_key = NEW.idempotency_key
          AND e.event_type = CASE WHEN NEW.scope LIKE 'create:%' THEN 'SettlementInitiated' ELSE 'LedgerEntryRecorded' END) THEN
    RAISE EXCEPTION 'idempotency key % does not reference a committed event', NEW.idempotency_key
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.outbox o WHERE o.event_id = (b->>'eventId')::uuid) THEN
    RAISE EXCEPTION 'idempotency key % does not reference an outbox row', NEW.idempotency_key
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END $f$;

CREATE OR REPLACE FUNCTION clearledger.idempotency_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $f$
BEGIN
  RAISE EXCEPTION 'clearledger.idempotency_keys is immutable: % is not permitted', TG_OP;
END $f$;

---------------------------------------------------------------------------
-- CHECK constraints
---------------------------------------------------------------------------
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_account_id_chk',
  $c$account_id = btrim(account_id) AND char_length(account_id) BETWEEN 3 AND 64$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_reference_chk',
  $c$reference = btrim(reference) AND char_length(reference) BETWEEN 3 AND 64$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_debit_party_chk',
  $c$debit_party = btrim(debit_party) AND char_length(debit_party) BETWEEN 2 AND 64$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_credit_party_chk',
  $c$credit_party = btrim(credit_party) AND char_length(credit_party) BETWEEN 2 AND 64$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_parties_distinct_chk',
  $c$debit_party <> credit_party$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_status_chk',
  $c$current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_stage_chk',
  $c$current_stage = btrim(current_stage) AND char_length(current_stage) BETWEEN 2 AND 74$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_last_memo_chk',
  $c$last_memo = btrim(last_memo) AND char_length(last_memo) BETWEEN 1 AND 256$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_version_chk',
  $c$version >= 1 AND entry_count >= 0$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_initial_state_chk',
  $c$version <> 1 OR (entry_count = 0 AND current_status = 'INITIATED' AND current_stage = 'INITIATED@' || debit_party AND last_entry_id IS NULL AND last_memo = 'Settlement initiated' AND updated_at = created_at)$c$);
SELECT pg_temp.ensure_check('clearledger.settlements', 'settlements_advanced_state_chk',
  $c$version <= 1 OR (entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL AND last_memo IS NOT NULL AND updated_at > created_at AND char_length(current_stage) <= 64)$c$);

SELECT pg_temp.ensure_check('clearledger.events', 'events_aggregate_version_chk',
  $c$aggregate_version >= 1$c$);
SELECT pg_temp.ensure_check('clearledger.events', 'events_event_type_chk',
  $c$event_type IN ('SettlementInitiated','LedgerEntryRecorded')$c$);
SELECT pg_temp.ensure_check('clearledger.events', 'events_correlation_id_chk',
  $c$correlation_id = btrim(correlation_id) AND char_length(correlation_id) BETWEEN 4 AND 128$c$);
SELECT pg_temp.ensure_check('clearledger.events', 'events_idempotency_key_chk',
  $c$idempotency_key = btrim(idempotency_key) AND char_length(idempotency_key) BETWEEN 8 AND 128$c$);
SELECT pg_temp.ensure_check('clearledger.events', 'events_payload_chk',
  $c$clearledger.event_row_valid(event_id, settlement_id, aggregate_version, event_type, correlation_id, idempotency_key, occurred_at, payload)$c$);

SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_aggregate_version_chk',
  $c$aggregate_version >= 1$c$);
SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_correlation_id_chk',
  $c$correlation_id = btrim(correlation_id) AND char_length(correlation_id) BETWEEN 4 AND 128$c$);
SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_payload_chk',
  $c$clearledger.outbox_row_valid(event_id, settlement_id, aggregate_version, correlation_id, payload)$c$);
SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_attempts_chk',
  $c$attempts >= 0$c$);
SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_initial_delivery_chk',
  $c$attempts <> 0 OR (published_at IS NULL AND last_error IS NULL)$c$);
SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_published_chk',
  $c$published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)$c$);
SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_last_error_chk',
  $c$last_error IS NULL OR (published_at IS NULL AND attempts >= 1 AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error))$c$);
SELECT pg_temp.ensure_check('clearledger.outbox', 'outbox_archived_chk',
  $c$archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)$c$);

SELECT pg_temp.ensure_check('clearledger.idempotency_keys', 'idempotency_scope_chk',
  $c$scope ~ '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'$c$);
SELECT pg_temp.ensure_check('clearledger.idempotency_keys', 'idempotency_key_chk',
  $c$idempotency_key = btrim(idempotency_key) AND char_length(idempotency_key) BETWEEN 8 AND 128$c$);
SELECT pg_temp.ensure_check('clearledger.idempotency_keys', 'idempotency_request_hash_chk',
  $c$request_hash ~ '^[0-9a-f]{64}$'$c$);
SELECT pg_temp.ensure_check('clearledger.idempotency_keys', 'idempotency_response_chk',
  $c$clearledger.idempotency_response_valid(scope, status_code, response_body)$c$);

---------------------------------------------------------------------------
-- Indexes
---------------------------------------------------------------------------
SELECT pg_temp.ensure_index('clearledger.outbox', 'idx_clearledger_outbox_unpublished',
  $c$(seq) WHERE published_at IS NULL$c$, false);
SELECT pg_temp.ensure_index('clearledger.outbox', 'idx_clearledger_outbox_unarchived',
  $c$(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL$c$, false);
SELECT pg_temp.ensure_index('clearledger.events', 'idx_clearledger_events_settlement_version',
  $c$(settlement_id, aggregate_version)$c$, false);
SELECT pg_temp.ensure_index('clearledger.idempotency_keys', 'idx_clearledger_idempotency_event',
  $c$(((response_body->>'eventId')::uuid))$c$, true);
SELECT pg_temp.ensure_index('clearledger.idempotency_keys', 'idx_clearledger_idempotency_version',
  $c$(((response_body->>'settlementId')::uuid), ((response_body->>'version')::integer))$c$, true);
SELECT pg_temp.ensure_index('clearledger.events', 'idx_clearledger_entry_id',
  $c$(settlement_id, ((payload->'data'->>'entryId')::uuid)) WHERE event_type = 'LedgerEntryRecorded'$c$, true);

---------------------------------------------------------------------------
-- Triggers (tgtype: ROW=1 BEFORE=2 INSERT=4 DELETE=8 UPDATE=16)
---------------------------------------------------------------------------
SELECT pg_temp.ensure_trigger('clearledger.settlements', 'trg_settlements_enforce_update', 1+2+16, 'clearledger.settlements_enforce_update');
SELECT pg_temp.ensure_trigger('clearledger.settlements', 'trg_settlements_forbid_delete', 1+2+8, 'clearledger.settlements_forbid_delete');
SELECT pg_temp.ensure_trigger('clearledger.events', 'trg_events_enforce_insert', 1+2+4, 'clearledger.events_enforce_insert');
SELECT pg_temp.ensure_trigger('clearledger.events', 'trg_events_forbid_mutation', 1+2+16+8, 'clearledger.events_forbid_mutation');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_enforce_insert', 1+2+4, 'clearledger.outbox_enforce_insert');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_enforce_update', 1+2+16, 'clearledger.outbox_enforce_update');
SELECT pg_temp.ensure_trigger('clearledger.outbox', 'trg_outbox_forbid_delete', 1+2+8, 'clearledger.outbox_forbid_delete');
SELECT pg_temp.ensure_trigger('clearledger.idempotency_keys', 'trg_idempotency_enforce_insert', 1+2+4, 'clearledger.idempotency_enforce_insert');
SELECT pg_temp.ensure_trigger('clearledger.idempotency_keys', 'trg_idempotency_forbid_mutation', 1+2+16+8, 'clearledger.idempotency_forbid_mutation');

-- Re-enable any user trigger that was disabled out-of-band.
DO $do$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT c.relname FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relnamespace = 'clearledger'::regnamespace AND NOT t.tgisinternal AND t.tgenabled <> 'O'
  LOOP
    EXECUTE format('ALTER TABLE clearledger.%I ENABLE TRIGGER USER', r.relname);
  END LOOP;
END $do$;

SELECT pg_advisory_unlock(7203041985);
