\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(71622101);
CREATE SCHEMA IF NOT EXISTS clearledger;

CREATE OR REPLACE FUNCTION clearledger.text_bounds(v text, lo int, hi int)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT v IS NOT NULL AND length(btrim(v)) BETWEEN lo AND hi;
$$;
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
 WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 ELSE -1 END;
$$;
CREATE OR REPLACE FUNCTION clearledger.transition_valid(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN old_status = 'RECONCILED' THEN false
 WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED','RECONCILED')
 ELSE new_status = 'DISPUTED' OR (clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
 AND clearledger.status_rank(new_status) >= 0) END;
$$;

CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; k text; v int; u uuid; t timestamptz;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']
 OR p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
   IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement'
 OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number'
 OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$'
 OR NOT clearledger.text_bounds(p->>'correlationId',4,128)
 OR NOT clearledger.text_bounds(p->>'idempotencyKey',8,128) THEN RETURN false; END IF;
 IF (p->>'eventId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR (p->>'aggregateId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR (p->>'occurredAt') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' THEN RETURN false; END IF;
 u := (p->>'eventId')::uuid; u := (p->>'aggregateId')::uuid; t := (p->>'occurredAt')::timestamptz;
 IF NOT isfinite(t) THEN RETURN false; END IF;
 v := (p->>'aggregateVersion')::int; d := p->'data';
 IF jsonb_typeof(d) IS DISTINCT FROM 'object'
 OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']
 OR d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
   IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.text_bounds(d->>'accountId',3,64) OR NOT clearledger.text_bounds(d->>'reference',3,64)
 OR NOT clearledger.text_bounds(d->>'debitParty',2,64) OR NOT clearledger.text_bounds(d->>'creditParty',2,64)
 OR btrim(d->>'debitParty') = btrim(d->>'creditParty') OR NOT clearledger.text_bounds(d->>'clearingStage',2,64)
 OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
 IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
   IF jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.text_bounds(d->>'memo',1,256) THEN RETURN false; END IF;
 END IF;
 IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN
   IF jsonb_typeof(d->'entryId') <> 'string' OR (d->>'entryId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN false; END IF;
   u := (d->>'entryId')::uuid;
 END IF;
 IF v = 1 THEN
   RETURN p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated'
     AND d->>'status' = 'INITIATED' AND d->>'entryId' IS NULL;
 ELSE
   RETURN p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded'
     AND d->>'status' <> 'INITIATED' AND d->>'entryId' IS NOT NULL;
 END IF;
EXCEPTION WHEN OTHERS THEN RETURN false;
END;
$$;

CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id uuid PRIMARY KEY,
 account_id text NOT NULL CHECK (clearledger.text_bounds(account_id,3,64)),
 reference text NOT NULL CHECK (clearledger.text_bounds(reference,3,64)),
 debit_party text NOT NULL CHECK (clearledger.text_bounds(debit_party,2,64)),
 credit_party text NOT NULL CHECK (clearledger.text_bounds(credit_party,2,64)),
 current_status text NOT NULL CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')),
 current_stage text NOT NULL CHECK (clearledger.text_bounds(current_stage,2,64)),
 last_entry_id uuid,
 last_memo text CHECK (last_memo IS NULL OR clearledger.text_bounds(last_memo,1,256)),
 version int NOT NULL CHECK (version >= 1),
 entry_count int NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (btrim(debit_party) <> btrim(credit_party)),
 CHECK (updated_at >= created_at),
 CHECK ((version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND last_entry_id IS NULL AND updated_at = created_at)
 OR (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS clearledger.events (
 seq bigserial PRIMARY KEY,
 event_id uuid NOT NULL UNIQUE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version int NOT NULL CHECK (aggregate_version >= 1),
 event_type text NOT NULL,
 correlation_id text NOT NULL CHECK (clearledger.text_bounds(correlation_id,4,128)),
 idempotency_key text NOT NULL CHECK (clearledger.text_bounds(idempotency_key,8,128)),
 occurred_at timestamptz NOT NULL,
 payload jsonb NOT NULL CHECK (clearledger.envelope_valid(payload)),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(settlement_id,aggregate_version), UNIQUE(settlement_id,idempotency_key),
 CHECK ((payload->>'eventId')::uuid = event_id AND (payload->>'aggregateId')::uuid = settlement_id
 AND (payload->>'aggregateVersion')::int = aggregate_version AND payload->>'eventType' = event_type
 AND payload->>'correlationId' = correlation_id AND payload->>'idempotencyKey' = idempotency_key
 AND (payload->>'occurredAt')::timestamptz = occurred_at)
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
 seq bigserial PRIMARY KEY,
 event_id uuid NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version int NOT NULL,
 correlation_id text NOT NULL,
 payload jsonb NOT NULL CHECK (clearledger.envelope_valid(payload)),
 created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz, archived_at timestamptz,
 attempts int NOT NULL DEFAULT 0 CHECK(attempts >= 0), last_error text,
 UNIQUE(settlement_id,aggregate_version),
 FOREIGN KEY(settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE,
 CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)),
 CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
 scope text NOT NULL CHECK (scope ~ '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
 idempotency_key text NOT NULL CHECK(clearledger.text_bounds(idempotency_key,8,128)),
 request_hash text NOT NULL CHECK(request_hash ~ '^[0-9a-f]{64}$'),
 status_code int NOT NULL CHECK(status_code IN (201,202)),
 response_body jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(scope,idempotency_key)
);

CREATE OR REPLACE FUNCTION clearledger.settlement_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'settlement deletion forbidden' USING ERRCODE='23514'; END IF;
 IF TG_OP = 'UPDATE' THEN
   IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
   IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
   OR NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1
   OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id OR NEW.updated_at < OLD.updated_at
   OR NOT clearledger.transition_valid(OLD.current_status,NEW.current_status) THEN
     RAISE EXCEPTION 'invalid settlement transition' USING ERRCODE='23514';
   END IF;
 END IF;
 RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION clearledger.event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements%ROWTYPE; prev clearledger.events%ROWTYPE; d jsonb; n int;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append-only' USING ERRCODE='23514'; END IF;
 IF NOT clearledger.envelope_valid(NEW.payload) THEN RAISE EXCEPTION 'invalid event envelope' USING ERRCODE='23514'; END IF;
 SELECT * INTO s FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing settlement' USING ERRCODE='23503'; END IF;
 d := NEW.payload->'data';
 SELECT coalesce(max(aggregate_version),0)+1 INTO n FROM clearledger.events WHERE settlement_id=NEW.settlement_id;
 IF NEW.aggregate_version <> n OR NEW.aggregate_version <> s.version
 OR (d->>'accountId') IS DISTINCT FROM s.account_id OR (d->>'reference') IS DISTINCT FROM s.reference
 OR (d->>'debitParty') IS DISTINCT FROM s.debit_party OR (d->>'creditParty') IS DISTINCT FROM s.credit_party
 OR (d->>'status') IS DISTINCT FROM s.current_status OR (d->>'clearingStage') IS DISTINCT FROM s.current_stage
 OR (d->>'entryId')::uuid IS DISTINCT FROM s.last_entry_id OR (d->>'memo') IS DISTINCT FROM s.last_memo
 OR NEW.occurred_at IS DISTINCT FROM s.updated_at
 OR (NEW.aggregate_version=1 AND NEW.occurred_at IS DISTINCT FROM s.created_at) THEN
   RAISE EXCEPTION 'event does not match parent or contiguous version' USING ERRCODE='23514';
 END IF;
 IF NEW.aggregate_version >= 2 THEN
   SELECT * INTO prev FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND aggregate_version=NEW.aggregate_version-1;
   IF NEW.occurred_at < prev.occurred_at OR NOT clearledger.transition_valid(prev.payload->'data'->>'status', d->>'status')
   OR EXISTS(SELECT 1 FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND payload->'data'->>'entryId'=d->>'entryId') THEN
     RAISE EXCEPTION 'invalid entry history' USING ERRCODE='23514';
   END IF;
 END IF;
 RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events%ROWTYPE; n int;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'outbox deletion forbidden' USING ERRCODE='23514'; END IF;
 IF TG_OP='INSERT' THEN
   PERFORM 1 FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
   SELECT * INTO e FROM clearledger.events WHERE event_id=NEW.event_id;
   IF NOT FOUND THEN RAISE EXCEPTION 'missing event' USING ERRCODE='23503'; END IF;
   SELECT coalesce(max(aggregate_version),0)+1 INTO n FROM clearledger.outbox WHERE settlement_id=NEW.settlement_id;
   IF ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload)
   IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload) OR NEW.aggregate_version <> n THEN
     RAISE EXCEPTION 'outbox must mirror contiguous events' USING ERRCODE='23514'; END IF;
 ELSE
   IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at)
   IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
   OR NEW.attempts < OLD.attempts THEN RAISE EXCEPTION 'immutable outbox envelope' USING ERRCODE='23514'; END IF;
   IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL) THEN
     RAISE EXCEPTION 'publishing requires attempt increment' USING ERRCODE='23514'; END IF;
   IF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND
   ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error) THEN
     RAISE EXCEPTION 'published delivery metadata immutable' USING ERRCODE='23514'; END IF;
   IF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL AND NEW.archived_at IS NOT NULL THEN
     RAISE EXCEPTION 'replay must reset archival' USING ERRCODE='23514'; END IF;
   IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND OLD.archived_at IS DISTINCT FROM NEW.archived_at THEN
     RAISE EXCEPTION 'archival metadata immutable until reset' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p jsonb; k text; sid uuid; eid uuid; v int;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'idempotency is append-only' USING ERRCODE='23514'; END IF;
 p:=NEW.response_body;
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
 OR p - ARRAY['settlementId','eventId','version','accepted','idempotentReplay'] <> '{}'::jsonb
 OR p->'accepted' IS DISTINCT FROM 'true'::jsonb OR p->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb
 OR jsonb_typeof(p->'settlementId') IS DISTINCT FROM 'string' OR jsonb_typeof(p->'eventId') IS DISTINCT FROM 'string'
 OR jsonb_typeof(p->'version') IS DISTINCT FROM 'number' OR (p->>'version') !~ '^[1-9][0-9]*$'
 OR (p->>'settlementId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR (p->>'eventId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
   RAISE EXCEPTION 'invalid accepted response' USING ERRCODE='23514'; END IF;
 sid:=(p->>'settlementId')::uuid; eid:=(p->>'eventId')::uuid; v:=(p->>'version')::int;
 IF NOT ((NEW.scope='create:'||sid::text AND NEW.status_code=201 AND v=1)
 OR (NEW.scope='entry:'||sid::text AND NEW.status_code=202 AND v>=2)) THEN
   RAISE EXCEPTION 'scope/version mismatch' USING ERRCODE='23514'; END IF;
 IF NOT EXISTS(SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o USING(event_id)
 WHERE e.event_id=eid AND e.settlement_id=sid AND e.aggregate_version=v AND e.idempotency_key=NEW.idempotency_key) THEN
   RAISE EXCEPTION 'idempotency requires committed event and outbox' USING ERRCODE='23503'; END IF;
 RETURN NEW;
END;
$$;
CREATE OR REPLACE TRIGGER settlements_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.settlements
 FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
CREATE OR REPLACE TRIGGER events_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events
 FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
CREATE OR REPLACE TRIGGER outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox
 FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
CREATE OR REPLACE TRIGGER idempotency_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys
 FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
COMMIT;
