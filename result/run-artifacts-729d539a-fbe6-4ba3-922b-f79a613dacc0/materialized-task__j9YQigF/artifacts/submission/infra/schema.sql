BEGIN;
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE OR REPLACE FUNCTION clearledger.trim(v text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT regexp_replace(v, '^\s+|\s+$', '', 'g') $$;
CREATE OR REPLACE FUNCTION clearledger.bounded(v text, lo int, hi int) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT v IS NOT NULL AND length(clearledger.trim(v)) BETWEEN lo AND hi $$;
CREATE OR REPLACE FUNCTION clearledger.rank(v text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
SELECT CASE v WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2 WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 ELSE -1 END $$;
CREATE OR REPLACE FUNCTION clearledger.transition(a text, b text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
SELECT a <> 'RECONCILED' AND CASE WHEN a = 'DISPUTED' THEN b IN ('DISPUTED','RECONCILED') ELSE b = 'DISPUTED' OR (clearledger.rank(b) >= clearledger.rank(a) AND clearledger.rank(a) >= 0) END $$;
CREATE OR REPLACE FUNCTION clearledger.envelope(p jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; k text; n int;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'] OR p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
  IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement' OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$' THEN RETURN false; END IF;
 n := (p->>'aggregateVersion')::int;
 PERFORM (p->>'eventId')::uuid, (p->>'aggregateId')::uuid, (p->>'occurredAt')::timestamptz;
 IF (p->>'occurredAt') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' OR NOT clearledger.bounded(p->>'correlationId',4,128) OR NOT clearledger.bounded(p->>'idempotencyKey',8,128) THEN RETURN false; END IF;
 d := p->'data';
 IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] OR d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
  IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.bounded(d->>'accountId',3,64) OR NOT clearledger.bounded(d->>'reference',3,64) OR NOT clearledger.bounded(d->>'debitParty',2,64) OR NOT clearledger.bounded(d->>'creditParty',2,64) OR clearledger.trim(d->>'debitParty') = clearledger.trim(d->>'creditParty') OR NOT clearledger.bounded(d->>'clearingStage',2,64) OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
 IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
  IF jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.bounded(d->>'memo',1,256) THEN RETURN false; END IF;
 END IF;
 IF n = 1 THEN
  RETURN p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated' AND d->>'status' = 'INITIATED' AND d->>'entryId' IS NULL;
 END IF;
 IF jsonb_typeof(d->'entryId') IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 PERFORM (d->>'entryId')::uuid;
 RETURN p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded' AND d->>'status' <> 'INITIATED';
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;
CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id uuid PRIMARY KEY, account_id text NOT NULL, reference text NOT NULL,
 debit_party text NOT NULL, credit_party text NOT NULL, current_status text NOT NULL,
 current_stage text NOT NULL, last_entry_id uuid, last_memo text, version integer NOT NULL,
 entry_count integer NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT settlement_headers CHECK (clearledger.bounded(account_id,3,64) AND clearledger.bounded(reference,3,64) AND clearledger.bounded(debit_party,2,64) AND clearledger.bounded(credit_party,2,64) AND clearledger.trim(debit_party) <> clearledger.trim(credit_party)),
 CONSTRAINT settlement_values CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') AND clearledger.bounded(current_stage,2,64) AND (last_memo IS NULL OR clearledger.bounded(last_memo,1,256)) AND version >= 1 AND updated_at >= created_at),
 CONSTRAINT settlement_version CHECK ((version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND last_entry_id IS NULL AND updated_at = created_at) OR (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS clearledger.events (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL UNIQUE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version integer NOT NULL, event_type text NOT NULL, correlation_id text NOT NULL,
 idempotency_key text NOT NULL, occurred_at timestamptz NOT NULL, payload jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (settlement_id,aggregate_version), UNIQUE (settlement_id,idempotency_key),
 CHECK (clearledger.bounded(correlation_id,4,128) AND clearledger.bounded(idempotency_key,8,128)),
 CHECK (clearledger.envelope(payload))
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version integer NOT NULL, correlation_id text NOT NULL, payload jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz, archived_at timestamptz,
 attempts integer NOT NULL DEFAULT 0, last_error text,
 UNIQUE (settlement_id,aggregate_version),
 FOREIGN KEY (settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE,
 CHECK (clearledger.envelope(payload)),
 CHECK (attempts >= 0 AND (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)) AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)))
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
 scope text NOT NULL, idempotency_key text NOT NULL, request_hash text NOT NULL,
 status_code integer NOT NULL, response_body jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (scope,idempotency_key),
 CHECK (scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'),
 CHECK (clearledger.bounded(idempotency_key,8,128) AND request_hash ~ '^[0-9a-f]{64}$')
);
CREATE OR REPLACE FUNCTION clearledger.settlement_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP = 'UPDATE' THEN
  IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at) IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at) OR NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1 OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id OR NEW.updated_at < OLD.updated_at OR NOT clearledger.transition(OLD.current_status,NEW.current_status) THEN
   RAISE EXCEPTION 'invalid settlement transition' USING ERRCODE = '23514';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements%ROWTYPE; prev clearledger.events%ROWTYPE; d jsonb; expected int;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append-only'; END IF;
 IF NOT clearledger.envelope(NEW.payload) THEN RAISE EXCEPTION 'invalid envelope' USING ERRCODE = '23514'; END IF;
 d := NEW.payload->'data';
 SELECT * INTO STRICT s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
 SELECT coalesce(max(aggregate_version),0)+1 INTO expected FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
 IF NEW.aggregate_version <> expected OR ROW(NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.event_type,NEW.correlation_id,NEW.idempotency_key,NEW.occurred_at) IS DISTINCT FROM ROW((NEW.payload->>'eventId')::uuid,(NEW.payload->>'aggregateId')::uuid,(NEW.payload->>'aggregateVersion')::int,NEW.payload->>'eventType',NEW.payload->>'correlationId',NEW.payload->>'idempotencyKey',(NEW.payload->>'occurredAt')::timestamptz) THEN RAISE EXCEPTION 'event envelope mismatch or noncontiguous version' USING ERRCODE = '23514'; END IF;
 IF ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_entry_id,s.last_memo,s.version,s.updated_at) IS DISTINCT FROM ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',(d->>'entryId')::uuid,d->>'memo',NEW.aggregate_version,NEW.occurred_at) OR (NEW.aggregate_version = 1 AND NEW.occurred_at <> s.created_at) THEN RAISE EXCEPTION 'event does not match settlement' USING ERRCODE = '23514'; END IF;
 IF NEW.aggregate_version >= 2 THEN
  SELECT * INTO STRICT prev FROM clearledger.events WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
  IF NEW.occurred_at < prev.occurred_at OR NOT clearledger.transition(prev.payload->'data'->>'status',d->>'status') OR EXISTS (SELECT 1 FROM clearledger.events WHERE settlement_id = NEW.settlement_id AND payload->'data'->>'entryId' = d->>'entryId') THEN RAISE EXCEPTION 'invalid event transition or duplicate entry' USING ERRCODE = '23514'; END IF;
 END IF;
 RETURN NEW;
EXCEPTION WHEN NO_DATA_FOUND THEN
 RAISE EXCEPTION 'event references missing settlement or prior event' USING ERRCODE = '23503';
END $$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events%ROWTYPE; expected int;
BEGIN
 IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'outbox cannot be deleted'; END IF;
 IF TG_OP = 'INSERT' THEN
  PERFORM 1 FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
  SELECT * INTO STRICT e FROM clearledger.events WHERE event_id = NEW.event_id;
  SELECT coalesce(max(aggregate_version),0)+1 INTO expected FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
  IF NEW.aggregate_version <> expected OR ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload) IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload) THEN RAISE EXCEPTION 'outbox does not mirror event' USING ERRCODE = '23514'; END IF;
 ELSE
  IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at) IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at) OR NEW.attempts < OLD.attempts THEN RAISE EXCEPTION 'immutable outbox envelope' USING ERRCODE = '23514'; END IF;
  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL) THEN RAISE EXCEPTION 'invalid publication' USING ERRCODE = '23514'; END IF;
  IF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error) THEN RAISE EXCEPTION 'immutable delivery metadata' USING ERRCODE = '23514'; END IF;
  IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at THEN RAISE EXCEPTION 'immutable archival timestamp' USING ERRCODE = '23514'; END IF;
 END IF;
 RETURN NEW;
EXCEPTION WHEN NO_DATA_FOUND THEN
 RAISE EXCEPTION 'outbox references missing event' USING ERRCODE = '23503';
END $$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p jsonb; v int; sid uuid; eid uuid;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'idempotency records are append-only'; END IF;
 p := NEW.response_body;
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay'] OR p - ARRAY['settlementId','eventId','version','accepted','idempotentReplay'] <> '{}'::jsonb OR p->'accepted' IS DISTINCT FROM 'true'::jsonb OR p->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb OR jsonb_typeof(p->'settlementId') IS DISTINCT FROM 'string' OR jsonb_typeof(p->'eventId') IS DISTINCT FROM 'string' OR jsonb_typeof(p->'version') IS DISTINCT FROM 'number' OR p->>'version' !~ '^[1-9][0-9]*$' THEN RAISE EXCEPTION 'invalid accepted response' USING ERRCODE = '23514'; END IF;
 BEGIN
  v := (p->>'version')::int; sid := (p->>'settlementId')::uuid; eid := (p->>'eventId')::uuid;
 EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'invalid response identifiers' USING ERRCODE = '23514'; END;
 IF NOT ((NEW.scope = 'create:' || sid::text AND v = 1 AND NEW.status_code = 201) OR (NEW.scope = 'entry:' || sid::text AND v >= 2 AND NEW.status_code = 202)) OR NOT EXISTS (SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o ON o.event_id = e.event_id WHERE e.event_id = eid AND e.settlement_id = sid AND e.aggregate_version = v AND e.idempotency_key = NEW.idempotency_key) THEN RAISE EXCEPTION 'idempotency response does not reference committed event' USING ERRCODE = '23514'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS settlement_guard ON clearledger.settlements;
CREATE TRIGGER settlement_guard BEFORE INSERT OR UPDATE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
DROP TRIGGER IF EXISTS event_guard ON clearledger.events;
CREATE TRIGGER event_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
DROP TRIGGER IF EXISTS outbox_guard ON clearledger.outbox;
CREATE TRIGGER outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
DROP TRIGGER IF EXISTS idempotency_guard ON clearledger.idempotency_keys;
CREATE TRIGGER idempotency_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
COMMIT;
