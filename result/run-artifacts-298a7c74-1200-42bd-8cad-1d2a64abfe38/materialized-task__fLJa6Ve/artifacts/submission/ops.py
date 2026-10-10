#!/usr/bin/env python3
"""Operational repairs only: cloud creation and canonical policies belong to Terraform."""
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlencode

import boto3
import jsonschema
import psycopg2
import requests
from botocore.config import Config
from botocore.exceptions import ClientError
from boto3.dynamodb.types import TypeSerializer

ROOT = Path(__file__).resolve().parent
C = json.loads(Path('/workspace/config/config.json').read_text())
P = C['resource_prefix']
if P.startswith('cl-base-') or not re.fullmatch(r'[a-z][a-z0-9-]{3,23}', P):
    raise ValueError('Invalid deployment prefix')
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])
CLIENTS = {}


def client(service):
    if service not in CLIENTS:
        CLIENTS[service] = SESSION.client(service, endpoint_url=C['aws_endpoint_url'],
                                        config=Config(retries={'max_attempts': 4}, connect_timeout=5, read_timeout=40,
                                                      s3={'addressing_style': 'path'}))
    return CLIENTS[service]


def pages(service, operation, key, **kwargs):
    c = client(service)
    if c.can_paginate(operation):
        for page in c.get_paginator(operation).paginate(**kwargs):
            yield from page.get(key, [])
    else:
        yield from getattr(c, operation)(**kwargs).get(key, [])


def attempt(fn, **kwargs):
    try:
        return fn(**kwargs)
    except ClientError as e:
        code = e.response['Error']['Code']
        if any(s in code.lower() for s in ['notfound', 'not_found', 'nosuch', 'doesnotexist']):
            return None
        raise


def manifest():
    return json.loads((ROOT / 'manifest.json').read_text())


def db(m=None):
    m = m or manifest()
    return psycopg2.connect(host=m['database']['endpoint'], port=m['database']['port'],
                            dbname=C['db_name'], user=C['db_username'], password=C['db_password'],
                            connect_timeout=5, application_name='clearledger-deploy')


def prepare():
    # Ignore unrelated configuration fields while reading every deployment input dynamically.
    keys = ['resource_prefix', 'region', 'aws_endpoint_url', 'db_name', 'db_username', 'db_password']
    keys += [w + suffix for w in ['api', 'projector', 'relay', 'archiver'] for suffix in ['_image', '_image_id']]
    (ROOT / 'infra' / 'inputs.auto.tfvars.json').write_text(json.dumps({'config': {k: C[k] for k in keys}}))


def state_resources():
    f = ROOT / 'infra' / 'terraform.tfstate'
    if not f.exists():
        return []
    return json.loads(f.read_text()).get('resources', [])


def control():
    iam = client('iam')
    for r in ['ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler']:
        name = f'{P}-{r}'
        if not attempt(iam.get_role, RoleName=name):
            continue
        for policy in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
            if policy != f'{P}-{r}-canonical':
                iam.delete_role_policy(RoleName=name, PolicyName=policy)
        for policy in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])
    # Enabled state is deliberately repaired here: the provider does not refresh it.
    kms = client('kms')
    for res in state_resources():
        if res['type'] == 'aws_kms_key':
            for instance in res['instances']:
                key = instance['attributes']['id']
                response = attempt(kms.describe_key, KeyId=key)
                if not response:
                    continue
                status = response['KeyMetadata']['KeyState']
                if status == 'PendingDeletion':
                    kms.cancel_key_deletion(KeyId=key)
                    status = 'Disabled'
                if status == 'Disabled':
                    kms.enable_key(KeyId=key)
    # Discard detached prefix-owned policies introduced outside Terraform.
    for policy in pages('iam', 'list_policies', 'Policies', Scope='Local'):
        if policy['PolicyName'].startswith(P + '-') and policy.get('AttachmentCount', 0) == 0:
            delete_policy(policy['Arn'])


def protect():
    result = subprocess.check_output(['terraform', f'-chdir={ROOT}/infra', 'show', '-json', f'{ROOT}/infra/deploy.plan'])
    plan = json.loads(result)
    for r in plan.get('resource_changes', []):
        if r['type'] in ['aws_db_instance', 'aws_dynamodb_table', 'aws_s3_bucket'] and 'delete' in r['change']['actions']:
            raise RuntimeError(f"Refusing destructive replacement of authoritative/persistent store: {r['address']}")


def export_manifest():
    raw = subprocess.check_output(['terraform', f'-chdir={ROOT}/infra', 'output', '-json', 'manifest'])
    m = json.loads(raw)
    jsonschema.validate(m, json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text()))
    tmp = ROOT / 'manifest.json.tmp'
    tmp.write_text(json.dumps(m, indent=2) + '\n')
    tmp.replace(ROOT / 'manifest.json')


def schema():
    deadline = time.monotonic() + 120
    while True:
        try:
            conn = db()
            break
        except psycopg2.OperationalError:
            if time.monotonic() > deadline:
                raise
            time.sleep(2)
    conn.close()
    m = manifest()
    env = dict(os.environ, PGHOST=m['database']['endpoint'], PGPORT=str(m['database']['port']),
               PGDATABASE=C['db_name'], PGUSER=C['db_username'], PGPASSWORD=C['db_password'])
    with (ROOT / 'schema.log').open('w') as log:
        subprocess.run(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-f', str(ROOT / 'schema.sql')], env=env,
                       stdout=log, stderr=log, check=True)


def ready():
    deadline = time.monotonic() + 120
    url = manifest()['service_url'] + '/health/ready'
    while time.monotonic() < deadline:
        try:
            if requests.get(url, timeout=5).status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(2)
    raise RuntimeError('API readiness deadline exceeded')


class Valkey:
    """Small RESP client, avoiding a runtime dependency on redis-cli."""
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.file = self.sock.makefile('rb')

    def read(self):
        line = self.file.readline().rstrip(b'\r\n')
        kind, payload = line[:1], line[1:]
        if kind == b'-':
            raise RuntimeError(payload.decode())
        if kind == b'+':
            return payload.decode()
        if kind == b':':
            return int(payload)
        if kind == b'$':
            n = int(payload)
            if n < 0:
                return None
            value = self.file.read(n)
            self.file.read(2)
            return value.decode()
        if kind == b'*':
            return [self.read() for _ in range(int(payload))]
        raise RuntimeError('Invalid RESP response')

    def command(self, *args):
        parts = [str(a).encode() if not isinstance(a, bytes) else a for a in args]
        data = b'*' + str(len(parts)).encode() + b'\r\n'
        for p in parts:
            data += b'$' + str(len(p)).encode() + b'\r\n' + p + b'\r\n'
        self.sock.sendall(data)
        return self.read()

    def close(self):
        self.file.close()
        self.sock.close()


SERIALIZER = TypeSerializer()


def av(item):
    return {k: SERIALIZER.serialize(v) for k, v in item.items() if v is not None}


def compact(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(',', ':'))


def canonical_envelope(p):
    # Envelope/data field order matches the domain schema and starts with schemaVersion/kind.
    keys = ['schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId', 'aggregateVersion',
            'occurredAt', 'correlationId', 'idempotencyKey', 'data']
    data_keys = ['kind', 'accountId', 'reference', 'debitParty', 'creditParty', 'entryId', 'status', 'clearingStage', 'memo']
    out = {k: p[k] for k in keys if k != 'data'}
    out['data'] = {k: p['data'][k] for k in data_keys if k in p['data']}
    return out


def set_schedule(name, enabled):
    c = client('scheduler')
    schedule = c.get_schedule(Name=name)
    kwargs = {k: schedule[k] for k in ['Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone',
                                      'StartDate', 'EndDate', 'Description', 'FlexibleTimeWindow', 'Target',
                                      'KmsKeyArn', 'ActionAfterCompletion'] if k in schedule}
    kwargs['State'] = 'ENABLED' if enabled else 'DISABLED'
    c.update_schedule(**kwargs)


def reconcile():
    m = manifest()
    lam = client('lambda')
    mapping = m['messaging']['event_source_mapping_uuid']
    schedules = [m['schedules']['outbox_schedule_name'], m['schedules']['archive_schedule_name']]
    lam.update_event_source_mapping(UUID=mapping, Enabled=False)
    for name in schedules:
        set_schedule(name, False)
    conn = None
    cache = None
    try:
        deadline = time.monotonic() + 60
        while lam.get_event_source_mapping(UUID=mapping)['State'] not in ['Disabled']:
            if time.monotonic() > deadline:
                raise RuntimeError('Projector did not quiesce')
            time.sleep(1)
        # Let invocations already dispatched finish before acquiring the consistency fence.
        time.sleep(4)
        conn = db(m)
        cur = conn.cursor()
        cur.execute("SET LOCAL lock_timeout = '40s'; SET LOCAL statement_timeout = '120s'")
        cur.execute('SELECT pg_advisory_xact_lock(743192001)')
        cur.execute('LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
        cur.execute('SELECT payload FROM clearledger.events ORDER BY settlement_id, aggregate_version')
        events = [r[0] for r in cur.fetchall()]
        cur.execute('SELECT seq,payload FROM clearledger.outbox ORDER BY seq')
        outbox = cur.fetchall()
        cur.execute('SELECT settlement_id::text,version FROM clearledger.settlements')
        settlements = dict(cur.fetchall())
        # Drain both old queue backlog and newly relayed rows while writers are fenced.
        # This precedes cache population, since even duplicate deliveries invalidate cache.
        sqs = client('sqs')
        cur.execute('SELECT seq,payload FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq')
        pending = cur.fetchall()
        for seq, envelope in pending:
            sqs.send_message(QueueUrl=m['messaging']['queue_url'], MessageBody=compact(canonical_envelope(envelope)))
        lam.update_event_source_mapping(UUID=mapping, Enabled=True)
        deadline = time.monotonic() + 120
        empty_observations = 0
        while time.monotonic() < deadline:
            attrs = sqs.get_queue_attributes(QueueUrl=m['messaging']['queue_url'], AttributeNames=[
                'ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', 'ApproximateNumberOfMessagesDelayed'])['Attributes']
            empty_observations = empty_observations + 1 if all(int(v) == 0 for v in attrs.values()) else 0
            if empty_observations >= 3:
                break
            time.sleep(1)
        else:
            raise RuntimeError('SQS backlog did not drain')
        lam.update_event_source_mapping(UUID=mapping, Enabled=False)
        while lam.get_event_source_mapping(UUID=mapping)['State'] != 'Disabled':
            if time.monotonic() > deadline:
                raise RuntimeError('Projector did not quiesce after draining')
            time.sleep(1)
        time.sleep(2)
        for seq, envelope in pending:
            cur.execute('UPDATE clearledger.outbox SET published_at=now(),attempts=attempts+1,last_error=NULL WHERE seq=%s AND published_at IS NULL', (seq,))
        expected = {}
        states = {}
        for e in events:
            sid = e['aggregateId']
            version = e['aggregateVersion']
            d = e['data']
            pk = 'SETTLEMENT#' + sid
            event = dict(PK=pk, SK=f'EVENT#{version:08d}', settlement_id=sid, event_id=e['eventId'],
                         version=version, event_type=e['eventType'], status=d['status'], clearing_stage=d['clearingStage'],
                         occurred_at=e['occurredAt'], correlation_id=e['correlationId'], envelope=compact(canonical_envelope(e)))
            if d.get('entryId') is not None:
                event['entry_id'] = d['entryId']
            if d.get('memo') is not None:
                event['memo'] = d['memo']
            expected[(pk, event['SK'])] = av(event)
            prior = states.get(sid, {})
            state = dict(PK=pk, SK='STATE', GSI1PK='ACCOUNT#' + d['accountId'], GSI1SK=pk, settlement_id=sid,
                         account_id=d['accountId'], reference=d['reference'], debit_party=d['debitParty'], credit_party=d['creditParty'],
                         status=d['status'], clearing_stage=d['clearingStage'], version=version, entry_count=version - 1,
                         updated_at=e['occurredAt'], last_entry_id=d.get('entryId'), last_memo=d.get('memo') or prior.get('last_memo'))
            states[sid] = state
        if {sid: s['version'] for sid, s in states.items()} != settlements:
            raise RuntimeError('PostgreSQL settlement/event versions diverge')
        for sid, s in states.items():
            expected[(s['PK'], 'STATE')] = av(s)
        dynamo = client('dynamodb')
        table = m['projections']['table_name']
        actual = {}
        for item in pages('dynamodb', 'scan', 'Items', TableName=table, ConsistentRead=True):
            actual[(item['PK']['S'], item['SK']['S'])] = item
        for key, item in actual.items():
            if key not in expected:
                dynamo.delete_item(TableName=table, Key={k: item[k] for k in ['PK', 'SK']})
        for key, item in expected.items():
            if actual.get(key) != item:
                dynamo.put_item(TableName=table, Item=item)

        reconcile_archive(m, outbox)
        cur.execute('UPDATE clearledger.outbox SET archived_at=GREATEST(now(),published_at) WHERE archived_at IS NULL AND published_at IS NOT NULL')
        cache = Valkey(m['cache']['endpoint'], m['cache']['port'])
        allowed = {'clearledger:settlement:' + sid for sid in states}
        cursor = '0'
        while True:
            cursor, keys = cache.command('SCAN', cursor, 'COUNT', 1000)
            for key in keys:
                if key not in allowed:
                    cache.command('DEL', key)
            if cursor == '0':
                break
        mapping_fields = {'settlement_id': 'settlementId', 'account_id': 'accountId', 'reference': 'reference',
                          'debit_party': 'debitParty', 'credit_party': 'creditParty', 'status': 'status',
                          'clearing_stage': 'clearingStage', 'last_entry_id': 'lastEntryId', 'last_memo': 'lastMemo',
                          'version': 'version', 'entry_count': 'entryCount', 'updated_at': 'updatedAt'}
        for sid, state in states.items():
            projection = {dst: state.get(src) for src, dst in mapping_fields.items()}
            cache.command('SET', 'clearledger:settlement:' + sid, compact(projection), 'EX', 90)
        # Verify the complete derived set before releasing blocked application writers.
        got = {(i['PK']['S'], i['SK']['S']): i for i in pages('dynamodb', 'scan', 'Items', TableName=table, ConsistentRead=True)}
        if got != expected:
            raise RuntimeError('Projection verification failed')
        conn.commit()
        print(f'Reconciled {len(states)} settlements, {len(events)} events, {len(outbox)} audit records.')
    finally:
        if conn:
            conn.close()
        if cache:
            cache.close()
        # Always restore canonical worker configuration, including on interrupted repairs.
        lam.update_event_source_mapping(UUID=mapping, Enabled=True)
        for name in schedules:
            set_schedule(name, True)


def reconcile_archive(m, outbox):
    s3 = client('s3')
    bucket = m['audit']['bucket_name']
    wanted = {}
    # Split at sequence gaps as well as the batch bound; each interval is gap-free.
    batches = []
    batch = []
    for row in outbox:
        if batch and (len(batch) >= 100 or row[0] != batch[-1][0] + 1):
            batches.append(batch)
            batch = []
        batch.append(row)
    if batch:
        batches.append(batch)
    for batch in batches:
        raw = ''.join(compact(canonical_envelope(e)) + '\n' for seq, e in batch).encode()
        key = f'ledger-audit/batch-{batch[0][0]:08d}-{batch[-1][0]:08d}-{hashlib.sha256(raw).hexdigest()[:16]}.ndjson'
        wanted[key] = raw
    current = {o['Key']: o for o in pages('s3', 'list_objects_v2', 'Contents', Bucket=bucket)}
    for key in set(current) - set(wanted):
        # Removing the current object first also handles pre-versioning/null objects.
        s3.delete_object(Bucket=bucket, Key=key)
    keep_versions = {}
    for key, raw in wanted.items():
        response = s3.get_object(Bucket=bucket, Key=key) if key in current else None
        found = response['Body'].read() if response else None
        if found != raw or response.get('ServerSideEncryption') != 'aws:kms' or response.get('SSEKMSKeyId') != m['kms']['audit_arn']:
            s3.put_object(Bucket=bucket, Key=key, Body=raw, ContentType='application/x-ndjson',
                          ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
        keep_versions[key] = s3.head_object(Bucket=bucket, Key=key).get('VersionId', 'null')
    versions = []
    for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
        for v in page.get('Versions', []):
            # HEAD identifies the actual current version even if a local control plane
            # returns stale IsLatest flags after suspended-versioning recovery.
            if v['VersionId'] != keep_versions.get(v['Key']):
                versions.append({'Key': v['Key'], 'VersionId': v['VersionId']})
        versions.extend({'Key': v['Key'], 'VersionId': v['VersionId']} for v in page.get('DeleteMarkers', []))
    for n in range(0, len(versions), 1000):
        result = s3.delete_objects(Bucket=bucket, Delete={'Objects': versions[n:n + 1000], 'Quiet': True})
        if result.get('Errors'):
            raise RuntimeError('Archive version deletion failed')
    if {o['Key'] for o in pages('s3', 'list_objects_v2', 'Contents', Bucket=bucket)} != set(wanted):
        raise RuntimeError('Archive key set verification failed')


def delete_policy(arn):
    iam = client('iam')
    for v in iam.list_policy_versions(PolicyArn=arn)['Versions']:
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    iam.delete_policy(PolicyArn=arn)


def report_error(filename):
    # Terraform logs can include environment strings; sanitize before displaying errors.
    text = (ROOT / filename).read_text()
    text = text.replace(C['db_password'], '[REDACTED]')
    if (ROOT / 'manifest.json').exists():
        for v in manifest()['auth']['clients'].values():
            text = text.replace(v['client_secret'], '[REDACTED]')
    print(text[-24000:], file=sys.stderr)


def cleanup(extra_only=False):
    from cleanup import sweep
    sweep(C, client, pages, attempt, state_resources(), extra_only)


def empty_state():
    if any(r.get('instances') for r in state_resources() if r.get('mode') == 'managed'):
        raise RuntimeError('Managed resources remain in Terraform state')


if __name__ == '__main__':
    commands = {'prepare': prepare, 'control': control, 'protect': protect, 'manifest': export_manifest,
                'schema': schema, 'ready': ready, 'reconcile': reconcile, 'cleanup': cleanup,
                'cleanup-extra': lambda: cleanup(True), 'empty-state': empty_state,
                'report-error': lambda: report_error('apply.log'),
                'report-destroy-error': lambda: report_error('destroy.log')}
    commands[sys.argv[1]]()
