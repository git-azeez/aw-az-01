#!/usr/bin/env python3
"""ClearLedger control-plane safety net and data-plane convergence.

PostgreSQL is the system of record. This script converges (in order):

  1. IAM:  removes out-of-band inline / attached policies from the six workload
           roles and deletes unattached customer-managed policies with the prefix.
  2. VPC:  revokes public ingress on ecs/rds/valkey SGs and any egress on rds/valkey.
  3. SQS:  publishes every unpublished outbox row (relay semantics) and waits for
           the main queue to drain through the projector.
  4. DynamoDB: makes the projection table a 1-to-1 image of settlements + events.
  5. S3:   purges noncurrent versions / delete markers, removes invalid batches and
           archives every published outbox row exactly once in canonical batches.
  6. Valkey: keeps only clearledger:settlement:<id> keys for known settlements and
           warms every one of them with the canonical projection (TTL 90s).

Usage: reconcile.py <manifest.json> <extra.json>
  extra.json: {"db_password": ..., "canonical_policies": {role_name: policy_name}}
"""
import datetime
import hashlib
import json
import os
import re
import sys
import time

import boto3
import psycopg2
import psycopg2.extras
import redis
from botocore.config import Config

CACHE_TTL = 90
AUDIT_BATCH_SIZE = 100
BATCH_KEY_RE = re.compile(r'^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$')

ENVELOPE_ORDER = ['schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId',
                  'aggregateVersion', 'occurredAt', 'correlationId', 'idempotencyKey', 'data']
DATA_ORDER = ['kind', 'accountId', 'reference', 'debitParty', 'creditParty', 'entryId',
              'status', 'clearingStage', 'memo']


def log(msg):
    print(f'[reconcile] {msg}', file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Canonical serialisation helpers (mirror the Rust workers' output)
# ---------------------------------------------------------------------------
def canonical_envelope(payload):
    """Envelope with struct field order and null optionals omitted."""
    out = {}
    for k in ENVELOPE_ORDER:
        if k == 'data':
            data = payload.get('data') or {}
            d = {}
            for dk in DATA_ORDER:
                if dk in data and data[dk] is not None:
                    d[dk] = data[dk]
            for dk in data:  # never drop unexpected keys silently
                if dk not in d and data[dk] is not None:
                    d[dk] = data[dk]
            out['data'] = d
        elif k in payload and payload[k] is not None:
            out[k] = payload[k]
    return out


def dumps(obj):
    return json.dumps(obj, separators=(',', ':'), ensure_ascii=False)


def strip_nulls(obj):
    if isinstance(obj, dict):
        return {k: strip_nulls(v) for k, v in obj.items() if v is not None}
    return obj


def _frac(dt):
    us = dt.microsecond
    if us == 0:
        return ''
    if us % 1000 == 0:
        return '.%03d' % (us // 1000)
    return '.%06d' % us


def rfc3339_offset(dt):
    """chrono DateTime<Utc>::to_rfc3339() -> 2026-01-01T00:00:00.123+00:00"""
    dt = dt.astimezone(datetime.timezone.utc)
    return dt.strftime('%Y-%m-%dT%H:%M:%S') + _frac(dt) + '+00:00'


def rfc3339_z(dt):
    """chrono to_rfc3339_opts(AutoSi, true) -> 2026-01-01T00:00:00.123Z"""
    dt = dt.astimezone(datetime.timezone.utc)
    return dt.strftime('%Y-%m-%dT%H:%M:%S') + _frac(dt) + 'Z'


def parse_ts(val):
    try:
        v = val.replace('Z', '+00:00')
        return datetime.datetime.fromisoformat(v)
    except Exception:  # noqa: BLE001
        return None


# ---------------------------------------------------------------------------
class Reconciler:
    def __init__(self, manifest, extra):
        self.m = manifest
        self.extra = extra
        self.prefix = manifest['resource_prefix']
        endpoint = os.environ.get('AWS_ENDPOINT_URL') or 'http://aws:4566'
        cfg = Config(retries={'max_attempts': 8, 'mode': 'standard'}, connect_timeout=10, read_timeout=60)
        kw = dict(endpoint_url=endpoint, region_name=manifest['region'], config=cfg,
                  aws_access_key_id=os.environ.get('AWS_ACCESS_KEY_ID', 'test'),
                  aws_secret_access_key=os.environ.get('AWS_SECRET_ACCESS_KEY', 'test'))
        self.iam = boto3.client('iam', **kw)
        self.ec2 = boto3.client('ec2', **kw)
        self.sqs = boto3.client('sqs', **kw)
        self.ddb = boto3.client('dynamodb', **kw)
        self.s3 = boto3.client('s3', **kw)
        self.table = manifest['projections']['table_name']
        self.bucket = manifest['audit']['bucket_name']
        self.queue_url = manifest['messaging']['queue_url']
        db = manifest['database']
        self.dsn = dict(host=db['endpoint'], port=db['port'], dbname=db['db_name'], user=db['username'],
                        password=extra['db_password'], connect_timeout=15, application_name='clearledger-deploy')

    def pg(self):
        conn = psycopg2.connect(**self.dsn)
        conn.autocommit = False
        return conn

    # ------------------------------------------------------------------ IAM
    def reconcile_iam(self):
        canonical = self.extra.get('canonical_policies', {})
        for arn in self.m['iam'].values():
            role = arn.split('/')[-1]
            keep = canonical.get(role)
            try:
                names = self.iam.list_role_policies(RoleName=role).get('PolicyNames', [])
            except self.iam.exceptions.NoSuchEntityException:
                continue
            for name in names:
                if name != keep:
                    log(f'IAM: deleting out-of-band inline policy {name} from {role}')
                    self.iam.delete_role_policy(RoleName=role, PolicyName=name)
            attached = self.iam.list_attached_role_policies(RoleName=role).get('AttachedPolicies', [])
            for pol in attached:
                log(f'IAM: detaching out-of-band managed policy {pol["PolicyArn"]} from {role}')
                self.iam.detach_role_policy(RoleName=role, PolicyArn=pol['PolicyArn'])
        # unattached customer-managed policies carrying the prefix
        marker = None
        while True:
            kw = {'Scope': 'Local', 'MaxItems': 100}
            if marker:
                kw['Marker'] = marker
            resp = self.iam.list_policies(**kw)
            for pol in resp.get('Policies', []):
                if not pol['PolicyName'].startswith(self.prefix):
                    continue
                ents = self.iam.list_entities_for_policy(PolicyArn=pol['Arn'])
                if ents.get('PolicyRoles') or ents.get('PolicyUsers') or ents.get('PolicyGroups'):
                    continue
                log(f'IAM: deleting unattached customer-managed policy {pol["PolicyName"]}')
                delete_managed_policy(self.iam, pol['Arn'])
            if not resp.get('IsTruncated'):
                break
            marker = resp.get('Marker')

    # ------------------------------------------------------------------ SGs
    def reconcile_security_groups(self):
        sgs = self.m['network']['security_group_ids']
        public = {'0.0.0.0/0', '::/0'}
        for kind in ('ecs', 'rds', 'valkey'):
            try:
                sg = self.ec2.describe_security_groups(GroupIds=[sgs[kind]])['SecurityGroups'][0]
            except Exception as exc:  # noqa: BLE001
                log(f'SG: cannot describe {kind}: {exc}')
                continue
            bad = []
            for perm in sg.get('IpPermissions', []):
                v4 = [r for r in perm.get('IpRanges', []) if r.get('CidrIp') in public]
                v6 = [r for r in perm.get('Ipv6Ranges', []) if r.get('CidrIpv6') in public]
                if v4 or v6:
                    p = {k: v for k, v in perm.items() if k in ('IpProtocol', 'FromPort', 'ToPort')}
                    if v4:
                        p['IpRanges'] = v4
                    if v6:
                        p['Ipv6Ranges'] = v6
                    bad.append(p)
            if bad:
                log(f'SG: revoking public ingress on {kind}')
                self.ec2.revoke_security_group_ingress(GroupId=sg['GroupId'], IpPermissions=bad)
            if kind in ('rds', 'valkey') and sg.get('IpPermissionsEgress'):
                log(f'SG: revoking egress rules on {kind}')
                self.ec2.revoke_security_group_egress(GroupId=sg['GroupId'],
                                                      IpPermissions=sg['IpPermissionsEgress'])

    # ------------------------------------------------------------------ outbox
    def publish_outbox(self):
        total = 0
        while True:
            conn = self.pg()
            try:
                with conn.cursor() as cur:
                    cur.execute("""SELECT seq, payload FROM clearledger.outbox
                                   WHERE published_at IS NULL ORDER BY seq
                                   LIMIT 50 FOR UPDATE SKIP LOCKED""")
                    rows = cur.fetchall()
                    if not rows:
                        conn.rollback()
                        break
                    for seq, payload in rows:
                        env = canonical_envelope(payload)
                        self.sqs.send_message(QueueUrl=self.queue_url, MessageBody=dumps(env))
                        cur.execute("""UPDATE clearledger.outbox
                                       SET published_at = NOW(), attempts = attempts + 1, last_error = NULL
                                       WHERE seq = %s AND published_at IS NULL""", (seq,))
                conn.commit()
                total += len(rows)
            finally:
                conn.close()
        if total:
            log(f'outbox: published {total} pending event(s) to SQS')
        return total

    def wait_queue_drained(self, timeout=150):
        deadline = time.time() + timeout
        stable = 0
        while time.time() < deadline:
            try:
                attrs = self.sqs.get_queue_attributes(
                    QueueUrl=self.queue_url,
                    AttributeNames=['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible',
                                    'ApproximateNumberOfMessagesDelayed'])['Attributes']
            except Exception as exc:  # noqa: BLE001
                log(f'sqs: cannot read queue attributes: {exc}')
                return False
            pending = sum(int(attrs.get(k, 0)) for k in attrs)
            if pending == 0:
                stable += 1
                if stable >= 2:
                    return True
            else:
                stable = 0
            time.sleep(2)
        log('sqs: main queue did not drain within timeout; continuing with direct convergence')
        return False

    # ------------------------------------------------------------------ PG snapshot
    def load_pg(self):
        conn = self.pg()
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
                cur.execute('SELECT * FROM clearledger.settlements')
                settlements = {str(r['settlement_id']): r for r in cur.fetchall()}
                cur.execute('SELECT * FROM clearledger.events ORDER BY settlement_id, aggregate_version')
                events = {}
                for r in cur.fetchall():
                    events.setdefault(str(r['settlement_id']), []).append(r)
            conn.rollback()
        finally:
            conn.close()
        return settlements, events

    # ------------------------------------------------------------------ DynamoDB
    @staticmethod
    def expected_state_item(s):
        sid = str(s['settlement_id'])
        item = {
            'PK': {'S': f'SETTLEMENT#{sid}'},
            'SK': {'S': 'STATE'},
            'GSI1PK': {'S': f'ACCOUNT#{s["account_id"]}'},
            'GSI1SK': {'S': f'SETTLEMENT#{sid}'},
            'settlement_id': {'S': sid},
            'account_id': {'S': s['account_id']},
            'reference': {'S': s['reference']},
            'debit_party': {'S': s['debit_party']},
            'credit_party': {'S': s['credit_party']},
            'status': {'S': s['current_status']},
            'clearing_stage': {'S': s['current_stage']},
            'version': {'N': str(s['version'])},
            'entry_count': {'N': str(s['entry_count'])},
            'updated_at': {'S': rfc3339_offset(s['updated_at'])},
        }
        if s['last_entry_id'] is not None:
            item['last_entry_id'] = {'S': str(s['last_entry_id'])}
        if s['last_memo'] is not None:
            item['last_memo'] = {'S': s['last_memo']}
        return item

    @staticmethod
    def expected_event_item(e):
        sid = str(e['settlement_id'])
        data = e['payload'].get('data') or {}
        item = {
            'PK': {'S': f'SETTLEMENT#{sid}'},
            'SK': {'S': 'EVENT#%08d' % e['aggregate_version']},
            'settlement_id': {'S': sid},
            'event_id': {'S': str(e['event_id'])},
            'version': {'N': str(e['aggregate_version'])},
            'event_type': {'S': e['event_type']},
            'status': {'S': data.get('status')},
            'clearing_stage': {'S': data.get('clearingStage')},
            'occurred_at': {'S': rfc3339_offset(e['occurred_at'])},
            'correlation_id': {'S': e['correlation_id']},
            'envelope': {'S': dumps(canonical_envelope(e['payload']))},
        }
        if data.get('entryId') is not None:
            item['entry_id'] = {'S': data['entryId']}
        if data.get('memo') is not None:
            item['memo'] = {'S': data['memo']}
        return item

    @staticmethod
    def items_equal(have, want):
        if set(have) != set(want):
            return False
        for k, wv in want.items():
            hv = have[k]
            if k == 'envelope':
                try:
                    if json.loads(hv.get('S', '')) != json.loads(wv['S']):
                        return False
                except Exception:  # noqa: BLE001
                    return False
            elif k in ('occurred_at', 'updated_at'):
                a, b = parse_ts(hv.get('S', '')), parse_ts(wv['S'])
                if a is None or a != b:
                    return False
            elif 'N' in wv:
                if 'N' not in hv or int(hv['N']) != int(wv['N']):
                    return False
            elif hv != wv:
                return False
        return True

    def scan_table(self):
        items = {}
        kw = {'TableName': self.table, 'ConsistentRead': True}
        while True:
            resp = self.ddb.scan(**kw)
            for it in resp.get('Items', []):
                items[(it['PK']['S'], it['SK']['S'])] = it
            if 'LastEvaluatedKey' not in resp:
                break
            kw['ExclusiveStartKey'] = resp['LastEvaluatedKey']
        return items

    def reconcile_dynamodb(self):
        # Scan first, then snapshot PostgreSQL: every legitimately projected
        # item is then guaranteed to be present in the snapshot.
        have = self.scan_table()
        settlements, events = self.load_pg()
        want = {}
        for sid, s in settlements.items():
            st = self.expected_state_item(s)
            want[(st['PK']['S'], 'STATE')] = st
            for e in events.get(sid, []):
                ev = self.expected_event_item(e)
                want[(ev['PK']['S'], ev['SK']['S'])] = ev

        deleted = written = 0
        for key, item in have.items():
            if key not in want:
                self.ddb.delete_item(TableName=self.table, Key={'PK': {'S': key[0]}, 'SK': {'S': key[1]}})
                deleted += 1
        for key, item in want.items():
            cur = have.get(key)
            if cur is not None and self.items_equal(cur, item):
                continue
            if key[1] == 'STATE':
                cond = 'attribute_not_exists(PK) OR #v <= :pgv'
                vals = {':pgv': item['version']}
                if cur is not None and 'version' in cur and 'N' in cur['version']:
                    cond += ' OR #v = :seen'
                    vals[':seen'] = cur['version']
                elif cur is not None:
                    cond += ' OR attribute_not_exists(#v)'
                try:
                    self.ddb.put_item(TableName=self.table, Item=item, ConditionExpression=cond,
                                      ExpressionAttributeNames={'#v': 'version'},
                                      ExpressionAttributeValues=vals)
                except self.ddb.exceptions.ConditionalCheckFailedException:
                    continue  # a newer live projection landed meanwhile
            else:
                self.ddb.put_item(TableName=self.table, Item=item)
            written += 1
        log(f'dynamodb: {len(settlements)} settlement(s); wrote {written}, deleted {deleted} item(s)')
        return settlements, events

    # ------------------------------------------------------------------ S3
    def list_versions(self):
        versions, markers = [], []
        kw = {'Bucket': self.bucket}
        while True:
            resp = self.s3.list_object_versions(**kw)
            versions.extend(resp.get('Versions', []) or [])
            markers.extend(resp.get('DeleteMarkers', []) or [])
            if not resp.get('IsTruncated'):
                break
            kw['KeyMarker'] = resp.get('NextKeyMarker')
            kw['VersionIdMarker'] = resp.get('NextVersionIdMarker')
            if not kw['KeyMarker']:
                kw.pop('KeyMarker')
            if not kw.get('VersionIdMarker'):
                kw.pop('VersionIdMarker', None)
        return versions, markers

    def delete_versions(self, objs):
        objs = [o for o in objs]
        for i in range(0, len(objs), 500):
            chunk = objs[i:i + 500]
            try:
                self.s3.delete_objects(Bucket=self.bucket, Delete={'Objects': chunk, 'Quiet': True})
            except Exception:  # noqa: BLE001
                for o in chunk:
                    self.s3.delete_object(Bucket=self.bucket, **o)

    def purge_history(self):
        """Keep only the single current version of keys that are not deleted."""
        versions, markers = self.list_versions()
        latest_marker_keys = {m['Key'] for m in markers if m.get('IsLatest')}
        doomed = []
        for m in markers:
            doomed.append({'Key': m['Key'], 'VersionId': m['VersionId']})
        for v in versions:
            if v['Key'] in latest_marker_keys or not v.get('IsLatest'):
                doomed.append({'Key': v['Key'], 'VersionId': v['VersionId']})
        if doomed:
            self.delete_versions(doomed)
        current = {v['Key']: v for v in versions if v.get('IsLatest') and v['Key'] not in latest_marker_keys}
        return current, len(doomed)

    def load_outbox(self):
        conn = self.pg()
        try:
            with conn.cursor() as cur:
                cur.execute("""SELECT seq, payload, published_at IS NOT NULL, archived_at IS NOT NULL
                               FROM clearledger.outbox ORDER BY seq""")
                rows = cur.fetchall()
            conn.rollback()
        finally:
            conn.close()
        return rows

    def reconcile_s3_pass(self):
        changes = 0
        current, purged = self.purge_history()
        changes += purged
        rows = self.load_outbox()
        seqs = [r[0] for r in rows]
        by_seq = {r[0]: r for r in rows}
        index_of = {s: i for i, s in enumerate(seqs)}

        valid = []   # (first, last, key)
        invalid = []
        for key in sorted(current):
            mt = BATCH_KEY_RE.match(key)
            if not mt:
                invalid.append(key)
                continue
            first, last, digest = int(mt.group(1)), int(mt.group(2)), mt.group(3)
            if first > last or first not in index_of or last not in index_of:
                invalid.append(key)
                continue
            body = self.s3.get_object(Bucket=self.bucket, Key=key)['Body'].read()
            if hashlib.sha256(body).hexdigest()[:16] != digest or not body.endswith(b'\n'):
                invalid.append(key)
                continue
            expected_rows = rows[index_of[first]:index_of[last] + 1]
            lines = body.decode('utf-8', errors='replace').split('\n')[:-1]
            ok = len(lines) == len(expected_rows)
            if ok:
                for line, row in zip(lines, expected_rows):
                    try:
                        if strip_nulls(json.loads(line)) != strip_nulls(row[1]) or not row[2]:
                            ok = False
                            break
                    except Exception:  # noqa: BLE001
                        ok = False
                        break
            if not ok:
                invalid.append(key)
                continue
            valid.append((first, last, key))

        # strictly disjoint intervals: keep earliest-starting, drop overlaps
        accepted, covered = [], set()
        last_end = -1
        for first, last, key in sorted(valid):
            if first <= last_end:
                invalid.append(key)
                continue
            accepted.append((first, last, key))
            last_end = last
            covered.update(seqs[index_of[first]:index_of[last] + 1])

        if invalid:
            log(f's3: removing {len(invalid)} invalid/overlapping audit object(s)')
            versions, markers = self.list_versions()
            bad = set(invalid)
            self.delete_versions([{'Key': o['Key'], 'VersionId': o['VersionId']}
                                  for o in versions + markers if o['Key'] in bad])
            changes += len(invalid)

        # archive every published-but-uncovered row in contiguous canonical batches
        runs, run = [], []
        for s in seqs:
            if s in covered or not by_seq[s][2]:
                if run:
                    runs.append(run)
                    run = []
                continue
            run.append(s)
        if run:
            runs.append(run)

        written = 0
        for run in runs:
            for i in range(0, len(run), AUDIT_BATCH_SIZE):
                chunk = run[i:i + AUDIT_BATCH_SIZE]
                if self.write_batch(chunk):
                    written += 1
                    covered.update(chunk)
        changes += written

        # every covered row must be stamped archived
        to_stamp = [s for s in covered if not by_seq.get(s, (None, None, False, True))[3]]
        if to_stamp:
            conn = self.pg()
            try:
                with conn.cursor() as cur:
                    cur.execute("""UPDATE clearledger.outbox SET archived_at = NOW()
                                   WHERE seq = ANY(%s) AND published_at IS NOT NULL AND archived_at IS NULL""",
                                (to_stamp,))
                conn.commit()
            finally:
                conn.close()
        if written:
            log(f's3: wrote {written} audit batch(es)')
        return changes

    def write_batch(self, chunk):
        conn = self.pg()
        try:
            with conn.cursor() as cur:
                cur.execute("""SELECT seq, payload, published_at IS NOT NULL FROM clearledger.outbox
                               WHERE seq = ANY(%s) ORDER BY seq FOR UPDATE""", (chunk,))
                rows = cur.fetchall()
                if [r[0] for r in rows] != sorted(chunk) or not all(r[2] for r in rows):
                    conn.rollback()
                    return False
                body = ''.join(dumps(canonical_envelope(r[1])) + '\n' for r in rows).encode('utf-8')
                digest = hashlib.sha256(body).hexdigest()[:16]
                key = 'ledger-audit/batch-%08d-%08d-%s.ndjson' % (rows[0][0], rows[-1][0], digest)
                self.s3.put_object(Bucket=self.bucket, Key=key, Body=body, ContentType='application/x-ndjson')
                cur.execute("""UPDATE clearledger.outbox SET archived_at = NOW()
                               WHERE seq = ANY(%s) AND archived_at IS NULL""", (chunk,))
            conn.commit()
            return True
        finally:
            conn.close()

    def reconcile_s3(self):
        for attempt in range(5):
            if self.reconcile_s3_pass() == 0:
                return
        log('s3: audit archive still changing after 5 passes (live traffic); last pass applied')

    # ------------------------------------------------------------------ Valkey
    def reconcile_valkey(self, settlements=None):
        if settlements is None:
            settlements, _ = self.load_pg()
        c = self.m['cache']
        r = redis.Redis(host=c['endpoint'], port=int(c['port']), socket_timeout=15, socket_connect_timeout=10)
        want = {}
        for sid, s in settlements.items():
            proj = {
                'settlementId': sid,
                'accountId': s['account_id'],
                'reference': s['reference'],
                'debitParty': s['debit_party'],
                'creditParty': s['credit_party'],
                'status': s['current_status'],
                'clearingStage': s['current_stage'],
            }
            if s['last_entry_id'] is not None:
                proj['lastEntryId'] = str(s['last_entry_id'])
            if s['last_memo'] is not None:
                proj['lastMemo'] = s['last_memo']
            proj['version'] = s['version']
            proj['entryCount'] = s['entry_count']
            proj['updatedAt'] = rfc3339_z(s['updated_at'])
            want[f'clearledger:settlement:{sid}'] = dumps(proj)
        stray = [k for k in r.scan_iter(count=1000) if k.decode('utf-8', 'replace') not in want]
        for i in range(0, len(stray), 500):
            r.delete(*stray[i:i + 500])
        pipe = r.pipeline(transaction=False)
        for k, v in want.items():
            pipe.set(k, v, ex=CACHE_TTL)
        pipe.execute()
        log(f'valkey: purged {len(stray)} stray key(s); warmed {len(want)} settlement projection(s)')


def delete_managed_policy(iam, arn):
    try:
        ents = iam.list_entities_for_policy(PolicyArn=arn)
        for r in ents.get('PolicyRoles', []):
            iam.detach_role_policy(RoleName=r['RoleName'], PolicyArn=arn)
        for u in ents.get('PolicyUsers', []):
            iam.detach_user_policy(UserName=u['UserName'], PolicyArn=arn)
        for g in ents.get('PolicyGroups', []):
            iam.detach_group_policy(GroupName=g['GroupName'], PolicyArn=arn)
    except Exception:  # noqa: BLE001
        pass
    try:
        for v in iam.list_policy_versions(PolicyArn=arn).get('Versions', []):
            if not v.get('IsDefaultVersion'):
                iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    except Exception:  # noqa: BLE001
        pass
    iam.delete_policy(PolicyArn=arn)


def main():
    manifest = json.load(open(sys.argv[1]))
    extra = json.load(open(sys.argv[2]))
    steps = sys.argv[3].split(',') if len(sys.argv) > 3 else ['iam', 'sg', 'data']
    rc = Reconciler(manifest, extra)
    if 'iam' in steps:
        rc.reconcile_iam()
    if 'sg' in steps:
        rc.reconcile_security_groups()
    if 'data' in steps:
        rc.publish_outbox()
        rc.wait_queue_drained()
        rc.publish_outbox()
        rc.reconcile_dynamodb()
        rc.reconcile_s3()
        # final pass: pick up anything committed meanwhile, then warm the cache last
        if rc.publish_outbox():
            rc.wait_queue_drained(timeout=60)
            rc.reconcile_s3()
        settlements, _ = rc.reconcile_dynamodb()
        rc.reconcile_valkey(settlements)


if __name__ == '__main__':
    main()
