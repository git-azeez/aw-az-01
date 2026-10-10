-- Atomic, data-preserving canonical schema repair. Serializes against API writes.
BEGIN;
SELECT pg_advisory_xact_lock(734291008);
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id UUID PRIMARY KEY, account_id TEXT NOT NULL, reference TEXT NOT NULL,
 debit_party TEXT NOT NULL, credit_party TEXT NOT NULL, current_status TEXT NOT NULL,
 current_stage TEXT NOT NULL, last_entry_id UUID, last_memo TEXT NOT NULL,
 version INTEGER NOT NULL, entry_count INTEGER NOT NULL DEFAULT 0,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS clearledger.events (
 seq BIGSERIAL PRIMARY KEY, event_id UUID NOT NULL, settlement_id UUID NOT NULL,
 aggregate_version INTEGER NOT NULL, event_type TEXT NOT NULL, correlation_id TEXT NOT NULL,
 idempotency_key TEXT NOT NULL, occurred_at TIMESTAMPTZ NOT NULL, payload JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
 seq BIGSERIAL PRIMARY KEY, event_id UUID NOT NULL, settlement_id UUID NOT NULL,
 aggregate_version INTEGER NOT NULL, correlation_id TEXT NOT NULL, payload JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), published_at TIMESTAMPTZ, archived_at TIMESTAMPTZ,
 attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
 scope TEXT NOT NULL, idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL,
 status_code INTEGER NOT NULL, response_body JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), PRIMARY KEY(scope,idempotency_key)
);
LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox,
 clearledger.idempotency_keys IN ACCESS EXCLUSIVE MODE;

CREATE OR REPLACE FUNCTION clearledger.trimmed(s TEXT, lo INTEGER, hi INTEGER)
RETURNS BOOLEAN LANGUAGE SQL IMMUTABLE AS $$
 SELECT COALESCE(s = btrim(s) AND length(s) BETWEEN lo AND hi, false)
$$;
CREATE OR REPLACE FUNCTION clearledger.status_rank(s TEXT)
RETURNS INTEGER LANGUAGE SQL IMMUTABLE AS $$
 SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
 WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 ELSE -1 END
$$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN LANGUAGE SQL IMMUTABLE AS $$
 SELECT COALESCE(old_status <> 'RECONCILED' AND new_status <> 'INITIATED' AND
 CASE WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED','RECONCILED')
 ELSE new_status = 'DISPUTED' OR (clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
 AND clearledger.status_rank(old_status) >= 0) END, false)
$$;
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d JSONB; v INTEGER; x TEXT; dt TIMESTAMPTZ;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT (p ?& ARRAY['schemaVersion','eventId','eventType',
 'aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'])
 OR (p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
 'occurredAt','correlationId','idempotencyKey','data']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH x IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
  IF jsonb_typeof(p->x) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement'
 OR NOT clearledger.trimmed(p->>'correlationId',4,128)
 OR NOT clearledger.trimmed(p->>'idempotencyKey',8,128)
 OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number'
 OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$' THEN RETURN false; END IF;
 PERFORM (p->>'eventId')::UUID, (p->>'aggregateId')::UUID;
 IF p->>'occurredAt' !~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)$' THEN RETURN false; END IF;
 dt := (p->>'occurredAt')::TIMESTAMPTZ;
 v := (p->>'aggregateVersion')::INTEGER;
 d := p->'data';
 IF jsonb_typeof(d) IS DISTINCT FROM 'object'
 OR NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'])
 OR (d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo']) <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH x IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
  IF jsonb_typeof(d->x) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.trimmed(d->>'accountId',3,64) OR NOT clearledger.trimmed(d->>'reference',3,64)
 OR NOT clearledger.trimmed(d->>'debitParty',2,64) OR NOT clearledger.trimmed(d->>'creditParty',2,64)
 OR d->>'debitParty' = d->>'creditParty' OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')
 THEN RETURN false; END IF;
 IF d->>'memo' IS NOT NULL AND (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.trimmed(d->>'memo',1,256)) THEN RETURN false; END IF;
 IF v = 1 THEN
  RETURN p->>'eventType' = 'SettlementInitiated' AND d->>'kind' = 'settlementInitiated'
   AND d->>'status' = 'INITIATED' AND d->>'clearingStage' = 'INITIATED@' || (d->>'debitParty')
   AND d->>'entryId' IS NULL AND d->>'memo' = 'Settlement initiated';
 END IF;
 IF jsonb_typeof(d->'entryId') IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 PERFORM (d->>'entryId')::UUID;
 RETURN p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded'
 AND d->>'status' <> 'INITIATED' AND clearledger.trimmed(d->>'clearingStage',2,64);
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

-- Drop dependent FKs before restoring unique keys. Replace every check definition,
-- rather than trusting a constraint's name after an out-of-band alteration.
DO $$ DECLARE r RECORD; BEGIN
 FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint
 WHERE connamespace = 'clearledger'::regnamespace AND contype = 'f'
 AND conrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass)
 LOOP EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',r.t,r.conname); END LOOP;
 FOR r IN SELECT conrelid::regclass AS t, conname FROM pg_constraint
 WHERE connamespace = 'clearledger'::regnamespace AND contype IN ('c','u','p')
 AND conrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass)
 LOOP EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I',r.t,r.conname); END LOOP;
 FOR r IN SELECT t.oid::regclass AS t,a.attname FROM pg_class t JOIN pg_attribute a ON a.attrelid=t.oid
 WHERE t.oid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass)
 AND a.attnum > 0 AND NOT a.attisdropped AND a.attname NOT IN ('last_entry_id','published_at','archived_at','last_error')
 LOOP EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET NOT NULL',r.t,r.attname); END LOOP;
END $$;
ALTER TABLE clearledger.settlements
 ADD CONSTRAINT settlements_pkey PRIMARY KEY(settlement_id),
 ADD CONSTRAINT settlements_fields CHECK (
 clearledger.trimmed(account_id,3,64) AND clearledger.trimmed(reference,3,64)
 AND clearledger.trimmed(debit_party,2,64) AND clearledger.trimmed(credit_party,2,64)
 AND debit_party <> credit_party AND clearledger.trimmed(current_stage,2,74)
 AND clearledger.trimmed(last_memo,1,256)
 AND current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') AND version >= 1),
 ADD CONSTRAINT settlements_lifecycle CHECK (
 (version = 1 AND entry_count = 0 AND current_status = 'INITIATED'
 AND current_stage = 'INITIATED@' || debit_party AND last_entry_id IS NULL
 AND last_memo = 'Settlement initiated' AND updated_at = created_at)
 OR (version > 1 AND entry_count = version-1 AND current_status <> 'INITIATED'
 AND last_entry_id IS NOT NULL AND updated_at > created_at AND length(current_stage) <= 64));
ALTER TABLE clearledger.events
 ADD CONSTRAINT events_pkey PRIMARY KEY(seq),
 ADD CONSTRAINT events_event_id_key UNIQUE(event_id),
 ADD CONSTRAINT events_settlement_version_key UNIQUE(settlement_id,aggregate_version),
 ADD CONSTRAINT events_settlement_idempotency_key UNIQUE(settlement_id,idempotency_key),
 ADD CONSTRAINT events_settlement_fk FOREIGN KEY(settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 ADD CONSTRAINT events_fields CHECK (aggregate_version >= 1 AND clearledger.trimmed(correlation_id,4,128)
 AND clearledger.trimmed(idempotency_key,8,128) AND clearledger.envelope_ok(payload)
 AND (payload->>'eventId')::uuid = event_id AND (payload->>'aggregateId')::uuid = settlement_id
 AND (payload->>'aggregateVersion')::integer = aggregate_version AND payload->>'eventType' = event_type
 AND payload->>'correlationId' = correlation_id AND payload->>'idempotencyKey' = idempotency_key
 AND (payload->>'occurredAt')::timestamptz = occurred_at);
ALTER TABLE clearledger.outbox
 ADD CONSTRAINT outbox_pkey PRIMARY KEY(seq),
 ADD CONSTRAINT outbox_event_id_key UNIQUE(event_id),
 ADD CONSTRAINT outbox_settlement_version_key UNIQUE(settlement_id,aggregate_version),
 ADD CONSTRAINT outbox_event_fk FOREIGN KEY(event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
 ADD CONSTRAINT outbox_settlement_fk FOREIGN KEY(settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
 ADD CONSTRAINT outbox_version_fk FOREIGN KEY(settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE,
 ADD CONSTRAINT outbox_fields CHECK (clearledger.envelope_ok(payload) AND aggregate_version >= 1
 AND clearledger.trimmed(correlation_id,4,128) AND (payload->>'eventId')::uuid = event_id
 AND (payload->>'aggregateId')::uuid = settlement_id AND (payload->>'aggregateVersion')::integer = aggregate_version
 AND payload->>'correlationId' = correlation_id),
 ADD CONSTRAINT outbox_lifecycle CHECK (attempts >= 0
 AND (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))
 AND (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))
 AND (last_error IS NULL OR (published_at IS NULL AND attempts >= 1 AND clearledger.trimmed(last_error,1,2147483647)))
 AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)));
ALTER TABLE clearledger.idempotency_keys
 ADD CONSTRAINT idempotency_keys_pkey PRIMARY KEY(scope,idempotency_key),
 ADD CONSTRAINT idempotency_fields CHECK (
 scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
 AND scope = btrim(scope) AND clearledger.trimmed(idempotency_key,8,128) AND request_hash ~ '^[0-9a-f]{64}$'
 AND jsonb_typeof(response_body) = 'object'
 AND response_body ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
 AND (response_body - ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) = '{}'::jsonb
 AND jsonb_typeof(response_body->'settlementId') = 'string' AND jsonb_typeof(response_body->'eventId') = 'string'
 AND jsonb_typeof(response_body->'version') = 'number' AND (response_body->>'version') ~ '^[1-9][0-9]*$'
 AND response_body->'accepted' = 'true'::jsonb AND response_body->'idempotentReplay' = 'false'::jsonb
 AND split_part(scope,':',2)::uuid = (response_body->>'settlementId')::uuid
 AND ((scope LIKE 'create:%' AND status_code = 201 AND (response_body->>'version')::integer = 1)
 OR (scope LIKE 'entry:%' AND status_code = 202 AND (response_body->>'version')::integer >= 2)));

ALTER TABLE clearledger.settlements ALTER COLUMN entry_count SET DEFAULT 0,
 ALTER COLUMN created_at SET DEFAULT NOW(), ALTER COLUMN updated_at SET DEFAULT NOW();
ALTER TABLE clearledger.events ALTER COLUMN created_at SET DEFAULT NOW();
ALTER TABLE clearledger.outbox ALTER COLUMN created_at SET DEFAULT NOW(), ALTER COLUMN attempts SET DEFAULT 0;
ALTER TABLE clearledger.idempotency_keys ALTER COLUMN created_at SET DEFAULT NOW();

CREATE OR REPLACE FUNCTION clearledger.settlement_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'settlements are append-only' USING ERRCODE='23514'; END IF;
 NEW.last_memo := COALESCE(NEW.last_memo,OLD.last_memo);
 IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
 IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
 OR NEW.version <> OLD.version+1 OR NEW.entry_count <> OLD.entry_count+1
 OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id OR NEW.updated_at <= OLD.updated_at
 OR NOT clearledger.transition_ok(OLD.current_status,NEW.current_status)
 THEN RAISE EXCEPTION 'invalid settlement transition' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.event_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements%ROWTYPE; prev clearledger.events%ROWTYPE; d JSONB; memo TEXT; expected INTEGER;
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append-only' USING ERRCODE='23514'; END IF;
 IF NOT clearledger.envelope_ok(NEW.payload) THEN RAISE EXCEPTION 'invalid event envelope' USING ERRCODE='23514'; END IF;
 SELECT * INTO s FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing settlement' USING ERRCODE='23503'; END IF;
 SELECT COALESCE(MAX(aggregate_version),0)+1 INTO expected FROM clearledger.events WHERE settlement_id=NEW.settlement_id;
 d := NEW.payload->'data';
 SELECT payload->'data'->>'memo' INTO memo FROM clearledger.events WHERE settlement_id=NEW.settlement_id
 AND payload->'data'->>'memo' IS NOT NULL ORDER BY aggregate_version DESC LIMIT 1;
 memo := COALESCE(d->>'memo',memo);
 IF NEW.aggregate_version <> expected OR NEW.aggregate_version <> s.version
 OR ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',memo)
 IS DISTINCT FROM ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_memo)
 OR (d->>'entryId')::uuid IS DISTINCT FROM s.last_entry_id OR NEW.occurred_at <> s.updated_at
 OR (NEW.aggregate_version=1 AND NEW.occurred_at <> s.created_at)
 THEN RAISE EXCEPTION 'event does not match aggregate' USING ERRCODE='23514'; END IF;
 IF NEW.aggregate_version >= 2 THEN
  SELECT * INTO prev FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND aggregate_version=NEW.aggregate_version-1;
  IF NEW.occurred_at <= prev.occurred_at OR NOT clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status') THEN
   RAISE EXCEPTION 'invalid event transition' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE e clearledger.events%ROWTYPE; expected INTEGER;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'outbox is append-only' USING ERRCODE='23514'; END IF;
 IF TG_OP='INSERT' THEN
  PERFORM 1 FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
  SELECT * INTO e FROM clearledger.events WHERE event_id=NEW.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'missing event' USING ERRCODE='23503'; END IF;
  SELECT COALESCE(MAX(aggregate_version),0)+1 INTO expected FROM clearledger.outbox WHERE settlement_id=NEW.settlement_id;
  IF ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload)
  IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload)
  OR NEW.aggregate_version <> expected THEN RAISE EXCEPTION 'outbox must mirror event' USING ERRCODE='23514'; END IF;
 ELSE
  IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at)
  IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
  OR NEW.attempts < OLD.attempts
  OR (OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL))
  OR (OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error))
  OR (OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at)
  THEN RAISE EXCEPTION 'invalid outbox lifecycle' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'idempotency records are append-only' USING ERRCODE='23514'; END IF;
 IF NOT EXISTS (SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o ON o.event_id=e.event_id
 WHERE e.event_id=(NEW.response_body->>'eventId')::uuid AND e.settlement_id=(NEW.response_body->>'settlementId')::uuid
 AND e.aggregate_version=(NEW.response_body->>'version')::integer AND e.idempotency_key=NEW.idempotency_key)
 THEN RAISE EXCEPTION 'idempotency response lacks committed event and outbox' USING ERRCODE='23503'; END IF;
 RETURN NEW;
END $$;
DO $$ DECLARE r RECORD; BEGIN
 FOR r IN SELECT tgrelid::regclass AS t,tgname FROM pg_trigger WHERE NOT tgisinternal
 AND tgrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass)
 LOOP EXECUTE format('DROP TRIGGER %I ON %s',r.tgname,r.t); END LOOP;
END $$;
CREATE TRIGGER trg_clearledger_settlements BEFORE UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
CREATE TRIGGER trg_clearledger_events BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
CREATE TRIGGER trg_clearledger_outbox BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
CREATE TRIGGER trg_clearledger_idempotency BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
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
CREATE UNIQUE INDEX idx_clearledger_entry_id ON clearledger.events(settlement_id,((payload->'data'->>'entryId')::uuid)) WHERE event_type='LedgerEntryRecorded';
COMMIT;
