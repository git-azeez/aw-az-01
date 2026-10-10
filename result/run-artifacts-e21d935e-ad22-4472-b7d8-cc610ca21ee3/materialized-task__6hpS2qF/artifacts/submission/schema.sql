BEGIN;
SELECT pg_advisory_xact_lock(hashtext('clearledger-schema'));
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE OR REPLACE FUNCTION clearledger.text_ok(t text, lo int, hi int) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT t IS NOT NULL AND length(btrim(t, E' \t\r\n')) BETWEEN lo AND hi $$;
CREATE OR REPLACE FUNCTION clearledger.status_rank(s text) RETURNS int
LANGUAGE sql IMMUTABLE AS $$ SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2 WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 ELSE -1 END $$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_status text, new_status text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT old_status <> 'RECONCILED' AND CASE WHEN old_status = 'DISPUTED'
 THEN new_status IN ('DISPUTED','RECONCILED') ELSE new_status = 'DISPUTED' OR
 (clearledger.status_rank(new_status) >= clearledger.status_rank(old_status) AND clearledger.status_rank(new_status) >= 0) END $$;
CREATE OR REPLACE FUNCTION clearledger.uuid_ok(t text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT t IS NOT NULL AND t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' $$;
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; k text; v int;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']
 OR (p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
  IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement' OR NOT clearledger.uuid_ok(p->>'eventId') OR NOT clearledger.uuid_ok(p->>'aggregateId')
 OR NOT clearledger.text_ok(p->>'correlationId',4,128) OR NOT clearledger.text_ok(p->>'idempotencyKey',8,128)
 OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$'
 OR (p->>'occurredAt') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' THEN RETURN false; END IF;
 PERFORM (p->>'occurredAt')::timestamptz;
 v := (p->>'aggregateVersion')::int; d := p->'data';
 IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']
 OR (d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
  IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.text_ok(d->>'accountId',3,64) OR NOT clearledger.text_ok(d->>'reference',3,64)
 OR NOT clearledger.text_ok(d->>'debitParty',2,64) OR NOT clearledger.text_ok(d->>'creditParty',2,64)
 OR btrim(d->>'debitParty',E' \t\r\n') = btrim(d->>'creditParty',E' \t\r\n')
 OR NOT clearledger.text_ok(d->>'clearingStage',2,64)
 OR (d->>'status') NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
 IF d ? 'memo' AND d->'memo' <> 'null'::jsonb AND (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.text_ok(d->>'memo',1,256)) THEN RETURN false; END IF;
 IF v = 1 THEN
  RETURN p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated' AND d->>'status' = 'INITIATED' AND d->>'entryId' IS NULL;
 ELSE
  RETURN p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded' AND d->>'status' <> 'INITIATED'
   AND jsonb_typeof(d->'entryId') = 'string' AND clearledger.uuid_ok(d->>'entryId');
 END IF;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;
CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id uuid PRIMARY KEY, account_id text NOT NULL, reference text NOT NULL, debit_party text NOT NULL, credit_party text NOT NULL,
 current_status text NOT NULL, current_stage text NOT NULL, last_entry_id uuid, last_memo text, version int NOT NULL, entry_count int NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 CONSTRAINT settlements_strings CHECK (clearledger.text_ok(account_id,3,64) AND clearledger.text_ok(reference,3,64) AND clearledger.text_ok(debit_party,2,64) AND clearledger.text_ok(credit_party,2,64)
 AND btrim(debit_party,E' \t\r\n') <> btrim(credit_party,E' \t\r\n') AND clearledger.text_ok(current_stage,2,64) AND (last_memo IS NULL OR clearledger.text_ok(last_memo,1,256))),
 CONSTRAINT settlements_state CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') AND version >= 1 AND updated_at >= created_at AND
 ((version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND last_entry_id IS NULL AND updated_at = created_at)
 OR (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL)))
);
CREATE TABLE IF NOT EXISTS clearledger.events (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL UNIQUE, settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 aggregate_version int NOT NULL, event_type text NOT NULL, correlation_id text NOT NULL, idempotency_key text NOT NULL,
 occurred_at timestamptz NOT NULL, payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(settlement_id,aggregate_version), UNIQUE(settlement_id,idempotency_key),
 CONSTRAINT events_envelope CHECK (clearledger.envelope_ok(payload) IS TRUE),
 CONSTRAINT events_columns CHECK (aggregate_version >= 1 AND clearledger.text_ok(correlation_id,4,128) AND clearledger.text_ok(idempotency_key,8,128)
 AND event_id = (payload->>'eventId')::uuid AND settlement_id = (payload->>'aggregateId')::uuid
 AND aggregate_version = (payload->>'aggregateVersion')::int AND event_type = payload->>'eventType'
 AND correlation_id = payload->>'correlationId' AND idempotency_key = payload->>'idempotencyKey' AND occurred_at = (payload->>'occurredAt')::timestamptz)
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
 settlement_id uuid NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE, aggregate_version int NOT NULL,
 correlation_id text NOT NULL, payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz,
 archived_at timestamptz, attempts int NOT NULL DEFAULT 0, last_error text,
 UNIQUE(settlement_id,aggregate_version), FOREIGN KEY(settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE,
 CONSTRAINT outbox_envelope CHECK (clearledger.envelope_ok(payload) IS TRUE),
 CONSTRAINT outbox_lifecycle CHECK (attempts >= 0 AND (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))
 AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)))
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
 scope text NOT NULL, idempotency_key text NOT NULL, request_hash text NOT NULL, status_code int NOT NULL,
 response_body jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(scope,idempotency_key),
 CONSTRAINT idempotency_format CHECK (scope ~* '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 AND clearledger.text_ok(idempotency_key,8,128) AND request_hash ~ '^[0-9a-f]{64}$')
);
CREATE OR REPLACE FUNCTION clearledger.settlement_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
 IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
 OR NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1 OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id
 OR NEW.updated_at < OLD.updated_at OR NOT clearledger.transition_ok(OLD.current_status,NEW.current_status) THEN
 RAISE EXCEPTION 'Invalid settlement transition' USING ERRCODE = '23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements; prev clearledger.events; d jsonb;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Events are append-only' USING ERRCODE='23514'; END IF;
 IF clearledger.envelope_ok(NEW.payload) IS NOT TRUE THEN RAISE EXCEPTION 'Invalid event envelope' USING ERRCODE='23514'; END IF;
 SELECT * INTO s FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Settlement missing' USING ERRCODE='23503'; END IF;
 d := NEW.payload->'data';
 IF NEW.aggregate_version <> COALESCE((SELECT max(aggregate_version) FROM clearledger.events WHERE settlement_id=NEW.settlement_id),0)+1
 OR NEW.aggregate_version <> s.version OR NEW.occurred_at <> s.updated_at
 OR ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',(d->>'entryId')::uuid,d->>'memo')
 IS DISTINCT FROM ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_entry_id,s.last_memo)
 OR (NEW.aggregate_version=1 AND NEW.occurred_at <> s.created_at) THEN RAISE EXCEPTION 'Event does not match aggregate' USING ERRCODE='23514'; END IF;
 IF NEW.aggregate_version >= 2 THEN
  SELECT * INTO prev FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND aggregate_version=NEW.aggregate_version-1;
  IF NEW.occurred_at < prev.occurred_at OR NOT clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status')
  OR EXISTS(SELECT 1 FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND payload->'data'->>'entryId'=d->>'entryId') THEN
   RAISE EXCEPTION 'Invalid ledger entry transition' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Outbox deletion forbidden' USING ERRCODE='23514'; END IF;
 IF TG_OP='INSERT' THEN
  PERFORM 1 FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
  SELECT * INTO e FROM clearledger.events WHERE event_id=NEW.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event missing' USING ERRCODE='23503'; END IF;
  IF ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload) IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload)
  OR NEW.aggregate_version <> COALESCE((SELECT max(aggregate_version) FROM clearledger.outbox WHERE settlement_id=NEW.settlement_id),0)+1 THEN
   RAISE EXCEPTION 'Outbox must mirror ordered event' USING ERRCODE='23514'; END IF;
 ELSE
  IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at)
  IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
  OR NEW.attempts < OLD.attempts
  OR (OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL))
  OR (OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error))
  OR (OLD.published_at IS NOT NULL AND NEW.published_at IS NULL AND NEW.archived_at IS NOT NULL)
  OR (OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at) THEN
   RAISE EXCEPTION 'Invalid outbox lifecycle' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p jsonb; v int;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Idempotency keys are append-only' USING ERRCODE='23514'; END IF;
 p := NEW.response_body;
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
 OR p - ARRAY['settlementId','eventId','version','accepted','idempotentReplay'] <> '{}'::jsonb
 OR jsonb_typeof(p->'settlementId') IS DISTINCT FROM 'string' OR jsonb_typeof(p->'eventId') IS DISTINCT FROM 'string'
 OR NOT clearledger.uuid_ok(p->>'settlementId') OR NOT clearledger.uuid_ok(p->>'eventId')
 OR jsonb_typeof(p->'version') IS DISTINCT FROM 'number' OR (p->>'version') !~ '^[1-9][0-9]*$'
 OR p->'accepted' IS DISTINCT FROM 'true'::jsonb OR p->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb THEN
  RAISE EXCEPTION 'Invalid accepted response' USING ERRCODE='23514'; END IF;
 v := (p->>'version')::int;
 IF NEW.scope <> ((CASE WHEN v=1 THEN 'create:' ELSE 'entry:' END) || (p->>'settlementId'))
 OR NEW.status_code <> (CASE WHEN v=1 THEN 201 ELSE 202 END) THEN RAISE EXCEPTION 'Invalid idempotency scope' USING ERRCODE='23514'; END IF;
 IF NOT EXISTS(SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o ON o.event_id=e.event_id
  WHERE e.event_id=(p->>'eventId')::uuid AND e.settlement_id=(p->>'settlementId')::uuid AND e.aggregate_version=v AND e.idempotency_key=NEW.idempotency_key) THEN
  RAISE EXCEPTION 'Idempotency response must reference committed event and outbox' USING ERRCODE='23503'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS settlements_guard ON clearledger.settlements;
CREATE TRIGGER settlements_guard BEFORE UPDATE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
DROP TRIGGER IF EXISTS events_guard ON clearledger.events;
CREATE TRIGGER events_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
DROP TRIGGER IF EXISTS outbox_guard ON clearledger.outbox;
CREATE TRIGGER outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
DROP TRIGGER IF EXISTS idempotency_guard ON clearledger.idempotency_keys;
CREATE TRIGGER idempotency_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
COMMIT;
