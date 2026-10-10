"""Operational repair only; all canonical cloud resources are Terraform-managed."""
import datetime as dt
import hashlib
import json
import os
import signal
from pathlib import Path
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
PREFIX = C['resource_prefix']
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])

def client(service):
    return SESSION.client(service, endpoint_url=C['aws_endpoint_url'], config=Config(retries={'max_attempts': 5, 'mode': 'standard'}, connect_timeout=5, read_timeout=30))

def pages(service, op, key, **kwargs):
    api = client(service)
    if api.can_paginate(op):
        for page in api.get_paginator(op).paginate(**kwargs):
            yield from page.get(key, [])
    else:
        yield from getattr(api, op)(**kwargs).get(key, [])

def absent(exc):
    return exc.response['Error']['Code'] in ('NoSuchEntity', 'NotFoundException', 'ResourceNotFoundException', 'DBInstanceNotFound', 'NoSuchBucket', 'QueueDoesNotExist', 'AWS.SimpleQueueService.NonExistentQueue')

def manifest():
    m = json.loads((ROOT / 'manifest.json').read_text())
    if m['resource_prefix'] != PREFIX:
        raise RuntimeError('Manifest belongs to another deployment')
    return m

def connection(m):
    return psycopg2.connect(host=m['database']['endpoint'], port=m['database']['port'], dbname=C['db_name'], user=C['db_username'], password=C['db_password'], connect_timeout=5)

def preflight():
    state = ROOT / 'infra/terraform.tfstate'
    if not state.exists():
        return
    s = json.loads(state.read_text())
    kms, iam = client('kms'), client('iam')
    for r in s.get('resources', []):
        for i in r.get('instances', []):
            a = i['attributes']
            if r['type'] == 'aws_kms_key':
                try:
                    key = a['id']
                    status = kms.describe_key(KeyId=key)['KeyMetadata']['KeyState']
                    if status == 'PendingDeletion':
                        kms.cancel_key_deletion(KeyId=key)
                        status = 'Disabled'
                    if status == 'Disabled':
                        kms.enable_key(KeyId=key)
                    kms.enable_key_rotation(KeyId=key)
                    kms.tag_resource(KeyId=key, Tags=[{'TagKey': 'ClearLedgerDeployment', 'TagValue': PREFIX}, {'TagKey': 'ClearLedgerKeyUsage', 'TagValue': i['index_key']}])
                except ClientError as e:
                    if not absent(e): raise
            if r['type'] == 'aws_iam_role':
                name = a['name']
                try:
                    for policy in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
                        if policy != f'{name}-canonical':
                            iam.delete_role_policy(RoleName=name, PolicyName=policy)
                    for p in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
                        iam.detach_role_policy(RoleName=name, PolicyArn=p['PolicyArn'])
                except ClientError as e:
                    if not absent(e): raise
    for p in pages('iam', 'list_policies', 'Policies', Scope='Local', OnlyAttached=False):
        tags = {t['Key']: t['Value'] for t in pages('iam', 'list_policy_tags', 'Tags', PolicyArn=p['Arn'])}
        scoped = p['PolicyName'].startswith(PREFIX + '-') or tags.get('ClearLedgerDeployment') == PREFIX
        if scoped and not p['PolicyName'].startswith('cl-base-') and p.get('AttachmentCount', 0) == 0:
            delete_policy(p['Arn'])
    print('Control-plane preflight complete', flush=True)

def delete_policy(arn):
    iam = client('iam')
    for v in pages('iam', 'list_policy_versions', 'Versions', PolicyArn=arn):
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    iam.delete_policy(PolicyArn=arn)

def ready(m):
    until = time.monotonic() + 150
    while time.monotonic() < until:
        try:
            with urllib.request.urlopen(m['service_url'] + '/health/ready', timeout=5) as r:
                if r.status == 200:
                    print('API readiness: 200', flush=True)
                    return
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError('API readiness did not reach 200')

def schema(m):
    env = dict(os.environ, PGHOST=m['database']['endpoint'], PGPORT=str(m['database']['port']), PGDATABASE=C['db_name'], PGUSER=C['db_username'], PGPASSWORD=C['db_password'], PGCONNECT_TIMEOUT='5')
    subprocess.run(['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-f', str(ROOT / 'schema.sql')], env=env, check=True, stdout=subprocess.DEVNULL)
    print('PostgreSQL schema, constraints, triggers and indexes ready', flush=True)

def control(m):
    # The local control plane can retain EC2's default egress rule on initial creation.
    # Revoke extras using the exact returned permission shape, including absent ports.
    ec2 = client('ec2')
    groups = ec2.describe_security_groups(GroupIds=list(m['network']['security_group_ids'].values()))['SecurityGroups']
    ids = m['network']['security_group_ids']
    cidr = ec2.describe_vpcs(VpcIds=[m['network']['vpc_id']])['Vpcs'][0]['CidrBlock']
    for group in groups:
        kind = next(k for k, v in ids.items() if v == group['GroupId'])
        for direction, field in [('ingress', 'IpPermissions'), ('egress', 'IpPermissionsEgress')]:
            for rule in group[field]:
                port = {'alb': 80, 'ecs': 8080, 'rds': 5432, 'valkey': 6379}[kind]
                ranges = [r['CidrIp'] for r in rule.get('IpRanges', [])]
                peers = [r['GroupId'] for r in rule.get('UserIdGroupPairs', [])]
                if direction == 'ingress':
                    valid = rule['IpProtocol']=='tcp' and rule.get('FromPort')==port and rule.get('ToPort')==port
                    valid &= (peers == [ids['alb']] and not ranges) if kind=='ecs' else (ranges == ['0.0.0.0/0' if kind=='alb' else cidr] and not peers)
                else:
                    valid = kind == 'ecs' or (kind=='alb' and rule['IpProtocol']=='tcp' and rule.get('FromPort')==8080 and rule.get('ToPort')==8080 and ranges==[cidr] and not peers)
                valid &= not rule.get('Ipv6Ranges') and not rule.get('PrefixListIds')
                if not valid:
                    getattr(ec2, 'revoke_security_group_'+direction)(GroupId=group['GroupId'], IpPermissions=[rule])

def workers(m, enabled):
    lam, sched = client('lambda'), client('scheduler')
    lam.update_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'], Enabled=enabled)
    for field in ('outbox_schedule_name', 'archive_schedule_name'):
        name = m['schedules'][field]
        old = sched.get_schedule(Name=name)
        args = {k: old[k] for k in ('Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone', 'StartDate', 'EndDate', 'Description', 'FlexibleTimeWindow', 'Target', 'KmsKeyArn', 'ActionAfterCompletion') if k in old}
        args['State'] = 'ENABLED' if enabled else 'DISABLED'
        sched.update_schedule(**args)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        status = lam.get_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])['State']
        if status.lower() == ('enabled' if enabled else 'disabled'):
            return
        time.sleep(1)
    raise RuntimeError('Event source mapping failed to settle')

def invoke(name, payload):
    r = client('lambda').invoke(FunctionName=name, InvocationType='RequestResponse', Payload=json.dumps(payload).encode())
    body = json.loads(r['Payload'].read() or b'{}')
    if r.get('FunctionError'):
        raise RuntimeError(f'Worker {name} invocation failed: {body}')
    return body

def drain(m):
    sqs = client('sqs')
    queue = m['messaging']['queue_url']
    empty = 0
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline and empty < 3:
        messages = sqs.receive_message(QueueUrl=queue, MaxNumberOfMessages=5, WaitTimeSeconds=1, VisibilityTimeout=15, MessageSystemAttributeNames=['ApproximateReceiveCount']).get('Messages', [])
        if not messages:
            empty += 1
            time.sleep(1)
            continue
        empty = 0
        result = invoke(m['workers']['projector']['function_name'], {'Records': [{'messageId': v['MessageId'], 'body': v['Body'], 'eventSource': 'aws:sqs', 'eventSourceARN': m['messaging']['queue_arn'], 'awsRegion': C['region']} for v in messages]})
        failed = {x['itemIdentifier'] for x in result.get('batchItemFailures', [])}
        for msg in messages:
            if msg['MessageId'] in failed:
                if int(msg.get('Attributes', {}).get('ApproximateReceiveCount', '1')) < 4:
                    sqs.change_message_visibility(QueueUrl=queue, ReceiptHandle=msg['ReceiptHandle'], VisibilityTimeout=0)
                    continue
                # Preserve failed envelopes after the canonical four delivery attempts.
                sqs.send_message(QueueUrl=m['messaging']['dlq_url'], MessageBody=msg['Body'])
            sqs.delete_message(QueueUrl=queue, ReceiptHandle=msg['ReceiptHandle'])
    if empty < 3:
        raise RuntimeError('SQS did not drain before recovery deadline')

def scan_table(m):
    return list(pages('dynamodb', 'scan', 'Items', TableName=m['projections']['table_name'], ConsistentRead=True))

def encoded(item):
    ser = TypeSerializer()
    return {k: ser.serialize(v) for k, v in item.items() if v is not None}

def canonical_items(rows):
    expected = {}
    states = {}
    for row in rows:
        p = row['payload']; d = p['data']; sid = p['aggregateId']; v = p['aggregateVersion']
        pk = 'SETTLEMENT#' + sid
        timestamp = dt.datetime.fromisoformat(p['occurredAt'].replace('Z', '+00:00')).isoformat()
        event = dict(PK=pk, SK=f'EVENT#{v:08d}', settlement_id=sid, event_id=p['eventId'], version=v, event_type=p['eventType'], status=d['status'], clearing_stage=d['clearingStage'], occurred_at=timestamp, correlation_id=p['correlationId'], envelope=json.dumps(p, separators=(',', ':'), ensure_ascii=False))
        for dest, src in [('entry_id', 'entryId'), ('memo', 'memo')]:
            if d.get(src) is not None: event[dest] = d[src]
        expected[(pk, event['SK'])] = encoded(event)
        state = dict(PK=pk, SK='STATE', GSI1PK='ACCOUNT#'+d['accountId'], GSI1SK=pk, settlement_id=sid, account_id=d['accountId'], reference=d['reference'], debit_party=d['debitParty'], credit_party=d['creditParty'], status=d['status'], clearing_stage=d['clearingStage'], version=v, entry_count=v-1, updated_at=timestamp, last_entry_id=d.get('entryId'), last_memo=d.get('memo'))
        expected[(pk, 'STATE')] = encoded(state)
        states[sid] = dict(settlementId=sid, accountId=d['accountId'], reference=d['reference'], debitParty=d['debitParty'], creditParty=d['creditParty'], status=d['status'], clearingStage=d['clearingStage'], version=v, entryCount=v-1, updatedAt=p['occurredAt'], lastEntryId=d.get('entryId'), lastMemo=d.get('memo'))
    return expected, states

def reconcile_ddb(m, expected):
    ddb = client('dynamodb'); table = m['projections']['table_name']
    actual = {(i['PK']['S'], i['SK']['S']): i for i in scan_table(m)}
    for key, item in expected.items():
        if actual.get(key) != item:
            ddb.put_item(TableName=table, Item=item)
    for key, item in actual.items():
        if key not in expected:
            ddb.delete_item(TableName=table, Key={k: item[k] for k in ('PK', 'SK')})
    final = {(i['PK']['S'], i['SK']['S']): i for i in scan_table(m)}
    if final != expected: raise RuntimeError('DynamoDB reconciliation verification failed')

def versions(bucket):
    s3 = client('s3')
    for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
        yield from [('version', v) for v in page.get('Versions', [])]
        yield from [('marker', v) for v in page.get('DeleteMarkers', [])]

def reconcile_s3(m, rows):
    s3 = client('s3'); bucket = m['audit']['bucket_name']; expected = {}
    batches = []
    for row in rows:
        if not batches or len(batches[-1]) >= 100 or row['seq'] != batches[-1][-1]['seq'] + 1:
            batches.append([])
        batches[-1].append(row)
    for batch in batches:
        raw = ''.join(json.dumps(r['payload'], sort_keys=True, ensure_ascii=False, separators=(',', ':'))+'\n' for r in batch).encode()
        key = f"ledger-audit/batch-{batch[0]['seq']:08d}-{batch[-1]['seq']:08d}-{hashlib.sha256(raw).hexdigest()[:16]}.ndjson"
        expected[key] = raw
    current = {v['Key']: v for kind, v in versions(bucket) if kind == 'version' and v['IsLatest']}
    for key, body in expected.items():
        valid = key in current and s3.get_object(Bucket=bucket, Key=key)['Body'].read() == body
        if not valid:
            s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType='application/x-ndjson', ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
    for kind, v in list(versions(bucket)):
        if kind == 'marker' or not v['IsLatest'] or v['Key'] not in expected:
            s3.delete_object(Bucket=bucket, Key=v['Key'], VersionId=v['VersionId'])
    remaining = list(versions(bucket))
    if len(remaining) != len(expected) or any(k != 'version' or not v['IsLatest'] or v['Key'] not in expected for k, v in remaining):
        raise RuntimeError('Audit version reconciliation verification failed')
    for key, body in expected.items():
        if s3.get_object(Bucket=bucket, Key=key)['Body'].read() != body:
            raise RuntimeError('Audit bytes verification failed')

def reconcile(m):
    try:
        workers(m, False)
        # Existing invocations have a three-second timeout. Stop mutation sources before snapshotting.
        time.sleep(4)
        with connection(m) as db:
            with db.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute("SET LOCAL lock_timeout='30s'")
                cur.execute('LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
                cur.execute('SELECT seq,payload FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq')
                for row in cur.fetchall():
                    client('sqs').send_message(QueueUrl=m['messaging']['queue_url'], MessageBody=json.dumps(row['payload']))
                    cur.execute('UPDATE clearledger.outbox SET published_at=clock_timestamp(), attempts=attempts+1,last_error=NULL WHERE seq=%s', (row['seq'],))
                drain(m)
                cur.execute('SELECT payload FROM clearledger.events ORDER BY settlement_id,aggregate_version')
                expected, states = canonical_items(cur.fetchall())
                reconcile_ddb(m, expected)
                cur.execute('SELECT seq,payload FROM clearledger.outbox ORDER BY seq')
                rows = cur.fetchall()
                reconcile_s3(m, rows)
                cur.execute('UPDATE clearledger.outbox SET archived_at=clock_timestamp() WHERE archived_at IS NULL')
                cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
                expected_keys = {'clearledger:settlement:'+sid for sid in states}
                for key in cache.scan_iter(count=500):
                    if key.decode() not in expected_keys: cache.delete(key)
                pipe = cache.pipeline()
                for sid, projection in states.items():
                    pipe.set('clearledger:settlement:'+sid, json.dumps(projection, separators=(',', ':')), ex=90)
                pipe.execute()
                for sid, projection in states.items():
                    key = 'clearledger:settlement:'+sid
                    if json.loads(cache.get(key)) != projection or not 0 < cache.ttl(key) <= 90:
                        raise RuntimeError('Cache reconciliation verification failed')
                cur.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL')
                if cur.fetchone()['n']: raise RuntimeError('Outbox remains incomplete')
        print(f'Reconciled {len(states)} settlements, {len(rows)} events, cache, and versioned audit archive', flush=True)
    finally:
        workers(m, True)

if __name__ == '__main__':
    def interrupted(signum, frame):
        raise InterruptedError('Lifecycle operation interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    action = sys.argv[1]
    if action == 'preflight': preflight()
    elif action == 'manifest':
        path = ROOT / 'manifest.json.tmp'
        jsonschema.validate(json.loads(path.read_text()), json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text()))
        path.replace(ROOT / 'manifest.json')
    elif action == 'empty-state':
        state = json.loads((ROOT / 'infra/terraform.tfstate').read_text())
        assert not [r for r in state.get('resources', []) if r['mode']=='managed'], 'Managed resources remain in state'
        print('Teardown complete; state has zero managed resources')
    else:
        {'schema': schema, 'ready': ready, 'reconcile': reconcile, 'control': control}[action](manifest())
