-- ClearLedger PostgreSQL schema (idempotent; safe to re-run on every deploy).
-- Applied by deploy.sh with: psql -v ON_ERROR_STOP=1 --single-transaction -f schema.sql
SET client_min_messages = warning;
SET lock_timeout = '60s';

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Tables (created if missing, columns / NOT NULL / defaults re-enforced)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS clearledger.settlements (
    settlement_id  UUID        NOT NULL,
    account_id     TEXT        NOT NULL,
    reference      TEXT        NOT NULL,
    debit_party    TEXT        NOT NULL,
    credit_party   TEXT        NOT NULL,
    current_status TEXT        NOT NULL,
    current_stage  TEXT        NOT NULL,
    last_entry_id  UUID        NULL,
    last_memo      TEXT        NOT NULL,
    version        INTEGER     NOT NULL,
    entry_count    INTEGER     NOT NULL DEFAULT 0,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT settlements_pkey PRIMARY KEY (settlement_id)
);

CREATE TABLE IF NOT EXISTS clearledger.events (
    seq               BIGSERIAL   NOT NULL,
    event_id          UUID        NOT NULL,
    settlement_id     UUID        NOT NULL,
    aggregate_version INTEGER     NOT NULL,
    event_type        TEXT        NOT NULL,
    correlation_id    TEXT        NOT NULL,
    idempotency_key   TEXT        NOT NULL,
    occurred_at       TIMESTAMPTZ NOT NULL,
    payload           JSONB       NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT events_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
    seq               BIGSERIAL   NOT NULL,
    event_id          UUID        NOT NULL,
    settlement_id     UUID        NOT NULL,
    aggregate_version INTEGER     NOT NULL,
    correlation_id    TEXT        NOT NULL,
    payload           JSONB       NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at      TIMESTAMPTZ NULL,
    archived_at       TIMESTAMPTZ NULL,
    attempts          INTEGER     NOT NULL DEFAULT 0,
    last_error        TEXT        NULL,
    CONSTRAINT outbox_pkey PRIMARY KEY (seq)
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
    scope           TEXT        NOT NULL,
    idempotency_key TEXT        NOT NULL,
    request_hash    TEXT        NOT NULL,
    status_code     INTEGER     NOT NULL,
    response_body   JSONB       NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT idempotency_keys_pkey PRIMARY KEY (scope, idempotency_key)
);

-- Re-assert columns, nullability and defaults (repairs out-of-band ALTERs).
DO $$
DECLARE
    spec RECORD;
BEGIN
    FOR spec IN
        SELECT * FROM (VALUES
            ('settlements','settlement_id','UUID',true,NULL),
            ('settlements','account_id','TEXT',true,NULL),
            ('settlements','reference','TEXT',true,NULL),
            ('settlements','debit_party','TEXT',true,NULL),
            ('settlements','credit_party','TEXT',true,NULL),
            ('settlements','current_status','TEXT',true,NULL),
            ('settlements','current_stage','TEXT',true,NULL),
            ('settlements','last_entry_id','UUID',false,NULL),
            ('settlements','last_memo','TEXT',true,NULL),
            ('settlements','version','INTEGER',true,NULL),
            ('settlements','entry_count','INTEGER',true,'0'),
            ('settlements','created_at','TIMESTAMPTZ',true,'NOW()'),
            ('settlements','updated_at','TIMESTAMPTZ',true,'NOW()'),
            ('events','event_id','UUID',true,NULL),
            ('events','settlement_id','UUID',true,NULL),
            ('events','aggregate_version','INTEGER',true,NULL),
            ('events','event_type','TEXT',true,NULL),
            ('events','correlation_id','TEXT',true,NULL),
            ('events','idempotency_key','TEXT',true,NULL),
            ('events','occurred_at','TIMESTAMPTZ',true,NULL),
            ('events','payload','JSONB',true,NULL),
            ('events','created_at','TIMESTAMPTZ',true,'NOW()'),
            ('outbox','event_id','UUID',true,NULL),
            ('outbox','settlement_id','UUID',true,NULL),
            ('outbox','aggregate_version','INTEGER',true,NULL),
            ('outbox','correlation_id','TEXT',true,NULL),
            ('outbox','payload','JSONB',true,NULL),
            ('outbox','created_at','TIMESTAMPTZ',true,'NOW()'),
            ('outbox','published_at','TIMESTAMPTZ',false,NULL),
            ('outbox','archived_at','TIMESTAMPTZ',false,NULL),
            ('outbox','attempts','INTEGER',true,'0'),
            ('outbox','last_error','TEXT',false,NULL),
            ('idempotency_keys','scope','TEXT',true,NULL),
            ('idempotency_keys','idempotency_key','TEXT',true,NULL),
            ('idempotency_keys','request_hash','TEXT',true,NULL),
            ('idempotency_keys','status_code','INTEGER',true,NULL),
            ('idempotency_keys','response_body','JSONB',true,NULL),
            ('idempotency_keys','created_at','TIMESTAMPTZ',true,'NOW()')
        ) AS t(tbl, col, typ, nn, dflt)
    LOOP
        EXECUTE format('ALTER TABLE clearledger.%I ADD COLUMN IF NOT EXISTS %I %s', spec.tbl, spec.col, spec.typ);
        IF spec.dflt IS NOT NULL THEN
            EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET DEFAULT %s', spec.tbl, spec.col, spec.dflt);
        ELSE
            EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I DROP DEFAULT', spec.tbl, spec.col);
        END IF;
        IF spec.nn THEN
            EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I SET NOT NULL', spec.tbl, spec.col);
        ELSE
            EXECUTE format('ALTER TABLE clearledger.%I ALTER COLUMN %I DROP NOT NULL', spec.tbl, spec.col);
        END IF;
    END LOOP;
END $$;

-- BIGSERIAL defaults for seq columns.
CREATE SEQUENCE IF NOT EXISTS clearledger.events_seq_seq OWNED BY clearledger.events.seq;
CREATE SEQUENCE IF NOT EXISTS clearledger.outbox_seq_seq OWNED BY clearledger.outbox.seq;
ALTER TABLE clearledger.events ALTER COLUMN seq SET DEFAULT nextval('clearledger.events_seq_seq'::regclass);
ALTER TABLE clearledger.outbox ALTER COLUMN seq SET DEFAULT nextval('clearledger.outbox_seq_seq'::regclass);
ALTER TABLE clearledger.events ALTER COLUMN seq SET NOT NULL;
ALTER TABLE clearledger.outbox ALTER COLUMN seq SET NOT NULL;
DO $$
BEGIN
    PERFORM setval('clearledger.events_seq_seq', GREATEST((SELECT COALESCE(MAX(seq), 0) FROM clearledger.events), (SELECT last_value FROM clearledger.events_seq_seq), 1), true);
    PERFORM setval('clearledger.outbox_seq_seq', GREATEST((SELECT COALESCE(MAX(seq), 0) FROM clearledger.outbox), (SELECT last_value FROM clearledger.outbox_seq_seq), 1), true);
END $$;

-- ---------------------------------------------------------------------------
-- Validation helper functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(v TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT v IS NOT NULL AND v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$$;

CREATE OR REPLACE FUNCTION clearledger.is_canonical_text(v TEXT, min_len INTEGER, max_len INTEGER)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT v IS NOT NULL AND v = btrim(v) AND char_length(v) BETWEEN min_len AND max_len
$$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(s TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE s
        WHEN 'INITIATED'  THEN 0
        WHEN 'VALIDATED'  THEN 1
        WHEN 'RESERVED'   THEN 2
        WHEN 'CLEARED'    THEN 3
        WHEN 'SETTLED'    THEN 4
        WHEN 'RECONCILED' THEN 5
        ELSE NULL
    END
$$;

-- Clearing lifecycle transition rules shared by settlements and events.
CREATE OR REPLACE FUNCTION clearledger.status_transition_allowed(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN old_status IS NULL OR new_status IS NULL THEN false
        WHEN new_status NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN false
        WHEN old_status = 'RECONCILED' THEN false
        WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED','RECONCILED')
        WHEN clearledger.status_rank(old_status) IS NULL THEN false
        WHEN new_status = 'DISPUTED' THEN true
        ELSE clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
    END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_json_int(v JSONB)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT v IS NOT NULL AND jsonb_typeof(v) = 'number' AND v::text ~ '^-?[0-9]+$' AND length(v::text) <= 10
$$;

CREATE OR REPLACE FUNCTION clearledger.try_timestamptz(v TEXT)
RETURNS TIMESTAMPTZ LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF v IS NULL OR v !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?([Zz]|[+-][0-9]{2}:[0-9]{2})$' THEN
        RETURN NULL;
    END IF;
    RETURN v::timestamptz;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END
$$;

-- Strict validation of ClearLedgerDomainEventEnvelope (schemas/events.schema.json)
-- including closed schemas (additionalProperties: false) and version/kind coupling.
CREATE OR REPLACE FUNCTION clearledger.envelope_valid(p JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    d JSONB;
    v INTEGER;
    k TEXT;
BEGIN
    IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;

    -- Envelope: exactly the ten declared properties.
    FOR k IN SELECT jsonb_object_keys(p) LOOP
        IF k NOT IN ('schemaVersion','eventId','eventType','aggregateType','aggregateId',
                     'aggregateVersion','occurredAt','correlationId','idempotencyKey','data') THEN
            RETURN false;
        END IF;
    END LOOP;
    IF NOT (p ?& ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId',
                       'aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) THEN
        RETURN false;
    END IF;

    IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN false; END IF;
    IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'eventId') THEN RETURN false; END IF;
    IF jsonb_typeof(p->'eventType') <> 'string' OR p->>'eventType' NOT IN ('SettlementInitiated','LedgerEntryRecorded') THEN RETURN false; END IF;
    IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN false; END IF;
    IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'aggregateId') THEN RETURN false; END IF;
    IF NOT clearledger.is_json_int(p->'aggregateVersion') THEN RETURN false; END IF;
    v := (p->>'aggregateVersion')::integer;
    IF v < 1 THEN RETURN false; END IF;
    IF jsonb_typeof(p->'occurredAt') <> 'string' OR clearledger.try_timestamptz(p->>'occurredAt') IS NULL THEN RETURN false; END IF;
    IF jsonb_typeof(p->'correlationId') <> 'string' OR NOT clearledger.is_canonical_text(p->>'correlationId', 4, 128) THEN RETURN false; END IF;
    IF jsonb_typeof(p->'idempotencyKey') <> 'string' OR NOT clearledger.is_canonical_text(p->>'idempotencyKey', 8, 128) THEN RETURN false; END IF;

    -- data: closed schema.
    d := p->'data';
    IF jsonb_typeof(d) <> 'object' THEN RETURN false; END IF;
    FOR k IN SELECT jsonb_object_keys(d) LOOP
        IF k NOT IN ('kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo') THEN
            RETURN false;
        END IF;
    END LOOP;
    IF NOT (d ?& ARRAY['kind','accountId','reference','debitParty','creditParty','status','clearingStage']) THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(d->'kind') <> 'string' OR d->>'kind' NOT IN ('settlementInitiated','ledgerEntryRecorded') THEN RETURN false; END IF;
    IF jsonb_typeof(d->'accountId') <> 'string' OR NOT clearledger.is_canonical_text(d->>'accountId', 3, 64) THEN RETURN false; END IF;
    IF jsonb_typeof(d->'reference') <> 'string' OR NOT clearledger.is_canonical_text(d->>'reference', 3, 64) THEN RETURN false; END IF;
    IF jsonb_typeof(d->'debitParty') <> 'string' OR NOT clearledger.is_canonical_text(d->>'debitParty', 2, 64) THEN RETURN false; END IF;
    IF jsonb_typeof(d->'creditParty') <> 'string' OR NOT clearledger.is_canonical_text(d->>'creditParty', 2, 64) THEN RETURN false; END IF;
    IF d->>'debitParty' = d->>'creditParty' THEN RETURN false; END IF;
    IF jsonb_typeof(d->'status') <> 'string'
       OR d->>'status' NOT IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED') THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(d->'clearingStage') <> 'string' OR d->>'clearingStage' <> btrim(d->>'clearingStage') THEN RETURN false; END IF;
    IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null'
       AND (jsonb_typeof(d->'entryId') <> 'string' OR NOT clearledger.is_uuid_text(d->>'entryId')) THEN
        RETURN false;
    END IF;
    IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null'
       AND (jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.is_canonical_text(d->>'memo', 1, 256)) THEN
        RETURN false;
    END IF;

    -- Version / kind / status / entryId coupling.
    IF v = 1 THEN
        IF p->>'eventType' <> 'SettlementInitiated' OR d->>'kind' <> 'settlementInitiated' THEN RETURN false; END IF;
        IF d->>'status' <> 'INITIATED' THEN RETURN false; END IF;
        IF d->>'clearingStage' <> 'INITIATED@' || (d->>'debitParty') THEN RETURN false; END IF;
        IF d->>'entryId' IS NOT NULL THEN RETURN false; END IF;
        IF d->>'memo' IS DISTINCT FROM 'Settlement initiated' THEN RETURN false; END IF;
    ELSE
        IF p->>'eventType' <> 'LedgerEntryRecorded' OR d->>'kind' <> 'ledgerEntryRecorded' THEN RETURN false; END IF;
        IF d->>'status' = 'INITIATED' THEN RETURN false; END IF;
        IF NOT clearledger.is_canonical_text(d->>'clearingStage', 2, 64) THEN RETURN false; END IF;
        IF d->>'entryId' IS NULL THEN RETURN false; END IF;
    END IF;

    RETURN true;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END
$$;

-- Column-to-envelope equality for clearledger.events.
CREATE OR REPLACE FUNCTION clearledger.event_columns_match(
    p JSONB, c_event_id UUID, c_settlement_id UUID, c_version INTEGER, c_event_type TEXT,
    c_correlation_id TEXT, c_idempotency_key TEXT, c_occurred_at TIMESTAMPTZ)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN (p->>'eventId')::uuid = c_event_id
       AND (p->>'aggregateId')::uuid = c_settlement_id
       AND (p->>'aggregateVersion')::integer = c_version
       AND p->>'eventType' = c_event_type
       AND p->>'correlationId' = c_correlation_id
       AND p->>'idempotencyKey' = c_idempotency_key
       AND clearledger.try_timestamptz(p->>'occurredAt') = c_occurred_at;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END
$$;

-- Column-to-envelope equality for clearledger.outbox.
CREATE OR REPLACE FUNCTION clearledger.outbox_columns_match(
    p JSONB, c_event_id UUID, c_settlement_id UUID, c_version INTEGER, c_correlation_id TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN (p->>'eventId')::uuid = c_event_id
       AND (p->>'aggregateId')::uuid = c_settlement_id
       AND (p->>'aggregateVersion')::integer = c_version
       AND p->>'correlationId' = c_correlation_id;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END
$$;

-- Closed-schema WriteAcceptedResponse + scope/status coupling for idempotency_keys.
CREATE OR REPLACE FUNCTION clearledger.idempotency_row_valid(
    c_scope TEXT, c_status INTEGER, b JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    k TEXT;
    v INTEGER;
BEGIN
    IF b IS NULL OR jsonb_typeof(b) <> 'object' THEN RETURN false; END IF;
    FOR k IN SELECT jsonb_object_keys(b) LOOP
        IF k NOT IN ('settlementId','eventId','version','accepted','idempotentReplay') THEN RETURN false; END IF;
    END LOOP;
    IF NOT (b ?& ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) THEN RETURN false; END IF;
    IF jsonb_typeof(b->'settlementId') <> 'string' OR NOT clearledger.is_uuid_text(b->>'settlementId') THEN RETURN false; END IF;
    IF jsonb_typeof(b->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(b->>'eventId') THEN RETURN false; END IF;
    IF NOT clearledger.is_json_int(b->'version') THEN RETURN false; END IF;
    IF b->'accepted' <> 'true'::jsonb THEN RETURN false; END IF;
    IF b->'idempotentReplay' <> 'false'::jsonb THEN RETURN false; END IF;
    v := (b->>'version')::integer;
    IF v < 1 THEN RETURN false; END IF;
    IF c_scope LIKE 'create:%' THEN
        IF c_status <> 201 OR v <> 1 THEN RETURN false; END IF;
    ELSIF c_scope LIKE 'entry:%' THEN
        IF c_status <> 202 OR v < 2 THEN RETURN false; END IF;
    ELSE
        RETURN false;
    END IF;
    IF (substr(c_scope, strpos(c_scope, ':') + 1))::uuid <> (b->>'settlementId')::uuid THEN RETURN false; END IF;
    RETURN true;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END
$$;

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION clearledger.trg_reject_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'clearledger.%: % is not permitted (append-only ledger)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'P0001';
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Omitted memo keeps the previous non-null memo.
    NEW.last_memo := COALESCE(NEW.last_memo, OLD.last_memo);

    IF OLD.current_status = 'RECONCILED' THEN
        RAISE EXCEPTION 'settlement % is RECONCILED (terminal)', OLD.settlement_id USING ERRCODE = 'P0001';
    END IF;
    IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
       OR NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.reference IS DISTINCT FROM OLD.reference
       OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
       OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'settlement header columns are immutable' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
        RAISE EXCEPTION 'settlement version must advance by exactly 1 (% -> %)', OLD.version, NEW.version USING ERRCODE = 'P0001';
    END IF;
    IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
        RAISE EXCEPTION 'settlement entry_count must advance by exactly 1' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
        RAISE EXCEPTION 'settlement update requires a new last_entry_id' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.updated_at IS NULL OR NEW.updated_at <= OLD.updated_at THEN
        RAISE EXCEPTION 'settlement updated_at must strictly increase' USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.status_transition_allowed(OLD.current_status, NEW.current_status) THEN
        RAISE EXCEPTION 'illegal settlement status transition % -> %', OLD.current_status, NEW.current_status USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    s        clearledger.settlements%ROWTYPE;
    prev     clearledger.events%ROWTYPE;
    max_v    INTEGER;
    d        JSONB;
    new_memo TEXT;
    exp_memo TEXT;
BEGIN
    IF NOT clearledger.envelope_valid(NEW.payload) THEN
        RAISE EXCEPTION 'event payload does not conform to ClearLedgerDomainEventEnvelope' USING ERRCODE = '23514';
    END IF;
    IF NOT clearledger.event_columns_match(NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version,
            NEW.event_type, NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
        RAISE EXCEPTION 'event columns do not match envelope' USING ERRCODE = '23514';
    END IF;
    d := NEW.payload->'data';

    -- Contiguous per-settlement versions starting at 1.
    SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v
      FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version <> max_v + 1 THEN
        RAISE EXCEPTION 'event version % is not contiguous (expected %)', NEW.aggregate_version, max_v + 1 USING ERRCODE = 'P0001';
    END IF;

    -- entryId unique per settlement.
    IF NEW.event_type = 'LedgerEntryRecorded' AND EXISTS (
        SELECT 1 FROM clearledger.events
         WHERE settlement_id = NEW.settlement_id
           AND event_type = 'LedgerEntryRecorded'
           AND payload->'data'->>'entryId' = d->>'entryId') THEN
        RAISE EXCEPTION 'entryId % already recorded for settlement', d->>'entryId' USING ERRCODE = '23505';
    END IF;

    -- Must mirror the parent aggregate row.
    SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'settlement % does not exist', NEW.settlement_id USING ERRCODE = '23503';
    END IF;
    IF d->>'accountId' IS DISTINCT FROM s.account_id
       OR d->>'reference' IS DISTINCT FROM s.reference
       OR d->>'debitParty' IS DISTINCT FROM s.debit_party
       OR d->>'creditParty' IS DISTINCT FROM s.credit_party
       OR d->>'status' IS DISTINCT FROM s.current_status
       OR d->>'clearingStage' IS DISTINCT FROM s.current_stage
       OR (d->>'entryId')::uuid IS DISTINCT FROM s.last_entry_id
       OR NEW.aggregate_version IS DISTINCT FROM s.version
       OR NEW.occurred_at IS DISTINCT FROM s.updated_at THEN
        RAISE EXCEPTION 'event does not match settlement aggregate state' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.aggregate_version = 1 AND NEW.occurred_at IS DISTINCT FROM s.created_at THEN
        RAISE EXCEPTION 'initiation event occurred_at must equal settlement created_at' USING ERRCODE = 'P0001';
    END IF;

    new_memo := d->>'memo';
    IF new_memo IS NOT NULL THEN
        exp_memo := new_memo;
    ELSE
        SELECT e.payload->'data'->>'memo' INTO exp_memo
          FROM clearledger.events e
         WHERE e.settlement_id = NEW.settlement_id
           AND e.payload->'data'->>'memo' IS NOT NULL
         ORDER BY e.aggregate_version DESC
         LIMIT 1;
    END IF;
    IF s.last_memo IS DISTINCT FROM exp_memo THEN
        RAISE EXCEPTION 'settlement last_memo does not match event memo history' USING ERRCODE = 'P0001';
    END IF;

    IF NEW.aggregate_version >= 2 THEN
        SELECT * INTO prev FROM clearledger.events
         WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'previous event missing' USING ERRCODE = 'P0001';
        END IF;
        IF NOT (NEW.occurred_at > prev.occurred_at) THEN
            RAISE EXCEPTION 'event occurred_at must be strictly after previous event' USING ERRCODE = 'P0001';
        END IF;
        IF NOT clearledger.status_transition_allowed(prev.payload->'data'->>'status', d->>'status') THEN
            RAISE EXCEPTION 'illegal status transition % -> %', prev.payload->'data'->>'status', d->>'status' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    e     clearledger.events%ROWTYPE;
    max_v INTEGER;
BEGIN
    IF NOT clearledger.envelope_valid(NEW.payload) THEN
        RAISE EXCEPTION 'outbox payload does not conform to ClearLedgerDomainEventEnvelope' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'outbox event % does not exist in clearledger.events', NEW.event_id USING ERRCODE = '23503';
    END IF;
    IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
       OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
       OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
       OR e.payload IS DISTINCT FROM NEW.payload THEN
        RAISE EXCEPTION 'outbox row must mirror clearledger.events' USING ERRCODE = 'P0001';
    END IF;
    SELECT COALESCE(MAX(aggregate_version), 0) INTO max_v
      FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version <> max_v + 1 THEN
        RAISE EXCEPTION 'outbox version % is not contiguous (expected %)', NEW.aggregate_version, max_v + 1 USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.seq IS DISTINCT FROM OLD.seq
       OR NEW.event_id IS DISTINCT FROM OLD.event_id
       OR NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
       OR NEW.aggregate_version IS DISTINCT FROM OLD.aggregate_version
       OR NEW.correlation_id IS DISTINCT FROM OLD.correlation_id
       OR NEW.payload IS DISTINCT FROM OLD.payload
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'outbox envelope columns are immutable' USING ERRCODE = 'P0001';
    END IF;
    IF NEW.attempts < OLD.attempts THEN
        RAISE EXCEPTION 'outbox attempts cannot decrease' USING ERRCODE = 'P0001';
    END IF;

    IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
        -- Publishing.
        IF NEW.attempts <> OLD.attempts + 1 THEN
            RAISE EXCEPTION 'publishing an outbox row must increment attempts' USING ERRCODE = 'P0001';
        END IF;
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'cannot archive while publishing' USING ERRCODE = 'P0001';
        END IF;
    ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
        -- Published rows: only archival state may change.
        IF NEW.published_at IS DISTINCT FROM OLD.published_at
           OR NEW.attempts IS DISTINCT FROM OLD.attempts
           OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
            RAISE EXCEPTION 'published outbox delivery state is immutable' USING ERRCODE = 'P0001';
        END IF;
        IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
           AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
            RAISE EXCEPTION 'archived_at cannot be changed without resetting it first' USING ERRCODE = 'P0001';
        END IF;
    ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
        -- Operational replay reset.
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'replay reset must also reset archived_at' USING ERRCODE = 'P0001';
        END IF;
    ELSE
        -- Unpublished -> unpublished (delivery failure bookkeeping).
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'unpublished outbox rows cannot be archived' USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    ev_id  UUID;
    st_id  UUID;
    ver    INTEGER;
BEGIN
    IF NOT clearledger.idempotency_row_valid(NEW.scope, NEW.status_code, NEW.response_body) THEN
        RAISE EXCEPTION 'idempotency response_body/scope/status_code invalid' USING ERRCODE = '23514';
    END IF;
    ev_id := (NEW.response_body->>'eventId')::uuid;
    st_id := (NEW.response_body->>'settlementId')::uuid;
    ver   := (NEW.response_body->>'version')::integer;
    IF NOT EXISTS (SELECT 1 FROM clearledger.events
                    WHERE event_id = ev_id AND settlement_id = st_id
                      AND aggregate_version = ver AND idempotency_key = NEW.idempotency_key) THEN
        RAISE EXCEPTION 'idempotency key references unknown event' USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM clearledger.outbox
                    WHERE event_id = ev_id AND settlement_id = st_id AND aggregate_version = ver) THEN
        RAISE EXCEPTION 'idempotency key references event missing from outbox' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (SELECT 1 FROM clearledger.idempotency_keys
                WHERE (response_body->>'eventId')::uuid = ev_id
                   OR ((response_body->>'settlementId')::uuid = st_id AND (response_body->>'version')::integer = ver)) THEN
        RAISE EXCEPTION 'idempotency response already recorded for event' USING ERRCODE = '23505';
    END IF;
    RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Constraints: keys / foreign keys (created when missing)
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    c RECORD;
BEGIN
    FOR c IN SELECT * FROM (VALUES
        (1, 'settlements', 'settlements_pkey', 'PRIMARY KEY (settlement_id)'),
        (1, 'events', 'events_pkey', 'PRIMARY KEY (seq)'),
        (1, 'events', 'events_event_id_key', 'UNIQUE (event_id)'),
        (1, 'events', 'events_settlement_id_aggregate_version_key', 'UNIQUE (settlement_id, aggregate_version)'),
        (1, 'events', 'events_settlement_id_idempotency_key_key', 'UNIQUE (settlement_id, idempotency_key)'),
        (1, 'outbox', 'outbox_pkey', 'PRIMARY KEY (seq)'),
        (1, 'outbox', 'outbox_event_id_key', 'UNIQUE (event_id)'),
        (1, 'outbox', 'outbox_settlement_id_aggregate_version_key', 'UNIQUE (settlement_id, aggregate_version)'),
        (1, 'idempotency_keys', 'idempotency_keys_pkey', 'PRIMARY KEY (scope, idempotency_key)'),
        (2, 'events', 'events_settlement_id_fkey', 'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
        (2, 'outbox', 'outbox_event_id_fkey', 'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE'),
        (2, 'outbox', 'outbox_settlement_id_fkey', 'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
        (2, 'outbox', 'outbox_settlement_id_aggregate_version_fkey', 'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE')
    ) AS t(phase, tbl, name, def) ORDER BY phase
    LOOP
        IF EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = c.name AND conrelid = format('clearledger.%I', c.tbl)::regclass
                      AND pg_get_constraintdef(oid) = c.def) THEN
            CONTINUE;
        END IF;
        IF EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = c.name AND conrelid = format('clearledger.%I', c.tbl)::regclass) THEN
            EXECUTE format('ALTER TABLE clearledger.%I DROP CONSTRAINT %I CASCADE', c.tbl, c.name);
        END IF;
        IF c.def LIKE 'PRIMARY KEY%' THEN
            -- Drop any non-canonical primary key first.
            PERFORM 1 FROM pg_constraint WHERE contype = 'p' AND conrelid = format('clearledger.%I', c.tbl)::regclass;
            IF FOUND THEN
                EXECUTE (SELECT format('ALTER TABLE clearledger.%I DROP CONSTRAINT %I CASCADE', c.tbl, conname)
                           FROM pg_constraint WHERE contype = 'p' AND conrelid = format('clearledger.%I', c.tbl)::regclass);
            END IF;
        END IF;
        EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', c.tbl, c.name, c.def);
    END LOOP;
    -- Re-run phase 2 in case a CASCADE above removed a dependent foreign key.
    FOR c IN SELECT * FROM (VALUES
        ('events', 'events_settlement_id_fkey', 'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
        ('outbox', 'outbox_event_id_fkey', 'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE'),
        ('outbox', 'outbox_settlement_id_fkey', 'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE'),
        ('outbox', 'outbox_settlement_id_aggregate_version_fkey', 'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE')
    ) AS t(tbl, name, def)
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conname = c.name AND conrelid = format('clearledger.%I', c.tbl)::regclass) THEN
            EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', c.tbl, c.name, c.def);
        END IF;
    END LOOP;
    -- Constraints must be enforced (not deferred / not left NOT VALID).
    FOR c IN SELECT 'clearledger.' || quote_ident(cl.relname) AS tbl, conname
               FROM pg_constraint JOIN pg_class cl ON cl.oid = conrelid
              WHERE connamespace = 'clearledger'::regnamespace AND contype IN ('f') AND NOT convalidated
    LOOP
        BEGIN
            EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', c.tbl, c.conname);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'could not validate %.%: %', c.tbl, c.conname, SQLERRM;
        END;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- CHECK constraints: canonical set is always re-created; any other CHECK
-- constraint on the four tables (weakened / altered / rogue) is dropped.
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _cl_checks (tbl TEXT, name TEXT, def TEXT) ON COMMIT DROP;
INSERT INTO _cl_checks VALUES
 ('settlements', 'settlements_canonical_text_check',
  $c$CHECK (clearledger.is_canonical_text(account_id, 3, 64) AND clearledger.is_canonical_text(reference, 3, 64) AND clearledger.is_canonical_text(debit_party, 2, 64) AND clearledger.is_canonical_text(credit_party, 2, 64) AND current_stage = btrim(current_stage) AND clearledger.is_canonical_text(last_memo, 1, 256))$c$),
 ('settlements', 'settlements_parties_check', $c$CHECK (debit_party <> credit_party)$c$),
 ('settlements', 'settlements_status_check',
  $c$CHECK (current_status IN ('INITIATED','VALIDATED','RESERVED','CLEARED','SETTLED','RECONCILED','DISPUTED'))$c$),
 ('settlements', 'settlements_version_check', $c$CHECK (version >= 1 AND entry_count >= 0)$c$),
 ('settlements', 'settlements_lifecycle_check',
  $c$CHECK ((version = 1 AND entry_count = 0 AND current_status = 'INITIATED' AND current_stage = ('INITIATED@' || debit_party) AND last_entry_id IS NULL AND last_memo = 'Settlement initiated' AND updated_at = created_at) OR (version > 1 AND entry_count = version - 1 AND current_status <> 'INITIATED' AND last_entry_id IS NOT NULL AND last_memo IS NOT NULL AND updated_at > created_at AND clearledger.is_canonical_text(current_stage, 2, 64)))$c$),
 ('events', 'events_canonical_text_check',
  $c$CHECK (clearledger.is_canonical_text(correlation_id, 4, 128) AND clearledger.is_canonical_text(idempotency_key, 8, 128))$c$),
 ('events', 'events_event_type_check',
  $c$CHECK (event_type IN ('SettlementInitiated','LedgerEntryRecorded') AND aggregate_version >= 1 AND ((aggregate_version = 1) = (event_type = 'SettlementInitiated')))$c$),
 ('events', 'events_payload_envelope_check', $c$CHECK (clearledger.envelope_valid(payload))$c$),
 ('events', 'events_payload_columns_check',
  $c$CHECK (clearledger.event_columns_match(payload, event_id, settlement_id, aggregate_version, event_type, correlation_id, idempotency_key, occurred_at))$c$),
 ('outbox', 'outbox_correlation_id_check', $c$CHECK (clearledger.is_canonical_text(correlation_id, 4, 128))$c$),
 ('outbox', 'outbox_payload_envelope_check', $c$CHECK (clearledger.envelope_valid(payload))$c$),
 ('outbox', 'outbox_payload_columns_check',
  $c$CHECK (clearledger.outbox_columns_match(payload, event_id, settlement_id, aggregate_version, correlation_id))$c$),
 ('outbox', 'outbox_attempts_check', $c$CHECK (attempts >= 0)$c$),
 ('outbox', 'outbox_unattempted_check', $c$CHECK (attempts <> 0 OR (published_at IS NULL AND last_error IS NULL))$c$),
 ('outbox', 'outbox_published_check',
  $c$CHECK (published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at))$c$),
 ('outbox', 'outbox_last_error_check',
  $c$CHECK (last_error IS NULL OR (published_at IS NULL AND attempts >= 1 AND length(btrim(last_error)) > 0 AND last_error = btrim(last_error)))$c$),
 ('outbox', 'outbox_archived_check',
  $c$CHECK (archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at))$c$),
 ('idempotency_keys', 'idempotency_keys_scope_check',
  $c$CHECK (scope ~ '^(create|entry):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')$c$),
 ('idempotency_keys', 'idempotency_keys_key_check', $c$CHECK (clearledger.is_canonical_text(idempotency_key, 8, 128))$c$),
 ('idempotency_keys', 'idempotency_keys_request_hash_check', $c$CHECK (request_hash ~ '^[0-9a-f]{64}$')$c$),
 ('idempotency_keys', 'idempotency_keys_status_code_check',
  $c$CHECK ((scope LIKE 'create:%' AND status_code = 201) OR (scope LIKE 'entry:%' AND status_code = 202))$c$),
 ('idempotency_keys', 'idempotency_keys_response_body_check',
  $c$CHECK (clearledger.idempotency_row_valid(scope, status_code, response_body))$c$);

DO $$
DECLARE
    c RECORD;
BEGIN
    -- Drop every CHECK constraint on the four tables (canonical ones are re-added below).
    FOR c IN SELECT 'clearledger.' || quote_ident(cl.relname) AS tbl, conname
               FROM pg_constraint JOIN pg_class cl ON cl.oid = conrelid
              WHERE contype = 'c'
                AND conrelid IN ('clearledger.settlements'::regclass, 'clearledger.events'::regclass,
                                 'clearledger.outbox'::regclass, 'clearledger.idempotency_keys'::regclass)
    LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', c.tbl, c.conname);
    END LOOP;
    FOR c IN SELECT * FROM _cl_checks LOOP
        BEGIN
            EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', c.tbl, c.name, c.def);
        EXCEPTION WHEN check_violation THEN
            -- Legacy rows violate the rule: still enforce it for all new writes.
            RAISE WARNING 'existing rows violate %.%, adding as NOT VALID', c.tbl, c.name;
            EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s NOT VALID', c.tbl, c.name, c.def);
        END;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Triggers: canonical set (re)created, non-canonical user triggers removed,
-- all triggers enabled (tgenabled = 'O').
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _cl_triggers (tbl TEXT, name TEXT, def TEXT) ON COMMIT DROP;
INSERT INTO _cl_triggers VALUES
 ('settlements', 'trg_settlements_before_update',
  'BEFORE UPDATE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_update()'),
 ('settlements', 'trg_settlements_reject_delete',
  'BEFORE DELETE ON clearledger.settlements FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation()'),
 ('events', 'trg_events_before_insert',
  'BEFORE INSERT ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_before_insert()'),
 ('events', 'trg_events_reject_mutation',
  'BEFORE UPDATE OR DELETE ON clearledger.events FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation()'),
 ('outbox', 'trg_outbox_before_insert',
  'BEFORE INSERT ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_insert()'),
 ('outbox', 'trg_outbox_before_update',
  'BEFORE UPDATE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_update()'),
 ('outbox', 'trg_outbox_reject_delete',
  'BEFORE DELETE ON clearledger.outbox FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation()'),
 ('idempotency_keys', 'trg_idempotency_before_insert',
  'BEFORE INSERT ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert()'),
 ('idempotency_keys', 'trg_idempotency_reject_mutation',
  'BEFORE UPDATE OR DELETE ON clearledger.idempotency_keys FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation()');

DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT 'clearledger.' || quote_ident(cl.relname) AS tbl, tg.tgname
               FROM pg_trigger tg JOIN pg_class cl ON cl.oid = tg.tgrelid
              WHERE NOT tg.tgisinternal
                AND tg.tgrelid IN ('clearledger.settlements'::regclass, 'clearledger.events'::regclass,
                                   'clearledger.outbox'::regclass, 'clearledger.idempotency_keys'::regclass)
    LOOP
        EXECUTE format('DROP TRIGGER %I ON %s', t.tgname, t.tbl);
    END LOOP;
    FOR t IN SELECT * FROM _cl_triggers LOOP
        EXECUTE format('CREATE TRIGGER %I %s', t.name, t.def);
    END LOOP;
    -- Enable everything (internal FK triggers included) in origin mode.
    EXECUTE 'ALTER TABLE clearledger.settlements ENABLE TRIGGER ALL';
    EXECUTE 'ALTER TABLE clearledger.events ENABLE TRIGGER ALL';
    EXECUTE 'ALTER TABLE clearledger.outbox ENABLE TRIGGER ALL';
    EXECUTE 'ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER ALL';
END $$;

-- ---------------------------------------------------------------------------
-- Required indexes (recreated when missing, invalid, or altered)
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE _cl_indexes (name TEXT, def TEXT) ON COMMIT DROP;
INSERT INTO _cl_indexes VALUES
 ('idx_clearledger_outbox_unpublished',
  'CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox USING btree (seq) WHERE (published_at IS NULL)'),
 ('idx_clearledger_outbox_unarchived',
  'CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox USING btree (seq) WHERE ((published_at IS NOT NULL) AND (archived_at IS NULL))'),
 ('idx_clearledger_events_settlement_version',
  'CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events USING btree (settlement_id, aggregate_version)'),
 ('idx_clearledger_idempotency_event',
  'CREATE UNIQUE INDEX idx_clearledger_idempotency_event ON clearledger.idempotency_keys USING btree ((((response_body ->> ''eventId''::text))::uuid))'),
 ('idx_clearledger_idempotency_version',
  'CREATE UNIQUE INDEX idx_clearledger_idempotency_version ON clearledger.idempotency_keys USING btree ((((response_body ->> ''settlementId''::text))::uuid), (((response_body ->> ''version''::text))::integer))'),
 ('idx_clearledger_entry_id',
  'CREATE UNIQUE INDEX idx_clearledger_entry_id ON clearledger.events USING btree (settlement_id, ((((payload -> ''data''::text) ->> ''entryId''::text))::uuid)) WHERE (event_type = ''LedgerEntryRecorded''::text)');

DO $$
DECLARE
    i RECORD;
    cur TEXT;
    ok BOOLEAN;
BEGIN
    FOR i IN SELECT * FROM _cl_indexes LOOP
        SELECT pg_get_indexdef(x.indexrelid), x.indisvalid AND x.indisready
          INTO cur, ok
          FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
         WHERE c.relname = i.name AND c.relnamespace = 'clearledger'::regnamespace;
        IF cur IS NOT NULL AND cur = i.def AND ok THEN
            CONTINUE;
        END IF;
        IF cur IS NOT NULL THEN
            EXECUTE format('DROP INDEX clearledger.%I', i.name);
        END IF;
        EXECUTE i.def;
    END LOOP;
END $$;

ANALYZE clearledger.settlements;
ANALYZE clearledger.events;
ANALYZE clearledger.outbox;
ANALYZE clearledger.idempotency_keys;
