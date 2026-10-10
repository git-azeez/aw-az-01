-- Applied atomically. Locks follow the API's aggregate -> event -> outbox order.
BEGIN;
SET LOCAL lock_timeout = '45s';
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE TABLE IF NOT EXISTS clearledger.settlements (
  settlement_id UUID NOT NULL, account_id TEXT NOT NULL, reference TEXT NOT NULL,
  debit_party TEXT NOT NULL, credit_party TEXT NOT NULL, current_status TEXT NOT NULL,
  current_stage TEXT NOT NULL, last_entry_id UUID, last_memo TEXT, version INTEGER NOT NULL,
  entry_count INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS clearledger.events (
  seq BIGSERIAL NOT NULL, event_id UUID NOT NULL, settlement_id UUID NOT NULL,
  aggregate_version INTEGER NOT NULL, event_type TEXT NOT NULL, correlation_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL, occurred_at TIMESTAMPTZ NOT NULL, payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS clearledger.outbox (
  seq BIGSERIAL NOT NULL, event_id UUID NOT NULL, settlement_id UUID NOT NULL,
  aggregate_version INTEGER NOT NULL, correlation_id TEXT NOT NULL, payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), published_at TIMESTAMPTZ,
  archived_at TIMESTAMPTZ, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT
);
CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
  scope TEXT NOT NULL, idempotency_key TEXT NOT NULL, request_hash TEXT NOT NULL,
  status_code INTEGER NOT NULL, response_body JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox,
  clearledger.idempotency_keys IN ACCESS EXCLUSIVE MODE;

CREATE OR REPLACE FUNCTION clearledger.canonical(s TEXT, lo INTEGER, hi INTEGER)
RETURNS BOOLEAN LANGUAGE SQL IMMUTABLE AS $$
  SELECT coalesce(s = btrim(s) AND length(s) BETWEEN lo AND hi, false)
$$;
CREATE OR REPLACE FUNCTION clearledger.status_rank(s TEXT)
RETURNS INTEGER LANGUAGE SQL IMMUTABLE AS $$
  SELECT CASE s WHEN 'INITIATED' THEN 0 WHEN 'VALIDATED' THEN 1 WHEN 'RESERVED' THEN 2
    WHEN 'CLEARED' THEN 3 WHEN 'SETTLED' THEN 4 WHEN 'RECONCILED' THEN 5 ELSE -1 END
$$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN LANGUAGE SQL IMMUTABLE AS $$
  SELECT coalesce(old_status <> 'RECONCILED' AND CASE WHEN old_status = 'DISPUTED'
    THEN new_status IN ('DISPUTED','RECONCILED') ELSE new_status = 'DISPUTED' OR
    clearledger.status_rank(new_status) >= clearledger.status_rank(old_status) END, false)
$$;
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d JSONB; v INTEGER; k TEXT; x UUID; ts TIMESTAMPTZ;
BEGIN
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY[
    'schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
    'occurredAt','correlationId','idempotencyKey','data'] OR
    p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion',
    'occurredAt','correlationId','idempotencyKey','data'] <> '{}'::jsonb THEN RETURN false; END IF;
  FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
    'occurredAt','correlationId','idempotencyKey'] LOOP
    IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
  END LOOP;
  IF p->>'schemaVersion' <> '1.0' OR p->>'aggregateType' <> 'settlement' OR
    jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number' OR
    (p->>'aggregateVersion') !~ '^[1-9][0-9]*$' OR
    NOT clearledger.canonical(p->>'correlationId',4,128) OR
    NOT clearledger.canonical(p->>'idempotencyKey',8,128) THEN RETURN false; END IF;
  IF p->>'eventId' !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' OR
     p->>'aggregateId' !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' OR
     p->>'occurredAt' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$'
     THEN RETURN false; END IF;
  x := (p->>'eventId')::uuid; x := (p->>'aggregateId')::uuid;
  ts := (p->>'occurredAt')::timestamptz; v := (p->>'aggregateVersion')::integer;
  d := p->'data';
  IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY[
    'kind','accountId','reference','debitParty','creditParty','status','clearingStage'] OR
    d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo']
    <> '{}'::jsonb THEN RETURN false; END IF;
  FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
    IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
  END LOOP;
  IF NOT clearledger.canonical(d->>'accountId',3,64) OR NOT clearledger.canonical(d->>'reference',3,64)
    OR NOT clearledger.canonical(d->>'debitParty',2,64) OR NOT clearledger.canonical(d->>'creditParty',2,64)
    OR d->>'debitParty' = d->>'creditParty' OR NOT clearledger.canonical(d->>'clearingStage',2,64)
    OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')
    THEN RETURN false; END IF;
  IF d ? 'memo' AND d->'memo' <> 'null'::jsonb AND
    (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.canonical(d->>'memo',1,256)) THEN RETURN false; END IF;
  IF d ? 'entryId' AND d->'entryId' <> 'null'::jsonb THEN
    IF jsonb_typeof(d->'entryId') <> 'string' OR d->>'entryId' !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
      THEN RETURN false; END IF;
    x := (d->>'entryId')::uuid;
  END IF;
  RETURN coalesce(CASE WHEN v = 1 THEN p->>'eventType' = 'SettlementInitiated'
    AND d->>'kind' = 'settlementInitiated' AND d->>'status' = 'INITIATED'
    AND d->>'clearingStage' = 'INITIATED@' || (d->>'debitParty') AND d->>'entryId' IS NULL
    AND d->>'memo' = 'Settlement initiated'
    ELSE p->>'eventType' = 'LedgerEntryRecorded' AND d->>'kind' = 'ledgerEntryRecorded'
    AND d->>'status' <> 'INITIATED' AND d->>'entryId' IS NOT NULL END, false);
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

-- Reinstall canonical constraints, including those removed or weakened out-of-band.
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT conrelid::regclass AS tbl, conname FROM pg_constraint
    WHERE connamespace = 'clearledger'::regnamespace AND conrelid IN
      ('clearledger.settlements'::regclass,'clearledger.events'::regclass,
       'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass)
    ORDER BY CASE contype WHEN 'f' THEN 0 ELSE 1 END
  LOOP EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I CASCADE',r.tbl,r.conname); END LOOP;
  FOR r IN SELECT table_name,column_name FROM information_schema.columns
    WHERE table_schema='clearledger' AND table_name IN ('settlements','events','outbox','idempotency_keys')
    AND column_name NOT IN ('last_entry_id','last_memo','published_at','archived_at','last_error')
  LOOP EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET NOT NULL',r.table_name,r.column_name); END LOOP;
END $$;
ALTER TABLE clearledger.settlements
  ADD PRIMARY KEY (settlement_id),
  ADD CONSTRAINT settlements_values CHECK (
    clearledger.canonical(account_id,3,64) AND clearledger.canonical(reference,3,64)
    AND clearledger.canonical(debit_party,2,64) AND clearledger.canonical(credit_party,2,64)
    AND debit_party <> credit_party AND clearledger.canonical(current_stage,2,64)
    AND (last_memo IS NULL OR clearledger.canonical(last_memo,1,256))
    AND current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED')
    AND version >= 1 AND entry_count = version - 1
    AND CASE WHEN version = 1 THEN current_status = 'INITIATED'
      AND current_stage = 'INITIATED@' || debit_party AND last_entry_id IS NULL
      AND last_memo IS NOT DISTINCT FROM 'Settlement initiated' AND updated_at = created_at
      ELSE current_status <> 'INITIATED' AND last_entry_id IS NOT NULL AND updated_at > created_at END
  );
ALTER TABLE clearledger.events
  ADD PRIMARY KEY (seq), ADD UNIQUE (event_id), ADD UNIQUE (settlement_id,aggregate_version),
  ADD UNIQUE (settlement_id,idempotency_key),
  ADD FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
  ADD CONSTRAINT events_envelope CHECK (
    clearledger.envelope_ok(payload) AND aggregate_version >= 1
    AND clearledger.canonical(correlation_id,4,128) AND clearledger.canonical(idempotency_key,8,128)
    AND event_id = (payload->>'eventId')::uuid AND settlement_id = (payload->>'aggregateId')::uuid
    AND aggregate_version = (payload->>'aggregateVersion')::integer AND event_type = payload->>'eventType'
    AND correlation_id = payload->>'correlationId' AND idempotency_key = payload->>'idempotencyKey'
    AND occurred_at = (payload->>'occurredAt')::timestamptz
  );
ALTER TABLE clearledger.outbox
  ADD PRIMARY KEY (seq), ADD UNIQUE (event_id), ADD UNIQUE (settlement_id,aggregate_version),
  ADD FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
  ADD FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
  ADD FOREIGN KEY (settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE,
  ADD CONSTRAINT outbox_envelope CHECK (clearledger.envelope_ok(payload)
    AND clearledger.canonical(correlation_id,4,128) AND event_id = (payload->>'eventId')::uuid
    AND settlement_id = (payload->>'aggregateId')::uuid
    AND aggregate_version = (payload->>'aggregateVersion')::integer AND correlation_id = payload->>'correlationId'),
  ADD CONSTRAINT outbox_lifecycle CHECK (attempts >= 0
    AND (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))
    AND (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))
    AND (last_error IS NULL OR (published_at IS NULL AND attempts >= 1 AND
      last_error = btrim(last_error) AND length(last_error) > 0))
    AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)));
ALTER TABLE clearledger.idempotency_keys
  ADD PRIMARY KEY (scope,idempotency_key),
  ADD CONSTRAINT idempotency_values CHECK (
    scope ~ '^(create|entry):[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
    AND clearledger.canonical(idempotency_key,8,128) AND request_hash ~ '^[0-9a-f]{64}$'
    AND jsonb_typeof(response_body) = 'object'
    AND response_body ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']
    AND response_body - ARRAY['settlementId','eventId','version','accepted','idempotentReplay'] = '{}'::jsonb
    AND response_body->'accepted' = 'true'::jsonb AND response_body->'idempotentReplay' = 'false'::jsonb
    AND jsonb_typeof(response_body->'settlementId') = 'string'
    AND jsonb_typeof(response_body->'eventId') = 'string'
    AND (response_body->>'eventId') ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
    AND jsonb_typeof(response_body->'version') = 'number' AND response_body->>'version' ~ '^[1-9][0-9]*$'
    AND split_part(scope,':',2) = response_body->>'settlementId'
    AND CASE WHEN scope LIKE 'create:%' THEN status_code = 201 AND (response_body->>'version')::integer = 1
      ELSE status_code = 202 AND (response_body->>'version')::integer >= 2 END
  );

CREATE OR REPLACE FUNCTION clearledger.settlement_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'settlements are append only' USING ERRCODE='23514'; END IF;
  IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at)
    IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
    OR NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1
    OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id OR NEW.updated_at <= OLD.updated_at
    OR NOT clearledger.transition_ok(OLD.current_status,NEW.current_status)
    THEN RAISE EXCEPTION 'invalid settlement transition' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.event_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements; prev clearledger.events; d JSONB; max_v INTEGER;
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'events are append only' USING ERRCODE='23514'; END IF;
  IF NOT clearledger.envelope_ok(NEW.payload) THEN RAISE EXCEPTION 'invalid envelope' USING ERRCODE='23514'; END IF;
  SELECT * INTO s FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'missing settlement' USING ERRCODE='23503'; END IF;
  SELECT coalesce(max(aggregate_version),0) INTO max_v FROM clearledger.events WHERE settlement_id=NEW.settlement_id;
  d := NEW.payload->'data';
  IF NEW.aggregate_version <> max_v + 1 OR
    ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_entry_id,s.last_memo,s.version,s.updated_at)
    IS DISTINCT FROM ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',
      (d->>'entryId')::uuid,d->>'memo',NEW.aggregate_version,NEW.occurred_at)
    OR (NEW.aggregate_version=1 AND NEW.occurred_at <> s.created_at)
    THEN RAISE EXCEPTION 'event must mirror current aggregate and be contiguous' USING ERRCODE='23514'; END IF;
  IF NEW.aggregate_version >= 2 THEN
    SELECT * INTO prev FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND aggregate_version=NEW.aggregate_version-1;
    IF NEW.occurred_at <= prev.occurred_at OR NOT clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status')
      OR EXISTS (SELECT 1 FROM clearledger.events WHERE settlement_id=NEW.settlement_id AND payload->'data'->>'entryId'=d->>'entryId')
      THEN RAISE EXCEPTION 'invalid ledger progression or reused entry' USING ERRCODE='23514'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.outbox_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE e clearledger.events; max_v INTEGER;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'outbox is append only' USING ERRCODE='23514'; END IF;
  IF TG_OP = 'INSERT' THEN
    PERFORM 1 FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
    SELECT * INTO e FROM clearledger.events WHERE event_id=NEW.event_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'missing event' USING ERRCODE='23503'; END IF;
    SELECT coalesce(max(aggregate_version),0) INTO max_v FROM clearledger.outbox WHERE settlement_id=NEW.settlement_id;
    IF NEW.aggregate_version <> max_v + 1 OR ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload)
      IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload)
      THEN RAISE EXCEPTION 'outbox must mirror event and be contiguous' USING ERRCODE='23514'; END IF;
  ELSE
    IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at)
      IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
      OR NEW.attempts < OLD.attempts
      OR (OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts <= OLD.attempts OR NEW.archived_at IS NOT NULL))
      OR (OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND
        ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error))
      OR (OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at <> OLD.archived_at)
      THEN RAISE EXCEPTION 'invalid outbox mutation' USING ERRCODE='23514'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.idempotency_guard()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'idempotency keys are append only' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS (SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o USING(event_id)
    WHERE e.event_id=(NEW.response_body->>'eventId')::uuid
      AND e.settlement_id=(NEW.response_body->>'settlementId')::uuid
      AND e.aggregate_version=(NEW.response_body->>'version')::integer AND e.idempotency_key=NEW.idempotency_key)
    THEN RAISE EXCEPTION 'idempotency response must reference committed event and outbox' USING ERRCODE='23503'; END IF;
  RETURN NEW;
EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'invalid idempotency response' USING ERRCODE='23514';
END $$;
-- Remove unexpected user triggers as well as replacing missing/modified canonical ones.
DO $$ DECLARE r RECORD; BEGIN
  FOR r IN SELECT tgrelid::regclass AS tbl,tgname FROM pg_trigger WHERE NOT tgisinternal
    AND tgrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass)
  LOOP EXECUTE format('DROP TRIGGER %I ON %s',r.tgname,r.tbl); END LOOP;
END $$;
CREATE TRIGGER settlement_guard BEFORE UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.settlement_guard();
CREATE TRIGGER event_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.event_guard();
CREATE TRIGGER outbox_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.outbox_guard();
CREATE TRIGGER idempotency_guard BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.idempotency_guard();
ALTER TABLE clearledger.settlements ENABLE TRIGGER ALL;
ALTER TABLE clearledger.events ENABLE TRIGGER ALL;
ALTER TABLE clearledger.outbox ENABLE TRIGGER ALL;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER ALL;
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
