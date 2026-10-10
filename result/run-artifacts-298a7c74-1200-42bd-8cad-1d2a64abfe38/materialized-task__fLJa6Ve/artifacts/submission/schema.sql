\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(743192001);
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id uuid NOT NULL, account_id text NOT NULL, reference text NOT NULL,
  debit_party text NOT NULL, credit_party text NOT NULL, current_status text NOT NULL,
  current_stage text NOT NULL, last_entry_id uuid, last_memo text NOT NULL,
  version integer NOT NULL, entry_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS clearledger.events (
  seq bigserial NOT NULL, event_id uuid NOT NULL, settlement_id uuid NOT NULL,
  aggregate_version integer NOT NULL, event_type text NOT NULL, correlation_id text NOT NULL,
  idempotency_key text NOT NULL, occurred_at timestamptz NOT NULL, payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq bigserial NOT NULL, event_id uuid NOT NULL, settlement_id uuid NOT NULL,
  aggregate_version integer NOT NULL, correlation_id text NOT NULL, payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz, archived_at timestamptz,
  attempts integer NOT NULL DEFAULT 0, last_error text
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope text NOT NULL, idempotency_key text NOT NULL, request_hash text NOT NULL,
  status_code integer NOT NULL, response_body jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN ACCESS EXCLUSIVE MODE;
DO $$ DECLARE t text; c text; BEGIN
  FOREACH t IN ARRAY ARRAY['settlements','events','outbox','idempotency_keys'] LOOP
    FOR c IN SELECT column_name FROM information_schema.columns WHERE table_schema='clearledger' AND table_name=t
      AND NOT ((t='settlements' AND column_name='last_entry_id') OR (t='outbox' AND column_name IN ('published_at','archived_at','last_error'))) LOOP
      EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET NOT NULL',t,c);
    END LOOP;
  END LOOP;
END $$;
ALTER TABLE clearledger.settlements ALTER COLUMN entry_count SET DEFAULT 0, ALTER COLUMN created_at SET DEFAULT now(), ALTER COLUMN updated_at SET DEFAULT now();
ALTER TABLE clearledger.events ALTER COLUMN created_at SET DEFAULT now();
ALTER TABLE clearledger.outbox ALTER COLUMN created_at SET DEFAULT now(), ALTER COLUMN attempts SET DEFAULT 0;
ALTER TABLE clearledger.idempotency_keys ALTER COLUMN created_at SET DEFAULT now();

CREATE OR REPLACE FUNCTION clearledger.canonical(s text, lo integer, hi integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT s IS NOT NULL AND s = btrim(s) AND length(s) BETWEEN lo AND hi $$;
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$ SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2 WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 ELSE -1 END $$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_status text, new_status text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT old_status <> 'RECONCILED' AND CASE WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED','RECONCILED') ELSE new_status = 'DISPUTED' OR (clearledger.status_rank(new_status) >= clearledger.status_rank(old_status) AND clearledger.status_rank(new_status) >= 0) END $$;

CREATE OR REPLACE FUNCTION clearledger.valid_envelope(p jsonb) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; v integer; k text; x uuid; ts timestamptz;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(p) a WHERE a <> ALL(ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'])) THEN RETURN false; END IF;
  FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
    IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
  END LOOP;
  IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement'
    OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$'
    OR NOT clearledger.canonical(p->>'correlationId',4,128) OR NOT clearledger.canonical(p->>'idempotencyKey',8,128) THEN RETURN false; END IF;
  x := (p->>'eventId')::uuid; x := (p->>'aggregateId')::uuid; ts := (p->>'occurredAt')::timestamptz;
  IF NOT isfinite(ts) OR p->>'occurredAt' !~ '^\d{4}-\d{2}-\d{2}T.*(Z|[+-]\d{2}:\d{2})$' THEN RETURN false; END IF;
  v := (p->>'aggregateVersion')::integer; d := p->'data';
  IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']
    OR EXISTS (SELECT 1 FROM jsonb_object_keys(d) a WHERE a <> ALL(ARRAY['kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo'])) THEN RETURN false; END IF;
  FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
    IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
  END LOOP;
  IF NOT clearledger.canonical(d->>'accountId',3,64) OR NOT clearledger.canonical(d->>'reference',3,64)
    OR NOT clearledger.canonical(d->>'debitParty',2,64) OR NOT clearledger.canonical(d->>'creditParty',2,64)
    OR d->>'debitParty' = d->>'creditParty' OR NOT clearledger.canonical(d->>'clearingStage',2,64)
    OR (d->>'status') NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
  IF d->>'memo' IS NOT NULL AND (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.canonical(d->>'memo',1,256)) THEN RETURN false; END IF;
  IF d->>'entryId' IS NOT NULL THEN
    IF jsonb_typeof(d->'entryId') <> 'string' THEN RETURN false; END IF;
    x := (d->>'entryId')::uuid;
  END IF;
  RETURN COALESCE(CASE WHEN v = 1 THEN p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated'
    AND d->>'status' = 'INITIATED' AND d->>'clearingStage' = 'INITIATED@' || (d->>'debitParty')
    AND d->>'entryId' IS NULL AND d->>'memo' = 'Settlement initiated'
    ELSE p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded'
    AND d->>'status' <> 'INITIATED' AND d->>'entryId' IS NOT NULL END,false);
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

-- Remove weakened or noncanonical constraints, including their dependent indexes,
-- and replace them transactionally under the same table locks.
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint WHERE connamespace = 'clearledger'::regnamespace AND contype = 'f' LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',r.t,r.conname);
  END LOOP;
  FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint WHERE connamespace = 'clearledger'::regnamespace AND conrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass) LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I CASCADE',r.t,r.conname);
  END LOOP;
END $$;
ALTER TABLE clearledger.settlements ADD CONSTRAINT settlements_pkey PRIMARY KEY(settlement_id),
 ADD CONSTRAINT settlements_header_check CHECK (
  clearledger.canonical(account_id,3,64) AND clearledger.canonical(reference,3,64)
  AND clearledger.canonical(debit_party,2,64) AND clearledger.canonical(credit_party,2,64)
  AND debit_party <> credit_party AND clearledger.canonical(current_stage,2,64)
  AND clearledger.canonical(last_memo,1,256) AND version >= 1
  AND current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')),
 ADD CONSTRAINT settlements_lifecycle_check CHECK (
  (version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND current_stage = 'INITIATED@' || debit_party AND last_entry_id IS NULL AND last_memo = 'Settlement initiated' AND updated_at = created_at)
  OR (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL AND last_memo IS NOT NULL AND updated_at > created_at));
ALTER TABLE clearledger.events ADD CONSTRAINT events_pkey PRIMARY KEY(seq),
 ADD CONSTRAINT events_event_id_key UNIQUE(event_id),
 ADD CONSTRAINT events_settlement_version_key UNIQUE(settlement_id,aggregate_version),
 ADD CONSTRAINT events_settlement_idempotency_key UNIQUE(settlement_id,idempotency_key),
 ADD CONSTRAINT events_settlement_fkey FOREIGN KEY(settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 ADD CONSTRAINT events_envelope_check CHECK (clearledger.valid_envelope(payload)
  AND clearledger.canonical(correlation_id,4,128) AND clearledger.canonical(idempotency_key,8,128)
  AND event_id = (payload->>'eventId')::uuid AND settlement_id = (payload->>'aggregateId')::uuid
  AND aggregate_version = (payload->>'aggregateVersion')::integer AND event_type = payload->>'eventType'
  AND correlation_id = payload->>'correlationId' AND idempotency_key = payload->>'idempotencyKey'
  AND occurred_at = (payload->>'occurredAt')::timestamptz);
ALTER TABLE clearledger.outbox ADD CONSTRAINT outbox_pkey PRIMARY KEY(seq),
 ADD CONSTRAINT outbox_event_id_key UNIQUE(event_id),
 ADD CONSTRAINT outbox_settlement_version_key UNIQUE(settlement_id,aggregate_version),
 ADD CONSTRAINT outbox_event_id_fkey FOREIGN KEY(event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
 ADD CONSTRAINT outbox_settlement_fkey FOREIGN KEY(settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 ADD CONSTRAINT outbox_settlement_version_fkey FOREIGN KEY(settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE,
 ADD CONSTRAINT outbox_envelope_check CHECK (clearledger.valid_envelope(payload) AND clearledger.canonical(correlation_id,4,128)),
 ADD CONSTRAINT outbox_lifecycle_check CHECK (attempts >= 0
  AND (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))
  AND (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))
  AND (last_error IS NULL OR (published_at IS NULL AND attempts >= 1 AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))
  AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)));
ALTER TABLE clearledger.idempotency_keys ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY(scope,idempotency_key),
 ADD CONSTRAINT idempotency_response_check CHECK (
  scope ~ '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND clearledger.canonical(idempotency_key,8,128) AND request_hash ~ '^[0-9a-f]{64}$'
  AND jsonb_typeof(response_body) = 'object'
  AND response_body ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
  AND (response_body - ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) = '{}'::jsonb
  AND jsonb_typeof(response_body->'settlementId') = 'string' AND jsonb_typeof(response_body->'eventId') = 'string'
  AND jsonb_typeof(response_body->'version') = 'number' AND response_body->>'version' ~ '^[1-9][0-9]*$'
  AND response_body->'accepted' = 'true'::jsonb AND response_body->'idempotentReplay' = 'false'::jsonb
  AND split_part(scope,':',2)::uuid = (response_body->>'settlementId')::uuid
  AND ((scope LIKE 'create:%' AND status_code = 201 AND (response_body->>'version')::integer = 1)
    OR (scope LIKE 'entry:%' AND status_code = 202 AND (response_body->>'version')::integer >= 2)));

CREATE OR REPLACE FUNCTION clearledger.settlement_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'settlements cannot be deleted' USING ERRCODE = '23514'; END IF;
  NEW.last_memo := COALESCE(NEW.last_memo,OLD.last_memo);
  IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
      IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
    OR NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1
    OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id OR NEW.updated_at <= OLD.updated_at
    OR NOT clearledger.transition_ok(OLD.current_status,NEW.current_status) THEN
    RAISE EXCEPTION 'invalid settlement transition' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements; prev clearledger.events; d jsonb; memo text; n integer;
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append only' USING ERRCODE = '23514'; END IF;
  IF NOT clearledger.valid_envelope(NEW.payload) THEN RAISE EXCEPTION 'invalid event envelope' USING ERRCODE = '23514'; END IF;
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'missing settlement' USING ERRCODE = '23503'; END IF;
  SELECT COALESCE(max(aggregate_version),0) INTO n FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> n + 1 THEN RAISE EXCEPTION 'noncontiguous event version' USING ERRCODE = '23514'; END IF;
  d := NEW.payload->'data';
  SELECT payload->'data'->>'memo' INTO memo FROM clearledger.events WHERE settlement_id = NEW.settlement_id AND payload->'data'->>'memo' IS NOT NULL ORDER BY aggregate_version DESC LIMIT 1;
  memo := COALESCE(d->>'memo',memo);
  IF ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.version,s.last_entry_id,s.last_memo,s.updated_at)
     IS DISTINCT FROM ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',NEW.aggregate_version,(d->>'entryId')::uuid,memo,NEW.occurred_at)
     OR (NEW.aggregate_version = 1 AND NEW.occurred_at <> s.created_at) THEN
    RAISE EXCEPTION 'event does not match aggregate' USING ERRCODE = '23514';
  END IF;
  IF NEW.aggregate_version > 1 THEN
    SELECT * INTO prev FROM clearledger.events WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
    IF NEW.occurred_at <= prev.occurred_at OR NOT clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status') THEN
      RAISE EXCEPTION 'invalid event transition' USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events; n integer;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'outbox cannot be deleted' USING ERRCODE = '23514'; END IF;
  IF TG_OP = 'INSERT' THEN
    PERFORM 1 FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
    SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
    IF NOT FOUND OR ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload)
      IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload) THEN
      RAISE EXCEPTION 'outbox does not mirror event' USING ERRCODE = '23514'; END IF;
    SELECT COALESCE(max(aggregate_version),0) INTO n FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version <> n + 1 THEN RAISE EXCEPTION 'noncontiguous outbox version' USING ERRCODE = '23514'; END IF;
  ELSE
    IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at)
      IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
      OR NEW.attempts < OLD.attempts
      OR (OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL))
      OR (OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error))
      OR (OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at) THEN
      RAISE EXCEPTION 'invalid outbox lifecycle' USING ERRCODE = '23514'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'idempotency responses are immutable' USING ERRCODE = '23514'; END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o USING(event_id)
    WHERE e.event_id = (NEW.response_body->>'eventId')::uuid AND e.settlement_id = (NEW.response_body->>'settlementId')::uuid
      AND e.aggregate_version = (NEW.response_body->>'version')::integer AND e.idempotency_key = NEW.idempotency_key) THEN
    RAISE EXCEPTION 'idempotency response requires committed event and outbox' USING ERRCODE = '23514'; END IF;
  RETURN NEW;
END $$;
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT tgrelid::regclass AS t,tgname FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass) LOOP
    EXECUTE format('DROP TRIGGER %I ON %s',r.tgname,r.t);
  END LOOP;
END $$;
CREATE TRIGGER settlements_guard BEFORE UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
CREATE TRIGGER events_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
CREATE TRIGGER outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
CREATE TRIGGER idempotency_keys_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
ALTER TABLE clearledger.settlements ENABLE TRIGGER USER;
ALTER TABLE clearledger.events ENABLE TRIGGER USER;
ALTER TABLE clearledger.outbox ENABLE TRIGGER USER;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER USER;
DROP INDEX IF EXISTS clearledger.idx_clearledger_outbox_unpublished;
DROP INDEX IF EXISTS clearledger.idx_clearledger_outbox_unarchived;
DROP INDEX IF EXISTS clearledger.idx_clearledger_events_settlement_version;
DROP INDEX IF EXISTS clearledger.idx_clearledger_idempotency_event;
DROP INDEX IF EXISTS clearledger.idx_clearledger_idempotency_version;
DROP INDEX IF EXISTS clearledger.idx_clearledger_entry_id;
CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
CREATE UNIQUE INDEX idx_clearledger_idempotency_event ON clearledger.idempotency_keys(((response_body->>'eventId')::uuid));
CREATE UNIQUE INDEX idx_clearledger_idempotency_version ON clearledger.idempotency_keys(((response_body->>'settlementId')::uuid),((response_body->>'version')::integer));
CREATE UNIQUE INDEX idx_clearledger_entry_id ON clearledger.events(settlement_id,((payload->'data'->>'entryId')::uuid)) WHERE event_type = 'LedgerEntryRecorded';
COMMIT;
