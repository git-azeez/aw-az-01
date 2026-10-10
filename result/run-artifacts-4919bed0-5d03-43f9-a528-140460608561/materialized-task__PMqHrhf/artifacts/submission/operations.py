"""Operational data repair only; cloud resource creation belongs to Terraform."""
import datetime
import hashlib
import json
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

import boto3
import jsonschema
import psycopg
import redis
from boto3.dynamodb.types import TypeSerializer
from botocore.config import Config
from botocore.exceptions import ClientError
from psycopg.rows import dict_row

ROOT = pathlib.Path(__file__).resolve().parent
C = json.loads(pathlib.Path('/workspace/config/config.json').read_text())
P = C['resource_prefix']
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])


def client(service):
    return SESSION.client(service, endpoint_url=C['aws_endpoint_url'], config=Config(
        connect_timeout=5, read_timeout=30, retries={'max_attempts': 4, 'mode': 'standard'},
        s3={'addressing_style': 'path'}))


def pages(c, op, key, **kw):
    if c.can_paginate(op):
        return [x for page in c.get_paginator(op).paginate(**kw) for x in page.get(key, [])]
    return getattr(c, op)(**kw).get(key, [])


def manifest():
    return json.loads((ROOT / 'manifest.json').read_text())


def database(m):
    d = m['database']
    return psycopg.connect(host=d['endpoint'], port=d['port'], dbname=C['db_name'],
        user=C['db_username'], password=C['db_password'], connect_timeout=5, row_factory=dict_row)


def scoped(name, tags=None):
    name = str(name)
    if 'cl-base-' in name:
        return False
    if isinstance(tags, list):
        tags = {t.get('Key', t.get('TagKey')): t.get('Value', t.get('TagValue')) for t in tags}
    return (name.startswith(P) or name.startswith('alias/' + P) or
            name.startswith('/clearledger/' + P + '/') or
            (tags or {}).get('ClearLedgerDeployment') == P or
            str((tags or {}).get('Name', '')).startswith(P))


def delete_policy(iam, arn):
    for v in pages(iam, 'list_policy_versions', 'Versions', PolicyArn=arn):
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    iam.delete_policy(PolicyArn=arn)


def prepare():
    # Reject accidentally using an existing state against a different deployment.
    state = ROOT / 'infra/terraform.tfstate'
    state_data = json.loads(state.read_text()) if state.exists() else {}
    if state.exists():
        saved = state_data.get('outputs', {}).get('manifest', {}).get('value', {})
        if saved and saved['resource_prefix'] != P:
            raise RuntimeError('Active state belongs to a different resource_prefix')
    iam = client('iam')
    for r in pages(iam, 'list_roles', 'Roles'):
        if not scoped(r['RoleName'], r.get('Tags')):
            continue
        name = r['RoleName']
        if name not in [P + '-' + k for k in ('ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler')]:
            continue
        for pol in pages(iam, 'list_role_policies', 'PolicyNames', RoleName=name):
            if pol != name + '-canonical':
                iam.delete_role_policy(RoleName=name, PolicyName=pol)
        for pol in pages(iam, 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=pol['PolicyArn'])
    for p in pages(iam, 'list_policies', 'Policies', Scope='Local'):
        if scoped(p['PolicyName']) and p.get('AttachmentCount', 0) == 0:
            delete_policy(iam, p['Arn'])
    managed_keys = {instance['attributes']['id']
        for resource in state_data.get('resources', []) if resource['type'] == 'aws_kms_key'
        for instance in resource.get('instances', [])}
    kms = client('kms')
    for k in pages(kms, 'list_keys', 'Keys'):
        if k['KeyId'] not in managed_keys:
            continue
        tags = pages(kms, 'list_resource_tags', 'Tags', KeyId=k['KeyId'])
        if scoped('', tags):
            info = kms.describe_key(KeyId=k['KeyId'])['KeyMetadata']
            if info['KeyState'] == 'PendingDeletion':
                kms.cancel_key_deletion(KeyId=k['KeyId'])
            if info['KeyState'] in ('PendingDeletion', 'Disabled'):
                kms.enable_key(KeyId=k['KeyId'])


def schema():
    m = manifest()
    for attempt in range(60):
        try:
            conn = database(m)
            break
        except psycopg.OperationalError:
            if attempt == 59:
                raise
            time.sleep(2)
    with conn:
        conn.execute((ROOT / 'schema.sql').read_text())
    print('PostgreSQL schema, constraints, triggers and indexes repaired.')


def ready():
    url = manifest()['service_url'] + '/health/ready'
    for _ in range(90):
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                if response.status == 200:
                    print('API readiness: HTTP 200')
                    return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(2)
    raise RuntimeError('API readiness timed out')


def schedule_state(c, name, state):
    s = c.get_schedule(Name=name)
    fields = ('Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone',
              'StartDate', 'EndDate', 'Description', 'KmsKeyArn', 'Target', 'FlexibleTimeWindow',
              'ActionAfterCompletion')
    c.update_schedule(**{k: v for k, v in s.items() if k in fields}, State=state)


def mapping_state(c, uuid, enabled):
    for _ in range(60):
        s = c.get_event_source_mapping(UUID=uuid)['State']
        if s == ('Enabled' if enabled else 'Disabled'):
            return
        if s in ('Enabled', 'Disabled'):
            c.update_event_source_mapping(UUID=uuid, Enabled=enabled)
        time.sleep(0.5)
    raise RuntimeError('Event source mapping did not stabilize')


def timestamp(t):
    return t.isoformat().replace('+00:00', 'Z') if isinstance(t, datetime.datetime) else t


def projection(s):
    return dict(settlementId=str(s['settlement_id']), accountId=s['account_id'], reference=s['reference'],
        debitParty=s['debit_party'], creditParty=s['credit_party'], status=s['current_status'],
        clearingStage=s['current_stage'], lastEntryId=str(s['last_entry_id']) if s['last_entry_id'] else None,
        lastMemo=s['last_memo'], version=s['version'], entryCount=s['entry_count'], updatedAt=timestamp(s['updated_at']))


def canonical_items(settlements, events):
    items = {}
    for s in settlements:
        sid = str(s['settlement_id'])
        item = dict(PK='SETTLEMENT#' + sid, SK='STATE', GSI1PK='ACCOUNT#' + s['account_id'],
            GSI1SK='SETTLEMENT#' + sid, settlement_id=sid, account_id=s['account_id'], reference=s['reference'],
            debit_party=s['debit_party'], credit_party=s['credit_party'], status=s['current_status'],
            clearing_stage=s['current_stage'], version=s['version'], entry_count=s['entry_count'],
            updated_at=timestamp(s['updated_at']))
        if s['last_entry_id'] is not None:
            item['last_entry_id'] = str(s['last_entry_id'])
        if s['last_memo'] is not None:
            item['last_memo'] = s['last_memo']
        items[(item['PK'], item['SK'])] = item
    for e in events:
        p = e['payload']; d = p['data']
        item = dict(PK='SETTLEMENT#' + str(e['settlement_id']), SK=f"EVENT#{e['aggregate_version']:08d}",
            settlement_id=str(e['settlement_id']), event_id=str(e['event_id']), version=e['aggregate_version'],
            event_type=e['event_type'], status=d['status'], clearing_stage=d['clearingStage'],
            occurred_at=p['occurredAt'], correlation_id=e['correlation_id'], envelope=json.dumps(p, separators=(',', ':')))
        for source, target in [('entryId', 'entry_id'), ('memo', 'memo')]:
            if d.get(source) is not None:
                item[target] = d[source]
        items[(item['PK'], item['SK'])] = item
    return items


def reconcile_ddb(m, settlements, events):
    ddb = client('dynamodb'); table = m['projections']['table_name']; ser = TypeSerializer()
    expected = canonical_items(settlements, events)
    existing = pages(ddb, 'scan', 'Items', TableName=table, ConsistentRead=True)
    for item in existing:
        key = (item['PK']['S'], item['SK']['S'])
        if key not in expected:
            ddb.delete_item(TableName=table, Key={k: item[k] for k in ('PK', 'SK')})
    for item in expected.values():
        ddb.put_item(TableName=table, Item={k: ser.serialize(v) for k, v in item.items()})
    actual = pages(ddb, 'scan', 'Items', TableName=table, ConsistentRead=True)
    encoded = {(i['PK']['S'], i['SK']['S']): i for i in actual}
    assert encoded == {key: {k: ser.serialize(v) for k, v in item.items()} for key, item in expected.items()}, 'DynamoDB verification failed'


def object_versions(s3, bucket):
    for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
        for kind in ('Versions', 'DeleteMarkers'):
            for obj in page.get(kind, []):
                yield kind, obj


def reconcile_s3(m, conn, rows):
    s3 = client('s3'); bucket = m['audit']['bucket_name']
    by_seq = {r['seq']: r for r in rows}; covered = set(); keep = set()
    pattern = re.compile(r'^ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson$')
    versions = list(object_versions(s3, bucket))
    for kind, obj in sorted(versions, key=lambda pair: pair[1]['Key']):
        key = obj['Key']; match = pattern.fullmatch(key)
        valid = False
        if kind == 'Versions' and obj['IsLatest'] and match:
            lo, hi = int(match[1]), int(match[2])
            seqs = [seq for seq in sorted(by_seq) if lo <= seq <= hi]
            if seqs and seqs[0] == lo and seqs[-1] == hi and not covered.intersection(seqs):
                body = s3.get_object(Bucket=bucket, Key=key, VersionId=obj['VersionId'])['Body'].read()
                try:
                    envelopes = [json.loads(line) for line in body.splitlines()]
                    valid = (hashlib.sha256(body).hexdigest()[:16] == match[3] and
                             envelopes == [by_seq[seq]['payload'] for seq in seqs])
                except (ValueError, UnicodeError):
                    pass
                if valid:
                    covered.update(seqs); keep.add((key, obj['VersionId']))
        if not valid:
            s3.delete_object(Bucket=bucket, Key=key, VersionId=obj['VersionId'])
    # Fill maximal uncovered runs, never bridge across an already retained batch.
    batches = []; batch = []
    for row in rows:
        if row['seq'] in covered:
            if batch: batches.append(batch); batch = []
        else:
            batch.append(row)
            if len(batch) == 100: batches.append(batch); batch = []
    if batch: batches.append(batch)
    for batch in batches:
        body = ''.join(json.dumps(r['payload'], sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n' for r in batch).encode()
        key = f"ledger-audit/batch-{batch[0]['seq']:08d}-{batch[-1]['seq']:08d}-{hashlib.sha256(body).hexdigest()[:16]}.ndjson"
        result = s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType='application/x-ndjson',
            ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
        keep.add((key, result['VersionId']))
        covered.update(r['seq'] for r in batch)
    # A delete marker might have hidden a previous version; remove every unretained version.
    for kind, obj in list(object_versions(s3, bucket)):
        if kind != 'Versions' or (obj['Key'], obj['VersionId']) not in keep:
            s3.delete_object(Bucket=bucket, Key=obj['Key'], VersionId=obj['VersionId'])
    assert covered == set(by_seq), 'Archive coverage mismatch'
    conn.execute('UPDATE clearledger.outbox SET archived_at=greatest(clock_timestamp(),published_at) WHERE archived_at IS NULL')
    assert all(kind == 'Versions' and obj['IsLatest'] and (obj['Key'], obj['VersionId']) in keep
               for kind, obj in object_versions(s3, bucket)), 'Archive version verification failed'


def reconcile():
    m = manifest(); lam = client('lambda'); scheduler = client('scheduler'); sqs = client('sqs')
    uuid = m['messaging']['event_source_mapping_uuid']
    schedules = [m['schedules'][k] for k in ('outbox_schedule_name', 'archive_schedule_name')]
    try:
        for name in schedules: schedule_state(scheduler, name, 'DISABLED')
        mapping_state(lam, uuid, False)
        time.sleep(4)  # Allow already-dispatched 3-second workers to finish.
        with database(m) as conn:
            conn.execute("SET LOCAL lock_timeout='45s'")
            conn.execute('LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
            settlements = conn.execute('SELECT * FROM clearledger.settlements ORDER BY settlement_id').fetchall()
            events = conn.execute('SELECT * FROM clearledger.events ORDER BY seq').fetchall()
            rows = conn.execute('SELECT * FROM clearledger.outbox ORDER BY seq').fetchall()
            for r in rows:
                if r['published_at'] is None:
                    sqs.send_message(QueueUrl=m['messaging']['queue_url'], MessageBody=json.dumps(r['payload']))
                    conn.execute('UPDATE clearledger.outbox SET published_at=greatest(clock_timestamp(),created_at), attempts=attempts+1,last_error=NULL WHERE seq=%s', (r['seq'],))
            reconcile_ddb(m, settlements, events)
            reconcile_s3(m, conn, rows)
            # All committed envelopes now have their exact projection. Acknowledge backlog
            # only after repair; unknown/poison envelopes remain available in the DLQ.
            empty = 0; deadline = time.monotonic() + 90
            canonical = {str(e['event_id']): e['payload'] for e in events}
            while empty < 3 and time.monotonic() < deadline:
                messages = sqs.receive_message(QueueUrl=m['messaging']['queue_url'], MaxNumberOfMessages=10, WaitTimeSeconds=1).get('Messages', [])
                empty = 0 if messages else empty + 1
                for msg in messages:
                    try:
                        envelope = json.loads(msg['Body'])
                        valid = isinstance(envelope, dict) and canonical.get(envelope.get('eventId')) == envelope
                    except ValueError:
                        valid = False
                    if not valid:
                        sqs.send_message(QueueUrl=m['messaging']['dlq_url'], MessageBody=msg['Body'])
                    sqs.delete_message(QueueUrl=m['messaging']['queue_url'], ReceiptHandle=msg['ReceiptHandle'])
            if empty < 3: raise RuntimeError('Queue drain timed out')
            cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
            allowed = {'clearledger:settlement:' + str(s['settlement_id']) for s in settlements}
            for key in cache.scan_iter(count=500):
                if key.decode() not in allowed: cache.delete(key)
            with cache.pipeline(transaction=True) as pipe:
                for s in settlements:
                    pipe.set('clearledger:settlement:' + str(s['settlement_id']), json.dumps(projection(s), separators=(',', ':')), ex=90)
                pipe.execute()
            for s in settlements:
                key = 'clearledger:settlement:' + str(s['settlement_id'])
                assert json.loads(cache.get(key)) == projection(s) and 0 < cache.ttl(key) <= 90
        print(f'Reconciled {len(settlements)} settlements and {len(events)} events across all derived stores.')
    finally:
        # Always restore canonical enabled state, including after an interrupted repair.
        mapping_state(lam, uuid, True)
        for name in schedules: schedule_state(scheduler, name, 'ENABLED')


if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'manifest':
        value = json.loads((ROOT / 'manifest.json.tmp').read_text())
        jsonschema.validate(value, json.loads(pathlib.Path('/workspace/contracts/schemas/manifest.schema.json').read_text()))
    else:
        {'prepare': prepare, 'schema': schema, 'ready': ready, 'reconcile': reconcile}[command]()
