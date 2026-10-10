"""Shared helpers for the ClearLedger deploy / destroy tooling."""
import datetime
import json
import sys
import time

import boto3
from botocore.config import Config


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_json(path):
    with open(path) as fh:
        return json.load(fh)


def client(cfg, service):
    return boto3.client(
        service,
        endpoint_url=cfg["aws_endpoint_url"],
        region_name=cfg["region"],
        aws_access_key_id="test",
        aws_secret_access_key="test",
        config=Config(retries={"max_attempts": 5, "mode": "standard"}, s3={"addressing_style": "path"}),
    )


def db_connect(cfg, mf):
    import psycopg2

    db = mf["database"]
    return psycopg2.connect(
        host=db["endpoint"],
        port=db["port"],
        dbname=cfg["db_name"],
        user=cfg["db_username"],
        password=cfg["db_password"],
        connect_timeout=10,
    )


def rfc3339_auto(dt, zulu=False):
    """RFC 3339 with the sub-second precision chrono's AutoSi would print."""
    dt = dt.astimezone(datetime.timezone.utc)
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    us = dt.microsecond
    if us == 0:
        frac = ""
    elif us % 1000 == 0:
        frac = ".%03d" % (us // 1000)
    else:
        frac = ".%06d" % us
    return base + frac + ("Z" if zulu else "+00:00")


def parse_ts(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(datetime.timezone.utc)


ENVELOPE_ORDER = [
    "schemaVersion", "eventId", "eventType", "aggregateType", "aggregateId",
    "aggregateVersion", "occurredAt", "correlationId", "idempotencyKey", "data",
]
DATA_ORDER = [
    "kind", "accountId", "reference", "debitParty", "creditParty", "entryId",
    "status", "clearingStage", "memo",
]


def canonical_envelope(payload):
    """Envelope in canonical struct field order (null / absent optional fields omitted)."""
    out = {}
    for key in ENVELOPE_ORDER:
        if key not in payload:
            continue
        if key == "data":
            data = payload["data"]
            out["data"] = {k: data[k] for k in DATA_ORDER if k in data and data[k] is not None}
        else:
            out[key] = payload[key]
    return out


def canonical_json(payload):
    return json.dumps(canonical_envelope(payload), separators=(",", ":"), ensure_ascii=False)
