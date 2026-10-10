"""Operational migrations and derived-store repair. Resource creation belongs to Terraform."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from boto3.dynamodb.types import TypeSerializer
import jsonschema
import psycopg2
from psycopg2.extras import RealDictCursor
import redis

ROOT = Path(__file__).resolve().parent
C = json.loads(Path('/workspace/config/config.json').read_text())
P = C['resource_prefix']
assert re.fullmatch(r'[a-z][a-z0-9-]{3,35}', P) and not P.startswith('cl-base-')
os.environ.update(AWS_ACCESS_KEY_ID='test', AWS_SECRET_ACCESS_KEY='test',
                  AWS_DEFAULT_REGION=C['region'], AWS_REGION=C['region'],
                  AWS_ENDPOINT_URL=C['aws_endpoint_url'], TF_VAR_config=json.dumps(C))
SESSION = boto3.Session(region_name=C['region'], aws_access_key_id='test', aws_secret_access_key='test')


def client(service):
    return SESSION.client(service, endpoint_url=C['aws_endpoint_url'],
                          config=Config(retries={'max_attempts': 4, 'mode': 'standard'},
                                        connect_timeout=5, read_timeout=45))


def tf(*args, capture=False):
    cmd = ['terraform', '-chdir=' + str(ROOT / 'infra'), *args]
    if capture:
        return subprocess.check_output(cmd, text=True)
    with (ROOT / 'terraform.log').open('a') as log:
        result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        # The diagnostic tail is bounded; do not expose secrets from plans.
        lines = (ROOT / 'terraform.log').read_text().splitlines()
        print('\n'.join(lines[-65:]), file=sys.stderr)
        raise RuntimeError('Terraform failed; see submission/terraform.log')


def pages(svc, op, field, **kwargs):
    c = client(svc)
    if c.can_paginate(op):
        return [x for p in c.get_paginator(op).paginate(**kwargs) for x in p.get(field, [])]
    return getattr(c, op)(**kwargs).get(field, [])


def absent_call(fn, **kwargs):
    try:
        return fn(**kwargs)
    except ClientError as e:
        if e.response['Error']['Code'] in ('NoSuchEntity', 'NotFoundException', 'ResourceNotFoundException',
                                         'ResourceNotFound', 'NoSuchBucket', 'DBInstanceNotFound',
                                         'DBInstanceNotFoundFault', 'AWS.SimpleQueueService.NonExistentQueue'):
            return None
        raise


def repair_roles():
    iam = client('iam')
    for r in ['ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler']:
        name = P + '-' + r
        if not absent_call(iam.get_role, RoleName=name):
            continue
        for pol in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
            if pol != P + '-canonical':
                iam.delete_role_policy(RoleName=name, PolicyName=pol)
        for pol in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=pol['PolicyArn'])
    for pol in pages('iam', 'list_policies', 'Policies', Scope='Local'):
        tags = iam.list_policy_tags(PolicyArn=pol['Arn']).get('Tags', [])
        if scoped(pol['PolicyName'], tags) and pol.get('AttachmentCount', 0) == 0:
            delete_policy(iam, pol['Arn'])
    kms = client('kms')
    for alias in pages('kms', 'list_aliases', 'Aliases'):
        if alias['AliasName'].startswith('alias/' + P + '-') and alias.get('TargetKeyId'):
            k = kms.describe_key(KeyId=alias['TargetKeyId'])['KeyMetadata']
            if k['KeyState'] == 'PendingDeletion':
                kms.cancel_key_deletion(KeyId=k['KeyId'])
            if k['KeyState'] != 'Enabled':
                kms.enable_key(KeyId=k['KeyId'])


def scoped(name, tags=()):
    if name.startswith('cl-base-') or '/cl-base-' in name or ':cl-base-' in name:
        return False
    if isinstance(tags, dict):
        tagmap = tags
    else:
        tagmap = {t.get('Key', t.get('key')): t.get('Value', t.get('value')) for t in tags}
    tagname = tagmap.get('Name', '')
    if tagname.startswith('cl-base-'):
        return False
    return any(part.startswith(P) for part in re.split(r'[:/]', name)) or tagname.startswith(P) or tagmap.get('ClearLedgerDeployment') == P


def delete_policy(iam, arn):
    for v in iam.list_policy_versions(PolicyArn=arn)['Versions']:
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    iam.delete_policy(PolicyArn=arn)


def database(m):
    d = m['database']
    return psycopg2.connect(host=d['endpoint'], port=d['port'], dbname=C['db_name'],
                            user=C['db_username'], password=C['db_password'], connect_timeout=5)


def wait_ready(m, seconds=150):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(m['service_url'] + '/health/ready', timeout=4) as r:
                if r.status == 200:
                    return
        except Exception:
            time.sleep(1)
    raise RuntimeError('API readiness deadline exceeded')


def schedules(m, enabled):
    c = client('scheduler')
    for name in [m['schedules']['outbox_schedule_name'], m['schedules']['archive_schedule_name']]:
        s = c.get_schedule(Name=name)
        args = {k: s[k] for k in ['Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone',
                'StartDate', 'EndDate', 'Description', 'FlexibleTimeWindow', 'Target', 'KmsKeyArn',
                'ActionAfterCompletion'] if k in s}
        c.update_schedule(**args, State='ENABLED' if enabled else 'DISABLED')


def mapping(m, enabled):
    c = client('lambda')
    uid = m['messaging']['event_source_mapping_uuid']
    c.update_event_source_mapping(UUID=uid, Enabled=enabled)
    for _ in range(60):
        if c.get_event_source_mapping(UUID=uid)['State'] == ('Enabled' if enabled else 'Disabled'):
            return
        time.sleep(.5)
    raise RuntimeError('Event source mapping did not stabilize')


def invoke(m, name, payload):
    r = client('lambda').invoke(FunctionName=m['workers'][name]['function_name'],
                                 Payload=json.dumps(payload).encode())
    body = r['Payload'].read()
    if r.get('FunctionError'):
        raise RuntimeError('Worker invocation failed: ' + name + ': ' + body.decode()[:500])
    return json.loads(body or b'{}')


def canonical(p):
    # Matches serde's tagged enum + struct order used by the supplied Rust workers.
    order = ['schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId',
             'aggregateVersion', 'occurredAt', 'correlationId', 'idempotencyKey']
    data_order = ['kind', 'accountId', 'reference', 'debitParty', 'creditParty',
                  'entryId', 'status', 'clearingStage', 'memo']
    q = {k: p[k] for k in order}
    q['data'] = {k: p['data'][k] for k in data_order if p['data'].get(k) is not None}
    return json.dumps(q, ensure_ascii=False, separators=(',', ':'))


def drain_queue(m):
    """Run the real projector; keep failed records for normal redrive to the DLQ."""
    sqs = client('sqs')
    url = m['messaging']['queue_url']
    deadline = time.monotonic() + 60
    empty = 0
    while time.monotonic() < deadline and empty < 2:
        msgs = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=5, WaitTimeSeconds=1,
                                  VisibilityTimeout=10).get('Messages', [])
        if not msgs:
            empty += 1
            continue
        empty = 0
        records = [{'messageId': x['MessageId'], 'receiptHandle': x['ReceiptHandle'],
                    'body': x['Body'], 'attributes': {}, 'messageAttributes': {},
                    'md5OfBody': x.get('MD5OfBody', ''), 'eventSource': 'aws:sqs',
                    'eventSourceARN': m['messaging']['queue_arn'], 'awsRegion': C['region']} for x in msgs]
        failed = {x['itemIdentifier'] for x in invoke(m, 'projector', {'Records': records}).get('batchItemFailures', [])}
        for msg in msgs:
            if msg['MessageId'] in failed:
                sqs.change_message_visibility(QueueUrl=url, ReceiptHandle=msg['ReceiptHandle'], VisibilityTimeout=0)
            else:
                sqs.delete_message(QueueUrl=url, ReceiptHandle=msg['ReceiptHandle'])


def reconcile(m):
    schedules(m, False)
    mapping(m, False)
    try:
        # Let already-started invocations finish before the reconciliation barrier.
        time.sleep(3)
        with database(m) as db:
            with db.cursor() as cur:
                cur.execute('SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL')
                pending = cur.fetchone()[0]
        for _ in range((pending + 49) // 50):
            invoke(m, 'outbox_relay', {})
        drain_queue(m)
        with database(m) as db:
            with db.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute("SET LOCAL lock_timeout='25s'")
                cur.execute('LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
                cur.execute('SELECT * FROM clearledger.events ORDER BY seq')
                events = cur.fetchall()
                cur.execute('SELECT * FROM clearledger.settlements ORDER BY settlement_id')
                settlements = cur.fetchall()
                cur.execute('SELECT * FROM clearledger.outbox ORDER BY seq')
                outbox = cur.fetchall()
                # New commits between relay tick and the barrier are published before marking delivery.
                sqs = client('sqs')
                for row in outbox:
                    if row['published_at'] is None:
                        sqs.send_message(QueueUrl=m['messaging']['queue_url'], MessageBody=canonical(row['payload']))
                        cur.execute('UPDATE clearledger.outbox SET published_at=NOW(), attempts=attempts+1, last_error=NULL WHERE seq=%s', (row['seq'],))
                drain_queue(m)
                reconcile_ddb(m, settlements, events)
                reconcile_archive(m, outbox)
                cur.execute('UPDATE clearledger.outbox SET archived_at=GREATEST(clock_timestamp(), published_at) WHERE archived_at IS NULL')
                reconcile_cache(m, settlements, events)
        print(f'Reconciled {len(settlements)} settlements and {len(events)} events.', flush=True)
    finally:
        schedules(m, True)
        mapping(m, True)


def expected_items(settlements, events):
    expected = {}
    latest = {}
    for row in events:
        p = row['payload']; d = p['data']; sid = str(row['settlement_id'])
        latest[sid] = p
        item = dict(PK='SETTLEMENT#' + sid, SK=f"EVENT#{row['aggregate_version']:08d}",
                    settlement_id=sid, event_id=str(row['event_id']), version=row['aggregate_version'],
                    event_type=row['event_type'], status=d['status'], clearing_stage=d['clearingStage'],
                    occurred_at=p['occurredAt'].replace('Z', '+00:00'), correlation_id=row['correlation_id'], envelope=canonical(p))
        for src, dst in [('entryId', 'entry_id'), ('memo', 'memo')]:
            if d.get(src) is not None:
                item[dst] = d[src]
        expected[(item['PK'], item['SK'])] = item
    for s in settlements:
        sid = str(s['settlement_id'])
        item = {k: s[k] for k in ['account_id', 'reference', 'debit_party', 'credit_party', 'version', 'entry_count', 'last_memo']}
        item.update(PK='SETTLEMENT#' + sid, SK='STATE', GSI1PK='ACCOUNT#' + s['account_id'],
                    GSI1SK='SETTLEMENT#' + sid, settlement_id=sid, status=s['current_status'],
                    clearing_stage=s['current_stage'], updated_at=latest[sid]['occurredAt'].replace('Z', '+00:00'))
        if s['last_entry_id'] is not None:
            item['last_entry_id'] = str(s['last_entry_id'])
        expected[(item['PK'], item['SK'])] = item
    return expected


def reconcile_ddb(m, settlements, events):
    c = client('dynamodb'); table = m['projections']['table_name']; ser = TypeSerializer()
    wanted = {key: {k: ser.serialize(v) for k, v in item.items()}
              for key, item in expected_items(settlements, events).items()}
    actual = {(i['PK']['S'], i['SK']['S']): i for i in pages('dynamodb', 'scan', 'Items', TableName=table, ConsistentRead=True)}
    writes = []
    for key, item in wanted.items():
        if actual.get(key) != item:
            writes.append({'PutRequest': {'Item': item}})
    for key in actual.keys() - wanted.keys():
        writes.append({'DeleteRequest': {'Key': {'PK': {'S': key[0]}, 'SK': {'S': key[1]}}}})
    for start in range(0, len(writes), 25):
        request = {table: writes[start:start + 25]}
        for retry in range(8):
            request = c.batch_write_item(RequestItems=request).get('UnprocessedItems', {})
            if not request:
                break
            time.sleep(.1 * 2 ** retry)
        if request:
            raise RuntimeError('Unprocessed DynamoDB repairs')
    actual = {(i['PK']['S'], i['SK']['S']): i for i in pages('dynamodb', 'scan', 'Items', TableName=table, ConsistentRead=True)}
    if actual != wanted:
        raise RuntimeError('DynamoDB reconciliation verification failed')


def versions(bucket):
    for page in client('s3').get_paginator('list_object_versions').paginate(Bucket=bucket):
        for kind in ['Versions', 'DeleteMarkers']:
            for v in page.get(kind, []):
                yield kind, v


def reconcile_archive(m, rows):
    s3 = client('s3'); bucket = m['audit']['bucket_name']
    wanted = {}
    # Stable bounded contiguous batches; handle BIGSERIAL gaps caused by rolled-back transactions.
    batches = []; batch = []
    for r in rows:
        if batch and (len(batch) >= 100 or r['seq'] != batch[-1]['seq'] + 1):
            batches.append(batch); batch = []
        batch.append(r)
    if batch:
        batches.append(batch)
    for batch in batches:
        body = (''.join(canonical(r['payload']) + '\n' for r in batch)).encode()
        digest = hashlib.sha256(body).hexdigest()[:16]
        key = f"ledger-audit/batch-{batch[0]['seq']:08d}-{batch[-1]['seq']:08d}-{digest}.ndjson"
        wanted[key] = body
    current = {v['Key']: v for kind, v in versions(bucket) if kind == 'Versions' and v['IsLatest']}
    for key, body in wanted.items():
        old = s3.get_object(Bucket=bucket, Key=key)['Body'].read() if key in current else None
        if old != body:
            s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType='application/x-ndjson',
                          ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
    delete = [{'Key': v['Key'], 'VersionId': v['VersionId']} for kind, v in versions(bucket)
              if kind == 'DeleteMarkers' or not v['IsLatest'] or v['Key'] not in wanted]
    for start in range(0, len(delete), 1000):
        r = s3.delete_objects(Bucket=bucket, Delete={'Objects': delete[start:start+1000], 'Quiet': True})
        if r.get('Errors'):
            raise RuntimeError('S3 version cleanup failed')
    remaining = list(versions(bucket))
    if len(remaining) != len(wanted) or any(k != 'Versions' or not v['IsLatest'] or v['Key'] not in wanted for k, v in remaining):
        raise RuntimeError('Archive version verification failed')


def reconcile_cache(m, settlements, events):
    r = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
    wanted = {}
    names = {'settlement_id': 'settlementId', 'account_id': 'accountId', 'reference': 'reference',
             'debit_party': 'debitParty', 'credit_party': 'creditParty', 'status': 'status',
             'clearing_stage': 'clearingStage', 'last_entry_id': 'lastEntryId', 'last_memo': 'lastMemo',
             'version': 'version', 'entry_count': 'entryCount', 'updated_at': 'updatedAt'}
    for item in expected_items(settlements, events).values():
        if item['SK'] == 'STATE':
            value = {dst: item.get(src) for src, dst in names.items()}
            value['updatedAt'] = value['updatedAt'].replace('+00:00', 'Z')
            wanted[('clearledger:settlement:' + item['settlement_id']).encode()] = json.dumps(value, separators=(',', ':'))
    pipeline = r.pipeline(transaction=True)
    for key in r.scan_iter():
        if key not in wanted:
            pipeline.delete(key)
    for key, value in wanted.items():
        pipeline.set(key, value, ex=90)
    pipeline.execute()
    for key, value in wanted.items():
        if r.get(key) != value.encode() or not 0 < r.ttl(key) <= 90:
            raise RuntimeError('Valkey reconciliation verification failed')


def deploy():
    print('Initializing and reconciling Terraform infrastructure.', flush=True)
    repair_roles()
    tf('init', '-input=false', '-no-color')
    tf('plan', '-input=false', '-no-color', '-out=deployment.plan')
    plan = json.loads(tf('show', '-json', 'deployment.plan', capture=True))
    for change in plan.get('resource_changes', []):
        if change['type'] in ('aws_db_instance', 'aws_dynamodb_table', 'aws_s3_bucket') and 'delete' in change['change']['actions']:
            raise RuntimeError('Refusing destructive replacement of authoritative/persistent resource ' + change['address'])
    tf('apply', '-input=false', '-no-color', 'deployment.plan')
    m = json.loads(tf('output', '-json', 'manifest', capture=True))
    # The AWS provider omits empty arrays when expanding ImageConfig updates.
    # Explicitly clear stale overrides on existing functions; their resources and
    # canonical empty image_config blocks remain owned by Terraform.
    lam = client('lambda')
    for worker in m['workers'].values():
        conf = lam.get_function_configuration(FunctionName=worker['function_name'])
        image = conf.get('ImageConfigResponse', {}).get('ImageConfig', {})
        if image.get('Command') or image.get('EntryPoint') or image.get('WorkingDirectory'):
            lam.update_function_configuration(FunctionName=worker['function_name'],
                ImageConfig={'Command': [], 'EntryPoint': [], 'WorkingDirectory': ''})
    jsonschema.validate(m, json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text()))
    tmp = ROOT / 'manifest.json.tmp'
    tmp.write_text(json.dumps(m, indent=2) + '\n')
    tmp.chmod(0o600)
    tmp.replace(ROOT / 'manifest.json')
    print('Enforcing PostgreSQL constraints, triggers, and indexes.', flush=True)
    with database(m) as db:
        with db.cursor() as cur:
            cur.execute((ROOT / 'schema.sql').read_text())
    wait_ready(m)
    reconcile(m)
    wait_ready(m)
    print('ClearLedger ready: ' + m['service_url'], flush=True)


if __name__ == '__main__':
    if sys.argv[1] == 'deploy':
        deploy()
    elif sys.argv[1] == 'destroy':
        from cleanup import destroy
        destroy()
    else:
        raise SystemExit('usage: ops.py deploy|destroy')
