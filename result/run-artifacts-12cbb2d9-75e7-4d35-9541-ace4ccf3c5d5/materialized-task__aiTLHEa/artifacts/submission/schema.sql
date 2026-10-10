\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(748294102);
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE OR REPLACE FUNCTION clearledger.canonical(v text, lo integer, hi integer) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT v IS NOT NULL AND v = btrim(v) AND length(v) BETWEEN lo AND hi $$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_status text, new_status text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN old_status = 'RECONCILED' THEN false
 WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED','RECONCILED')
 ELSE new_status = 'DISPUTED' OR array_position(ARRAY['INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED'], new_status)
 >= array_position(ARRAY['INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED'], old_status) END
$$;
CREATE OR REPLACE FUNCTION clearledger.valid_envelope(p jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; k text; v integer;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']
 OR (p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
  IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement' OR jsonb_typeof(p->'aggregateVersion') <> 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$' THEN RETURN false; END IF;
 v := (p->>'aggregateVersion')::integer;
 PERFORM (p->>'eventId')::uuid, (p->>'aggregateId')::uuid, (p->>'occurredAt')::timestamptz;
 IF (p->>'eventId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR (p->>'aggregateId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR (p->>'occurredAt') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$'
 OR NOT clearledger.canonical(p->>'correlationId',4,128) OR NOT clearledger.canonical(p->>'idempotencyKey',8,128) THEN RETURN false; END IF;
 d := p->'data';
 IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']
 OR (d - ARRAY['kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
  IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.canonical(d->>'accountId',3,64) OR NOT clearledger.canonical(d->>'reference',3,64)
 OR NOT clearledger.canonical(d->>'debitParty',2,64) OR NOT clearledger.canonical(d->>'creditParty',2,64)
 OR d->>'debitParty' = d->>'creditParty' OR NOT clearledger.canonical(d->>'clearingStage',2,64)
 OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
 IF d ? 'memo' AND d->'memo' <> 'null'::jsonb AND (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.canonical(d->>'memo',1,256)) THEN RETURN false; END IF;
 IF d ? 'entryId' AND d->'entryId' <> 'null'::jsonb THEN
  IF jsonb_typeof(d->'entryId') <> 'string' OR (d->>'entryId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN false; END IF;
  PERFORM (d->>'entryId')::uuid;
 END IF;
 IF v = 1 THEN
  RETURN (p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated' AND d->>'status' = 'INITIATED'
   AND d->>'clearingStage' = 'INITIATED@' || (d->>'debitParty') AND d->>'entryId' IS NULL AND d->>'memo' = 'Settlement initiated') IS TRUE;
 ELSE
  RETURN (p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded' AND d->>'status' <> 'INITIATED' AND d->>'entryId' IS NOT NULL) IS TRUE;
 END IF;
EXCEPTION WHEN others THEN RETURN false;
END $$;
CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id uuid PRIMARY KEY, account_id text NOT NULL, reference text NOT NULL, debit_party text NOT NULL, credit_party text NOT NULL,
 current_status text NOT NULL, current_stage text NOT NULL, last_entry_id uuid, last_memo text, version integer NOT NULL,
 entry_count integer NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS clearledger.events (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL, settlement_id uuid NOT NULL, aggregate_version integer NOT NULL,
 event_type text NOT NULL, correlation_id text NOT NULL, idempotency_key text NOT NULL, occurred_at timestamptz NOT NULL,
 payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
 seq bigserial PRIMARY KEY, event_id uuid NOT NULL, settlement_id uuid NOT NULL, aggregate_version integer NOT NULL,
 correlation_id text NOT NULL, payload jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), published_at timestamptz,
 archived_at timestamptz, attempts integer NOT NULL DEFAULT 0, last_error text
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
 scope text NOT NULL, idempotency_key text NOT NULL, request_hash text NOT NULL, status_code integer NOT NULL,
 response_body jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(scope,idempotency_key)
);
-- Serialize schema repair with writers; never remove ledger data.
LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN ACCESS EXCLUSIVE MODE;
DO $$ DECLARE r record; col record; BEGIN
 FOR r IN SELECT * FROM (VALUES ('settlements','settlement_id'),('events','seq'),('outbox','seq'),('idempotency_keys','scope,idempotency_key')) AS v(tbl,cols) LOOP
  IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=('clearledger.'||r.tbl)::regclass AND contype='p') THEN
   EXECUTE format('ALTER TABLE clearledger.%I ADD PRIMARY KEY (%s)',r.tbl,r.cols);
  END IF;
 END LOOP;
 FOR col IN SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='clearledger'
  AND table_name IN ('settlements','events','outbox','idempotency_keys')
  AND NOT (table_name='settlements' AND column_name IN ('last_entry_id','last_memo'))
  AND NOT (table_name='outbox' AND column_name IN ('published_at','archived_at','last_error')) LOOP
  EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET NOT NULL',col.table_name,col.column_name);
 END LOOP;
END $$;
DO $$ DECLARE r record; BEGIN
 FOR r IN SELECT * FROM (VALUES
 ('events','events_event_id_key','UNIQUE(event_id)'),
 ('events','events_settlement_version_key','UNIQUE(settlement_id,aggregate_version)'),
 ('events','events_settlement_idempotency_key','UNIQUE(settlement_id,idempotency_key)'),
 ('events','events_settlement_fk','FOREIGN KEY(settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
 ('outbox','outbox_event_id_key','UNIQUE(event_id)'),
 ('outbox','outbox_settlement_version_key','UNIQUE(settlement_id,aggregate_version)'),
 ('outbox','outbox_event_fk','FOREIGN KEY(event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE'),
 ('outbox','outbox_settlement_fk','FOREIGN KEY(settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
 ('outbox','outbox_version_fk','FOREIGN KEY(settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE')
 ) AS v(tbl,n,definition) LOOP
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid = ('clearledger.'||r.tbl)::regclass AND conname = r.n) THEN
  EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s',r.tbl,r.n,r.definition);
 END IF; END LOOP;
END $$;
ALTER TABLE clearledger.settlements DROP CONSTRAINT IF EXISTS settlements_domain;
ALTER TABLE clearledger.settlements ADD CONSTRAINT settlements_domain CHECK (
 clearledger.canonical(account_id,3,64) AND clearledger.canonical(reference,3,64) AND clearledger.canonical(debit_party,2,64)
 AND clearledger.canonical(credit_party,2,64) AND debit_party <> credit_party AND clearledger.canonical(current_stage,2,64)
 AND (last_memo IS NULL OR clearledger.canonical(last_memo,1,256)) AND version >= 1
 AND current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')
 AND ((version=1 AND entry_count=0 AND current_status='INITIATED' AND current_stage='INITIATED@'||debit_party
 AND last_entry_id IS NULL AND last_memo IS NOT DISTINCT FROM 'Settlement initiated' AND updated_at=created_at)
 OR (version>1 AND entry_count=version-1 AND current_status<>'INITIATED' AND last_entry_id IS NOT NULL AND updated_at>created_at))
);
ALTER TABLE clearledger.events DROP CONSTRAINT IF EXISTS events_domain;
ALTER TABLE clearledger.events ADD CONSTRAINT events_domain CHECK (
 clearledger.valid_envelope(payload) AND aggregate_version>=1 AND clearledger.canonical(correlation_id,4,128)
 AND clearledger.canonical(idempotency_key,8,128)
 AND (payload->>'eventId')::uuid=event_id AND (payload->>'aggregateId')::uuid=settlement_id
 AND (payload->>'aggregateVersion')::integer=aggregate_version AND payload->>'eventType'=event_type
 AND payload->>'correlationId'=correlation_id AND payload->>'idempotencyKey'=idempotency_key
 AND (payload->>'occurredAt')::timestamptz=occurred_at
);
ALTER TABLE clearledger.outbox DROP CONSTRAINT IF EXISTS outbox_domain;
ALTER TABLE clearledger.outbox ADD CONSTRAINT outbox_domain CHECK (
 clearledger.valid_envelope(payload) AND clearledger.canonical(correlation_id,4,128) AND attempts>=0
 AND (attempts<>0 OR (published_at IS NULL AND last_error IS NULL))
 AND (published_at IS NULL OR (attempts>=1 AND last_error IS NULL AND published_at>=created_at))
 AND (last_error IS NULL OR (published_at IS NULL AND attempts>=1 AND length(btrim(last_error))>0 AND last_error=btrim(last_error)))
 AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at>=published_at))
);
CREATE OR REPLACE FUNCTION clearledger.valid_response(s text, k text, h text, code integer, p jsonb) RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v integer; sid uuid; eid uuid;
BEGIN
 IF NOT clearledger.canonical(k,8,128) OR h !~ '^[0-9a-f]{64}$' OR s !~ '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
 OR (p - ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) <> '{}'::jsonb
 OR p->'accepted' IS DISTINCT FROM 'true'::jsonb OR p->'idempotentReplay' IS DISTINCT FROM 'false'::jsonb
 OR jsonb_typeof(p->'settlementId') <> 'string' OR jsonb_typeof(p->'eventId') <> 'string'
 OR (p->>'settlementId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR (p->>'eventId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 OR jsonb_typeof(p->'version') <> 'number' OR (p->>'version') !~ '^[1-9][0-9]*$' THEN RETURN false; END IF;
 v := (p->>'version')::integer; sid := (p->>'settlementId')::uuid; eid := (p->>'eventId')::uuid;
 RETURN (s = split_part(s,':',1)||':'||sid::text AND ((s LIKE 'create:%' AND code=201 AND v=1) OR (s LIKE 'entry:%' AND code=202 AND v>=2))) IS TRUE;
EXCEPTION WHEN others THEN RETURN false;
END $$;
ALTER TABLE clearledger.idempotency_keys DROP CONSTRAINT IF EXISTS idempotency_domain;
ALTER TABLE clearledger.idempotency_keys ADD CONSTRAINT idempotency_domain CHECK(clearledger.valid_response(scope,idempotency_key,request_hash,status_code,response_body));
DROP INDEX IF EXISTS clearledger.idempotency_event_unique;
CREATE UNIQUE INDEX idempotency_event_unique ON clearledger.idempotency_keys (((response_body->>'eventId')::uuid));
DROP INDEX IF EXISTS clearledger.idempotency_version_unique;
CREATE UNIQUE INDEX idempotency_version_unique ON clearledger.idempotency_keys (((response_body->>'settlementId')::uuid),((response_body->>'version')::integer));
CREATE OR REPLACE FUNCTION clearledger.settlement_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'settlements are append-only'; END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.version <> 1 THEN RAISE EXCEPTION 'aggregate must start at version 1'; END IF;
 ELSE
  IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
   IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
   OR NEW.version <> OLD.version+1 OR NEW.entry_count <> OLD.entry_count+1 OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id
   OR NEW.updated_at <= OLD.updated_at OR clearledger.transition_ok(OLD.current_status,NEW.current_status) IS NOT TRUE THEN
   RAISE EXCEPTION 'invalid aggregate transition'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.event_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements; prev clearledger.events; d jsonb; maxv integer;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append-only'; END IF;
 IF NOT clearledger.valid_envelope(NEW.payload) THEN RAISE EXCEPTION 'invalid envelope'; END IF;
 SELECT * INTO s FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing aggregate' USING ERRCODE='23503'; END IF;
 d := NEW.payload->'data';
 SELECT coalesce(max(aggregate_version),0) INTO maxv FROM clearledger.events WHERE settlement_id=NEW.settlement_id;
 IF NEW.aggregate_version<>maxv+1 OR NEW.aggregate_version<>s.version OR NEW.occurred_at<>s.updated_at
 OR ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',(d->>'entryId')::uuid,d->>'memo')
 IS DISTINCT FROM ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_entry_id,s.last_memo)
 OR (NEW.aggregate_version=1 AND NEW.occurred_at<>s.created_at) THEN RAISE EXCEPTION 'event does not mirror aggregate'; END IF;
 IF NEW.aggregate_version>=2 THEN
  SELECT * INTO prev FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND aggregate_version=NEW.aggregate_version-1;
  IF NEW.occurred_at<=prev.occurred_at OR clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status') IS NOT TRUE
  OR EXISTS(SELECT 1 FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND (payload->'data'->>'entryId')::uuid=(d->>'entryId')::uuid) THEN
   RAISE EXCEPTION 'invalid event progression or duplicate entry'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events; maxv integer;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'outbox is append-only'; END IF;
 IF TG_OP='INSERT' THEN
  PERFORM 1 FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
  SELECT * INTO e FROM clearledger.events WHERE event_id=NEW.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'missing event' USING ERRCODE='23503'; END IF;
  SELECT coalesce(max(aggregate_version),0) INTO maxv FROM clearledger.outbox WHERE settlement_id=NEW.settlement_id;
  IF NEW.aggregate_version<>maxv+1 OR ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload)
   IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload) THEN RAISE EXCEPTION 'outbox must mirror events'; END IF;
 ELSE
  IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at)
   IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
   OR NEW.attempts<OLD.attempts THEN RAISE EXCEPTION 'immutable outbox envelope'; END IF;
  IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts<=OLD.attempts OR NEW.archived_at IS NOT NULL) THEN RAISE EXCEPTION 'invalid publishing transition'; END IF;
  IF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND ROW(NEW.published_at,NEW.attempts,NEW.last_error)
   IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error) THEN RAISE EXCEPTION 'published delivery immutable'; END IF;
  IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at<>OLD.archived_at THEN RAISE EXCEPTION 'archive timestamp immutable'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'idempotency records are append-only'; END IF;
 IF NOT clearledger.valid_response(NEW.scope,NEW.idempotency_key,NEW.request_hash,NEW.status_code,NEW.response_body) THEN RAISE EXCEPTION 'invalid write response'; END IF;
 IF NOT EXISTS(SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o ON o.event_id=e.event_id
  WHERE e.event_id=(NEW.response_body->>'eventId')::uuid AND e.settlement_id=(NEW.response_body->>'settlementId')::uuid
  AND e.aggregate_version=(NEW.response_body->>'version')::integer AND e.idempotency_key=NEW.idempotency_key) THEN RAISE EXCEPTION 'write response has no event and outbox'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS settlement_guard ON clearledger.settlements;
CREATE TRIGGER settlement_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
DROP TRIGGER IF EXISTS event_guard ON clearledger.events;
CREATE TRIGGER event_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
DROP TRIGGER IF EXISTS outbox_guard ON clearledger.outbox;
CREATE TRIGGER outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
DROP TRIGGER IF EXISTS idempotency_guard ON clearledger.idempotency_keys;
CREATE TRIGGER idempotency_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
ALTER TABLE clearledger.settlements ENABLE TRIGGER ALL;
ALTER TABLE clearledger.events ENABLE TRIGGER ALL;
ALTER TABLE clearledger.outbox ENABLE TRIGGER ALL;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER ALL;
DROP INDEX IF EXISTS clearledger.idx_clearledger_outbox_unpublished;
CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
DROP INDEX IF EXISTS clearledger.idx_clearledger_outbox_unarchived;
CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
DROP INDEX IF EXISTS clearledger.idx_clearledger_events_settlement_version;
CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
COMMIT;
