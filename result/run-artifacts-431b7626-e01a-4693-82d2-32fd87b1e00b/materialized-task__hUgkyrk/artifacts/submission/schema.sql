BEGIN;
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE OR REPLACE FUNCTION clearledger.trimmed(s text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT regexp_replace(s, '^\s+|\s+$', '', 'g') $$;
CREATE OR REPLACE FUNCTION clearledger.bounded(s text, lo int, hi int) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT s IS NOT NULL AND length(clearledger.trimmed(s)) BETWEEN lo AND hi $$;
CREATE OR REPLACE FUNCTION clearledger.uuid_ok(s text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT s IS NOT NULL AND s ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' $$;
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2 WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 ELSE -1 END $$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_s text, new_s text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT old_s <> 'RECONCILED' AND CASE WHEN old_s = 'DISPUTED' THEN new_s IN ('DISPUTED','RECONCILED')
 ELSE new_s = 'DISPUTED' OR clearledger.status_rank(new_s) >= clearledger.status_rank(old_s) END $$;
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; k text; v int;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']
 OR (p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
   IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement'
 OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$'
 OR NOT clearledger.bounded(p->>'correlationId',4,128) OR NOT clearledger.bounded(p->>'idempotencyKey',8,128) THEN RETURN false; END IF;
 IF NOT clearledger.uuid_ok(p->>'eventId') OR NOT clearledger.uuid_ok(p->>'aggregateId') THEN RETURN false; END IF;
 PERFORM (p->>'eventId')::uuid, (p->>'aggregateId')::uuid, (p->>'occurredAt')::timestamptz;
 IF p->>'occurredAt' !~ '^\d{4}-\d{2}-\d{2}T' THEN RETURN false; END IF;
 d := p->'data'; v := (p->>'aggregateVersion')::int;
 IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']
 OR (d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
   IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.bounded(d->>'accountId',3,64) OR NOT clearledger.bounded(d->>'reference',3,64)
 OR NOT clearledger.bounded(d->>'debitParty',2,64) OR NOT clearledger.bounded(d->>'creditParty',2,64)
 OR clearledger.trimmed(d->>'debitParty') = clearledger.trimmed(d->>'creditParty') OR NOT clearledger.bounded(d->>'clearingStage',2,64)
 OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
 IF d ? 'memo' AND d->'memo' <> 'null'::jsonb THEN
   IF jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.bounded(d->>'memo',1,256) THEN RETURN false; END IF;
 END IF;
 IF d ? 'entryId' AND d->'entryId' <> 'null'::jsonb THEN
   IF jsonb_typeof(d->'entryId') <> 'string' OR NOT clearledger.uuid_ok(d->>'entryId') THEN RETURN false; END IF;
   PERFORM (d->>'entryId')::uuid;
 END IF;
 IF v = 1 THEN
   RETURN p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated' AND d->>'status' = 'INITIATED' AND d->>'entryId' IS NULL;
 END IF;
 RETURN p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded' AND d->>'status' <> 'INITIATED' AND d->>'entryId' IS NOT NULL;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id uuid PRIMARY KEY, account_id text NOT NULL, reference text NOT NULL,
 debit_party text NOT NULL, credit_party text NOT NULL, current_status text NOT NULL, current_stage text NOT NULL,
 last_entry_id uuid, last_memo text, version int NOT NULL, entry_count int NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (clearledger.bounded(account_id,3,64) AND clearledger.bounded(reference,3,64)
 AND clearledger.bounded(debit_party,2,64) AND clearledger.bounded(credit_party,2,64)
 AND clearledger.trimmed(debit_party) <> clearledger.trimmed(credit_party) AND clearledger.bounded(current_stage,2,64)
 AND (last_memo IS NULL OR clearledger.bounded(last_memo,1,256))),
 CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')),
 CHECK (version >= 1 AND updated_at >= created_at),
 CHECK ((version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND last_entry_id IS NULL AND updated_at = created_at)
 OR (version > 1 AND entry_count = version-1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS clearledger.events (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL UNIQUE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version int NOT NULL, event_type text NOT NULL, correlation_id text NOT NULL, idempotency_key text NOT NULL,
 occurred_at timestamptz NOT NULL, payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (settlement_id,aggregate_version), UNIQUE (settlement_id,idempotency_key),
 CHECK (aggregate_version >= 1 AND clearledger.bounded(correlation_id,4,128) AND clearledger.bounded(idempotency_key,8,128)),
 CHECK (clearledger.envelope_ok(payload))
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version int NOT NULL, correlation_id text NOT NULL, payload jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz, archived_at timestamptz,
 attempts int NOT NULL DEFAULT 0, last_error text,
 UNIQUE (settlement_id,aggregate_version),
 FOREIGN KEY (settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE,
 CHECK (clearledger.envelope_ok(payload) AND aggregate_version >= 1 AND clearledger.bounded(correlation_id,4,128)),
 CHECK (attempts >= 0 AND (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))
 AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)))
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
 scope text NOT NULL, idempotency_key text NOT NULL, request_hash text NOT NULL, status_code int NOT NULL,
 response_body jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (scope,idempotency_key),
 CHECK (scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'),
 CHECK (clearledger.bounded(idempotency_key,8,128) AND request_hash ~ '^[0-9a-f]{64}$')
);
CREATE OR REPLACE FUNCTION clearledger.settlement_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'settlements are permanent'; END IF;
 IF TG_OP = 'INSERT' THEN
   IF NEW.version <> 1 THEN RAISE EXCEPTION 'settlements must begin at version one'; END IF;
 ELSE
   IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
     IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
   OR NEW.version <> OLD.version+1 OR NEW.entry_count <> OLD.entry_count+1 OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id
   OR NEW.updated_at < OLD.updated_at OR NOT clearledger.transition_ok(OLD.current_status,NEW.current_status) THEN
     RAISE EXCEPTION 'invalid settlement transition';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements%ROWTYPE; prev clearledger.events%ROWTYPE; d jsonb;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append only'; END IF;
 IF NOT clearledger.envelope_ok(NEW.payload) THEN RAISE EXCEPTION 'invalid event envelope'; END IF;
 d := NEW.payload->'data';
 SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'parent settlement missing' USING ERRCODE='23503'; END IF;
 IF NEW.aggregate_version <> coalesce((SELECT max(aggregate_version) FROM clearledger.events WHERE settlement_id = NEW.settlement_id),0)+1
 OR ROW(NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.event_type,NEW.correlation_id,NEW.idempotency_key,NEW.occurred_at)
 IS DISTINCT FROM ROW((NEW.payload->>'eventId')::uuid,(NEW.payload->>'aggregateId')::uuid,(NEW.payload->>'aggregateVersion')::int,
 NEW.payload->>'eventType',NEW.payload->>'correlationId',NEW.payload->>'idempotencyKey',(NEW.payload->>'occurredAt')::timestamptz)
 OR ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_entry_id,s.last_memo,s.version,s.updated_at)
 IS DISTINCT FROM ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',(d->>'entryId')::uuid,d->>'memo',NEW.aggregate_version,NEW.occurred_at)
 OR (NEW.aggregate_version=1 AND NEW.occurred_at <> s.created_at) THEN RAISE EXCEPTION 'event does not match aggregate'; END IF;
 IF NEW.aggregate_version >= 2 THEN
   SELECT * INTO prev FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND aggregate_version=NEW.aggregate_version-1;
   IF NOT FOUND OR NEW.occurred_at < prev.occurred_at OR NOT clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status')
   OR EXISTS(SELECT 1 FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND payload->'data'->>'entryId'=d->>'entryId') THEN
     RAISE EXCEPTION 'invalid ledger progression';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events%ROWTYPE;
BEGIN
 IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'outbox deletion forbidden'; END IF;
 IF TG_OP = 'INSERT' THEN
   SELECT * INTO e FROM clearledger.events WHERE event_id=NEW.event_id;
   IF NOT FOUND OR ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload)
   IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload)
   OR NEW.aggregate_version <> coalesce((SELECT max(aggregate_version) FROM clearledger.outbox WHERE settlement_id=NEW.settlement_id),0)+1 THEN
     RAISE EXCEPTION 'outbox must mirror ordered events';
   END IF;
 ELSE
   IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at)
   IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
   OR NEW.attempts < OLD.attempts THEN RAISE EXCEPTION 'immutable outbox envelope'; END IF;
   IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL) THEN
     RAISE EXCEPTION 'publishing must increment attempts';
   END IF;
   IF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND
   ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error) THEN
     RAISE EXCEPTION 'published delivery metadata immutable';
   END IF;
   IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at THEN
     RAISE EXCEPTION 'archival timestamp immutable';
   END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p jsonb; v int; sid uuid; eid uuid;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'idempotency records are append only'; END IF;
 p := NEW.response_body;
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
 OR (p - ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) <> '{}'::jsonb
 OR p->'accepted' IS DISTINCT FROM 'true'::jsonb OR p->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb
 OR jsonb_typeof(p->'settlementId') IS DISTINCT FROM 'string' OR jsonb_typeof(p->'eventId') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p->'version') IS DISTINCT FROM 'number' OR (p->>'version') !~ '^[1-9][0-9]*$'
 OR NOT clearledger.uuid_ok(p->>'settlementId') OR NOT clearledger.uuid_ok(p->>'eventId') THEN
   RAISE EXCEPTION 'invalid accepted response';
 END IF;
 BEGIN
   v := (p->>'version')::int; sid := (p->>'settlementId')::uuid; eid := (p->>'eventId')::uuid;
 EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'invalid response identifiers'; END;
 IF NOT ((NEW.scope='create:'||sid::text AND NEW.status_code=201 AND v=1) OR (NEW.scope='entry:'||sid::text AND NEW.status_code=202 AND v>=2))
 OR NOT EXISTS(SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o USING(event_id)
 WHERE e.event_id=eid AND e.settlement_id=sid AND e.aggregate_version=v AND e.idempotency_key=NEW.idempotency_key) THEN
   RAISE EXCEPTION 'response must reference committed event and outbox';
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER settlement_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
CREATE OR REPLACE TRIGGER event_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
CREATE OR REPLACE TRIGGER outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
CREATE OR REPLACE TRIGGER idempotency_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
COMMIT;
