-- ===========================================================================
-- ClearLedger PostgreSQL schema (idempotent).
--
-- Applied by deploy.sh on every run. Safe to re-run against a live database:
--   * tables / columns are created only when missing,
--   * NOT NULL / DEFAULT / CHECK / UNIQUE / FK constraints are (re)asserted,
--   * PL/pgSQL functions and triggers are replaced in place,
--   * indexes are recreated when missing or when their definition drifted,
--   * every user trigger is re-enabled (tgenabled = 'O').
-- ===========================================================================

SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS clearledger;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clearledger.settlements (
    settlement_id   UUID        NOT NULL,
    account_id      TEXT        NOT NULL,
    reference       TEXT        NOT NULL,
    debit_party     TEXT        NOT NULL,
    credit_party    TEXT        NOT NULL,
    current_status  TEXT        NOT NULL,
    current_stage   TEXT        NOT NULL,
    last_entry_id   UUID        NULL,
    last_memo       TEXT        NULL,
    version         INTEGER     NOT NULL,
    entry_count     INTEGER     NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
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

-- Re-assert NOT NULL / DEFAULT in case of out-of-band column drift.
ALTER TABLE clearledger.settlements
    ALTER COLUMN settlement_id  SET NOT NULL,
    ALTER COLUMN account_id     SET NOT NULL,
    ALTER COLUMN reference      SET NOT NULL,
    ALTER COLUMN debit_party    SET NOT NULL,
    ALTER COLUMN credit_party   SET NOT NULL,
    ALTER COLUMN current_status SET NOT NULL,
    ALTER COLUMN current_stage  SET NOT NULL,
    ALTER COLUMN version        SET NOT NULL,
    ALTER COLUMN entry_count    SET NOT NULL,
    ALTER COLUMN entry_count    SET DEFAULT 0,
    ALTER COLUMN created_at     SET NOT NULL,
    ALTER COLUMN created_at     SET DEFAULT NOW(),
    ALTER COLUMN updated_at     SET NOT NULL,
    ALTER COLUMN updated_at     SET DEFAULT NOW();

ALTER TABLE clearledger.events
    ALTER COLUMN seq               SET NOT NULL,
    ALTER COLUMN event_id          SET NOT NULL,
    ALTER COLUMN settlement_id     SET NOT NULL,
    ALTER COLUMN aggregate_version SET NOT NULL,
    ALTER COLUMN event_type        SET NOT NULL,
    ALTER COLUMN correlation_id    SET NOT NULL,
    ALTER COLUMN idempotency_key   SET NOT NULL,
    ALTER COLUMN occurred_at       SET NOT NULL,
    ALTER COLUMN payload           SET NOT NULL,
    ALTER COLUMN created_at        SET NOT NULL,
    ALTER COLUMN created_at        SET DEFAULT NOW();

ALTER TABLE clearledger.outbox
    ALTER COLUMN seq               SET NOT NULL,
    ALTER COLUMN event_id          SET NOT NULL,
    ALTER COLUMN settlement_id     SET NOT NULL,
    ALTER COLUMN aggregate_version SET NOT NULL,
    ALTER COLUMN correlation_id    SET NOT NULL,
    ALTER COLUMN payload           SET NOT NULL,
    ALTER COLUMN created_at        SET NOT NULL,
    ALTER COLUMN created_at        SET DEFAULT NOW(),
    ALTER COLUMN attempts          SET NOT NULL,
    ALTER COLUMN attempts          SET DEFAULT 0;

ALTER TABLE clearledger.idempotency_keys
    ALTER COLUMN scope           SET NOT NULL,
    ALTER COLUMN idempotency_key SET NOT NULL,
    ALTER COLUMN request_hash    SET NOT NULL,
    ALTER COLUMN status_code     SET NOT NULL,
    ALTER COLUMN response_body   SET NOT NULL,
    ALTER COLUMN created_at      SET NOT NULL,
    ALTER COLUMN created_at      SET DEFAULT NOW();

-- ---------------------------------------------------------------------------
-- Pure helper functions (IMMUTABLE, usable from CHECK constraints)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger.is_canonical_text(val TEXT, min_len INTEGER, max_len INTEGER)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT val IS NOT NULL
       AND val = btrim(val)
       AND char_length(val) BETWEEN min_len AND max_len
$$;

CREATE OR REPLACE FUNCTION clearledger.is_uuid_text(val TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT val IS NOT NULL
       AND val ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$$;

CREATE OR REPLACE FUNCTION clearledger.status_rank(status TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE status
        WHEN 'INITIATED'  THEN 0
        WHEN 'VALIDATED'  THEN 1
        WHEN 'RESERVED'   THEN 2
        WHEN 'CLEARED'    THEN 3
        WHEN 'SETTLED'    THEN 4
        WHEN 'RECONCILED' THEN 5
        ELSE NULL
    END
$$;

CREATE OR REPLACE FUNCTION clearledger.is_valid_status(status TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT status IN ('INITIATED', 'VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED', 'RECONCILED', 'DISPUTED')
$$;

-- Clearing lifecycle transition rules (old -> new).
CREATE OR REPLACE FUNCTION clearledger.is_valid_status_transition(old_status TEXT, new_status TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN old_status IS NULL OR new_status IS NULL THEN FALSE
        WHEN NOT clearledger.is_valid_status(old_status) OR NOT clearledger.is_valid_status(new_status) THEN FALSE
        WHEN old_status = 'RECONCILED' THEN FALSE
        WHEN old_status = 'DISPUTED' THEN new_status IN ('DISPUTED', 'RECONCILED')
        WHEN new_status = 'DISPUTED' THEN TRUE
        ELSE clearledger.status_rank(new_status) >= clearledger.status_rank(old_status)
    END
$$;

-- Clearing stage bounds: 2..64 canonical characters, except the system
-- generated initiation stage 'INITIATED@<debit_party>' (debit party may be 64).
CREATE OR REPLACE FUNCTION clearledger.is_valid_stage(stage TEXT, version INTEGER, debit_party TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT stage IS NOT NULL
       AND stage = btrim(stage)
       AND (
            char_length(stage) BETWEEN 2 AND 64
            OR (version = 1 AND debit_party IS NOT NULL AND stage = 'INITIATED@' || debit_party)
       )
$$;

CREATE OR REPLACE FUNCTION clearledger.try_timestamptz(val TEXT)
RETURNS TIMESTAMPTZ LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF val IS NULL
       OR val !~* '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' THEN
        RETURN NULL;
    END IF;
    RETURN val::timestamptz;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END
$$;

-- Strict validation of the ClearLedgerDomainEventEnvelope (events.schema.json)
-- plus the domain coupling rules from services/rds.md.
CREATE OR REPLACE FUNCTION clearledger.is_valid_envelope(p JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    d        JSONB;
    v        NUMERIC;
    etype    TEXT;
    kind     TEXT;
    status   TEXT;
    stage    TEXT;
    debit    TEXT;
    credit   TEXT;
    k        TEXT;
BEGIN
    IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN
        RETURN FALSE;
    END IF;

    -- additionalProperties: false + required (envelope)
    FOR k IN SELECT jsonb_object_keys(p) LOOP
        IF k NOT IN ('schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId',
                     'aggregateVersion', 'occurredAt', 'correlationId', 'idempotencyKey', 'data') THEN
            RETURN FALSE;
        END IF;
    END LOOP;
    IF NOT (p ?& ARRAY['schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId',
                       'aggregateVersion', 'occurredAt', 'correlationId', 'idempotencyKey', 'data']) THEN
        RETURN FALSE;
    END IF;

    IF jsonb_typeof(p->'schemaVersion') <> 'string' OR p->>'schemaVersion' <> '1.0' THEN RETURN FALSE; END IF;
    IF jsonb_typeof(p->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'eventId') THEN RETURN FALSE; END IF;
    IF jsonb_typeof(p->'eventType') <> 'string' THEN RETURN FALSE; END IF;
    etype := p->>'eventType';
    IF etype NOT IN ('SettlementInitiated', 'LedgerEntryRecorded') THEN RETURN FALSE; END IF;
    IF jsonb_typeof(p->'aggregateType') <> 'string' OR p->>'aggregateType' <> 'settlement' THEN RETURN FALSE; END IF;
    IF jsonb_typeof(p->'aggregateId') <> 'string' OR NOT clearledger.is_uuid_text(p->>'aggregateId') THEN RETURN FALSE; END IF;

    IF jsonb_typeof(p->'aggregateVersion') <> 'number' THEN RETURN FALSE; END IF;
    v := (p->>'aggregateVersion')::numeric;
    IF v <> trunc(v) OR v < 1 OR v > 2147483647 THEN RETURN FALSE; END IF;

    IF jsonb_typeof(p->'occurredAt') <> 'string' OR clearledger.try_timestamptz(p->>'occurredAt') IS NULL THEN
        RETURN FALSE;
    END IF;
    IF jsonb_typeof(p->'correlationId') <> 'string'
       OR NOT clearledger.is_canonical_text(p->>'correlationId', 4, 128) THEN
        RETURN FALSE;
    END IF;
    IF jsonb_typeof(p->'idempotencyKey') <> 'string'
       OR NOT clearledger.is_canonical_text(p->>'idempotencyKey', 8, 128) THEN
        RETURN FALSE;
    END IF;

    -- data
    d := p->'data';
    IF jsonb_typeof(d) <> 'object' THEN RETURN FALSE; END IF;
    FOR k IN SELECT jsonb_object_keys(d) LOOP
        IF k NOT IN ('kind', 'accountId', 'reference', 'debitParty', 'creditParty',
                     'entryId', 'status', 'clearingStage', 'memo') THEN
            RETURN FALSE;
        END IF;
    END LOOP;
    IF NOT (d ?& ARRAY['kind', 'accountId', 'reference', 'debitParty', 'creditParty', 'status', 'clearingStage']) THEN
        RETURN FALSE;
    END IF;
    IF jsonb_typeof(d->'kind') <> 'string' OR jsonb_typeof(d->'accountId') <> 'string'
       OR jsonb_typeof(d->'reference') <> 'string' OR jsonb_typeof(d->'debitParty') <> 'string'
       OR jsonb_typeof(d->'creditParty') <> 'string' OR jsonb_typeof(d->'status') <> 'string'
       OR jsonb_typeof(d->'clearingStage') <> 'string' THEN
        RETURN FALSE;
    END IF;

    kind   := d->>'kind';
    status := d->>'status';
    stage  := d->>'clearingStage';
    debit  := d->>'debitParty';
    credit := d->>'creditParty';

    IF kind NOT IN ('settlementInitiated', 'ledgerEntryRecorded') THEN RETURN FALSE; END IF;
    IF NOT clearledger.is_valid_status(status) THEN RETURN FALSE; END IF;
    IF NOT clearledger.is_canonical_text(d->>'accountId', 3, 64) THEN RETURN FALSE; END IF;
    IF NOT clearledger.is_canonical_text(d->>'reference', 3, 64) THEN RETURN FALSE; END IF;
    IF NOT clearledger.is_canonical_text(debit, 2, 64) THEN RETURN FALSE; END IF;
    IF NOT clearledger.is_canonical_text(credit, 2, 64) THEN RETURN FALSE; END IF;
    IF debit = credit THEN RETURN FALSE; END IF;
    IF NOT clearledger.is_valid_stage(stage, v::integer, debit) THEN RETURN FALSE; END IF;

    IF d ? 'memo' AND jsonb_typeof(d->'memo') <> 'null' THEN
        IF jsonb_typeof(d->'memo') <> 'string' OR NOT clearledger.is_canonical_text(d->>'memo', 1, 256) THEN
            RETURN FALSE;
        END IF;
    END IF;
    IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN
        IF jsonb_typeof(d->'entryId') <> 'string' OR NOT clearledger.is_uuid_text(d->>'entryId') THEN
            RETURN FALSE;
        END IF;
    END IF;

    -- version / kind / status / entryId coupling
    IF etype = 'SettlementInitiated' THEN
        IF v <> 1 OR kind <> 'settlementInitiated' OR status <> 'INITIATED' THEN RETURN FALSE; END IF;
        IF d ? 'entryId' AND jsonb_typeof(d->'entryId') <> 'null' THEN RETURN FALSE; END IF;
        IF stage <> 'INITIATED@' || debit THEN RETURN FALSE; END IF;
        IF jsonb_typeof(d->'memo') IS DISTINCT FROM 'string' OR d->>'memo' <> 'Settlement initiated' THEN
            RETURN FALSE;
        END IF;
    ELSE
        IF v < 2 OR kind <> 'ledgerEntryRecorded' OR status = 'INITIATED' THEN RETURN FALSE; END IF;
        IF NOT (d ? 'entryId') OR jsonb_typeof(d->'entryId') <> 'string' THEN RETURN FALSE; END IF;
    END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END
$$;

-- Column-to-envelope equality for clearledger.events.
CREATE OR REPLACE FUNCTION clearledger.event_columns_match_envelope(
    p JSONB, p_event_id UUID, p_settlement_id UUID, p_version INTEGER, p_event_type TEXT,
    p_correlation_id TEXT, p_idempotency_key TEXT, p_occurred_at TIMESTAMPTZ)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN clearledger.is_valid_envelope(p)
       AND (p->>'eventId')::uuid = p_event_id
       AND (p->>'aggregateId')::uuid = p_settlement_id
       AND (p->>'aggregateVersion')::integer = p_version
       AND p->>'eventType' = p_event_type
       AND p->>'correlationId' = p_correlation_id
       AND p->>'idempotencyKey' = p_idempotency_key
       AND clearledger.try_timestamptz(p->>'occurredAt') = p_occurred_at;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END
$$;

-- Column-to-envelope equality for clearledger.outbox.
CREATE OR REPLACE FUNCTION clearledger.outbox_columns_match_envelope(
    p JSONB, p_event_id UUID, p_settlement_id UUID, p_version INTEGER, p_correlation_id TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN clearledger.is_valid_envelope(p)
       AND (p->>'eventId')::uuid = p_event_id
       AND (p->>'aggregateId')::uuid = p_settlement_id
       AND (p->>'aggregateVersion')::integer = p_version
       AND p->>'correlationId' = p_correlation_id;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END
$$;

-- Closed-schema WriteAcceptedResponse + scope/status coupling.
CREATE OR REPLACE FUNCTION clearledger.is_valid_idempotency_record(
    p_scope TEXT, p_status_code INTEGER, body JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    k   TEXT;
    v   NUMERIC;
    sid TEXT;
BEGIN
    IF body IS NULL OR jsonb_typeof(body) <> 'object' THEN RETURN FALSE; END IF;
    FOR k IN SELECT jsonb_object_keys(body) LOOP
        IF k NOT IN ('settlementId', 'eventId', 'version', 'accepted', 'idempotentReplay') THEN
            RETURN FALSE;
        END IF;
    END LOOP;
    IF NOT (body ?& ARRAY['settlementId', 'eventId', 'version', 'accepted', 'idempotentReplay']) THEN
        RETURN FALSE;
    END IF;
    IF jsonb_typeof(body->'settlementId') <> 'string' OR NOT clearledger.is_uuid_text(body->>'settlementId') THEN
        RETURN FALSE;
    END IF;
    IF jsonb_typeof(body->'eventId') <> 'string' OR NOT clearledger.is_uuid_text(body->>'eventId') THEN
        RETURN FALSE;
    END IF;
    IF jsonb_typeof(body->'version') <> 'number' THEN RETURN FALSE; END IF;
    v := (body->>'version')::numeric;
    IF v <> trunc(v) OR v < 1 OR v > 2147483647 THEN RETURN FALSE; END IF;
    IF body->'accepted' <> 'true'::jsonb THEN RETURN FALSE; END IF;
    IF body->'idempotentReplay' <> 'false'::jsonb THEN RETURN FALSE; END IF;

    IF p_scope !~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        RETURN FALSE;
    END IF;
    sid := substr(p_scope, strpos(p_scope, ':') + 1);
    IF sid::uuid <> (body->>'settlementId')::uuid THEN RETURN FALSE; END IF;

    IF p_scope LIKE 'create:%' THEN
        RETURN p_status_code = 201 AND v = 1;
    END IF;
    RETURN p_status_code = 202 AND v >= 2;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END
$$;

-- ---------------------------------------------------------------------------
-- CHECK constraints (dropped and re-added so definitions converge)
-- ---------------------------------------------------------------------------
ALTER TABLE clearledger.settlements
    DROP CONSTRAINT IF EXISTS settlements_canonical_text_chk,
    DROP CONSTRAINT IF EXISTS settlements_parties_distinct_chk,
    DROP CONSTRAINT IF EXISTS settlements_status_chk,
    DROP CONSTRAINT IF EXISTS settlements_version_chk,
    DROP CONSTRAINT IF EXISTS settlements_lifecycle_chk;

ALTER TABLE clearledger.settlements
    ADD CONSTRAINT settlements_canonical_text_chk CHECK (
        clearledger.is_canonical_text(account_id, 3, 64)
        AND clearledger.is_canonical_text(reference, 3, 64)
        AND clearledger.is_canonical_text(debit_party, 2, 64)
        AND clearledger.is_canonical_text(credit_party, 2, 64)
        AND clearledger.is_valid_stage(current_stage, version, debit_party)
        AND (last_memo IS NULL OR clearledger.is_canonical_text(last_memo, 1, 256))
    ) NOT VALID,
    ADD CONSTRAINT settlements_parties_distinct_chk CHECK (debit_party <> credit_party) NOT VALID,
    ADD CONSTRAINT settlements_status_chk CHECK (clearledger.is_valid_status(current_status)) NOT VALID,
    ADD CONSTRAINT settlements_version_chk CHECK (version >= 1 AND entry_count >= 0) NOT VALID,
    ADD CONSTRAINT settlements_lifecycle_chk CHECK (
        (
            version = 1
            AND entry_count = 0
            AND current_status = 'INITIATED'
            AND current_stage = 'INITIATED@' || debit_party
            AND last_entry_id IS NULL
            AND last_memo IS NOT NULL AND last_memo = 'Settlement initiated'
            AND updated_at = created_at
        )
        OR
        (
            version > 1
            AND entry_count = version - 1
            AND current_status <> 'INITIATED'
            AND last_entry_id IS NOT NULL
            AND updated_at > created_at
        )
    ) NOT VALID;

ALTER TABLE clearledger.settlements
    VALIDATE CONSTRAINT settlements_canonical_text_chk,
    VALIDATE CONSTRAINT settlements_parties_distinct_chk,
    VALIDATE CONSTRAINT settlements_status_chk,
    VALIDATE CONSTRAINT settlements_version_chk,
    VALIDATE CONSTRAINT settlements_lifecycle_chk;

ALTER TABLE clearledger.events
    DROP CONSTRAINT IF EXISTS events_canonical_text_chk,
    DROP CONSTRAINT IF EXISTS events_version_chk,
    DROP CONSTRAINT IF EXISTS events_type_chk,
    DROP CONSTRAINT IF EXISTS events_envelope_chk;

ALTER TABLE clearledger.events
    ADD CONSTRAINT events_canonical_text_chk CHECK (
        clearledger.is_canonical_text(correlation_id, 4, 128)
        AND clearledger.is_canonical_text(idempotency_key, 8, 128)
    ) NOT VALID,
    ADD CONSTRAINT events_version_chk CHECK (aggregate_version >= 1) NOT VALID,
    ADD CONSTRAINT events_type_chk CHECK (
        event_type IN ('SettlementInitiated', 'LedgerEntryRecorded')
        AND ((event_type = 'SettlementInitiated') = (aggregate_version = 1))
    ) NOT VALID,
    ADD CONSTRAINT events_envelope_chk CHECK (
        clearledger.event_columns_match_envelope(
            payload, event_id, settlement_id, aggregate_version, event_type,
            correlation_id, idempotency_key, occurred_at)
    ) NOT VALID;

ALTER TABLE clearledger.events
    VALIDATE CONSTRAINT events_canonical_text_chk,
    VALIDATE CONSTRAINT events_version_chk,
    VALIDATE CONSTRAINT events_type_chk,
    VALIDATE CONSTRAINT events_envelope_chk;

ALTER TABLE clearledger.outbox
    DROP CONSTRAINT IF EXISTS outbox_canonical_text_chk,
    DROP CONSTRAINT IF EXISTS outbox_version_chk,
    DROP CONSTRAINT IF EXISTS outbox_envelope_chk,
    DROP CONSTRAINT IF EXISTS outbox_attempts_chk,
    DROP CONSTRAINT IF EXISTS outbox_unattempted_chk,
    DROP CONSTRAINT IF EXISTS outbox_published_chk,
    DROP CONSTRAINT IF EXISTS outbox_last_error_chk,
    DROP CONSTRAINT IF EXISTS outbox_archived_chk;

ALTER TABLE clearledger.outbox
    ADD CONSTRAINT outbox_canonical_text_chk CHECK (
        clearledger.is_canonical_text(correlation_id, 4, 128)
    ) NOT VALID,
    ADD CONSTRAINT outbox_version_chk CHECK (aggregate_version >= 1) NOT VALID,
    ADD CONSTRAINT outbox_envelope_chk CHECK (
        clearledger.outbox_columns_match_envelope(payload, event_id, settlement_id, aggregate_version, correlation_id)
    ) NOT VALID,
    ADD CONSTRAINT outbox_attempts_chk CHECK (attempts >= 0) NOT VALID,
    ADD CONSTRAINT outbox_unattempted_chk CHECK (
        attempts <> 0 OR (published_at IS NULL AND last_error IS NULL)
    ) NOT VALID,
    ADD CONSTRAINT outbox_published_chk CHECK (
        published_at IS NULL
        OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)
    ) NOT VALID,
    ADD CONSTRAINT outbox_last_error_chk CHECK (
        last_error IS NULL
        OR (
            published_at IS NULL
            AND attempts >= 1
            AND char_length(btrim(last_error)) > 0
            AND last_error = btrim(last_error)
        )
    ) NOT VALID,
    ADD CONSTRAINT outbox_archived_chk CHECK (
        archived_at IS NULL
        OR (published_at IS NOT NULL AND archived_at >= published_at)
    ) NOT VALID;

ALTER TABLE clearledger.outbox
    VALIDATE CONSTRAINT outbox_canonical_text_chk,
    VALIDATE CONSTRAINT outbox_version_chk,
    VALIDATE CONSTRAINT outbox_envelope_chk,
    VALIDATE CONSTRAINT outbox_attempts_chk,
    VALIDATE CONSTRAINT outbox_unattempted_chk,
    VALIDATE CONSTRAINT outbox_published_chk,
    VALIDATE CONSTRAINT outbox_last_error_chk,
    VALIDATE CONSTRAINT outbox_archived_chk;

ALTER TABLE clearledger.idempotency_keys
    DROP CONSTRAINT IF EXISTS idempotency_keys_scope_chk,
    DROP CONSTRAINT IF EXISTS idempotency_keys_key_chk,
    DROP CONSTRAINT IF EXISTS idempotency_keys_hash_chk,
    DROP CONSTRAINT IF EXISTS idempotency_keys_response_chk;

ALTER TABLE clearledger.idempotency_keys
    ADD CONSTRAINT idempotency_keys_scope_chk CHECK (
        scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    ) NOT VALID,
    ADD CONSTRAINT idempotency_keys_key_chk CHECK (
        clearledger.is_canonical_text(idempotency_key, 8, 128)
    ) NOT VALID,
    ADD CONSTRAINT idempotency_keys_hash_chk CHECK (request_hash ~ '^[0-9a-f]{64}$') NOT VALID,
    ADD CONSTRAINT idempotency_keys_response_chk CHECK (
        status_code IN (201, 202)
        AND clearledger.is_valid_idempotency_record(scope, status_code, response_body)
    ) NOT VALID;

ALTER TABLE clearledger.idempotency_keys
    VALIDATE CONSTRAINT idempotency_keys_scope_chk,
    VALIDATE CONSTRAINT idempotency_keys_key_chk,
    VALIDATE CONSTRAINT idempotency_keys_hash_chk,
    VALIDATE CONSTRAINT idempotency_keys_response_chk;

-- ---------------------------------------------------------------------------
-- PRIMARY KEY / UNIQUE / FOREIGN KEY constraints (added when missing)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger._ensure_constraint(tbl TEXT, cname TEXT, ddl TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace
        WHERE n.nspname = 'clearledger' AND r.relname = tbl AND c.conname = cname
    ) THEN
        EXECUTE format('ALTER TABLE clearledger.%I ADD CONSTRAINT %I %s', tbl, cname, ddl);
    END IF;
END
$$;

SELECT clearledger._ensure_constraint('settlements', 'settlements_pkey', 'PRIMARY KEY (settlement_id)');
SELECT clearledger._ensure_constraint('events', 'events_pkey', 'PRIMARY KEY (seq)');
SELECT clearledger._ensure_constraint('events', 'events_event_id_key', 'UNIQUE (event_id)');
SELECT clearledger._ensure_constraint('events', 'events_settlement_id_aggregate_version_key',
    'UNIQUE (settlement_id, aggregate_version)');
SELECT clearledger._ensure_constraint('events', 'events_settlement_id_idempotency_key_key',
    'UNIQUE (settlement_id, idempotency_key)');
SELECT clearledger._ensure_constraint('events', 'events_settlement_id_fkey',
    'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT clearledger._ensure_constraint('outbox', 'outbox_pkey', 'PRIMARY KEY (seq)');
SELECT clearledger._ensure_constraint('outbox', 'outbox_event_id_key', 'UNIQUE (event_id)');
SELECT clearledger._ensure_constraint('outbox', 'outbox_settlement_id_aggregate_version_key',
    'UNIQUE (settlement_id, aggregate_version)');
SELECT clearledger._ensure_constraint('outbox', 'outbox_event_id_fkey',
    'FOREIGN KEY (event_id) REFERENCES clearledger.events(event_id) ON DELETE CASCADE');
SELECT clearledger._ensure_constraint('outbox', 'outbox_settlement_id_fkey',
    'FOREIGN KEY (settlement_id) REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE');
SELECT clearledger._ensure_constraint('outbox', 'outbox_settlement_version_fkey',
    'FOREIGN KEY (settlement_id, aggregate_version) REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE');
SELECT clearledger._ensure_constraint('idempotency_keys', 'idempotency_keys_pkey', 'PRIMARY KEY (scope, idempotency_key)');

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

-- settlements: initiation must start at version 1.
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.version IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'settlement % must be initiated at version 1 (got %)', NEW.settlement_id, NEW.version
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

-- settlements: immutable header, +1 stepping, lifecycle progression.
CREATE OR REPLACE FUNCTION clearledger.trg_settlements_before_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.current_status = 'RECONCILED' THEN
        RAISE EXCEPTION 'settlement % is RECONCILED (terminal) and cannot be updated', OLD.settlement_id
            USING ERRCODE = 'P0001';
    END IF;
    IF NEW.settlement_id IS DISTINCT FROM OLD.settlement_id
       OR NEW.account_id IS DISTINCT FROM OLD.account_id
       OR NEW.reference IS DISTINCT FROM OLD.reference
       OR NEW.debit_party IS DISTINCT FROM OLD.debit_party
       OR NEW.credit_party IS DISTINCT FROM OLD.credit_party
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'settlement % header columns are immutable', OLD.settlement_id
            USING ERRCODE = 'P0001';
    END IF;
    IF NEW.version IS DISTINCT FROM OLD.version + 1 THEN
        RAISE EXCEPTION 'settlement % version must step by +1 (% -> %)', OLD.settlement_id, OLD.version, NEW.version
            USING ERRCODE = 'P0001';
    END IF;
    IF NEW.entry_count IS DISTINCT FROM OLD.entry_count + 1 THEN
        RAISE EXCEPTION 'settlement % entry_count must step by +1 (% -> %)', OLD.settlement_id, OLD.entry_count, NEW.entry_count
            USING ERRCODE = 'P0001';
    END IF;
    IF NEW.last_entry_id IS NULL OR NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
        RAISE EXCEPTION 'settlement % update requires a new last_entry_id', OLD.settlement_id
            USING ERRCODE = 'P0001';
    END IF;
    IF NOT (NEW.updated_at > OLD.updated_at) THEN
        RAISE EXCEPTION 'settlement % updated_at must strictly increase', OLD.settlement_id
            USING ERRCODE = 'P0001';
    END IF;
    IF NOT clearledger.is_valid_status_transition(OLD.current_status, NEW.current_status) THEN
        RAISE EXCEPTION 'settlement % invalid status transition % -> %', OLD.settlement_id, OLD.current_status, NEW.current_status
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION clearledger.trg_reject_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'clearledger.% is append-only: % is not permitted', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'P0001';
END
$$;

-- events: contiguous versions, parent consistency, transitions, entryId uniqueness.
CREATE OR REPLACE FUNCTION clearledger.trg_events_before_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    s         clearledger.settlements%ROWTYPE;
    prev      clearledger.events%ROWTYPE;
    max_ver   INTEGER;
    d         JSONB;
    new_entry TEXT;
BEGIN
    IF NOT clearledger.event_columns_match_envelope(
            NEW.payload, NEW.event_id, NEW.settlement_id, NEW.aggregate_version, NEW.event_type,
            NEW.correlation_id, NEW.idempotency_key, NEW.occurred_at) THEN
        RAISE EXCEPTION 'event % payload does not conform to ClearLedgerDomainEventEnvelope or mismatches its columns', NEW.event_id
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO s FROM clearledger.settlements WHERE settlement_id = NEW.settlement_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'event % references unknown settlement %', NEW.event_id, NEW.settlement_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    SELECT COALESCE(MAX(aggregate_version), 0) INTO max_ver
      FROM clearledger.events WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version <> max_ver + 1 THEN
        RAISE EXCEPTION 'event % version % is not contiguous (expected %)', NEW.event_id, NEW.aggregate_version, max_ver + 1
            USING ERRCODE = 'P0001';
    END IF;

    d := NEW.payload->'data';
    new_entry := CASE WHEN jsonb_typeof(d->'entryId') = 'string' THEN d->>'entryId' END;

    IF d->>'accountId' IS DISTINCT FROM s.account_id
       OR d->>'reference' IS DISTINCT FROM s.reference
       OR d->>'debitParty' IS DISTINCT FROM s.debit_party
       OR d->>'creditParty' IS DISTINCT FROM s.credit_party THEN
        RAISE EXCEPTION 'event % header does not match settlement %', NEW.event_id, s.settlement_id
            USING ERRCODE = 'P0001';
    END IF;
    IF NEW.aggregate_version IS DISTINCT FROM s.version
       OR d->>'status' IS DISTINCT FROM s.current_status
       OR d->>'clearingStage' IS DISTINCT FROM s.current_stage
       OR new_entry::uuid IS DISTINCT FROM s.last_entry_id
       OR (CASE WHEN jsonb_typeof(d->'memo') = 'string' THEN d->>'memo' END) IS DISTINCT FROM s.last_memo
       OR NEW.occurred_at IS DISTINCT FROM s.updated_at THEN
        RAISE EXCEPTION 'event % does not match current state of settlement %', NEW.event_id, s.settlement_id
            USING ERRCODE = 'P0001';
    END IF;

    IF NEW.aggregate_version = 1 THEN
        IF NEW.occurred_at IS DISTINCT FROM s.created_at THEN
            RAISE EXCEPTION 'initiation event % occurred_at must equal settlement created_at', NEW.event_id
                USING ERRCODE = 'P0001';
        END IF;
    ELSE
        SELECT * INTO prev FROM clearledger.events
         WHERE settlement_id = NEW.settlement_id AND aggregate_version = NEW.aggregate_version - 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'event % has no predecessor', NEW.event_id USING ERRCODE = 'P0001';
        END IF;
        IF NOT (NEW.occurred_at > prev.occurred_at) THEN
            RAISE EXCEPTION 'event % occurred_at must be strictly after the preceding event', NEW.event_id
                USING ERRCODE = 'P0001';
        END IF;
        IF NOT clearledger.is_valid_status_transition(prev.payload->'data'->>'status', d->>'status') THEN
            RAISE EXCEPTION 'event % invalid status transition % -> %', NEW.event_id,
                prev.payload->'data'->>'status', d->>'status'
                USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (
            SELECT 1 FROM clearledger.events e
             WHERE e.settlement_id = NEW.settlement_id
               AND e.event_type = 'LedgerEntryRecorded'
               AND (e.payload->'data'->>'entryId')::uuid = new_entry::uuid
        ) THEN
            RAISE EXCEPTION 'entryId % already recorded for settlement %', new_entry, NEW.settlement_id
                USING ERRCODE = 'unique_violation';
        END IF;
    END IF;

    RETURN NEW;
END
$$;

-- outbox: insert must mirror the event, in contiguous per-settlement order.
CREATE OR REPLACE FUNCTION clearledger.trg_outbox_before_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    e       clearledger.events%ROWTYPE;
    max_ver INTEGER;
BEGIN
    SELECT * INTO e FROM clearledger.events WHERE event_id = NEW.event_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'outbox row references unknown event %', NEW.event_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF e.settlement_id IS DISTINCT FROM NEW.settlement_id
       OR e.aggregate_version IS DISTINCT FROM NEW.aggregate_version
       OR e.correlation_id IS DISTINCT FROM NEW.correlation_id
       OR e.payload IS DISTINCT FROM NEW.payload THEN
        RAISE EXCEPTION 'outbox row for event % does not mirror clearledger.events', NEW.event_id
            USING ERRCODE = 'P0001';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('clearledger.outbox:' || NEW.settlement_id::text, 0));
    SELECT COALESCE(MAX(aggregate_version), 0) INTO max_ver
      FROM clearledger.outbox WHERE settlement_id = NEW.settlement_id;
    IF NEW.aggregate_version <> max_ver + 1 THEN
        RAISE EXCEPTION 'outbox version % for settlement % is not contiguous (expected %)',
            NEW.aggregate_version, NEW.settlement_id, max_ver + 1
            USING ERRCODE = 'P0001';
    END IF;
    RETURN NEW;
END
$$;

-- outbox: delivery / archival lifecycle.
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
        RAISE EXCEPTION 'outbox % envelope columns are immutable', OLD.seq USING ERRCODE = 'P0001';
    END IF;

    IF NEW.attempts < OLD.attempts THEN
        RAISE EXCEPTION 'outbox % attempts cannot decrease (% -> %)', OLD.seq, OLD.attempts, NEW.attempts
            USING ERRCODE = 'P0001';
    END IF;

    IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
        -- publishing an unpublished row
        IF NEW.attempts <> OLD.attempts + 1 THEN
            RAISE EXCEPTION 'outbox % publishing must increment attempts by 1', OLD.seq USING ERRCODE = 'P0001';
        END IF;
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'outbox % cannot be archived while being published', OLD.seq USING ERRCODE = 'P0001';
        END IF;
    ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
        -- published row: only archived_at may move (set, keep, or reset to NULL)
        IF NEW.published_at IS DISTINCT FROM OLD.published_at
           OR NEW.attempts IS DISTINCT FROM OLD.attempts
           OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
            RAISE EXCEPTION 'outbox % published_at, attempts and last_error are immutable once published', OLD.seq
                USING ERRCODE = 'P0001';
        END IF;
        IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL
           AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
            RAISE EXCEPTION 'outbox % archived_at cannot be re-stamped without first resetting it to NULL', OLD.seq
                USING ERRCODE = 'P0001';
        END IF;
    ELSIF OLD.published_at IS NOT NULL AND NEW.published_at IS NULL THEN
        -- operational replay: reset published_at and archived_at together
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'outbox % replay reset requires archived_at = NULL', OLD.seq USING ERRCODE = 'P0001';
        END IF;
    ELSE
        -- unpublished row (failed delivery bookkeeping)
        IF NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'outbox % cannot be archived before it is published', OLD.seq USING ERRCODE = 'P0001';
        END IF;
    END IF;

    RETURN NEW;
END
$$;

-- idempotency_keys: referenced event must exist in events and outbox; unique responses.
CREATE OR REPLACE FUNCTION clearledger.trg_idempotency_before_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_event_id      UUID;
    v_settlement_id UUID;
    v_version       INTEGER;
BEGIN
    IF NOT clearledger.is_valid_idempotency_record(NEW.scope, NEW.status_code, NEW.response_body) THEN
        RAISE EXCEPTION 'idempotency record %/% has an invalid scope, status or response body', NEW.scope, NEW.idempotency_key
            USING ERRCODE = 'check_violation';
    END IF;

    v_event_id      := (NEW.response_body->>'eventId')::uuid;
    v_settlement_id := (NEW.response_body->>'settlementId')::uuid;
    v_version       := (NEW.response_body->>'version')::integer;

    IF NOT EXISTS (
        SELECT 1 FROM clearledger.events
         WHERE event_id = v_event_id AND settlement_id = v_settlement_id
           AND aggregate_version = v_version AND idempotency_key = NEW.idempotency_key
    ) THEN
        RAISE EXCEPTION 'idempotency record references event % which is not in clearledger.events', v_event_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM clearledger.outbox
         WHERE event_id = v_event_id AND settlement_id = v_settlement_id AND aggregate_version = v_version
    ) THEN
        RAISE EXCEPTION 'idempotency record references event % which is not in clearledger.outbox', v_event_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('clearledger.idempotency:' || v_settlement_id::text, 0));
    IF EXISTS (
        SELECT 1 FROM clearledger.idempotency_keys
         WHERE (response_body->>'eventId')::uuid = v_event_id
            OR ((response_body->>'settlementId')::uuid = v_settlement_id
                AND (response_body->>'version')::integer = v_version)
    ) THEN
        RAISE EXCEPTION 'an idempotency record for event % / settlement % v% already exists',
            v_event_id, v_settlement_id, v_version
            USING ERRCODE = 'unique_violation';
    END IF;

    RETURN NEW;
END
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER settlements_before_insert
    BEFORE INSERT ON clearledger.settlements
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_insert();
CREATE OR REPLACE TRIGGER settlements_before_update
    BEFORE UPDATE ON clearledger.settlements
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_settlements_before_update();
CREATE OR REPLACE TRIGGER settlements_before_delete
    BEFORE DELETE ON clearledger.settlements
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

CREATE OR REPLACE TRIGGER events_before_insert
    BEFORE INSERT ON clearledger.events
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_events_before_insert();
CREATE OR REPLACE TRIGGER events_before_update
    BEFORE UPDATE ON clearledger.events
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();
CREATE OR REPLACE TRIGGER events_before_delete
    BEFORE DELETE ON clearledger.events
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

CREATE OR REPLACE TRIGGER outbox_before_insert
    BEFORE INSERT ON clearledger.outbox
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_insert();
CREATE OR REPLACE TRIGGER outbox_before_update
    BEFORE UPDATE ON clearledger.outbox
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_outbox_before_update();
CREATE OR REPLACE TRIGGER outbox_before_delete
    BEFORE DELETE ON clearledger.outbox
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

CREATE OR REPLACE TRIGGER idempotency_keys_before_insert
    BEFORE INSERT ON clearledger.idempotency_keys
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_idempotency_before_insert();
CREATE OR REPLACE TRIGGER idempotency_keys_before_update
    BEFORE UPDATE ON clearledger.idempotency_keys
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();
CREATE OR REPLACE TRIGGER idempotency_keys_before_delete
    BEFORE DELETE ON clearledger.idempotency_keys
    FOR EACH ROW EXECUTE FUNCTION clearledger.trg_reject_mutation();

-- Re-enable every trigger (including any disabled out-of-band).
ALTER TABLE clearledger.settlements      ENABLE TRIGGER ALL;
ALTER TABLE clearledger.events           ENABLE TRIGGER ALL;
ALTER TABLE clearledger.outbox           ENABLE TRIGGER ALL;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER ALL;

-- ---------------------------------------------------------------------------
-- Indexes (recreated when missing or when their definition drifted)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clearledger._ensure_index(idx TEXT, ddl TEXT, expected TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    current_def TEXT;
BEGIN
    SELECT indexdef INTO current_def FROM pg_indexes WHERE schemaname = 'clearledger' AND indexname = idx;
    IF current_def IS NOT NULL
       AND regexp_replace(current_def, '\s+', ' ', 'g') <> expected THEN
        EXECUTE format('DROP INDEX clearledger.%I', idx);
        current_def := NULL;
    END IF;
    IF current_def IS NULL THEN
        EXECUTE ddl;
    END IF;
END
$$;

SELECT clearledger._ensure_index(
    'idx_clearledger_outbox_unpublished',
    'CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox (seq) WHERE published_at IS NULL',
    'CREATE INDEX idx_clearledger_outbox_unpublished ON clearledger.outbox USING btree (seq) WHERE (published_at IS NULL)');
SELECT clearledger._ensure_index(
    'idx_clearledger_outbox_unarchived',
    'CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox (seq) WHERE published_at IS NOT NULL AND archived_at IS NULL',
    'CREATE INDEX idx_clearledger_outbox_unarchived ON clearledger.outbox USING btree (seq) WHERE ((published_at IS NOT NULL) AND (archived_at IS NULL))');
SELECT clearledger._ensure_index(
    'idx_clearledger_events_settlement_version',
    'CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events (settlement_id, aggregate_version)',
    'CREATE INDEX idx_clearledger_events_settlement_version ON clearledger.events USING btree (settlement_id, aggregate_version)');

-- Make sure no index was left INVALID by an interrupted build.
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT c.relname FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'clearledger' AND NOT i.indisvalid
    LOOP
        EXECUTE format('REINDEX INDEX clearledger.%I', r.relname);
    END LOOP;
END
$$;
