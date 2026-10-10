#!/usr/bin/env python3
"""Lifecycle repairs and derived-data maintenance; resource creation is Terraform-only."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import jsonschema
import psycopg2
from psycopg2.extras import RealDictCursor
import redis
import requests

ROOT = Path(__file__).resolve().parent
C = json.loads(Path('/workspace/config/config.json').read_text())
P = C['resource_prefix']
if P.startswith('cl-base-') or len(P) < 4:
    raise RuntimeError('Deployment prefix must be distinct from the baseline')
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])
CLIENTS = {}
DEADLINE = time.monotonic() + 540


def client(service):
    if service not in CLIENTS:
        CLIENTS[service] = SESSION.client(service, endpoint_url=C['aws_endpoint_url'],
            config=Config(connect_timeout=5, read_timeout=25, retries={'max_attempts': 4},
                          s3={'addressing_style': 'path'}))
    return CLIENTS[service]


def check_time():
    if time.monotonic() > DEADLINE:
        raise TimeoutError('Lifecycle reconciliation deadline exceeded')


def pages(service, operation, result, **kwargs):
    api = client(service)
    if api.can_paginate(operation):
        for page in api.get_paginator(operation).paginate(**kwargs):
            yield from page.get(result, [])
    else:
        yield from getattr(api, operation)(**kwargs).get(result, [])


def attempt(service, operation, **kwargs):
    try:
        return getattr(client(service), operation)(**kwargs)
    except ClientError as exc:
        code = exc.response['Error']['Code']
        if code in {'ResourceNotFoundException', 'ResourceNotFound', 'NoSuchEntity',
                    'NoSuchBucket', 'NotFound', 'DBInstanceNotFound', 'DBSubnetGroupNotFoundFault',
                    'CacheClusterNotFound', 'ReplicationGroupNotFoundFault',
                    'AWS.SimpleQueueService.NonExistentQueue', 'InvalidGroup.NotFound',
                    'InvalidVpcID.NotFound', 'InvalidSubnetID.NotFound', 'InvalidRouteTableID.NotFound',
                    'InvalidNetworkAclID.NotFound',
                    'LoadBalancerNotFound', 'TargetGroupNotFound', 'ResourceNotFoundFault'}:
            return None
        raise


def state():
    path = ROOT / 'infra/terraform.tfstate'
    return json.loads(path.read_text()) if path.exists() else {'resources': []}


def attrs(kind):
    return [i['attributes'] for r in state().get('resources', []) if r.get('type') == kind
            for i in r.get('instances', [])]


def scoped(name='', tags=None):
    tags = tags or {}
    if isinstance(tags, list):
        tags = {t.get('Key', t.get('key')): t.get('Value', t.get('value')) for t in tags}
    # Baseline exclusion takes precedence, even when tags are accidentally copied.
    if 'cl-base-' in name or any(str(v).startswith('cl-base-') for v in tags.values()):
        return False
    return any(part.startswith(P + '-') for part in name.split('/')) or name.startswith('alias/' + P + '-') or (
        '/clearledger/' + P + '/' in name) or tags.get('ClearLedgerDeployment') == P


def owned(kind, identity, all_resources):
    if all_resources:
        return True
    return not any(identity in (a.get('id'), a.get('arn'), a.get('name'), a.get('identifier'),
        a.get('function_name'), a.get('bucket'), a.get('replication_group_id')) for a in attrs(kind))


def preflight():
    # Recover key cancellation/enablement before the provider reads a pending key.
    for a in attrs('aws_kms_key'):
        key = attempt('kms', 'describe_key', KeyId=a['id'])
        if not key:
            continue
        status = key['KeyMetadata']['KeyState']
        if status == 'PendingDeletion':
            client('kms').cancel_key_deletion(KeyId=a['id'])
            status = 'Disabled'
        if status == 'Disabled':
            client('kms').enable_key(KeyId=a['id'])
    # Terraform inline policy resources are not exclusive owners of the role.
    for role in attrs('aws_iam_role'):
        name = role['name']
        current = attempt('iam', 'get_role', RoleName=name)
        if not current:
            continue
        canonical = name + '-canonical'
        for policy in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
            if policy != canonical:
                client('iam').delete_role_policy(RoleName=name, PolicyName=policy)
        for policy in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            client('iam').detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])
        if current['Role'].get('PermissionsBoundary'):
            attempt('iam', 'delete_role_permissions_boundary', RoleName=name)
    # Remove untracked deployment-local policies after detaching from roles.
    cleanup_policies(False)


def adopt_keys():
    # AWS retains scheduled-for-deletion keys. Reuse the canonical key after a
    # teardown/redeploy (or lost state) rather than accumulate duplicate CMKs.
    tracked = {a['id'] for a in attrs('aws_kms_key')}
    tracked_usage = {a.get('tags', {}).get('ClearLedgerKeyUsage') for a in attrs('aws_kms_key')}
    for key in pages('kms', 'list_keys', 'Keys'):
        if key['KeyId'] in tracked:
            continue
        meta = client('kms').describe_key(KeyId=key['KeyId'])['KeyMetadata']
        for usage in ['database', 'messaging', 'projection', 'audit']:
            if usage in tracked_usage or meta.get('Description') != P + '-' + usage:
                continue
            tags = {t['TagKey']: t['TagValue'] for t in client('kms').list_resource_tags(KeyId=key['KeyId']).get('Tags', [])}
            if tags.get('ClearLedgerDeployment') != P:
                continue
            status = meta['KeyState']
            if status == 'PendingDeletion':
                client('kms').cancel_key_deletion(KeyId=key['KeyId']); status = 'Disabled'
            if status == 'Disabled':
                client('kms').enable_key(KeyId=key['KeyId'])
            subprocess.run(['terraform', '-chdir=' + str(ROOT / 'infra'), 'import', '-input=false', '-no-color',
                            f'aws_kms_key.store["{usage}"]', key['KeyId']], check=True)
            tracked_usage.add(usage)


def protect():
    plan = json.loads(subprocess.check_output(['terraform', '-chdir=' + str(ROOT / 'infra'),
                                             'show', '-json', str(ROOT / 'infra/deploy.tfplan')]))
    for change in plan.get('resource_changes', []):
        if change['type'] in {'aws_db_instance', 'aws_dynamodb_table', 'aws_s3_bucket'}:
            if 'delete' in change['change']['actions']:
                raise RuntimeError('Refusing replacement of authoritative or durable resource: ' + change['address'])


def manifest():
    m = json.loads((ROOT / 'manifest.json.tmp').read_text())
    jsonschema.validate(m, json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text()))


def connection(m):
    d = m['database']
    while True:
        check_time()
        try:
            return psycopg2.connect(host=d['endpoint'], port=d['port'], dbname=d['db_name'],
                                   user=d['username'], password=C['db_password'], connect_timeout=5)
        except psycopg2.OperationalError:
            time.sleep(2)


def invoke(name, payload=None):
    check_time()
    result = client('lambda').invoke(FunctionName=name, InvocationType='RequestResponse',
                                    Payload=json.dumps(payload or {}).encode())
    body = result['Payload'].read()
    if result.get('FunctionError'):
        raise RuntimeError('Worker invocation failed: ' + name)
    obj = json.loads(body) if body else {}
    if obj.get('batchItemFailures'):
        raise RuntimeError('Worker rejected committed event during recovery')
    return obj


def scheduler_state(name, enabled, group='default'):
    s = client('scheduler').get_schedule(Name=name, GroupName=group)
    args = {k: s[k] for k in ['Name', 'GroupName', 'ScheduleExpression', 'FlexibleTimeWindow', 'Target',
        'ScheduleExpressionTimezone', 'StartDate', 'EndDate', 'Description', 'KmsKeyArn', 'ActionAfterCompletion'] if k in s}
    args['State'] = 'ENABLED' if enabled else 'DISABLED'
    client('scheduler').update_schedule(**args)


def sources(m, enabled):
    client('lambda').update_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'], Enabled=enabled)
    for key in ['outbox_schedule_name', 'archive_schedule_name']:
        scheduler_state(m['schedules'][key], enabled)
    while True:
        check_time()
        es = client('lambda').get_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
        if es['State'] == ('Enabled' if enabled else 'Disabled'):
            break
        time.sleep(1)


def timestamp(value, z=False):
    if isinstance(value, str):
        match = re.fullmatch(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)', value)
        if not match:
            raise ValueError('Non-RFC3339 event timestamp')
        nanos = int((match[2] or '').ljust(9, '0'))
        value = dt.datetime.fromisoformat(match[1] + match[3].replace('Z', '+00:00'))
    else:
        nanos = value.microsecond * 1000
    value = value.astimezone(dt.timezone.utc)
    digits = 0 if nanos == 0 else (3 if nanos % 1000000 == 0 else (6 if nanos % 1000 == 0 else 9))
    fraction = ('.' + f'{nanos:09d}'[:digits]) if digits else ''
    return value.strftime('%Y-%m-%dT%H:%M:%S') + fraction + ('Z' if z else '+00:00')


def canonical(p):
    # Canonical serde struct/enum ordering verified against the immutable images.
    envelope = {k: p[k] for k in ['schemaVersion', 'eventId', 'eventType', 'aggregateType', 'aggregateId',
                                  'aggregateVersion', 'occurredAt', 'correlationId', 'idempotencyKey']}
    envelope['occurredAt'] = timestamp(envelope['occurredAt'], True)
    for k in ['eventId', 'aggregateId']:
        envelope[k] = str(uuid.UUID(envelope[k]))
    d = p['data']
    envelope['data'] = {k: d[k] for k in ['kind', 'accountId', 'reference', 'debitParty', 'creditParty',
                                         'entryId', 'status', 'clearingStage', 'memo'] if d.get(k) is not None}
    if envelope['data'].get('entryId'):
        envelope['data']['entryId'] = str(uuid.UUID(envelope['data']['entryId']))
    return json.dumps(envelope, ensure_ascii=False, separators=(',', ':'))


def scan_table(table):
    result = []
    kwargs = {'TableName': table, 'ConsistentRead': True}
    while True:
        page = client('dynamodb').scan(**kwargs)
        result.extend(page.get('Items', []))
        if not page.get('LastEvaluatedKey'):
            return result
        kwargs['ExclusiveStartKey'] = page['LastEvaluatedKey']


def expected_items(settlements, events):
    items = {}
    event_times = {(str(e['settlement_id']), e['aggregate_version']): e['payload']['occurredAt'] for e in events}
    for e in events:
        p = e['payload']; d = p['data']; sid = str(e['settlement_id']); v = e['aggregate_version']
        raw = {'PK': 'SETTLEMENT#' + sid, 'SK': f'EVENT#{v:08d}', 'settlement_id': sid,
               'event_id': str(e['event_id']), 'version': v, 'event_type': e['event_type'],
               'status': d['status'], 'clearing_stage': d['clearingStage'],
               'occurred_at': timestamp(p['occurredAt']), 'correlation_id': e['correlation_id'],
               'envelope': canonical(p)}
        for k in ['entryId', 'memo']:
            if d.get(k) is not None:
                raw['entry_id' if k == 'entryId' else 'memo'] = d[k]
        items[(raw['PK'], raw['SK'])] = encode_item(raw)
    for s in settlements:
        sid = str(s['settlement_id'])
        raw = {'PK': 'SETTLEMENT#' + sid, 'SK': 'STATE', 'settlement_id': sid,
               'account_id': s['account_id'], 'reference': s['reference'], 'debit_party': s['debit_party'],
               'credit_party': s['credit_party'], 'status': s['current_status'], 'clearing_stage': s['current_stage'],
               'version': s['version'], 'entry_count': s['entry_count'], 'updated_at': timestamp(event_times[(sid, s['version'])]),
               'last_memo': s['last_memo'], 'GSI1PK': 'ACCOUNT#' + s['account_id'], 'GSI1SK': 'SETTLEMENT#' + sid}
        if s['last_entry_id']:
            raw['last_entry_id'] = str(s['last_entry_id'])
        items[(raw['PK'], raw['SK'])] = encode_item(raw)
    return items


def encode_item(raw):
    return {k: {'N': str(v)} if isinstance(v, int) else {'S': v} for k, v in raw.items()}


def item_key(i):
    return i['PK']['S'], i['SK']['S']


def repair_projections(m, settlements, events):
    table = m['projections']['table_name']
    expected = expected_items(settlements, events)
    current = {item_key(i): i for i in scan_table(table)}
    dirty = {k[0] for k in set(current) | set(expected) if current.get(k) != expected.get(k)}
    # Rewrite only divergent partitions; healthy projections remain continuously readable.
    for k, item in current.items():
        if k[0] in dirty:
            client('dynamodb').delete_item(TableName=table, Key={x: item[x] for x in ['PK', 'SK']})
    batch = []
    for e in events:
        if 'SETTLEMENT#' + str(e['settlement_id']) in dirty:
            batch.append({'messageId': str(e['event_id']), 'body': canonical(e['payload']),
                          'eventSource': 'aws:sqs', 'eventSourceARN': m['messaging']['queue_arn'],
                          'awsRegion': C['region'], 'attributes': {}, 'messageAttributes': {}})
            if len(batch) == 5:
                invoke(m['workers']['projector']['function_name'], {'Records': batch}); batch = []
    if batch:
        invoke(m['workers']['projector']['function_name'], {'Records': batch})
    actual = {item_key(i): i for i in scan_table(table)}
    if actual != expected:
        raise RuntimeError('Projection verification failed after canonical replay')
    print(f'Projection convergence: {len(settlements)} states, {len(events)} ledger events')


def drain_queue(m, authoritative):
    sqs = client('sqs'); queue = m['messaging']['queue_url']; empty = 0
    while empty < 3:
        check_time()
        msgs = sqs.receive_message(QueueUrl=queue, MaxNumberOfMessages=10, WaitTimeSeconds=1,
                                  VisibilityTimeout=5).get('Messages', [])
        empty = 0 if msgs else empty + 1
        for msg in msgs:
            try:
                p = json.loads(msg['Body'])
                valid = p.get('eventId') in authoritative and p == authoritative[p['eventId']]
            except (ValueError, TypeError, AttributeError, KeyError):
                valid = False
            if not valid:
                # Quarantine rather than letting divergent/orphan events re-contaminate projections.
                sqs.send_message(QueueUrl=m['messaging']['dlq_url'], MessageBody=msg['Body'])
            sqs.delete_message(QueueUrl=queue, ReceiptHandle=msg['ReceiptHandle'])


def versions(bucket):
    for page in client('s3').get_paginator('list_object_versions').paginate(Bucket=bucket):
        for kind in ['Versions', 'DeleteMarkers']:
            for v in page.get(kind, []):
                yield kind, v


def delete_versions(bucket, objects):
    for offset in range(0, len(objects), 1000):
        response = client('s3').delete_objects(Bucket=bucket, Delete={'Objects': objects[offset:offset+1000], 'Quiet': True})
        if response.get('Errors'):
            raise RuntimeError('Failed to remove audit object versions')


def repair_archive(m, cur, outbox):
    bucket = m['audit']['bucket_name']
    by_seq = {o['seq']: o for o in outbox}
    covered = set(); removals = []
    # Sorting intervals yields a deterministic winner if overlapping copies were injected.
    all_versions = sorted(list(versions(bucket)), key=lambda kv: (kv[1]['Key'], kv[1]['VersionId']))
    for kind, v in all_versions:
        check_time()
        key = v['Key']; valid = False
        match = re.fullmatch(r'ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson', key)
        if kind == 'Versions' and v['IsLatest'] and match:
            lo, hi = int(match[1]), int(match[2]); seqs = list(range(lo, hi + 1)) if 0 <= hi-lo < 100000 else []
            if seqs and all(s in by_seq and s not in covered for s in seqs):
                body = client('s3').get_object(Bucket=bucket, Key=key, VersionId=v['VersionId'])['Body'].read()
                expected = ''.join(canonical(by_seq[s]['payload']) + '\n' for s in seqs).encode()
                valid = body == expected and hashlib.sha256(body).hexdigest()[:16] == match[3]
                if valid:
                    covered.update(seqs)
        if not valid:
            removals.append({'Key': key, 'VersionId': v['VersionId']})
    delete_versions(bucket, removals)
    missing = sorted(set(by_seq) - covered)
    groups = []
    for seq in missing:
        if not groups or len(groups[-1]) >= 100 or seq != groups[-1][-1]+1:
            groups.append([])
        groups[-1].append(seq)
    for seqs in groups:
        check_time()
        body = ''.join(canonical(by_seq[s]['payload']) + '\n' for s in seqs).encode()
        digest = hashlib.sha256(body).hexdigest()[:16]
        key = f'ledger-audit/batch-{seqs[0]:08d}-{seqs[-1]:08d}-{digest}.ndjson'
        client('s3').put_object(Bucket=bucket, Key=key, Body=body, ContentType='application/x-ndjson',
                               ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
        covered.update(seqs)
    cur.execute('UPDATE clearledger.outbox SET archived_at=GREATEST(clock_timestamp(),published_at) WHERE archived_at IS NULL')
    leftovers = [{'Key': v['Key'], 'VersionId': v['VersionId']} for kind, v in versions(bucket)
                 if kind == 'DeleteMarkers' or not v['IsLatest']]
    delete_versions(bucket, leftovers)
    if covered != set(by_seq):
        raise RuntimeError('Archive coverage verification failed')
    print(f'Audit convergence: {len(covered)} events, {len(removals)} invalid/noncurrent versions removed')


def ready(m):
    while True:
        check_time()
        try:
            r = requests.get(m['service_url'] + '/health/ready', timeout=5)
            if r.status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(2)


def repair_cache(m, settlements):
    cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
    for k in cache.scan_iter(count=500):
        cache.delete(k)
    c = m['auth']['clients']['read']
    r = requests.post(m['auth']['token_endpoint'], data={'grant_type': 'client_credentials',
        'client_id': c['client_id'], 'client_secret': c['client_secret'], 'scope': c['scope']}, timeout=10)
    r.raise_for_status(); token = r.json()['access_token']
    payloads = {}
    for s in settlements:
        check_time(); sid = str(s['settlement_id'])
        while True:
            check_time()
            r = requests.get(m['service_url'] + '/v1/settlements/' + sid,
                             headers={'Authorization': 'Bearer ' + token, 'X-Correlation-Id': 'deploy-convergence'}, timeout=10)
            if r.status_code not in {401, 502, 503}:
                break
            time.sleep(1)
        r.raise_for_status(); p = r.json()
        if p['version'] != s['version'] or p['lastMemo'] != s['last_memo']:
            raise RuntimeError('API/cache payload does not match authoritative settlement')
        payloads['clearledger:settlement:' + sid] = json.dumps(p, ensure_ascii=False, separators=(',', ':'))
    # Refresh every key at the same final point, including large deployments (>90s).
    with cache.pipeline(transaction=True) as pipe:
        for k, value in payloads.items():
            pipe.set(k, value, ex=90)
        pipe.execute()
    actual = {k.decode() for k in cache.scan_iter(count=500)}
    if actual != set(payloads) or any(not 0 < cache.ttl(k) <= 90 for k in actual):
        raise RuntimeError('Valkey namespace/TTL verification failed')
    print(f'Cache convergence: {len(payloads)} populated settlement keys with 90-second TTL')


def converge():
    m = json.loads((ROOT / 'manifest.json').read_text())
    conn = connection(m)
    with conn.cursor() as cur:
        cur.execute((ROOT / 'schema.sql').read_text())
    conn.commit()
    ready(m)
    # Run immutable workers once to drain ordinary committed work and emit operational logs.
    invoke(m['workers']['outbox_relay']['function_name'])
    invoke(m['workers']['audit_archiver']['function_name'])
    try:
        sources(m, False)
        # Lambda timeout and SQS visibility are both 3 seconds: wait out in-flight consumers.
        time.sleep(4)
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SET LOCAL lock_timeout='30s'; SET LOCAL statement_timeout='480s'")
            cur.execute('SELECT pg_advisory_xact_lock(734291008)')
            # Short write fence keeps reads/live traffic available and prevents a torn repair snapshot.
            cur.execute('LOCK TABLE clearledger.settlements,clearledger.events,clearledger.outbox IN SHARE ROW EXCLUSIVE MODE')
            cur.execute('SELECT * FROM clearledger.settlements ORDER BY settlement_id'); settlements = cur.fetchall()
            cur.execute('SELECT * FROM clearledger.events ORDER BY seq'); events = cur.fetchall()
            cur.execute('SELECT * FROM clearledger.outbox ORDER BY seq'); outbox = cur.fetchall()
            for o in outbox:
                if o['published_at'] is None:
                    client('sqs').send_message(QueueUrl=m['messaging']['queue_url'], MessageBody=canonical(o['payload']))
                    cur.execute('UPDATE clearledger.outbox SET published_at=GREATEST(clock_timestamp(),created_at), attempts=attempts+1,last_error=NULL WHERE seq=%s', (o['seq'],))
            drain_queue(m, {str(e['event_id']): e['payload'] for e in events})
            repair_projections(m, settlements, events)
            repair_archive(m, cur, outbox)
            repair_cache(m, settlements)
            cur.execute('SELECT count(*) AS pending FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL')
            if cur.fetchone()['pending']:
                raise RuntimeError('Outbox convergence incomplete')
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        sources(m, True)
        conn.close()
    ready(m)
    print('ClearLedger deployment ready; schema and derived stores verified')


def cleanup_policies(all_resources):
    iam = client('iam')
    for p in pages('iam', 'list_policies', 'Policies', Scope='Local'):
        tags = iam.list_policy_tags(PolicyArn=p['Arn']).get('Tags', [])
        if scoped(p['PolicyName'], tags) and owned('aws_iam_policy', p['Arn'], all_resources):
            entities = iam.list_entities_for_policy(PolicyArn=p['Arn'])
            for r in entities.get('PolicyRoles', []):
                iam.detach_role_policy(RoleName=r['RoleName'], PolicyArn=p['Arn'])
            for u in entities.get('PolicyUsers', []):
                iam.detach_user_policy(UserName=u['UserName'], PolicyArn=p['Arn'])
            for g in entities.get('PolicyGroups', []):
                iam.detach_group_policy(GroupName=g['GroupName'], PolicyArn=p['Arn'])
            for v in iam.list_policy_versions(PolicyArn=p['Arn']).get('Versions', []):
                if not v['IsDefaultVersion']:
                    iam.delete_policy_version(PolicyArn=p['Arn'], VersionId=v['VersionId'])
            iam.delete_policy(PolicyArn=p['Arn'])


def quiesce():
    # Teardown may delete managed resources imperatively. Stop producers first,
    # then remove mappings/queues before Terraform refresh to avoid its long SQS
    # eventual-consistency deletion waiter in the local control plane.
    record_vpcs({v['VpcId'] for v in client('ec2').describe_vpcs()['Vpcs'] if scoped('', v.get('Tags'))})
    for s in pages('scheduler', 'list_schedules', 'Schedules'):
        if scoped(s['Name']):
            scheduler_state(s['Name'], False, s.get('GroupName', 'default'))
    for f in pages('lambda', 'list_functions', 'Functions'):
        tags = client('lambda').list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if scoped(f['FunctionName'], tags):
            for e in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                attempt('lambda', 'delete_event_source_mapping', UUID=e['UUID'])
    time.sleep(4)
    for url in pages('sqs', 'list_queues', 'QueueUrls'):
        tags = client('sqs').list_queue_tags(QueueUrl=url).get('Tags', {})
        if scoped(url.rsplit('/', 1)[-1], tags):
            attempt('sqs', 'delete_queue', QueueUrl=url)


def cleanup(all_resources):
    """Dependency-ordered prefix/tag-scoped sweep. No cloud resource is created here."""
    preflight()
    # Schedules and mappings first: prevent recreation of queues/objects while destroying.
    for s in pages('scheduler', 'list_schedules', 'Schedules'):
        if scoped(s['Name']) and owned('aws_scheduler_schedule', s['Name'], all_resources):
            attempt('scheduler', 'delete_schedule', Name=s['Name'], GroupName=s.get('GroupName', 'default'))
    for g in pages('scheduler', 'list_schedule_groups', 'ScheduleGroups'):
        if g['Name'] == 'default':
            continue
        tags = client('scheduler').list_tags_for_resource(ResourceArn=g['Arn']).get('Tags', [])
        if scoped(g['Name'], tags):
            attempt('scheduler', 'delete_schedule_group', Name=g['Name'])
    lamb = client('lambda')
    functions = list(pages('lambda', 'list_functions', 'Functions'))
    for f in functions:
        tags = lamb.list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if not scoped(f['FunctionName'], tags):
            continue
        if owned('aws_lambda_function', f['FunctionName'], all_resources):
            for e in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                attempt('lambda', 'delete_event_source_mapping', UUID=e['UUID'])
            attempt('lambda', 'delete_function', FunctionName=f['FunctionName'])
        else:
            for e in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                if owned('aws_lambda_event_source_mapping', e['UUID'], all_resources):
                    attempt('lambda', 'delete_event_source_mapping', UUID=e['UUID'])
    # ECS task revisions are retained after deregistration and need explicit deletion.
    ecs = client('ecs')
    for arn in pages('ecs', 'list_clusters', 'clusterArns'):
        desc = ecs.describe_clusters(clusters=[arn], include=['TAGS']).get('clusters', [])
        if not desc or not scoped(desc[0]['clusterName'], desc[0].get('tags')):
            continue
        cluster = desc[0]
        for service in pages('ecs', 'list_services', 'serviceArns', cluster=arn):
            if owned('aws_ecs_service', service, all_resources):
                attempt('ecs', 'delete_service', cluster=arn, service=service, force=True)
        if owned('aws_ecs_cluster', arn, all_resources):
            for task in pages('ecs', 'list_tasks', 'taskArns', cluster=arn):
                attempt('ecs', 'stop_task', cluster=arn, task=task)
            attempt('ecs', 'delete_cluster', cluster=arn)
    for status in ['ACTIVE', 'INACTIVE']:
        for arn in pages('ecs', 'list_task_definitions', 'taskDefinitionArns', status=status):
            family = arn.split('/')[-1].split(':')[0]
            definition = ecs.describe_task_definition(taskDefinition=arn, include=['TAGS'])
            if scoped(family, definition.get('tags')) and owned('aws_ecs_task_definition', arn, all_resources):
                if status == 'ACTIVE':
                    attempt('ecs', 'deregister_task_definition', taskDefinition=arn)
                attempt('ecs', 'delete_task_definitions', taskDefinitions=[arn])
    elb = client('elbv2')
    for lb in pages('elbv2', 'describe_load_balancers', 'LoadBalancers'):
        tags = elb.describe_tags(ResourceArns=[lb['LoadBalancerArn']])['TagDescriptions'][0]['Tags']
        if scoped(lb['LoadBalancerName'], tags) and owned('aws_lb', lb['LoadBalancerArn'], all_resources):
            for listener in elb.describe_listeners(LoadBalancerArn=lb['LoadBalancerArn']).get('Listeners', []):
                attempt('elbv2', 'delete_listener', ListenerArn=listener['ListenerArn'])
            attempt('elbv2', 'delete_load_balancer', LoadBalancerArn=lb['LoadBalancerArn'])
    for tg in pages('elbv2', 'describe_target_groups', 'TargetGroups'):
        tags = elb.describe_tags(ResourceArns=[tg['TargetGroupArn']])['TagDescriptions'][0]['Tags']
        if scoped(tg['TargetGroupName'], tags) and owned('aws_lb_target_group', tg['TargetGroupArn'], all_resources):
            attempt('elbv2', 'delete_target_group', TargetGroupArn=tg['TargetGroupArn'])
    rds = client('rds')
    for d in pages('rds', 'describe_db_instances', 'DBInstances'):
        tags = rds.list_tags_for_resource(ResourceName=d['DBInstanceArn']).get('TagList', [])
        if scoped(d['DBInstanceIdentifier'], tags) and owned('aws_db_instance', d['DBInstanceIdentifier'], all_resources):
            if d.get('DeletionProtection'):
                rds.modify_db_instance(DBInstanceIdentifier=d['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
            attempt('rds', 'delete_db_instance', DBInstanceIdentifier=d['DBInstanceIdentifier'], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
            rds.get_waiter('db_instance_deleted').wait(DBInstanceIdentifier=d['DBInstanceIdentifier'], WaiterConfig={'Delay': 2, 'MaxAttempts': 90})
    for d in pages('rds', 'describe_db_snapshots', 'DBSnapshots'):
        tags = rds.list_tags_for_resource(ResourceName=d['DBSnapshotArn']).get('TagList', [])
        if scoped(d['DBSnapshotIdentifier'], tags):
            attempt('rds', 'delete_db_snapshot', DBSnapshotIdentifier=d['DBSnapshotIdentifier'])
    for d in pages('rds', 'describe_db_subnet_groups', 'DBSubnetGroups'):
        tags = rds.list_tags_for_resource(ResourceName=d['DBSubnetGroupArn']).get('TagList', [])
        if scoped(d['DBSubnetGroupName'], tags) and owned('aws_db_subnet_group', d['DBSubnetGroupName'], all_resources):
            attempt('rds', 'delete_db_subnet_group', DBSubnetGroupName=d['DBSubnetGroupName'])
    cache = client('elasticache')
    for r in pages('elasticache', 'describe_replication_groups', 'ReplicationGroups'):
        tags = cache.list_tags_for_resource(ResourceName=r['ARN']).get('TagList', [])
        if scoped(r['ReplicationGroupId'], tags) and owned('aws_elasticache_replication_group', r['ReplicationGroupId'], all_resources):
            attempt('elasticache', 'delete_replication_group', ReplicationGroupId=r['ReplicationGroupId'], RetainPrimaryCluster=False)
    for r in pages('elasticache', 'describe_cache_clusters', 'CacheClusters'):
        if scoped(r['CacheClusterId']) and not r.get('ReplicationGroupId'):
            attempt('elasticache', 'delete_cache_cluster', CacheClusterId=r['CacheClusterId'])
    for r in pages('elasticache', 'describe_cache_subnet_groups', 'CacheSubnetGroups'):
        if scoped(r['CacheSubnetGroupName']) and owned('aws_elasticache_subnet_group', r['CacheSubnetGroupName'], all_resources):
            attempt('elasticache', 'delete_cache_subnet_group', CacheSubnetGroupName=r['CacheSubnetGroupName'])
    ddb = client('dynamodb')
    for name in pages('dynamodb', 'list_tables', 'TableNames'):
        table = ddb.describe_table(TableName=name)['Table']
        tags = ddb.list_tags_of_resource(ResourceArn=table['TableArn']).get('Tags', [])
        if scoped(name, tags) and owned('aws_dynamodb_table', name, all_resources):
            if table.get('DeletionProtectionEnabled'):
                ddb.update_table(TableName=name, DeletionProtectionEnabled=False)
            attempt('dynamodb', 'delete_table', TableName=name)
    sqs = client('sqs')
    for url in pages('sqs', 'list_queues', 'QueueUrls'):
        tags = sqs.list_queue_tags(QueueUrl=url).get('Tags', {})
        if scoped(url.rsplit('/', 1)[-1], tags) and owned('aws_sqs_queue', url, all_resources):
            attempt('sqs', 'delete_queue', QueueUrl=url)
    s3 = client('s3')
    for b in s3.list_buckets().get('Buckets', []):
        try:
            tags = s3.get_bucket_tagging(Bucket=b['Name']).get('TagSet', [])
        except ClientError as exc:
            if exc.response['Error']['Code'] not in {'NoSuchTagSet', 'NoSuchTagSetError'}:
                raise
            tags = []
        if scoped(b['Name'], tags) and owned('aws_s3_bucket', b['Name'], all_resources):
            for upload in pages('s3', 'list_multipart_uploads', 'Uploads', Bucket=b['Name']):
                s3.abort_multipart_upload(Bucket=b['Name'], Key=upload['Key'], UploadId=upload['UploadId'])
            delete_versions(b['Name'], [{'Key': v['Key'], 'VersionId': v['VersionId']} for _, v in versions(b['Name'])])
            objects = list(pages('s3', 'list_objects_v2', 'Contents', Bucket=b['Name']))
            delete_versions(b['Name'], [{'Key': o['Key']} for o in objects])
            attempt('s3', 'delete_bucket', Bucket=b['Name'])
    cog = client('cognito-idp')
    for pool in pages('cognito-idp', 'list_user_pools', 'UserPools', MaxResults=60):
        desc = cog.describe_user_pool(UserPoolId=pool['Id'])['UserPool']
        if scoped(pool['Name'], desc.get('UserPoolTags')) and owned('aws_cognito_user_pool', pool['Id'], all_resources):
            if desc.get('Domain'):
                attempt('cognito-idp', 'delete_user_pool_domain', UserPoolId=pool['Id'], Domain=desc['Domain'])
            for c in pages('cognito-idp', 'list_user_pool_clients', 'UserPoolClients', UserPoolId=pool['Id'], MaxResults=60):
                cog.delete_user_pool_client(UserPoolId=pool['Id'], ClientId=c['ClientId'])
            cog.delete_user_pool(UserPoolId=pool['Id'])
    for g in pages('logs', 'describe_log_groups', 'logGroups'):
        arn = g.get('logGroupArn', g['arn'].removesuffix(':*'))
        tags = client('logs').list_tags_for_resource(resourceArn=arn).get('tags', {})
        if scoped(g['logGroupName'], tags) and owned('aws_cloudwatch_log_group', g['logGroupName'], all_resources):
            attempt('logs', 'delete_log_group', logGroupName=g['logGroupName'])
    cleanup_policies(all_resources)
    iam = client('iam')
    for role in pages('iam', 'list_roles', 'Roles'):
        tags = iam.list_role_tags(RoleName=role['RoleName']).get('Tags', [])
        if scoped(role['RoleName'], tags) and owned('aws_iam_role', role['RoleName'], all_resources):
            for p in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=role['RoleName']):
                iam.delete_role_policy(RoleName=role['RoleName'], PolicyName=p)
            for p in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=role['RoleName']):
                iam.detach_role_policy(RoleName=role['RoleName'], PolicyArn=p['PolicyArn'])
            for ip in pages('iam', 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=role['RoleName']):
                iam.remove_role_from_instance_profile(InstanceProfileName=ip['InstanceProfileName'], RoleName=role['RoleName'])
                if scoped(ip['InstanceProfileName']):
                    iam.delete_instance_profile(InstanceProfileName=ip['InstanceProfileName'])
            iam.delete_role(RoleName=role['RoleName'])
    kms = client('kms')
    for a in pages('kms', 'list_aliases', 'Aliases'):
        if scoped(a['AliasName']) and owned('aws_kms_alias', a['AliasName'], all_resources):
            attempt('kms', 'delete_alias', AliasName=a['AliasName'])
    for key in pages('kms', 'list_keys', 'Keys'):
        tags = {t['TagKey']: t['TagValue'] for t in kms.list_resource_tags(KeyId=key['KeyId']).get('Tags', [])}
        desc = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        if scoped(desc.get('Description', ''), tags) and owned('aws_kms_key', key['KeyId'], all_resources):
            if desc['KeyState'] != 'PendingDeletion':
                kms.schedule_key_deletion(KeyId=key['KeyId'], PendingWindowInDays=10)
    cleanup_network(all_resources)
    print('Prefix-scoped cleanup complete')


def cleanup_network(all_resources):
    ec2 = client('ec2')
    vpcs = ec2.describe_vpcs()['Vpcs']
    selected = {v['VpcId'] for v in vpcs if scoped('', v.get('Tags')) and owned('aws_vpc', v['VpcId'], all_resources)}
    record_vpcs(selected)
    if all_resources:
        selected.update(record_vpcs(set()))
        backup = ROOT / 'infra/terraform.tfstate.backup'
        if backup.exists():
            for r in json.loads(backup.read_text()).get('resources', []):
                if r.get('type') == 'aws_vpc':
                    for instance in r.get('instances', []):
                        a = instance['attributes']
                        if scoped('', a.get('tags_all', a.get('tags'))):
                            selected.add(a['id'])
    def select(r, name, kind):
        return (r.get('VpcId') in selected or scoped(r.get('GroupName', ''), r.get('Tags'))) and owned(kind, r[name], all_resources)
    for eni in ec2.describe_network_interfaces()['NetworkInterfaces']:
        if eni.get('VpcId') in selected and eni.get('Status') == 'available':
            attempt('ec2', 'delete_network_interface', NetworkInterfaceId=eni['NetworkInterfaceId'])
    groups = [g for g in ec2.describe_security_groups()['SecurityGroups'] if select(g, 'GroupId', 'aws_security_group') and g['GroupName'] != 'default']
    for g in groups:
        for direction, field in [('ingress','IpPermissions'), ('egress','IpPermissionsEgress')]:
            if g.get(field):
                getattr(ec2, 'revoke_security_group_' + direction)(GroupId=g['GroupId'], IpPermissions=g[field])
    for g in groups:
        attempt('ec2', 'delete_security_group', GroupId=g['GroupId'])
    for r in ec2.describe_route_tables()['RouteTables']:
        if select(r, 'RouteTableId', 'aws_route_table'):
            for a in r.get('Associations', []):
                if not a.get('Main'):
                    attempt('ec2', 'disassociate_route_table', AssociationId=a['RouteTableAssociationId'])
            if not any(a.get('Main') for a in r.get('Associations', [])):
                attempt('ec2', 'delete_route_table', RouteTableId=r['RouteTableId'])
    for s in ec2.describe_subnets()['Subnets']:
        if select(s, 'SubnetId', 'aws_subnet'):
            attempt('ec2', 'delete_subnet', SubnetId=s['SubnetId'])
    for g in ec2.describe_internet_gateways()['InternetGateways']:
        if (scoped('', g.get('Tags')) or any(a['VpcId'] in selected for a in g.get('Attachments', []))) and owned('aws_internet_gateway', g['InternetGatewayId'], all_resources):
            for a in g.get('Attachments', []):
                attempt('ec2', 'detach_internet_gateway', InternetGatewayId=g['InternetGatewayId'], VpcId=a['VpcId'])
            attempt('ec2', 'delete_internet_gateway', InternetGatewayId=g['InternetGatewayId'])
    for vpc in selected:
        attempt('ec2', 'delete_vpc', VpcId=vpc)
    # The local backend retains untagged default SGs, route tables and NACLs
    # after DeleteVpc. Their recorded parent ownership keeps cleanup scoped.
    existing = {v['VpcId'] for v in ec2.describe_vpcs()['Vpcs']}
    retired = selected - existing
    for g in ec2.describe_security_groups()['SecurityGroups']:
        if g.get('VpcId') in retired:
            attempt('ec2', 'delete_security_group', GroupId=g['GroupId'])
    for r in ec2.describe_route_tables()['RouteTables']:
        if r.get('VpcId') in retired:
            attempt('ec2', 'delete_route_table', RouteTableId=r['RouteTableId'])
    for a in ec2.describe_network_acls()['NetworkAcls']:
        if a.get('VpcId') in retired:
            try:
                attempt('ec2', 'delete_network_acl', NetworkAclId=a['NetworkAclId'])
            except ClientError as exc:
                # Default NACL lifetime belongs to DeleteVpc; AWS does not expose
                # an independent deletion operation for a default NACL.
                if not (a.get('IsDefault') and exc.response['Error']['Code'] == 'InvalidParameterValue'):
                    raise


def record_vpcs(ids):
    path = ROOT / 'ownership.json'
    history = json.loads(path.read_text()) if path.exists() else {}
    owned_ids = set(history.get(P, [])) | set(ids)
    history[P] = sorted(owned_ids)
    path.write_text(json.dumps(history, indent=2) + '\n')
    return owned_ids


if __name__ == '__main__':
    action = sys.argv[1]
    if action == 'preflight': preflight(); adopt_keys()
    elif action == 'protect': protect()
    elif action == 'manifest': manifest()
    elif action == 'converge': converge()
    elif action == 'quiesce': quiesce()
    elif action == 'cleanup-extra': cleanup(False)
    elif action == 'cleanup-all': cleanup(True)
    else: raise RuntimeError('Unknown lifecycle operation')
