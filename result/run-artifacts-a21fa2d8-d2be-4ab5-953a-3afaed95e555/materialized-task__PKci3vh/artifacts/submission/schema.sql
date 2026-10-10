\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(736214901);
CREATE SCHEMA IF NOT EXISTS clearledger;
CREATE OR REPLACE FUNCTION clearledger.canonical(s text, lo integer, hi integer)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT s IS NOT NULL AND s=btrim(s) AND length(s) BETWEEN lo AND hi $$;
CREATE OR REPLACE FUNCTION clearledger.uuid_text(s text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(s ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',false) $$;
CREATE OR REPLACE FUNCTION clearledger.transition_ok(old_status text, new_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
 SELECT COALESCE(old_status <> 'RECONCILED' AND CASE WHEN old_status='DISPUTED'
 THEN new_status IN ('DISPUTED','RECONCILED') ELSE new_status='DISPUTED' OR
 array_position(ARRAY['INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED'],new_status)
 >= array_position(ARRAY['INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED'],old_status) END,false)
$$;
CREATE OR REPLACE FUNCTION clearledger.envelope_ok(p jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d jsonb; v integer; k text;
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'] OR
    p - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','occurredAt','correlationId','idempotencyKey'] LOOP
   IF jsonb_typeof(p->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF p->>'schemaVersion'<>'1.0' OR p->>'aggregateType'<>'settlement' OR jsonb_typeof(p->'aggregateVersion') IS DISTINCT FROM 'number' OR (p->>'aggregateVersion') !~ '^[1-9][0-9]*$' THEN RETURN false; END IF;
 PERFORM (p->>'eventId')::uuid, (p->>'aggregateId')::uuid, (p->>'occurredAt')::timestamptz;
 IF NOT clearledger.uuid_text(p->>'eventId') OR NOT clearledger.uuid_text(p->>'aggregateId') THEN RETURN false; END IF;
 IF p->>'occurredAt' !~ '^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$' THEN RETURN false; END IF;
 IF NOT clearledger.canonical(p->>'correlationId',4,128) OR NOT clearledger.canonical(p->>'idempotencyKey',8,128) THEN RETURN false; END IF;
 v := (p->>'aggregateVersion')::integer; d := p->'data';
 IF jsonb_typeof(d) IS DISTINCT FROM 'object' OR NOT d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] OR
 d - ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage','entryId','memo'] <> '{}'::jsonb THEN RETURN false; END IF;
 FOREACH k IN ARRAY ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage'] LOOP
   IF jsonb_typeof(d->k) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
 END LOOP;
 IF NOT clearledger.canonical(d->>'accountId',3,64) OR NOT clearledger.canonical(d->>'reference',3,64)
 OR NOT clearledger.canonical(d->>'debitParty',2,64) OR NOT clearledger.canonical(d->>'creditParty',2,64)
 OR d->>'debitParty'=d->>'creditParty' OR NOT clearledger.canonical(d->>'clearingStage',2,64)
 OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN RETURN false; END IF;
 IF d->>'memo' IS NOT NULL AND (jsonb_typeof(d->'memo')<>'string' OR NOT clearledger.canonical(d->>'memo',1,256)) THEN RETURN false; END IF;
 IF d->>'entryId' IS NOT NULL THEN
   IF jsonb_typeof(d->'entryId')<>'string' OR NOT clearledger.uuid_text(d->>'entryId') THEN RETURN false; END IF;
   PERFORM (d->>'entryId')::uuid;
 END IF;
 IF v=1 THEN RETURN p->>'eventType'='SettlementInitiated' AND d->>'kind'='settlementInitiated'
   AND d->>'status'='INITIATED' AND d->>'clearingStage'='INITIATED@'||(d->>'debitParty')
   AND d->>'entryId' IS NULL AND COALESCE(d->>'memo'='Settlement initiated',false);
 END IF;
 RETURN p->>'eventType'='LedgerEntryRecorded' AND d->>'kind'='ledgerEntryRecorded' AND d->>'status'<>'INITIATED' AND d->>'entryId' IS NOT NULL;
EXCEPTION WHEN OTHERS THEN RETURN false;
END $$;

CREATE TABLE IF NOT EXISTS clearledger.settlements (
 settlement_id uuid NOT NULL, account_id text NOT NULL, reference text NOT NULL,
 debit_party text NOT NULL, credit_party text NOT NULL, current_status text NOT NULL,
 current_stage text NOT NULL, last_entry_id uuid, last_memo text, version integer NOT NULL,
 entry_count integer NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
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
-- Named constraints can be restored after an operator removes them, without rebuilding tables.
CREATE OR REPLACE FUNCTION pg_temp.ensure_constraint(t text,n text,definition text)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid=('clearledger.'||t)::regclass AND conname=n) THEN
 EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s',t,n,definition); END IF;
END $$;
SELECT pg_temp.ensure_constraint(t,n,d) FROM (VALUES
 ('settlements','settlements_pkey','PRIMARY KEY (settlement_id)'),
 ('settlements','settlements_header_check',$c$CHECK (clearledger.canonical(account_id,3,64) AND clearledger.canonical(reference,3,64) AND clearledger.canonical(debit_party,2,64) AND clearledger.canonical(credit_party,2,64) AND debit_party<>credit_party AND clearledger.canonical(current_stage,2,64) AND (last_memo IS NULL OR clearledger.canonical(last_memo,1,256)) AND current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$),
 ('settlements','settlements_lifecycle_check',$c$CHECK (version>=1 AND ((version=1 AND entry_count=0 AND current_status='INITIATED' AND current_stage='INITIATED@'||debit_party AND last_entry_id IS NULL AND last_memo IS NOT NULL AND last_memo='Settlement initiated' AND updated_at=created_at) OR (version>1 AND entry_count=version-1 AND current_status<>'INITIATED' AND last_entry_id IS NOT NULL AND updated_at>created_at)))$c$),
 ('events','events_pkey','PRIMARY KEY (seq)'),
 ('events','events_event_id_key','UNIQUE (event_id)'),
 ('events','events_settlement_version_key','UNIQUE (settlement_id,aggregate_version)'),
 ('events','events_settlement_idempotency_key','UNIQUE (settlement_id,idempotency_key)'),
 ('events','events_settlement_id_fkey','FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
 ('events','events_envelope_check',$c$CHECK (clearledger.envelope_ok(payload) AND (payload->>'eventId')::uuid=event_id AND (payload->>'aggregateId')::uuid=settlement_id AND (payload->>'aggregateVersion')::integer=aggregate_version AND payload->>'eventType'=event_type AND payload->>'correlationId'=correlation_id AND payload->>'idempotencyKey'=idempotency_key AND (payload->>'occurredAt')::timestamptz=occurred_at AND clearledger.canonical(correlation_id,4,128) AND clearledger.canonical(idempotency_key,8,128))$c$),
 ('outbox','outbox_pkey','PRIMARY KEY (seq)'),
 ('outbox','outbox_event_id_key','UNIQUE (event_id)'),
 ('outbox','outbox_settlement_version_key','UNIQUE (settlement_id,aggregate_version)'),
 ('outbox','outbox_event_id_fkey','FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE'),
 ('outbox','outbox_settlement_id_fkey','FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
 ('outbox','outbox_settlement_version_fkey','FOREIGN KEY (settlement_id,aggregate_version) REFERENCES clearledger.events(settlement_id,aggregate_version) ON DELETE CASCADE'),
 ('outbox','outbox_envelope_check',$c$CHECK (clearledger.envelope_ok(payload) AND clearledger.canonical(correlation_id,4,128))$c$),
 ('outbox','outbox_delivery_check',$c$CHECK (attempts>=0 AND (attempts<>0 OR (published_at IS NULL AND last_error IS NULL)) AND (published_at IS NULL OR (attempts>=1 AND last_error IS NULL AND published_at>=created_at)) AND (last_error IS NULL OR (published_at IS NULL AND attempts>=1 AND clearledger.canonical(last_error,1,2147483647))) AND (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at>=published_at)))$c$),
 ('idempotency_keys','idempotency_keys_pkey','PRIMARY KEY (scope,idempotency_key)'),
 ('idempotency_keys','idempotency_keys_uuid_check',$c$CHECK (clearledger.uuid_text(response_body->>'eventId') AND clearledger.uuid_text(response_body->>'settlementId'))$c$),
 ('idempotency_keys','idempotency_keys_shape_check',$c$CHECK (scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' AND clearledger.canonical(idempotency_key,8,128) AND request_hash ~ '^[0-9a-f]{64}$' AND jsonb_typeof(response_body)='object' AND response_body ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay'] AND response_body - ARRAY['settlementId','eventId','version','accepted','idempotentReplay']='{}'::jsonb AND jsonb_typeof(response_body->'settlementId')='string' AND jsonb_typeof(response_body->'eventId')='string' AND jsonb_typeof(response_body->'version')='number' AND response_body->>'version' ~ '^[1-9][0-9]*$' AND response_body->'accepted'='true'::jsonb AND response_body->'idempotentReplay'='false'::jsonb AND split_part(scope,':',2)::uuid=(response_body->>'settlementId')::uuid AND ((scope LIKE 'create:%' AND status_code=201 AND (response_body->>'version')::integer=1) OR (scope LIKE 'entry:%' AND status_code=202 AND (response_body->>'version')::integer>=2)))$c$)
) AS constraints(t,n,d);

CREATE OR REPLACE FUNCTION clearledger.guard_settlement() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'settlements are append-only'; END IF;
 IF ROW(NEW.settlement_id,NEW.account_id,NEW.reference,NEW.debit_party,NEW.credit_party,NEW.created_at) IS DISTINCT FROM ROW(OLD.settlement_id,OLD.account_id,OLD.reference,OLD.debit_party,OLD.credit_party,OLD.created_at)
 OR NEW.version<>OLD.version+1 OR NEW.entry_count<>OLD.entry_count+1 OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id OR NEW.updated_at<=OLD.updated_at
 OR NOT clearledger.transition_ok(OLD.current_status,NEW.current_status) THEN RAISE EXCEPTION 'invalid settlement transition'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.guard_event() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s clearledger.settlements%ROWTYPE; prev clearledger.events%ROWTYPE; d jsonb;
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'events are append-only'; END IF;
 IF NOT clearledger.envelope_ok(NEW.payload) THEN RAISE EXCEPTION 'invalid envelope'; END IF;
 SELECT * INTO s FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'missing parent settlement' USING ERRCODE='23503'; END IF;
 SELECT * INTO prev FROM clearledger.events WHERE settlement_id=NEW.settlement_id ORDER BY aggregate_version DESC LIMIT 1;
 IF NEW.aggregate_version<>COALESCE(prev.aggregate_version,0)+1 THEN RAISE EXCEPTION 'noncontiguous event'; END IF;
 d:=NEW.payload->'data';
 IF ROW(d->>'accountId',d->>'reference',d->>'debitParty',d->>'creditParty',d->>'status',d->>'clearingStage',(d->>'entryId')::uuid,d->>'memo',NEW.aggregate_version,NEW.occurred_at)
 IS DISTINCT FROM ROW(s.account_id,s.reference,s.debit_party,s.credit_party,s.current_status,s.current_stage,s.last_entry_id,s.last_memo,s.version,s.updated_at)
 OR (NEW.aggregate_version=1 AND NEW.occurred_at<>s.created_at) THEN RAISE EXCEPTION 'event does not match aggregate'; END IF;
 IF NEW.aggregate_version>=2 AND (NEW.occurred_at<=prev.occurred_at OR NOT clearledger.transition_ok(prev.payload->'data'->>'status',d->>'status')) THEN RAISE EXCEPTION 'invalid event transition'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.guard_outbox() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e clearledger.events%ROWTYPE; v integer;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'outbox is append-only'; END IF;
 IF TG_OP='INSERT' THEN
   PERFORM 1 FROM clearledger.settlements WHERE settlement_id=NEW.settlement_id FOR UPDATE;
   SELECT * INTO e FROM clearledger.events WHERE event_id=NEW.event_id;
   IF NOT FOUND OR ROW(NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload) IS DISTINCT FROM ROW(e.settlement_id,e.aggregate_version,e.correlation_id,e.payload) THEN RAISE EXCEPTION 'outbox must mirror event'; END IF;
   SELECT COALESCE(max(aggregate_version),0)+1 INTO v FROM clearledger.outbox WHERE settlement_id=NEW.settlement_id;
   IF NEW.aggregate_version<>v THEN RAISE EXCEPTION 'noncontiguous outbox'; END IF;
 ELSE
   IF ROW(NEW.seq,NEW.event_id,NEW.settlement_id,NEW.aggregate_version,NEW.correlation_id,NEW.payload,NEW.created_at) IS DISTINCT FROM ROW(OLD.seq,OLD.event_id,OLD.settlement_id,OLD.aggregate_version,OLD.correlation_id,OLD.payload,OLD.created_at)
   OR NEW.attempts<OLD.attempts THEN RAISE EXCEPTION 'immutable outbox envelope'; END IF;
   IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL AND (NEW.attempts<=OLD.attempts OR NEW.archived_at IS NOT NULL) THEN RAISE EXCEPTION 'invalid publish'; END IF;
   IF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL AND ROW(NEW.published_at,NEW.attempts,NEW.last_error) IS DISTINCT FROM ROW(OLD.published_at,OLD.attempts,OLD.last_error) THEN RAISE EXCEPTION 'published delivery is immutable'; END IF;
   IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND OLD.archived_at<>NEW.archived_at THEN RAISE EXCEPTION 'archival timestamp is immutable'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION clearledger.guard_idempotency() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'idempotency records are append-only'; END IF;
 IF NOT EXISTS (SELECT 1 FROM clearledger.events e JOIN clearledger.outbox o ON o.event_id=e.event_id
 WHERE e.event_id=(NEW.response_body->>'eventId')::uuid AND e.settlement_id=(NEW.response_body->>'settlementId')::uuid
 AND e.aggregate_version=(NEW.response_body->>'version')::integer AND e.idempotency_key=NEW.idempotency_key) THEN RAISE EXCEPTION 'idempotency response requires committed event and outbox'; END IF;
 RETURN NEW;
END $$;
CREATE OR REPLACE TRIGGER guard_settlement BEFORE UPDATE OR DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.guard_settlement();
CREATE OR REPLACE TRIGGER guard_event BEFORE INSERT OR UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.guard_event();
CREATE OR REPLACE TRIGGER guard_outbox BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.guard_outbox();
CREATE OR REPLACE TRIGGER guard_idempotency BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.guard_idempotency();
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished ON clearledger.outbox(seq) WHERE published_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived ON clearledger.outbox(seq) WHERE published_at IS NOT NULL AND archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version ON clearledger.events(settlement_id,aggregate_version);
CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_event ON clearledger.idempotency_keys (((response_body->>'eventId')::uuid));
CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_version ON clearledger.idempotency_keys (((response_body->>'settlementId')::uuid),((response_body->>'version')::integer));
CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_entry_id ON clearledger.events(settlement_id,((payload->'data'->>'entryId')::uuid)) WHERE event_type='LedgerEntryRecorded';
ALTER TABLE clearledger.settlements ENABLE TRIGGER ALL;
ALTER TABLE clearledger.events ENABLE TRIGGER ALL;
ALTER TABLE clearledger.outbox ENABLE TRIGGER ALL;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER ALL;
COMMIT;
