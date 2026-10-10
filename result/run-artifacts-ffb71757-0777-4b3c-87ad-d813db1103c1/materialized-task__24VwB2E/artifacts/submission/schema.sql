BEGIN;
CREATE SCHEMA IF NOT EXISTS clearledger;

CREATE OR REPLACE FUNCTION clearledger.bounded(s text, lo int, hi int)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT s IS NOT NULL AND length(btrim(s)) BETWEEN lo AND hi
$$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE
 WHEN old_status = 'RECONCILED' THEN false
 WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED','RECONCILED')
 WHEN new_status = 'DISPUTED' THEN true
 ELSE COALESCE(array_position(ARRAY['INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED'], new_status)
   >= array_position(ARRAY['INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED'], old_status), false) END
$$;

CREATE OR REPLACE FUNCTION clearledger.valid_envelope(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; k text; v integer;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']
 OR p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
   IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement'
 OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number'
 OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$'
 OR NOT clearledger.bounded(p->>'correlationId',4,128)
 OR NOT clearledger.bounded(p->>'idempotencyKey',8,128)
 OR p->>'eventId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR p->>'aggregateId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR p->>'occurredAt' !~ '^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$'
 THEN RETURN false; END IF;
 PERFORM (p->>'occurredAt')::timestamptz;
 v := (p->>'aggregateVersion')::integer;
 d := p->'data';
 IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']
 OR d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
   IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.bounded(d->>'accountId',3,64) OR NOT clearledger.bounded(d->>'reference',3,64)
 OR NOT clearledger.bounded(d->>'debitParty',2,64) OR NOT clearledger.bounded(d->>'creditParty',2,64)
 OR btrim(d->>'debitParty') = btrim(d->>'creditParty')
 OR NOT clearledger.bounded(d->>'clearingStage',2,64)
 OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
 IF d ? 'memo' AND d->'memo' <> 'null'::jsonb AND (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.bounded(d->>'memo',1,256)) THEN RETURN false; END IF;
 IF d ? 'entryId' AND d->'entryId' <> 'null'::jsonb AND (jsonb_typeof(d->'entryId') <> 'string' OR d->>'entryId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN RETURN false; END IF;
 IF v = 1 THEN
   RETURN p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated' AND d->>'status' = 'INITIATED' AND d->>'entryId' IS NULL;
 END IF;
 RETURN p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded' AND d->>'status' <> 'INITIATED' AND d->>'entryId' IS NOT NULL;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id uuid PRIMARY KEY,
 account_id text NOT NULL CHECK (clearledger.bounded(account_id,3,64)),
 reference text NOT NULL CHECK (clearledger.bounded(reference,3,64)),
 debit_party text NOT NULL CHECK (clearledger.bounded(debit_party,2,64)),
 credit_party text NOT NULL CHECK (clearledger.bounded(credit_party,2,64)),
 current_status text NOT NULL CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')),
 current_stage text NOT NULL CHECK (clearledger.bounded(current_stage,2,64)),
 last_entry_id uuid,
 last_memo text CHECK (last_memo IS NULL OR clearledger.bounded(last_memo,1,256)),
 version integer NOT NULL CHECK (version >= 1),
 entry_count integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK (btrim(debit_party) <> btrim(credit_party)),
 CHECK (updated_at >= created_at),
 CHECK ((version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND last_entry_id IS NULL AND updated_at = created_at)
   OR (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS clearledger.events (
 seq bigserial PRIMARY KEY,
 event_id uuid NOT NULL UNIQUE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version integer NOT NULL CHECK (aggregate_version >= 1),
 event_type text NOT NULL CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded')),
 correlation_id text NOT NULL CHECK (clearledger.bounded(correlation_id,4,128)),
 idempotency_key text NOT NULL CHECK (clearledger.bounded(idempotency_key,8,128)),
 occurred_at timestamptz NOT NULL,
 payload jsonb NOT NULL CHECK (clearledger.valid_envelope(payload)),
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (settlement_id, aggregate_version),
 UNIQUE (settlement_id, idempotency_key)
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
 seq bigserial PRIMARY KEY,
 event_id uuid NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version integer NOT NULL CHECK (aggregate_version >= 1),
 correlation_id text NOT NULL CHECK (clearledger.bounded(correlation_id,4,128)),
 payload jsonb NOT NULL CHECK (clearledger.valid_envelope(payload)),
 created_at timestamptz NOT NULL DEFAULT now(),
 published_at timestamptz,
 archived_at timestamptz,
 attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
 last_error text,
 UNIQUE (settlement_id, aggregate_version),
 FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE,
 CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)),
 CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
 scope text NOT NULL CHECK (scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
 idempotency_key text NOT NULL CHECK (clearledger.bounded(idempotency_key,8,128)),
 request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
 status_code integer NOT NULL CHECK (status_code IN (201,202)),
 response_body jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (scope,idempotency_key)
);

CREATE OR REPLACE FUNCTION clearledger.guard_settlement() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
 IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
 OR NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1
 OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id OR NEW.updated_at < OLD.updated_at
 OR NOT clearledger.transition_ok(OLD.current_status,NEW.current_status)
 THEN RAISE EXCEPTION 'invalid settlement transition' USING ERRCODE = '23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER settlement_invariants BEFORE UPDATE ON clearledger.settlements
 FOR EACH ROW EXECUTE FUNCTION clearledger.guard_settlement();

CREATE OR REPLACE FUNCTION clearledger.guard_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements; prev clearledger.events; d jsonb; next_version int;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append-only' USING ERRCODE = '23514'; END IF;
 IF NOT clearledger.valid_envelope(NEW.payload) THEN RAISE EXCEPTION 'invalid envelope' USING ERRCODE = '23514'; END IF;
 d := NEW.payload->'data';
 SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing settlement' USING ERRCODE = '23503'; END IF;
 SELECT coalesce(max(aggregate_version),0)+1 INTO next_version FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
 IF NEW.aggregate_version <> next_version
 OR ROW(NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.event_type,NEW.correlation_id,NEW.idempotency_key,NEW.occurred_at)
 IS DISTINCT FROM ROW((NEW.payload->>'eventId')::uuid,(NEW.payload->>'aggregateId')::uuid,(NEW.payload->>'aggregateVersion')::int,NEW.payload->>'eventType',NEW.payload->>'correlationId',NEW.payload->>'idempotencyKey',(NEW.payload->>'occurredAt')::timestamptz)
 OR ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_entry_id,s.last_memo,s.version,s.updated_at)
 IS DISTINCT FROM ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',(d->>'entryId')::uuid,d->>'memo',NEW.aggregate_version,NEW.occurred_at)
 OR (NEW.aggregate_version = 1 AND NEW.occurred_at <> s.created_at)
 THEN RAISE EXCEPTION 'event differs from authoritative settlement' USING ERRCODE = '23514'; END IF;
 IF NEW.aggregate_version >= 2 THEN
   SELECT * INTO prev FROM clearledger.events WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version-1;
   IF NEW.occurred_at < prev.occurred_at OR NOT clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status')
   OR EXISTS (SELECT 1 FROM clearledger.events WHERE settlement_id = NEW.settlement_id AND (payload->'data'->>'entryId')::uuid = (d->>'entryId')::uuid)
   THEN RAISE EXCEPTION 'invalid ledger progression or repeated entry' USING ERRCODE = '23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER event_invariants BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events
 FOR EACH ROW EXECUTE FUNCTION clearledger.guard_event();

CREATE OR REPLACE FUNCTION clearledger.guard_outbox() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events; next_version int;
BEGIN
 IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'outbox deletion forbidden' USING ERRCODE = '23514'; END IF;
 IF TG_OP = 'INSERT' THEN
   PERFORM 1 FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
   SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
   IF NOT FOUND THEN RAISE EXCEPTION 'missing event' USING ERRCODE = '23503'; END IF;
   SELECT coalesce(max(aggregate_version),0)+1 INTO next_version FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
   IF NEW.aggregate_version <> next_version
   OR ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload) IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload)
   THEN RAISE EXCEPTION 'outbox must mirror event' USING ERRCODE = '23514'; END IF;
 ELSE
   IF (to_jsonb(NEW)-ARRAY['published_at','archived_at','attempts','last_error']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['published_at','archived_at','attempts','last_error'])
   OR NEW.attempts < OLD.attempts
   OR (OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL))
   OR (OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error))
   OR (OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at)
   THEN RAISE EXCEPTION 'invalid outbox lifecycle' USING ERRCODE = '23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER outbox_invariants BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox
 FOR EACH ROW EXECUTE FUNCTION clearledger.guard_outbox();

CREATE OR REPLACE FUNCTION clearledger.guard_idempotency() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b jsonb; v integer; sid uuid; eid uuid;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'idempotency records are immutable' USING ERRCODE = '23514'; END IF;
 b := NEW.response_body;
 IF jsonb_typeof(b) IS DISTINCT FROM 'object' OR NOT b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
 OR b - ARRAY['settlementId','eventId','version','accepted','idempotentReplay'] <> '{}'::jsonb
 OR b->'accepted' IS DISTINCT FROM 'true'::jsonb OR b->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb
 OR jsonb_typeof(b->'version') IS DISTINCT FROM 'number' OR b->>'version' !~ '^[1-9][0-9]*$'
 OR jsonb_typeof(b->'settlementId') IS DISTINCT FROM 'string' OR jsonb_typeof(b->'eventId') IS DISTINCT FROM 'string'
 OR b->>'settlementId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR b->>'eventId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 THEN RAISE EXCEPTION 'invalid idempotency response' USING ERRCODE = '23514'; END IF;
 v := (b->>'version')::integer; sid := (b->>'settlementId')::uuid; eid := (b->>'eventId')::uuid;
 IF NOT ((NEW.scope = 'create:' || sid::text AND v = 1 AND NEW.status_code = 201)
 OR (NEW.scope = 'entry:' || sid::text AND v >= 2 AND NEW.status_code = 202))
 THEN RAISE EXCEPTION 'idempotency scope or version mismatch' USING ERRCODE = '23514'; END IF;
 IF NOT EXISTS (SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o USING(event_id)
 WHERE e.event_id = eid AND e.settlement_id = sid AND e.aggregate_version = v AND e.idempotency_key = NEW.idempotency_key)
 THEN RAISE EXCEPTION 'idempotency event missing' USING ERRCODE = '23503'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER idempotency_invariants BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys
 FOR EACH ROW EXECUTE FUNCTION clearledger.guard_idempotency();

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
COMMIT;
