#!/usr/bin/env bash
set -euo pipefail

unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy
export PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export NO_PROXY="localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
export no_proxy="localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
export AWS_EC2_METADATA_DISABLED="true"

CONFIG_FILE="/workspace/config/config.json"
SUBMISSION_DIR="/workspace/submission"
INFRA_DIR="${SUBMISSION_DIR}/infra"
STATE_FILE="${INFRA_DIR}/terraform.tfstate"
MANIFEST_FILE="${SUBMISSION_DIR}/manifest.json"
TFVARS_FILE="${INFRA_DIR}/config.auto.tfvars.json"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Missing ${CONFIG_FILE}" >&2
  exit 1
fi

if command -v terraform >/dev/null 2>&1; then
  IAC_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then
  IAC_BIN="tofu"
else
  echo "Neither terraform nor tofu is available" >&2
  exit 1
fi

export AWS_REGION="$(jq -r '.region' "${CONFIG_FILE}")"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_ENDPOINT_URL="$(jq -r '.aws_endpoint_url' "${CONFIG_FILE}")"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export TF_IN_AUTOMATION=1

cp "${CONFIG_FILE}" "${TFVARS_FILE}"

# Pre-reconcile any existing canonical KMS keys that were scheduled for deletion or disabled out-of-band
# so that Terraform refresh/apply can read and update them without KMSInvalidStateException.
/opt/venv/bin/python3 - <<'PY' || true
import json
from pathlib import Path
import boto3

cfg = json.loads(Path("/workspace/config/config.json").read_text(encoding="utf-8"))
kms = boto3.client(
    "kms",
    region_name=cfg["region"],
    endpoint_url=cfg["aws_endpoint_url"],
    aws_access_key_id="test",
    aws_secret_access_key="test",
)
key_ids: set[str] = set()
manifest_path = Path("/workspace/submission/manifest.json")
if manifest_path.is_file():
    try:
        m = json.loads(manifest_path.read_text(encoding="utf-8"))
        for arn in (m.get("kms") or {}).values():
            if arn:
                key_ids.add(str(arn))
    except Exception:
        pass
state_path = Path("/workspace/submission/infra/terraform.tfstate")
if state_path.is_file():
    try:
        st = json.loads(state_path.read_text(encoding="utf-8"))
        for res in st.get("resources", []):
            if res.get("mode") == "managed" and res.get("type") == "aws_kms_key":
                for inst in res.get("instances", []):
                    attrs = inst.get("attributes") or {}
                    kid = attrs.get("key_id") or attrs.get("arn") or attrs.get("id")
                    if kid:
                        key_ids.add(str(kid))
    except Exception:
        pass
for kid in key_ids:
    try:
        kms.cancel_key_deletion(KeyId=kid)
    except Exception:
        pass
    try:
        kms.enable_key(KeyId=kid)
    except Exception:
        pass
    try:
        kms.enable_key_rotation(KeyId=kid)
    except Exception:
        pass
PY

pushd "${INFRA_DIR}" >/dev/null

"${IAC_BIN}" init -input=false -no-color >/dev/null

"${IAC_BIN}" apply \
  -input=false \
  -auto-approve \
  -no-color \
  -state="${STATE_FILE}"

"${IAC_BIN}" output \
  -json \
  -state="${STATE_FILE}" \
  manifest >"${MANIFEST_FILE}.tmp"

mv "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"
popd >/dev/null

DB_RAW_HOST="$(jq -r '.database.endpoint' "${MANIFEST_FILE}")"
if [[ "${DB_RAW_HOST}" == "localhost" || "${DB_RAW_HOST}" == *.amazonaws.com ]]; then
  DB_HOST="aws"
else
  DB_HOST="${DB_RAW_HOST}"
fi
DB_PORT="$(jq -r '.database.port' "${MANIFEST_FILE}")"
DB_NAME="$(jq -r '.database.db_name' "${MANIFEST_FILE}")"
DB_USER="$(jq -r '.database.username' "${MANIFEST_FILE}")"
export PGPASSWORD="$(jq -r '.db_password' "${CONFIG_FILE}")"

for _ in $(seq 1 30); do
  if psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

psql -v ON_ERROR_STOP=1 -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" <<'SQL' >/dev/null
CREATE SCHEMA IF NOT EXISTS clearledger;

CREATE TABLE IF NOT EXISTS clearledger.settlements (
    settlement_id UUID PRIMARY KEY,
    account_id TEXT NOT NULL,
    reference TEXT NOT NULL,
    debit_party TEXT NOT NULL,
    credit_party TEXT NOT NULL,
    current_status TEXT NOT NULL,
    current_stage TEXT NOT NULL,
    last_entry_id UUID NULL,
    last_memo TEXT NULL,
    version INTEGER NOT NULL,
    entry_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_settlements_nonempty_fields CHECK (
        char_length(btrim(account_id)) BETWEEN 3 AND 64
        AND account_id = btrim(account_id)
        AND char_length(btrim(reference)) BETWEEN 3 AND 64
        AND reference = btrim(reference)
        AND char_length(btrim(debit_party)) BETWEEN 2 AND 64
        AND debit_party = btrim(debit_party)
        AND char_length(btrim(credit_party)) BETWEEN 2 AND 64
        AND credit_party = btrim(credit_party)
        AND char_length(btrim(current_stage)) BETWEEN 2 AND 64
        AND current_stage = btrim(current_stage)
        AND (last_memo IS NULL OR (char_length(btrim(last_memo)) BETWEEN 1 AND 256 AND last_memo = btrim(last_memo)))
        AND updated_at >= created_at
    ),
    CONSTRAINT chk_settlements_distinct_parties CHECK (btrim(debit_party) <> btrim(credit_party)),
    CONSTRAINT chk_settlements_version_positive CHECK (version >= 1),
    CONSTRAINT chk_settlements_entry_count_version CHECK (entry_count >= 0 AND entry_count = version - 1),
    CONSTRAINT chk_settlements_lifecycle_state CHECK (
        (
            version = 1
            AND entry_count = 0
            AND current_status = 'INITIATED'
            AND current_stage = ('INITIATED@' || debit_party)
            AND last_entry_id IS NULL
            AND last_memo = 'Settlement initiated'
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
    ),
    CONSTRAINT chk_settlements_status_enum CHECK (
        current_status IN (
            'INITIATED',
            'VALIDATED',
            'RESERVED',
            'CLEARED',
            'SETTLED',
            'RECONCILED',
            'DISPUTED'
        )
    )
);

CREATE TABLE IF NOT EXISTS clearledger.events (
    seq BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE,
    settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
    aggregate_version INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    correlation_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (settlement_id, aggregate_version),
    UNIQUE (settlement_id, idempotency_key),
    CONSTRAINT chk_events_nonempty_fields CHECK (
        char_length(btrim(correlation_id)) BETWEEN 4 AND 128
        AND correlation_id = btrim(correlation_id)
        AND char_length(btrim(idempotency_key)) BETWEEN 8 AND 128
        AND idempotency_key = btrim(idempotency_key)
    ),
    CONSTRAINT chk_events_version_positive CHECK (aggregate_version >= 1),
    CONSTRAINT chk_events_type_version CHECK (
        (event_type = 'SettlementInitiated' AND aggregate_version = 1)
        OR
        (event_type = 'LedgerEntryRecorded' AND aggregate_version >= 2)
    ),
    CONSTRAINT chk_events_payload_coherence CHECK (
        (
            jsonb_typeof(payload) = 'object'
            AND (payload - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) = '{}'::jsonb
            AND payload->>'schemaVersion' = '1.0'
            AND payload->>'aggregateType' = 'settlement'
            AND payload->>'eventId' = event_id::text
            AND payload->>'aggregateId' = settlement_id::text
            AND (payload->>'aggregateVersion') ~ '^[0-9]+$'
            AND (payload->>'aggregateVersion')::integer = aggregate_version
            AND payload->>'eventType' = event_type
            AND payload->>'correlationId' = correlation_id
            AND payload->>'idempotencyKey' = idempotency_key
            AND btrim(COALESCE(payload->>'occurredAt', '')) <> ''
            AND jsonb_typeof(payload->'data') = 'object'
            AND ((payload->'data') - ARRAY['kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo']) = '{}'::jsonb
            AND char_length(btrim(COALESCE(payload #>> '{data,accountId}', ''))) BETWEEN 3 AND 64
            AND (payload #>> '{data,accountId}') = btrim(COALESCE(payload #>> '{data,accountId}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,clearingStage}', ''))) BETWEEN 2 AND 64
            AND (payload #>> '{data,clearingStage}') = btrim(COALESCE(payload #>> '{data,clearingStage}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,reference}', ''))) BETWEEN 3 AND 64
            AND (payload #>> '{data,reference}') = btrim(COALESCE(payload #>> '{data,reference}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,debitParty}', ''))) BETWEEN 2 AND 64
            AND (payload #>> '{data,debitParty}') = btrim(COALESCE(payload #>> '{data,debitParty}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,creditParty}', ''))) BETWEEN 2 AND 64
            AND (payload #>> '{data,creditParty}') = btrim(COALESCE(payload #>> '{data,creditParty}', ''))
            AND btrim(COALESCE(payload #>> '{data,debitParty}', '')) <> btrim(COALESCE(payload #>> '{data,creditParty}', ''))
            AND (
                payload->'data'->'memo' IS NULL
                OR jsonb_typeof(payload->'data'->'memo') = 'null'
                OR (
                    char_length(btrim(COALESCE(payload #>> '{data,memo}', ''))) BETWEEN 1 AND 256
                    AND (payload #>> '{data,memo}') = btrim(COALESCE(payload #>> '{data,memo}', ''))
                )
            )
            AND (
                (
                    event_type = 'SettlementInitiated'
                    AND payload #>> '{data,kind}' = 'settlementInitiated'
                    AND payload #>> '{data,status}' = 'INITIATED'
                    AND (payload #>> '{data,clearingStage}') = ('INITIATED@' || (payload #>> '{data,debitParty}'))
                    AND (payload #>> '{data,memo}') = 'Settlement initiated'
                    AND (payload->'data'->'entryId' IS NULL OR jsonb_typeof(payload->'data'->'entryId') = 'null')
                )
                OR
                (
                    event_type = 'LedgerEntryRecorded'
                    AND payload #>> '{data,kind}' = 'ledgerEntryRecorded'
                    AND (payload #>> '{data,status}') IN ('VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED', 'RECONCILED', 'DISPUTED')
                    AND (payload #>> '{data,entryId}') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                )
            )
        ) IS TRUE
    )
);

CREATE TABLE IF NOT EXISTS clearledger.outbox (
    seq BIGSERIAL PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE REFERENCES clearledger.events(event_id) ON DELETE CASCADE,
    settlement_id UUID NOT NULL REFERENCES clearledger.settlements(settlement_id) ON DELETE CASCADE,
    aggregate_version INTEGER NOT NULL,
    correlation_id TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ NULL,
    archived_at TIMESTAMPTZ NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NULL,
    UNIQUE (settlement_id, aggregate_version),
    FOREIGN KEY (settlement_id, aggregate_version)
        REFERENCES clearledger.events(settlement_id, aggregate_version) ON DELETE CASCADE,
    CONSTRAINT chk_outbox_nonempty_corr CHECK (
        char_length(btrim(correlation_id)) BETWEEN 4 AND 128
        AND correlation_id = btrim(correlation_id)
    ),
    CONSTRAINT chk_outbox_version_positive CHECK (aggregate_version >= 1),
    CONSTRAINT chk_outbox_attempts_nonnegative CHECK (attempts >= 0),
    CONSTRAINT chk_outbox_attempts_zero_state CHECK (
        attempts > 0 OR (published_at IS NULL AND last_error IS NULL)
    ),
    CONSTRAINT chk_outbox_published_attempts CHECK (
        published_at IS NULL OR (attempts >= 1 AND last_error IS NULL AND published_at >= created_at)
    ),
    CONSTRAINT chk_outbox_last_error_state CHECK (
        last_error IS NULL OR (
            published_at IS NULL
            AND attempts >= 1
            AND char_length(btrim(last_error)) > 0
            AND last_error = btrim(last_error)
        )
    ),
    CONSTRAINT chk_outbox_archived_requires_published CHECK (
        archived_at IS NULL OR (published_at IS NOT NULL AND archived_at >= published_at)
    ),
    CONSTRAINT chk_outbox_payload_coherence CHECK (
        (
            jsonb_typeof(payload) = 'object'
            AND (payload - ARRAY['schemaVersion','eventId','eventType','aggregateType','aggregateId','aggregateVersion','occurredAt','correlationId','idempotencyKey','data']) = '{}'::jsonb
            AND payload->>'schemaVersion' = '1.0'
            AND payload->>'aggregateType' = 'settlement'
            AND payload->>'eventId' = event_id::text
            AND payload->>'aggregateId' = settlement_id::text
            AND (payload->>'aggregateVersion') ~ '^[0-9]+$'
            AND (payload->>'aggregateVersion')::integer = aggregate_version
            AND payload->>'correlationId' = correlation_id
            AND char_length(btrim(COALESCE(payload->>'idempotencyKey', ''))) BETWEEN 8 AND 128
            AND (payload->>'idempotencyKey') = btrim(COALESCE(payload->>'idempotencyKey', ''))
            AND btrim(COALESCE(payload->>'occurredAt', '')) <> ''
            AND jsonb_typeof(payload->'data') = 'object'
            AND ((payload->'data') - ARRAY['kind','accountId','reference','debitParty','creditParty','entryId','status','clearingStage','memo']) = '{}'::jsonb
            AND char_length(btrim(COALESCE(payload #>> '{data,accountId}', ''))) BETWEEN 3 AND 64
            AND (payload #>> '{data,accountId}') = btrim(COALESCE(payload #>> '{data,accountId}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,clearingStage}', ''))) BETWEEN 2 AND 64
            AND (payload #>> '{data,clearingStage}') = btrim(COALESCE(payload #>> '{data,clearingStage}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,reference}', ''))) BETWEEN 3 AND 64
            AND (payload #>> '{data,reference}') = btrim(COALESCE(payload #>> '{data,reference}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,debitParty}', ''))) BETWEEN 2 AND 64
            AND (payload #>> '{data,debitParty}') = btrim(COALESCE(payload #>> '{data,debitParty}', ''))
            AND char_length(btrim(COALESCE(payload #>> '{data,creditParty}', ''))) BETWEEN 2 AND 64
            AND (payload #>> '{data,creditParty}') = btrim(COALESCE(payload #>> '{data,creditParty}', ''))
            AND btrim(COALESCE(payload #>> '{data,debitParty}', '')) <> btrim(COALESCE(payload #>> '{data,creditParty}', ''))
            AND (
                payload->'data'->'memo' IS NULL
                OR jsonb_typeof(payload->'data'->'memo') = 'null'
                OR (
                    char_length(btrim(COALESCE(payload #>> '{data,memo}', ''))) BETWEEN 1 AND 256
                    AND (payload #>> '{data,memo}') = btrim(COALESCE(payload #>> '{data,memo}', ''))
                )
            )
            AND (
                (
                    aggregate_version = 1
                    AND payload->>'eventType' = 'SettlementInitiated'
                    AND payload #>> '{data,kind}' = 'settlementInitiated'
                    AND payload #>> '{data,status}' = 'INITIATED'
                    AND (payload #>> '{data,clearingStage}') = ('INITIATED@' || (payload #>> '{data,debitParty}'))
                    AND (payload #>> '{data,memo}') = 'Settlement initiated'
                    AND (payload->'data'->'entryId' IS NULL OR jsonb_typeof(payload->'data'->'entryId') = 'null')
                )
                OR
                (
                    aggregate_version >= 2
                    AND payload->>'eventType' = 'LedgerEntryRecorded'
                    AND payload #>> '{data,kind}' = 'ledgerEntryRecorded'
                    AND (payload #>> '{data,status}') IN ('VALIDATED', 'RESERVED', 'CLEARED', 'SETTLED', 'RECONCILED', 'DISPUTED')
                    AND (payload #>> '{data,entryId}') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                )
            )
        ) IS TRUE
    )
);

CREATE TABLE IF NOT EXISTS clearledger.idempotency_keys (
    scope TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    response_body JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (scope, idempotency_key),
    CONSTRAINT chk_idempotency_fields CHECK (
        (
            scope ~ '^(create|entry):[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            AND request_hash ~ '^[0-9a-f]{64}$'
            AND char_length(btrim(idempotency_key)) BETWEEN 8 AND 128
            AND idempotency_key = btrim(idempotency_key)
            AND jsonb_typeof(response_body) = 'object'
            AND (response_body - ARRAY['settlementId','eventId','version','accepted','idempotentReplay']) = '{}'::jsonb
            AND response_body->>'settlementId' = split_part(scope, ':', 2)
            AND (response_body->>'eventId') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            AND (response_body->>'version') ~ '^[0-9]+$'
            AND response_body->'accepted' = 'true'::jsonb
            AND response_body->'idempotentReplay' = 'false'::jsonb
        ) IS TRUE
    ),
    CONSTRAINT chk_idempotency_status_code CHECK (
        (
            (scope LIKE 'create:%' AND status_code = 201 AND (response_body->>'version')::integer = 1)
            OR
            (scope LIKE 'entry:%' AND status_code = 202 AND (response_body->>'version')::integer >= 2)
        ) IS TRUE
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_unique_event_id
    ON clearledger.idempotency_keys ((response_body->>'eventId'));

CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_unique_settlement_version
    ON clearledger.idempotency_keys ((response_body->>'settlementId'), ((response_body->>'version')::integer));

CREATE OR REPLACE FUNCTION clearledger.fn_guard_idempotency_keys()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_ev_sid uuid;
    v_ev_ver integer;
    v_ev_idem text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT settlement_id, aggregate_version, idempotency_key
          INTO v_ev_sid, v_ev_ver, v_ev_idem
          FROM clearledger.events
         WHERE event_id = (NEW.response_body->>'eventId')::uuid;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Idempotency eventId % not found in clearledger.events', NEW.response_body->>'eventId'
                USING ERRCODE = '23503';
        END IF;

        IF v_ev_sid <> (NEW.response_body->>'settlementId')::uuid
           OR v_ev_ver <> (NEW.response_body->>'version')::integer
           OR v_ev_idem <> NEW.idempotency_key THEN
            RAISE EXCEPTION 'Idempotency row does not match referenced clearledger.events row'
                USING ERRCODE = '23514';
        END IF;

        IF NOT EXISTS (
            SELECT 1
              FROM clearledger.outbox
             WHERE event_id = (NEW.response_body->>'eventId')::uuid
               AND settlement_id = v_ev_sid
               AND aggregate_version = v_ev_ver
        ) THEN
            RAISE EXCEPTION 'Idempotency eventId % not found in clearledger.outbox', NEW.response_body->>'eventId'
                USING ERRCODE = '23503';
        END IF;

        IF EXISTS (
            SELECT 1
              FROM clearledger.idempotency_keys
             WHERE (response_body->>'eventId') = (NEW.response_body->>'eventId')
                OR (
                    (response_body->>'settlementId') = (NEW.response_body->>'settlementId')
                    AND (response_body->>'version')::integer = (NEW.response_body->>'version')::integer
                )
        ) THEN
            RAISE EXCEPTION 'Duplicate eventId or (settlementId, version) in clearledger.idempotency_keys'
                USING ERRCODE = '23505';
        END IF;

        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'clearledger.idempotency_keys is an append-only ledger (% is forbidden)', TG_OP
        USING ERRCODE = '23514';
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_idempotency_guard ON clearledger.idempotency_keys;
CREATE TRIGGER trg_clearledger_idempotency_guard
    BEFORE INSERT OR UPDATE OR DELETE ON clearledger.idempotency_keys
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_idempotency_keys();

CREATE OR REPLACE FUNCTION clearledger.fn_status_rank(p_status text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE p_status
        WHEN 'INITIATED' THEN 0
        WHEN 'VALIDATED' THEN 1
        WHEN 'RESERVED' THEN 2
        WHEN 'CLEARED' THEN 3
        WHEN 'SETTLED' THEN 4
        WHEN 'RECONCILED' THEN 5
        ELSE -1
    END;
$$;

CREATE OR REPLACE FUNCTION clearledger.fn_guard_settlements_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.settlement_id <> OLD.settlement_id
       OR NEW.account_id <> OLD.account_id
       OR NEW.reference <> OLD.reference
       OR NEW.debit_party <> OLD.debit_party
       OR NEW.credit_party <> OLD.credit_party
       OR NEW.created_at <> OLD.created_at THEN
        RAISE EXCEPTION 'Immutable settlement header attributes cannot be modified'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.version <> OLD.version + 1 OR NEW.entry_count <> OLD.entry_count + 1 THEN
        RAISE EXCEPTION 'Settlement version and entry_count must increment by exactly 1'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.updated_at <= OLD.updated_at THEN
        RAISE EXCEPTION 'Settlement updated_at must strictly increase beyond OLD.updated_at'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.last_entry_id IS NOT DISTINCT FROM OLD.last_entry_id THEN
        RAISE EXCEPTION 'Settlement update must record a distinct last_entry_id'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.current_status = 'RECONCILED' THEN
        RAISE EXCEPTION 'RECONCILED settlement is strictly terminal and cannot be updated'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.current_status = 'DISPUTED'
       AND NEW.current_status NOT IN ('DISPUTED', 'RECONCILED') THEN
        RAISE EXCEPTION 'DISPUTED settlement can only remain DISPUTED or resolve to RECONCILED, not %', NEW.current_status
            USING ERRCODE = '23514';
    END IF;

    IF OLD.current_status <> 'DISPUTED' AND NEW.current_status <> 'DISPUTED' THEN
        IF clearledger.fn_status_rank(NEW.current_status) < clearledger.fn_status_rank(OLD.current_status) THEN
            RAISE EXCEPTION 'Settlement cannot regress from % to %', OLD.current_status, NEW.current_status
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_settlements_before_update ON clearledger.settlements;
CREATE TRIGGER trg_clearledger_settlements_before_update
    BEFORE UPDATE ON clearledger.settlements
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_settlements_update();

CREATE OR REPLACE FUNCTION clearledger.fn_guard_settlements_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'clearledger.settlements is an append-only aggregate root (DELETE is forbidden)'
        USING ERRCODE = '23514';
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_settlements_before_delete ON clearledger.settlements;
CREATE TRIGGER trg_clearledger_settlements_before_delete
    BEFORE DELETE ON clearledger.settlements
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_settlements_delete();

CREATE OR REPLACE FUNCTION clearledger.fn_guard_events_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_ver integer;
    v_acct text;
    v_ref text;
    v_debit text;
    v_credit text;
    v_status text;
    v_stage text;
    v_last_entry uuid;
    v_last_memo text;
    v_parent_ver integer;
    v_parent_created timestamptz;
    v_parent_updated timestamptz;
    v_prev_occurred timestamptz;
    v_prev_status text;
    v_dup_entry integer;
BEGIN
    IF ABS(EXTRACT(EPOCH FROM ((NEW.payload->>'occurredAt')::timestamptz - NEW.occurred_at))) > 0.001 THEN
        RAISE EXCEPTION 'Event payload occurredAt does not match occurred_at column'
            USING ERRCODE = '23514';
    END IF;

    SELECT COALESCE(MAX(aggregate_version), 0)
      INTO v_max_ver
      FROM clearledger.events
     WHERE settlement_id = NEW.settlement_id;

    IF NEW.aggregate_version <> v_max_ver + 1 THEN
        RAISE EXCEPTION 'Non-contiguous event aggregate_version % (expected %)', NEW.aggregate_version, v_max_ver + 1
            USING ERRCODE = '23514';
    END IF;

    SELECT account_id, reference, debit_party, credit_party, current_status, current_stage,
           last_entry_id, last_memo, version, created_at, updated_at
      INTO v_acct, v_ref, v_debit, v_credit, v_status, v_stage,
           v_last_entry, v_last_memo, v_parent_ver, v_parent_created, v_parent_updated
      FROM clearledger.settlements
     WHERE settlement_id = NEW.settlement_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parent settlement % does not exist', NEW.settlement_id
            USING ERRCODE = '23503';
    END IF;

    IF v_parent_ver <> NEW.aggregate_version
       OR v_acct <> (NEW.payload #>> '{data,accountId}')
       OR v_ref <> (NEW.payload #>> '{data,reference}')
       OR v_debit <> (NEW.payload #>> '{data,debitParty}')
       OR v_credit <> (NEW.payload #>> '{data,creditParty}')
       OR v_status <> (NEW.payload #>> '{data,status}')
       OR v_stage <> (NEW.payload #>> '{data,clearingStage}')
       OR COALESCE(v_last_memo, '') <> COALESCE(NEW.payload #>> '{data,memo}', '')
       OR ABS(EXTRACT(EPOCH FROM (NEW.occurred_at - v_parent_updated))) > 0.001
       OR (NEW.aggregate_version = 1 AND ABS(EXTRACT(EPOCH FROM (NEW.occurred_at - v_parent_created))) > 0.001) THEN
        RAISE EXCEPTION 'Event row does not match parent settlement state at version %', NEW.aggregate_version
            USING ERRCODE = '23514';
    END IF;

    IF NEW.aggregate_version >= 2 THEN
        IF v_last_entry IS NULL OR v_last_entry::text <> (NEW.payload #>> '{data,entryId}') THEN
            RAISE EXCEPTION 'LedgerEntryRecorded entryId does not match parent settlement last_entry_id'
                USING ERRCODE = '23514';
        END IF;

        SELECT occurred_at, payload #>> '{data,status}'
          INTO v_prev_occurred, v_prev_status
          FROM clearledger.events
         WHERE settlement_id = NEW.settlement_id
           AND aggregate_version = NEW.aggregate_version - 1;

        IF NEW.occurred_at <= v_prev_occurred THEN
            RAISE EXCEPTION 'Event occurred_at (%) must strictly increase beyond previous event occurred_at (%)', NEW.occurred_at, v_prev_occurred
                USING ERRCODE = '23514';
        END IF;

        IF v_prev_status = 'RECONCILED' THEN
            RAISE EXCEPTION 'Cannot record event after terminal RECONCILED event'
                USING ERRCODE = '23514';
        ELSIF v_prev_status = 'DISPUTED' AND (NEW.payload #>> '{data,status}') NOT IN ('DISPUTED', 'RECONCILED') THEN
            RAISE EXCEPTION 'Cannot transition from DISPUTED event to %', NEW.payload #>> '{data,status}'
                USING ERRCODE = '23514';
        ELSIF v_prev_status <> 'DISPUTED' AND (NEW.payload #>> '{data,status}') <> 'DISPUTED'
              AND clearledger.fn_status_rank(NEW.payload #>> '{data,status}') < clearledger.fn_status_rank(v_prev_status) THEN
            RAISE EXCEPTION 'Event status cannot regress from % to %', v_prev_status, NEW.payload #>> '{data,status}'
                USING ERRCODE = '23514';
        END IF;

        SELECT COUNT(*)
          INTO v_dup_entry
          FROM clearledger.events
         WHERE settlement_id = NEW.settlement_id
           AND aggregate_version >= 2
           AND (payload #>> '{data,entryId}') = (NEW.payload #>> '{data,entryId}');

        IF v_dup_entry > 0 THEN
            RAISE EXCEPTION 'Duplicate entryId % for settlement %', NEW.payload #>> '{data,entryId}', NEW.settlement_id
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_events_before_insert ON clearledger.events;
CREATE TRIGGER trg_clearledger_events_before_insert
    BEFORE INSERT ON clearledger.events
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_events_insert();

CREATE OR REPLACE FUNCTION clearledger.fn_guard_events_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'clearledger.events is an append-only event log (% is forbidden)', TG_OP
        USING ERRCODE = '23514';
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_events_immutable ON clearledger.events;
CREATE TRIGGER trg_clearledger_events_immutable
    BEFORE UPDATE OR DELETE ON clearledger.events
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_events_immutable();

CREATE OR REPLACE FUNCTION clearledger.fn_guard_outbox_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_outbox_ver integer;
    v_ev_sid uuid;
    v_ev_ver integer;
    v_ev_corr text;
    v_ev_payload jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT COALESCE(MAX(aggregate_version), 0)
          INTO v_max_outbox_ver
          FROM clearledger.outbox
         WHERE settlement_id = NEW.settlement_id;

        IF NEW.aggregate_version <> v_max_outbox_ver + 1 THEN
            RAISE EXCEPTION 'Non-contiguous outbox aggregate_version % (expected %)', NEW.aggregate_version, v_max_outbox_ver + 1
                USING ERRCODE = '23514';
        END IF;

        SELECT settlement_id, aggregate_version, correlation_id, payload
          INTO v_ev_sid, v_ev_ver, v_ev_corr, v_ev_payload
          FROM clearledger.events
         WHERE event_id = NEW.event_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Outbox event_id % not found in clearledger.events', NEW.event_id
                USING ERRCODE = '23503';
        END IF;

        IF v_ev_sid <> NEW.settlement_id
           OR v_ev_ver <> NEW.aggregate_version
           OR v_ev_corr <> NEW.correlation_id
           OR v_ev_payload <> NEW.payload THEN
            RAISE EXCEPTION 'Outbox row does not match referenced clearledger.events row'
                USING ERRCODE = '23514';
        END IF;

        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'clearledger.outbox rows cannot be deleted'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.seq <> OLD.seq
       OR NEW.event_id <> OLD.event_id
       OR NEW.settlement_id <> OLD.settlement_id
       OR NEW.aggregate_version <> OLD.aggregate_version
       OR NEW.correlation_id <> OLD.correlation_id
       OR NEW.payload <> OLD.payload
       OR NEW.created_at <> OLD.created_at
       OR NEW.attempts < OLD.attempts THEN
        RAISE EXCEPTION 'clearledger.outbox envelope is immutable and attempts cannot decrease'
            USING ERRCODE = '23514';
    END IF;

    IF OLD.published_at IS NULL AND NEW.published_at IS NOT NULL THEN
        IF NEW.attempts < OLD.attempts + 1 OR NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Publishing an unpublished outbox row requires incrementing attempts and keeping archived_at NULL'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF OLD.published_at IS NOT NULL AND NEW.published_at IS NOT NULL THEN
        IF NEW.published_at IS DISTINCT FROM OLD.published_at
           OR NEW.attempts <> OLD.attempts
           OR NEW.last_error IS DISTINCT FROM OLD.last_error THEN
            RAISE EXCEPTION 'Once published_at is set on clearledger.outbox, published_at, attempts, and last_error are immutable'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NOT NULL AND NEW.archived_at IS DISTINCT FROM OLD.archived_at THEN
        RAISE EXCEPTION 'Once archived_at is set on clearledger.outbox, it cannot be mutated without resetting archived_at to NULL first'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_clearledger_outbox_guard ON clearledger.outbox;
CREATE TRIGGER trg_clearledger_outbox_guard
    BEFORE INSERT OR UPDATE OR DELETE ON clearledger.outbox
    FOR EACH ROW
    EXECUTE FUNCTION clearledger.fn_guard_outbox_mutation();

ALTER TABLE clearledger.settlements ENABLE TRIGGER ALL;
ALTER TABLE clearledger.events ENABLE TRIGGER ALL;
ALTER TABLE clearledger.outbox ENABLE TRIGGER ALL;
ALTER TABLE clearledger.idempotency_keys ENABLE TRIGGER ALL;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unpublished
    ON clearledger.outbox (seq)
    WHERE published_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_outbox_unarchived
    ON clearledger.outbox (seq)
    WHERE published_at IS NOT NULL AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_clearledger_events_settlement_version
    ON clearledger.events (settlement_id, aggregate_version);

CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_event
    ON clearledger.idempotency_keys (((response_body->>'eventId')::uuid));

CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_idempotency_version
    ON clearledger.idempotency_keys (((response_body->>'settlementId')::uuid), ((response_body->>'version')::integer));

CREATE UNIQUE INDEX IF NOT EXISTS idx_clearledger_entry_id
    ON clearledger.events (settlement_id, ((payload->'data'->>'entryId')::uuid))
    WHERE event_type = 'LedgerEntryRecorded';
SQL

SERVICE_URL="$(jq -r '.service_url' "${MANIFEST_FILE}")"
READY_URL="${SERVICE_URL%/}/health/ready"

READY_OK=0
for attempt in $(seq 1 90); do
  if curl -fsS --max-time 5 "${READY_URL}" >/dev/null 2>&1 || /opt/venv/bin/python3 -c "import sys, urllib.request; r = urllib.request.urlopen('${READY_URL}', timeout=5); sys.exit(0 if r.status == 200 else 1)" >/dev/null 2>&1; then
    READY_OK=1
    break
  fi
  if [[ "${attempt}" -eq 3 || "${attempt}" -eq 15 || "${attempt}" -eq 30 || "${attempt}" -eq 50 ]]; then
    /opt/venv/bin/python3 - <<'PY' || true
import json
import boto3

with open("/workspace/config/config.json", encoding="utf-8") as f:
    cfg = json.load(f)
with open("/workspace/submission/manifest.json", encoding="utf-8") as f:
    m = json.load(f)

kw = {
    "region_name": cfg["region"],
    "endpoint_url": cfg["aws_endpoint_url"],
    "aws_access_key_id": "test",
    "aws_secret_access_key": "test",
}
ecs = boto3.client("ecs", **kw)
elbv2 = boto3.client("elbv2", **kw)
cluster = m["compute"]["cluster_arn"]
service = m["compute"]["service_name"]
tg_arn = m["ingress"]["target_group_arn"]

task_arns = ecs.list_tasks(cluster=cluster, serviceName=service).get("taskArns", [])
running_ips = []
if task_arns:
    tasks = ecs.describe_tasks(cluster=cluster, tasks=task_arns).get("tasks", [])
    for t in tasks:
        if t.get("lastStatus") == "RUNNING":
            for att in t.get("attachments", []):
                for d in att.get("details", []):
                    if d.get("name") == "privateIPv4Address" and d.get("value"):
                        running_ips.append(d["value"])
            for c in t.get("containers", []):
                for ni in c.get("networkInterfaces", []):
                    if ni.get("privateIpv4Address"):
                        running_ips.append(ni["privateIpv4Address"])

if len(task_arns) < 2:
    ecs.update_service(cluster=cluster, service=service, desiredCount=2, forceNewDeployment=True)
elif running_ips:
    th = elbv2.describe_target_health(TargetGroupArn=tg_arn).get("TargetHealthDescriptions", [])
    reg_ips = {d.get("Target", {}).get("Id") for d in th}
    missing = [ip for ip in set(running_ips) if ip not in reg_ips]
    if missing:
        elbv2.register_targets(
            TargetGroupArn=tg_arn,
            Targets=[{"Id": ip, "Port": 8080} for ip in missing],
        )
PY
  fi
  sleep 2
done

if [[ "${READY_OK}" -ne 1 ]]; then
  echo "Service did not become ready at ${READY_URL}" >&2
  /opt/venv/bin/python3 - <<'PY' >&2 || true
import json
import urllib.request
import boto3

with open("/workspace/config/config.json", encoding="utf-8") as f:
    cfg = json.load(f)
with open("/workspace/submission/manifest.json", encoding="utf-8") as f:
    m = json.load(f)

for path in ("/health/live", "/health/ready"):
    url = m["service_url"].rstrip("/") + path
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            print(f"GET {url} -> {resp.status}: {resp.read().decode('utf-8', errors='replace')}")
    except Exception as exc:
        body = getattr(exc, "read", lambda: b"")()
        print(f"GET {url} ERROR -> {exc} body={body!r}")

kw = {
    "region_name": cfg["region"],
    "endpoint_url": cfg["aws_endpoint_url"],
    "aws_access_key_id": "test",
    "aws_secret_access_key": "test",
}
ecs = boto3.client("ecs", **kw)
elbv2 = boto3.client("elbv2", **kw)
logs = boto3.client("logs", **kw)
cluster = m["compute"]["cluster_arn"]
service = m["compute"]["service_name"]
tg_arn = m["ingress"]["target_group_arn"]
task_arns = ecs.list_tasks(cluster=cluster, serviceName=service).get("taskArns", [])
print("ECS task_arns:", task_arns)
if task_arns:
    tasks = ecs.describe_tasks(cluster=cluster, tasks=task_arns).get("tasks", [])
    for t in tasks:
        print("Task:", t.get("taskArn"), t.get("lastStatus"), t.get("stoppedReason"), t.get("containers"))
print("TargetHealth:", elbv2.describe_target_health(TargetGroupArn=tg_arn).get("TargetHealthDescriptions", []))
lg = m["logs"]["api_log_group"]
for stream in logs.describe_log_streams(logGroupName=lg).get("logStreams", [])[:4]:
    sname = stream["logStreamName"]
    evts = logs.get_log_events(logGroupName=lg, logStreamName=sname, limit=20).get("events", [])
    for e in evts:
        print(f"[{sname}] {e.get('message')}")
PY
  exit 1
fi

/opt/venv/bin/python3 - <<'PY'
from datetime import datetime
import hashlib
import json
import time
from urllib.parse import urlparse

import boto3
import psycopg
import redis


def same_ts(a: str | None, b: str | None) -> bool:
    if not a or not b:
        return False
    try:
        return datetime.fromisoformat(a) == datetime.fromisoformat(b)
    except Exception:
        return False


with open("/workspace/config/config.json", encoding="utf-8") as f:
    cfg = json.load(f)
with open("/workspace/submission/manifest.json", encoding="utf-8") as f:
    m = json.load(f)

endpoint_url = cfg["aws_endpoint_url"]
region = cfg["region"]
parsed_ep = urlparse(endpoint_url)
floci_host = parsed_ep.hostname or "aws"


def resolve_host(raw_host: str) -> str:
    h = raw_host.split(":")[0]
    if h in {"localhost", "127.0.0.1"} or h.endswith(".amazonaws.com") or h.endswith(".local"):
        return floci_host
    return h


boto_kwargs = {
    "region_name": region,
    "endpoint_url": endpoint_url,
    "aws_access_key_id": "test",
    "aws_secret_access_key": "test",
}
lam = boto3.client("lambda", **boto_kwargs)
ddb = boto3.client("dynamodb", **boto_kwargs)
s3 = boto3.client("s3", **boto_kwargs)
iam = boto3.client("iam", **boto_kwargs)
ec2 = boto3.client("ec2", **boto_kwargs)
kms = boto3.client("kms", **boto_kwargs)
rds = boto3.client("rds", **boto_kwargs)
elbv2 = boto3.client("elbv2", **boto_kwargs)
ecs = boto3.client("ecs", **boto_kwargs)
sqs = boto3.client("sqs", **boto_kwargs)
logs = boto3.client("logs", **boto_kwargs)
scheduler = boto3.client("scheduler", **boto_kwargs)

# 0. Reconcile out-of-band control-plane drift and non-canonical prefix-scoped resources
try:
    with open("/workspace/submission/infra/terraform.tfstate", encoding="utf-8") as sf:
        tfstate = json.load(sf)
except Exception:
    tfstate = {}

managed_inline_by_role: dict[str, set[str]] = {}
managed_attached_by_role: dict[str, set[str]] = {}
managed_policy_arns: set[str] = set()
for res in tfstate.get("resources", []):
    if res.get("mode") != "managed":
        continue
    rtype = res.get("type", "")
    for inst in res.get("instances", []):
        attrs = inst.get("attributes") or {}
        if rtype == "aws_iam_role_policy":
            rname = str(attrs.get("role") or "")
            pname = str(attrs.get("name") or "")
            if rname and pname:
                managed_inline_by_role.setdefault(rname, set()).add(pname)
        elif rtype == "aws_iam_role_policy_attachment":
            rname = str(attrs.get("role") or "")
            parn = str(attrs.get("policy_arn") or "")
            if rname and parn:
                managed_attached_by_role.setdefault(rname, set()).add(parn)
        elif rtype == "aws_iam_policy":
            parn = str(attrs.get("arn") or "")
            if parn:
                managed_policy_arns.add(parn)

prefix = cfg["resource_prefix"]
iam_map = m.get("iam") or {}
canonical_role_names: set[str] = set()
for role_arn in iam_map.values():
    role_name = str(role_arn).rsplit("/", 1)[-1]
    canonical_role_names.add(role_name)
    allowed_inline = managed_inline_by_role.get(role_name, set())
    for pname in iam.list_role_policies(RoleName=role_name).get("PolicyNames", []):
        if pname not in allowed_inline:
            try:
                iam.delete_role_policy(RoleName=role_name, PolicyName=pname)
            except Exception:
                pass
    allowed_attached = managed_attached_by_role.get(role_name, set())
    for att in iam.list_attached_role_policies(RoleName=role_name).get("AttachedPolicies", []):
        parn = att.get("PolicyArn", "")
        pname = att.get("PolicyName", "")
        if parn and parn not in allowed_attached:
            try:
                iam.detach_role_policy(RoleName=role_name, PolicyArn=parn)
            except Exception:
                pass
            if pname.startswith(prefix) and parn not in managed_policy_arns:
                try:
                    for pv in iam.list_policy_versions(PolicyArn=parn).get("Versions", []):
                        if not pv.get("IsDefaultVersion"):
                            iam.delete_policy_version(PolicyArn=parn, VersionId=pv["VersionId"])
                    iam.delete_policy(PolicyArn=parn)
                except Exception:
                    pass

# Purge any non-canonical IAM roles and policies scoped to prefix
try:
    for r_obj in iam.list_roles().get("Roles", []):
        rname = r_obj.get("RoleName", "")
        if not rname or rname in canonical_role_names:
            continue
        is_prefix_role = rname.startswith(prefix)
        if not is_prefix_role:
            try:
                rtags = {t["Key"]: t["Value"] for t in iam.list_role_tags(RoleName=rname).get("Tags", [])}
                is_prefix_role = rtags.get("ClearLedgerDeployment") == prefix
            except Exception:
                pass
        if is_prefix_role:
            for pname in iam.list_role_policies(RoleName=rname).get("PolicyNames", []):
                try:
                    iam.delete_role_policy(RoleName=rname, PolicyName=pname)
                except Exception:
                    pass
            for att in iam.list_attached_role_policies(RoleName=rname).get("AttachedPolicies", []):
                try:
                    iam.detach_role_policy(RoleName=rname, PolicyArn=att["PolicyArn"])
                except Exception:
                    pass
            try:
                iam.delete_role(RoleName=rname)
            except Exception:
                pass
except Exception:
    pass

try:
    for pol in iam.list_policies(Scope="Local").get("Policies", []):
        pname = pol.get("PolicyName", "")
        parn = pol.get("Arn", "")
        if pname.startswith(prefix) and parn and parn not in managed_policy_arns:
            try:
                for pv in iam.list_policy_versions(PolicyArn=parn).get("Versions", []):
                    if not pv.get("IsDefaultVersion"):
                        iam.delete_policy_version(PolicyArn=parn, VersionId=pv["VersionId"])
                iam.delete_policy(PolicyArn=parn)
            except Exception:
                pass
except Exception:
    pass

# Reconcile canonical KMS keys (state, rotation, tags, bilateral policy) and purge rogue prefix KMS keys/aliases
kms_map = m.get("kms") or {}
all_role_keys = ("ecs_execution_role_arn", "ecs_task_role_arn", "projector_role_arn", "relay_role_arn", "archiver_role_arn", "scheduler_role_arn")
kms_authorized_roles = {
    "database": ["relay_role_arn", "archiver_role_arn"],
    "messaging": ["ecs_task_role_arn", "projector_role_arn", "relay_role_arn"],
    "projection": ["ecs_task_role_arn", "projector_role_arn"],
    "audit": ["archiver_role_arn"],
}
sample_role_arn = str(iam_map.get("ecs_execution_role_arn") or "arn:aws:iam::000000000000:role/root")
acct_id = sample_role_arn.split(":")[4] if len(sample_role_arn.split(":")) > 4 else "000000000000"
canonical_kms_ids: set[str] = set()
for usage_name, arn_key in (
    ("database", "database_arn"),
    ("messaging", "messaging_arn"),
    ("projection", "projection_arn"),
    ("audit", "audit_arn"),
):
    k_arn = str(kms_map.get(arn_key) or "")
    if not k_arn:
        continue
    canonical_kms_ids.add(k_arn)
    canonical_kms_ids.add(k_arn.rsplit("/", 1)[-1])
    try:
        kms.cancel_key_deletion(KeyId=k_arn)
    except Exception:
        pass
    try:
        kms.enable_key(KeyId=k_arn)
    except Exception:
        pass
    try:
        kms.enable_key_rotation(KeyId=k_arn)
    except Exception:
        pass
    try:
        kms.tag_resource(
            KeyId=k_arn,
            Tags=[
                {"TagKey": "ClearLedgerDeployment", "TagValue": prefix},
                {"TagKey": "ClearLedgerKeyUsage", "TagValue": usage_name},
            ],
        )
    except Exception:
        pass
    allow_arns = [str(iam_map[rk]) for rk in kms_authorized_roles[usage_name] if iam_map.get(rk)]
    deny_arns = [str(iam_map[rk]) for rk in all_role_keys if rk not in kms_authorized_roles[usage_name] and iam_map.get(rk)]
    expected_kms_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AllowRootAdmin",
                "Effect": "Allow",
                "Principal": {"AWS": f"arn:aws:iam::{acct_id}:root"},
                "Action": "kms:*",
                "Resource": "*",
            },
            {
                "Sid": "AllowAuthorizedWorkloadRoles",
                "Effect": "Allow",
                "Principal": {"AWS": allow_arns},
                "Action": ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
                "Resource": "*",
            },
            {
                "Sid": "DenyUnauthorizedWorkloadRoles",
                "Effect": "Deny",
                "Principal": {"AWS": deny_arns},
                "Action": ["kms:Decrypt", "kms:GenerateDataKey"],
                "Resource": "*",
            },
        ],
    }
    try:
        kms.put_key_policy(KeyId=k_arn, PolicyName="default", Policy=json.dumps(expected_kms_policy))
    except Exception:
        pass

canonical_aliases = {f"alias/{prefix}-{u}" for u in ("database", "messaging", "projection", "audit")}
rogue_kms_ids: set[str] = set()
try:
    for al in kms.list_aliases().get("Aliases", []):
        aname = al.get("AliasName", "")
        if aname.startswith(f"alias/{prefix}") and aname not in canonical_aliases:
            tkid = al.get("TargetKeyId")
            if tkid and tkid not in canonical_kms_ids:
                rogue_kms_ids.add(tkid)
            try:
                kms.delete_alias(AliasName=aname)
            except Exception:
                pass
except Exception:
    pass

try:
    for k_entry in kms.list_keys().get("Keys", []):
        kid = k_entry.get("KeyId", "")
        if not kid or kid in canonical_kms_ids:
            continue
        try:
            kmeta = kms.describe_key(KeyId=kid).get("KeyMetadata", {})
            if kmeta.get("KeyManager") == "AWS" or kmeta.get("KeyState") == "PendingDeletion":
                continue
            is_rogue = kid in rogue_kms_ids or prefix in str(kmeta.get("Description") or "")
            if not is_rogue:
                ktags = {
                    t.get("TagKey"): t.get("TagValue")
                    for t in kms.list_resource_tags(KeyId=kid).get("Tags", [])
                }
                is_rogue = ktags.get("ClearLedgerDeployment") == prefix
            if is_rogue:
                kms.schedule_key_deletion(KeyId=kid, PendingWindowInDays=7)
        except Exception:
            pass
except Exception:
    pass

# Reconcile RDS tags, ALB health check, ECS containerInsights, DynamoDB PITR, S3 PublicAccessBlock
try:
    rds_arn = str((m.get("database") or {}).get("instance_arn") or "")
    if rds_arn:
        rds.add_tags_to_resource(
            ResourceName=rds_arn,
            Tags=[{"Key": "ClearLedgerDeployment", "Value": prefix}],
        )
    raw_db_id = str((m.get("database") or {}).get("instance_id") or "")
    arn_db_id = rds_arn.rsplit(":", 1)[-1] if rds_arn else ""
    for d in rds.describe_db_instances().get("DBInstances", []):
        if (
            d.get("DBInstanceIdentifier") in {raw_db_id, arn_db_id}
            or d.get("DbiResourceId") == raw_db_id
            or d.get("DBInstanceArn") == rds_arn
        ) and d.get("DBInstanceArn"):
            rds.add_tags_to_resource(
                ResourceName=d["DBInstanceArn"],
                Tags=[{"Key": "ClearLedgerDeployment", "Value": prefix}],
            )
except Exception:
    pass

try:
    elbv2.modify_target_group(
        TargetGroupArn=m["ingress"]["target_group_arn"],
        HealthCheckPath="/health/ready",
        HealthCheckPort="8080",
        HealthCheckProtocol="HTTP",
        Matcher={"HttpCode": "200"},
    )
except Exception:
    pass

for cluster_ref in (
    (m.get("compute") or {}).get("cluster_name"),
    (m.get("compute") or {}).get("cluster_arn"),
):
    if cluster_ref:
        try:
            ecs.update_cluster_settings(
                cluster=str(cluster_ref),
                settings=[{"name": "containerInsights", "value": "enabled"}],
            )
        except Exception:
            pass

try:
    ddb.update_continuous_backups(
        TableName=m["projections"]["table_name"],
        PointInTimeRecoverySpecification={"PointInTimeRecoveryEnabled": True},
    )
except Exception:
    pass

try:
    s3.put_public_access_block(
        Bucket=m["audit"]["bucket_name"],
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
except Exception:
    pass

# Reconcile EventBridge schedules, SQS queues, CloudWatch Log Groups, and Lambda worker configs/ESM,
# and purge any non-canonical prefix-scoped resources
sched_map = m.get("schedules") or {}
canonical_schedules = {
    str(sched_map.get("outbox_schedule_name") or ""),
    str(sched_map.get("archive_schedule_name") or ""),
} - {""}
for sched_name, sched_expr, fn_key in (
    (sched_map.get("outbox_schedule_name"), "rate(1 minute)", "outbox_relay"),
    (sched_map.get("archive_schedule_name"), "rate(5 minutes)", "audit_archiver"),
):
    if sched_name:
        try:
            cur_s = scheduler.get_schedule(Name=str(sched_name))
            scheduler.update_schedule(
                Name=str(sched_name),
                ScheduleExpression=sched_expr,
                FlexibleTimeWindow=cur_s.get("FlexibleTimeWindow") or {"Mode": "OFF"},
                Target=cur_s.get("Target")
                or {
                    "Arn": m["workers"][fn_key]["function_arn"],
                    "RoleArn": m["iam"]["scheduler_role_arn"],
                },
                State="ENABLED",
            )
        except Exception:
            pass

try:
    for sc in scheduler.list_schedules().get("Schedules", []):
        sname = sc.get("Name", "")
        if sname.startswith(prefix) and sname not in canonical_schedules:
            try:
                scheduler.delete_schedule(Name=sname, GroupName=sc.get("GroupName", "default"))
            except Exception:
                pass
except Exception:
    pass

msg_map = m.get("messaging") or {}
main_q_url = str(msg_map.get("queue_url") or "")
dlq_q_url = str(msg_map.get("dlq_url") or "")
try:
    if main_q_url:
        sqs.set_queue_attributes(
            QueueUrl=main_q_url,
            Attributes={
                "VisibilityTimeout": "3",
                "ReceiveMessageWaitTimeSeconds": "2",
                "MessageRetentionPeriod": "172800",
                "RedrivePolicy": json.dumps(
                    {
                        "deadLetterTargetArn": msg_map["dlq_arn"],
                        "maxReceiveCount": 4,
                    }
                ),
            },
        )
except Exception:
    pass
try:
    if dlq_q_url:
        sqs.set_queue_attributes(
            QueueUrl=dlq_q_url,
            Attributes={
                "MessageRetentionPeriod": "1209600",
            },
        )
except Exception:
    pass

canonical_queue_names = {
    str(msg_map.get("queue_name") or main_q_url.rsplit("/", 1)[-1]),
    str(msg_map.get("dlq_name") or dlq_q_url.rsplit("/", 1)[-1]),
} - {""}
try:
    for qurl in sqs.list_queues(QueueNamePrefix=prefix).get("QueueUrls", []):
        qname = str(qurl).rsplit("/", 1)[-1]
        if qname.startswith(prefix) and qname not in canonical_queue_names:
            try:
                sqs.delete_queue(QueueUrl=qurl)
            except Exception:
                pass
except Exception:
    pass

canonical_log_groups = set((m.get("logs") or {}).values())
for lg_name in canonical_log_groups:
    if lg_name:
        try:
            logs.put_retention_policy(logGroupName=str(lg_name), retentionInDays=14)
        except Exception:
            pass
try:
    for lg_prefix in (f"/clearledger/{prefix}", prefix):
        for lg_obj in logs.describe_log_groups(logGroupNamePrefix=lg_prefix).get("logGroups", []):
            lg_name = lg_obj.get("logGroupName", "")
            if lg_name and lg_name not in canonical_log_groups:
                try:
                    logs.delete_log_group(logGroupName=lg_name)
                except Exception:
                    pass
except Exception:
    pass

for fn_key, expected_updates in (
    ("projector", {"PROJECTION_TABLE": m["projections"]["table_name"]}),
    ("outbox_relay", {"OUTBOX_BATCH_SIZE": "50", "EVENT_QUEUE_URL": main_q_url, "SQS_QUEUE_URL": main_q_url}),
    ("audit_archiver", {"AUDIT_BUCKET": m["audit"]["bucket_name"], "AUDIT_PREFIX": str(m["audit"]["prefix"]), "AUDIT_BATCH_SIZE": "100"}),
):
    try:
        fn_name = m["workers"][fn_key]["function_name"]
        fn_cfg = lam.get_function_configuration(FunctionName=fn_name)
        cur_env = dict((fn_cfg.get("Environment") or {}).get("Variables") or {})
        if any(cur_env.get(k) != v for k, v in expected_updates.items() if v):
            cur_env.update({k: v for k, v in expected_updates.items() if v})
            lam.update_function_configuration(
                FunctionName=fn_name,
                Environment={"Variables": cur_env},
            )
    except Exception:
        pass

try:
    if msg_map.get("event_source_mapping_uuid"):
        lam.update_event_source_mapping(
            UUID=str(msg_map["event_source_mapping_uuid"]),
            Enabled=True,
            BatchSize=5,
            FunctionResponseTypes=["ReportBatchItemFailures"],
        )
except Exception:
    pass

sg_ids = (m.get("network") or {}).get("security_group_ids") or {}
for sg_key in ("alb", "ecs", "rds", "valkey"):
    sg_id = sg_ids.get(sg_key)
    if not sg_id:
        continue
    try:
        rules = ec2.describe_security_group_rules(
            Filters=[{"Name": "group-id", "Values": [sg_id]}]
        ).get("SecurityGroupRules", [])
        revoke_egress_ids = []
        revoke_ingress_ids = []
        for r in rules:
            if r.get("IsEgress"):
                if sg_key in ("rds", "valkey") or (
                    sg_key == "alb" and (r.get("CidrIpv4") == "0.0.0.0/0" or r.get("CidrIpv6") == "::/0")
                ):
                    if r.get("SecurityGroupRuleId"):
                        revoke_egress_ids.append(r["SecurityGroupRuleId"])
            else:
                if (sg_key == "ecs" and (r.get("CidrIpv4") or r.get("CidrIpv6"))) or (
                    sg_key in ("rds", "valkey")
                    and (r.get("CidrIpv4") == "0.0.0.0/0" or r.get("CidrIpv6") == "::/0")
                ):
                    if r.get("SecurityGroupRuleId"):
                        revoke_ingress_ids.append(r["SecurityGroupRuleId"])
        if revoke_egress_ids:
            ec2.revoke_security_group_egress(GroupId=sg_id, SecurityGroupRuleIds=revoke_egress_ids)
        if revoke_ingress_ids:
            ec2.revoke_security_group_ingress(GroupId=sg_id, SecurityGroupRuleIds=revoke_ingress_ids)
    except Exception:
        pass
    try:
        sg_desc = ec2.describe_security_groups(GroupIds=[sg_id]).get("SecurityGroups", [])
        for sg_obj in sg_desc:
            for perm in sg_obj.get("IpPermissionsEgress") or []:
                v4 = [rng.get("CidrIp") for rng in perm.get("IpRanges") or []]
                v6 = [rng.get("CidrIpv6") for rng in perm.get("Ipv6Ranges") or []]
                if sg_key in ("rds", "valkey") or (sg_key == "alb" and ("0.0.0.0/0" in v4 or "::/0" in v6)):
                    try:
                        ec2.revoke_security_group_egress(GroupId=sg_id, IpPermissions=[perm])
                    except Exception:
                        pass
            if sg_key in ("ecs", "rds", "valkey"):
                for perm in sg_obj.get("IpPermissions") or []:
                    v4 = [rng.get("CidrIp") for rng in perm.get("IpRanges") or []]
                    v6 = [rng.get("CidrIpv6") for rng in perm.get("Ipv6Ranges") or []]
                    if (sg_key == "ecs" and (v4 or v6)) or (
                        sg_key in ("rds", "valkey") and ("0.0.0.0/0" in v4 or "::/0" in v6)
                    ):
                        try:
                            ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=[perm])
                        except Exception:
                            pass
    except Exception:
        pass

db = m["database"]
pg_conninfo = (
    f"host={resolve_host(str(db['endpoint']))} port={db['port']} "
    f"dbname={db['db_name']} user={db['username']} password={cfg['db_password']} connect_timeout=5"
)
rclient = redis.Redis(
    host=resolve_host(str(m["cache"]["endpoint"])),
    port=int(m["cache"]["port"]),
    decode_responses=True,
    socket_connect_timeout=5,
    socket_timeout=5,
)

relay_fn = m["workers"]["outbox_relay"]["function_name"]
projector_fn = m["workers"]["projector"]["function_name"]
archiver_fn = m["workers"]["audit_archiver"]["function_name"]
table_name = m["projections"]["table_name"]
audit_bucket = m["audit"]["bucket_name"]
audit_prefix = str(m["audit"]["prefix"])


def purge_s3_key_all_versions(bucket: str, target_key: str) -> None:
    try:
        ver_resp = s3.list_object_versions(Bucket=bucket, Prefix=target_key)
        for v in ver_resp.get("Versions", []):
            if v.get("Key") == target_key and v.get("VersionId"):
                s3.delete_object(Bucket=bucket, Key=target_key, VersionId=v["VersionId"])
        for dm in ver_resp.get("DeleteMarkers", []):
            if dm.get("Key") == target_key and dm.get("VersionId"):
                s3.delete_object(Bucket=bucket, Key=target_key, VersionId=dm["VersionId"])
    except Exception:
        pass
    try:
        s3.delete_object(Bucket=bucket, Key=target_key)
    except Exception:
        pass


def purge_noncurrent_and_deleted_s3_versions(bucket: str, keep_live_keys: set[str] | None = None) -> None:
    try:
        ver_resp = s3.list_object_versions(Bucket=bucket)
        for dm in ver_resp.get("DeleteMarkers", []):
            k = dm.get("Key", "")
            vid = dm.get("VersionId")
            if k and vid:
                s3.delete_object(Bucket=bucket, Key=k, VersionId=vid)
        for v in ver_resp.get("Versions", []):
            k = v.get("Key", "")
            vid = v.get("VersionId")
            is_latest = bool(v.get("IsLatest"))
            if k and vid and (not is_latest or (keep_live_keys is not None and k not in keep_live_keys)):
                s3.delete_object(Bucket=bucket, Key=k, VersionId=vid)
    except Exception:
        pass


with psycopg.connect(pg_conninfo) as conn:
    with conn.cursor() as cur:
        # 1. Drain unpublished outbox backlog via outbox_relay
        for _ in range(20):
            cur.execute("SELECT COUNT(*) FROM clearledger.outbox WHERE published_at IS NULL")
            unpub = cur.fetchone()[0]
            if unpub == 0:
                break
            lam.invoke(FunctionName=relay_fn, InvocationType="RequestResponse", Payload=b"{}")
            time.sleep(0.3)

        # 2. Load authoritative PostgreSQL settlements and events
        cur.execute(
            """
            SELECT settlement_id::text, account_id, reference, debit_party, credit_party,
                   current_status, current_stage, version, entry_count,
                   last_entry_id::text, last_memo
            FROM clearledger.settlements
            """
        )
        pg_settlements = {row[0]: row[1:] for row in cur.fetchall()}

        # 3. Purge orphan DynamoDB partitions and Valkey keys not present in PostgreSQL
        scan_kwargs = {"TableName": table_name, "ConsistentRead": True}
        while True:
            scan_resp = ddb.scan(**scan_kwargs)
            for item in scan_resp.get("Items", []):
                pk_val = (item.get("PK") or {}).get("S", "")
                sk_val = (item.get("SK") or {}).get("S", "")
                sid_candidate = pk_val.split("SETTLEMENT#", 1)[1] if pk_val.startswith("SETTLEMENT#") else ""
                if not sid_candidate or sid_candidate not in pg_settlements:
                    ddb.delete_item(
                        TableName=table_name,
                        Key={"PK": {"S": pk_val}, "SK": {"S": sk_val}},
                    )
            if "LastEvaluatedKey" not in scan_resp:
                break
            scan_kwargs["ExclusiveStartKey"] = scan_resp["LastEvaluatedKey"]

        for rkey in rclient.keys("*"):
            sid_candidate = rkey.split("clearledger:settlement:", 1)[1] if rkey.startswith("clearledger:settlement:") else ""
            if not sid_candidate or sid_candidate not in pg_settlements:
                rclient.delete(rkey)

        # 4. Reconcile each PostgreSQL settlement's DynamoDB STATE + EVENT#* items and Valkey cache
        for sid, (acct, ref, debit, credit, status, stage, pg_ver, pg_ec, pg_last_entry, pg_last_memo) in pg_settlements.items():
            pk = f"SETTLEMENT#{sid}"
            cur.execute(
                """
                SELECT aggregate_version, event_id::text, event_type, payload
                FROM clearledger.events
                WHERE settlement_id = %s
                ORDER BY aggregate_version ASC
                """,
                (sid,),
            )
            pg_events = cur.fetchall()

            expected_ddb_last_memo = pg_last_memo
            expected_updated_at = None
            for _, _, _, ev_payload in pg_events:
                ev_obj = json.loads(ev_payload) if isinstance(ev_payload, str) else ev_payload
                ev_memo = (ev_obj.get("data") or {}).get("memo")
                if ev_memo is not None:
                    expected_ddb_last_memo = ev_memo
                expected_updated_at = ev_obj.get("occurredAt")

            q_items = ddb.query(
                TableName=table_name,
                ConsistentRead=True,
                KeyConditionExpression="PK = :pk",
                ExpressionAttributeValues={":pk": {"S": pk}},
            ).get("Items", [])

            state_item = None
            event_items_by_sk = {}
            for it in q_items:
                sk_val = (it.get("SK") or {}).get("S", "")
                if sk_val == "STATE":
                    state_item = it
                elif sk_val.startswith("EVENT#"):
                    event_items_by_sk[sk_val] = it

            state_ok = False
            if state_item is not None and len(q_items) == 1 + len(pg_events):
                try:
                    state_ok = (
                        (state_item.get("settlement_id") or {}).get("S") == sid
                        and int((state_item.get("version") or {}).get("N", -1)) == pg_ver
                        and int((state_item.get("entry_count") or {}).get("N", -1)) == pg_ec
                        and (state_item.get("status") or {}).get("S") == status
                        and (state_item.get("clearing_stage") or {}).get("S") == stage
                        and (state_item.get("account_id") or {}).get("S") == acct
                        and (state_item.get("reference") or {}).get("S") == ref
                        and (state_item.get("debit_party") or {}).get("S") == debit
                        and (state_item.get("credit_party") or {}).get("S") == credit
                        and (state_item.get("last_entry_id") or {}).get("S") == pg_last_entry
                        and (state_item.get("last_memo") or {}).get("S") == expected_ddb_last_memo
                        and same_ts((state_item.get("updated_at") or {}).get("S"), expected_updated_at)
                        and (state_item.get("GSI1PK") or {}).get("S") == f"ACCOUNT#{acct}"
                        and (state_item.get("GSI1SK") or {}).get("S") == f"SETTLEMENT#{sid}"
                    )
                except Exception:
                    state_ok = False

            events_ok = len(event_items_by_sk) == len(pg_events) and len(q_items) == 1 + len(pg_events)
            if events_ok:
                for ev_ver, ev_id, ev_type, ev_payload in pg_events:
                    expected_sk = f"EVENT#{ev_ver:08d}"
                    ddb_ev = event_items_by_sk.get(expected_sk)
                    if ddb_ev is None:
                        events_ok = False
                        break
                    ev_obj = json.loads(ev_payload) if isinstance(ev_payload, str) else ev_payload
                    ev_data = ev_obj.get("data") or {}
                    ddb_env_raw = (ddb_ev.get("envelope") or {}).get("S")
                    ddb_env_ok = False
                    if ddb_env_raw:
                        try:
                            ddb_env_ok = json.loads(ddb_env_raw) == ev_obj
                        except Exception:
                            ddb_env_ok = False
                    if (
                        (ddb_ev.get("settlement_id") or {}).get("S") != sid
                        or int((ddb_ev.get("version") or {}).get("N", -1)) != ev_ver
                        or (ddb_ev.get("event_id") or {}).get("S") != ev_id
                        or (ddb_ev.get("event_type") or {}).get("S") != ev_type
                        or (ddb_ev.get("status") or {}).get("S") != ev_data.get("status")
                        or (ddb_ev.get("clearing_stage") or {}).get("S") != ev_data.get("clearingStage")
                        or (ddb_ev.get("entry_id") or {}).get("S") != ev_data.get("entryId")
                        or (ddb_ev.get("memo") or {}).get("S") != ev_data.get("memo")
                        or (ddb_ev.get("correlation_id") or {}).get("S") != ev_obj.get("correlationId")
                        or not same_ts((ddb_ev.get("occurred_at") or {}).get("S"), ev_obj.get("occurredAt"))
                        or not ddb_env_ok
                    ):
                        events_ok = False
                        break

            if not (state_ok and events_ok):
                for it in q_items:
                    ddb.delete_item(
                        TableName=table_name,
                        Key={"PK": it["PK"], "SK": it["SK"]},
                    )
                records = []
                for idx, (_, _, _, ev_payload) in enumerate(pg_events, start=1):
                    body = ev_payload if isinstance(ev_payload, str) else json.dumps(ev_payload)
                    records.append({"messageId": f"reconcile-{sid}-{idx}", "body": body})
                if records:
                    lam.invoke(
                        FunctionName=projector_fn,
                        InvocationType="RequestResponse",
                        Payload=json.dumps({"Records": records}).encode("utf-8"),
                    )

            expected_cache_obj = {
                "settlementId": sid,
                "accountId": acct,
                "reference": ref,
                "debitParty": debit,
                "creditParty": credit,
                "status": status,
                "clearingStage": stage,
                "version": int(pg_ver),
                "entryCount": int(pg_ec),
                "updatedAt": expected_updated_at,
            }
            if pg_last_entry is not None:
                expected_cache_obj["lastEntryId"] = pg_last_entry
            if expected_ddb_last_memo is not None:
                expected_cache_obj["lastMemo"] = expected_ddb_last_memo
            rclient.set(f"clearledger:settlement:{sid}", json.dumps(expected_cache_obj), ex=90)

        # 5. Reconcile S3 audit archive objects and versions 1-to-1 against clearledger.outbox
        cur.execute("SELECT seq, event_id::text, archived_at, payload FROM clearledger.outbox ORDER BY seq ASC")
        pg_outbox = {}
        for seq, ev_id, arch_at, payload in cur.fetchall():
            pay_obj = json.loads(payload) if isinstance(payload, str) else payload
            pg_outbox[ev_id] = (int(seq), arch_at, pay_obj)
        all_pg_seqs = sorted(seq for seq, _, _ in pg_outbox.values())

        all_s3_objs = s3.list_objects_v2(Bucket=audit_bucket).get("Contents", [])
        seen_s3_event_ids: set[str] = set()
        seen_seq_intervals: list[tuple[int, int]] = []
        valid_live_keys: set[str] = set()
        had_invalid_s3_obj = False
        for obj in sorted(all_s3_objs, key=lambda o: o["Key"]):
            key = obj["Key"]
            if not key.startswith(audit_prefix):
                had_invalid_s3_obj = True
                purge_s3_key_all_versions(audit_bucket, key)
                continue
            try:
                raw_bytes = s3.get_object(Bucket=audit_bucket, Key=key)["Body"].read()
                raw_body = raw_bytes.decode("utf-8")
                lines = [ln for ln in raw_body.splitlines() if ln.strip()]
                if not lines:
                    raise ValueError("Empty S3 audit batch")
                batch_ids: list[str] = []
                batch_seqs: list[int] = []
                batch_seen: set[str] = set()
                for line in lines:
                    parsed_line = json.loads(line)
                    ev_id = str(parsed_line.get("eventId") or "")
                    if not ev_id or ev_id not in pg_outbox:
                        raise ValueError(f"Orphan eventId {ev_id} in S3 audit batch")
                    if ev_id in seen_s3_event_ids or ev_id in batch_seen:
                        raise ValueError(f"Duplicate eventId {ev_id} in S3 audit batch")
                    row_seq, arch_at, authoritative_payload = pg_outbox[ev_id]
                    if arch_at is None:
                        raise ValueError(f"Outbox row {ev_id} is marked unarchived in PostgreSQL")
                    if parsed_line != authoritative_payload:
                        raise ValueError(f"Tampered S3 audit record for {ev_id}")
                    batch_seen.add(ev_id)
                    batch_ids.append(ev_id)
                    batch_seqs.append(int(row_seq))
                if batch_seqs != sorted(batch_seqs):
                    raise ValueError("S3 audit batch records are not in ascending outbox.seq order")
                first_b_seq = batch_seqs[0]
                last_b_seq = batch_seqs[-1]
                expected_range_seqs = [s for s in all_pg_seqs if first_b_seq <= s <= last_b_seq]
                if batch_seqs != expected_range_seqs:
                    raise ValueError("S3 audit batch has interior outbox.seq gap")
                if any(not (last_b_seq < s0 or first_b_seq > s1) for s0, s1 in seen_seq_intervals):
                    raise ValueError("S3 audit batch has overlapping [first_seq, last_seq] range")
                digest_hex = hashlib.sha256(raw_bytes).hexdigest()[:16]
                expected_key = (
                    f"{audit_prefix}batch-{first_b_seq:08d}-{last_b_seq:08d}-{digest_hex}.ndjson"
                )
                if key != expected_key:
                    raise ValueError(f"S3 audit batch key {key} does not match canonical {expected_key}")
                seen_s3_event_ids.update(batch_ids)
                seen_seq_intervals.append((first_b_seq, last_b_seq))
                valid_live_keys.add(key)
            except Exception:
                had_invalid_s3_obj = True
                purge_s3_key_all_versions(audit_bucket, key)

        missing_seqs = [
            seq
            for ev_id, (seq, arch_at, _) in pg_outbox.items()
            if arch_at is not None and ev_id not in seen_s3_event_ids
        ]
        unarchived_seqs = [
            seq for _, (seq, arch_at, _) in pg_outbox.items() if arch_at is None
        ]
        max_kept_seq = max((s1 for _, s1 in seen_seq_intervals), default=0)
        min_pending_seq = min(missing_seqs + unarchived_seqs, default=max_kept_seq + 1)

        if had_invalid_s3_obj or missing_seqs or (seen_seq_intervals and min_pending_seq <= max_kept_seq):
            for k in list(valid_live_keys):
                purge_s3_key_all_versions(audit_bucket, k)
            purge_noncurrent_and_deleted_s3_versions(audit_bucket, set())
            cur.execute(
                "UPDATE clearledger.outbox SET archived_at = NULL WHERE published_at IS NOT NULL"
            )
            conn.commit()
        else:
            purge_noncurrent_and_deleted_s3_versions(audit_bucket, valid_live_keys)

        for _ in range(20):
            cur.execute(
                "SELECT COUNT(*) FROM clearledger.outbox WHERE published_at IS NOT NULL AND archived_at IS NULL"
            )
            unarch = cur.fetchone()[0]
            if unarch == 0:
                break
            lam.invoke(FunctionName=archiver_fn, InvocationType="RequestResponse", Payload=b"{}")
            time.sleep(0.3)

        purge_noncurrent_and_deleted_s3_versions(audit_bucket)
PY

echo "ClearLedger deployment ready at ${SERVICE_URL}"
exit 0
