"""Shared helpers for the ClearLedger deploy/destroy tooling (boto3 against the local control plane)."""
import json
import sys
import time

import boto3
from botocore.config import Config

CONFIG_PATH = "/workspace/config/config.json"
MANIFEST_PATH = "/workspace/submission/manifest.json"

ROLE_KEYS = ["ecs-execution", "ecs-task", "projector", "relay", "archiver", "scheduler"]


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_config():
    with open(CONFIG_PATH) as fh:
        return json.load(fh)


def load_manifest():
    with open(MANIFEST_PATH) as fh:
        return json.load(fh)


class Aws:
    """Lazy boto3 client factory bound to the configured endpoint."""

    def __init__(self, cfg=None):
        self.cfg = cfg or load_config()
        self.region = self.cfg.get("region", "us-east-1")
        self.endpoint = self.cfg.get("aws_endpoint_url", "http://aws:4566")
        self._clients = {}

    def client(self, name, read_timeout=300):
        if name not in self._clients:
            self._clients[name] = boto3.client(
                name,
                region_name=self.region,
                endpoint_url=self.endpoint,
                aws_access_key_id="test",
                aws_secret_access_key="test",
                config=Config(
                    retries={"max_attempts": 4, "mode": "standard"},
                    connect_timeout=10,
                    read_timeout=read_timeout,
                    s3={"addressing_style": "path"},
                ),
            )
        return self._clients[name]


def pg_connect(cfg, host, port):
    import psycopg2

    last = None
    for _ in range(30):
        try:
            conn = psycopg2.connect(
                host=host,
                port=port,
                user=cfg["db_username"],
                password=cfg["db_password"],
                dbname=cfg["db_name"],
                connect_timeout=10,
            )
            conn.autocommit = False
            return conn
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(2)
    raise RuntimeError(f"cannot connect to PostgreSQL {host}:{port}: {last}")


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)
