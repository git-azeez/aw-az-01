#!/usr/bin/env python3
"""Control-plane hygiene and transactional reconciliation of derived stores.

Cloud resources are created exclusively by Terraform. This utility performs
schema migrations, data-plane repairs, and prefix-scoped operational cleanup.
"""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.request

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import jsonschema
import psycopg
from psycopg.rows import dict_row
import redis

ROOT = Path(__file__).resolve().parent
C = json.loads(Path(os.environ.get('CLEARLEDGER_CONFIG', '/workspace/config/config.json')).read_text())
P = C['resource_prefix']
if P.startswith('cl-base-') or not re.fullmatch(r'[a-z][a-z0-9-]{3,23}', P):
    raise ValueError('Invalid or baseline deployment prefix')
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])
CLIENTS = {}


def client(service):
    if service not in CLIENTS:
        CLIENTS[service] = SESSION.client(service, endpoint_url=C['aws_endpoint_url'],
            config=Config(retries={'max_attempts': 5, 'mode': 'standard'}, connect_timeout=5, read_timeout=30))
    return CLIENTS[service]


def pages(service, operation, key, **kwargs):
    c = client(service)
    if c.can_paginate(operation):
        for page in c.get_paginator(operation).paginate(**kwargs):
            yield from page.get(key, [])
    else:
        yield from getattr(c, operation)(**kwargs).get(key, [])


def absent(call, **kwargs):
    try:
        return call(**kwargs)
    except ClientError as e:
        if e.response['Error']['Code'] in ('NoSuchEntity', 'NoSuchEntityException', 'ResourceNotFoundException',
                'ResourceNotFound', 'DBInstanceNotFound', 'DBInstanceNotFoundFault', 'NoSuchBucket',
                'AWS.SimpleQueueService.NonExistentQueue', 'InvalidGroup.NotFound', 'InvalidVpcID.NotFound',
                'ReplicationGroupNotFoundFault', 'CacheClusterNotFound', 'NotFoundException', 'NoSuchTagSet'):
            return None
        raise


def scoped(name, tags=()):
    if isinstance(tags, dict):
        tag = tags.get('ClearLedgerDeployment')
    else:
        tag = next((t.get('Value') for t in tags if t.get('Key') == 'ClearLedgerDeployment'), None)
    return not str(name).startswith('cl-base-') and (str(name).startswith(P + '-') or tag == P)


def manifest(path=None):
    m = json.loads(Path(path or ROOT / 'manifest.json').read_text())
    jsonschema.Draft202012Validator(json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text())).validate(m)
    if m['resource_prefix'] != P:
        raise ValueError('Manifest belongs to a different deployment')
    return m


def db(m):
    d = m['database']
    deadline = time.monotonic() + 90
    while True:
        try:
            return psycopg.connect(host=d['endpoint'], port=d['port'], dbname=C['db_name'],
                user=C['db_username'], password=C['db_password'], connect_timeout=5, row_factory=dict_row)
        except psycopg.OperationalError:
            if time.monotonic() > deadline:
                raise
            time.sleep(2)


def remove_policy(arn):
    iam = client('iam')
    for v in pages('iam', 'list_policy_versions', 'Versions', PolicyArn=arn):
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    iam.delete_policy(PolicyArn=arn)


def iam_hygiene(destroy=False):
    iam = client('iam')
    for r in pages('iam', 'list_roles', 'Roles'):
        name = r['RoleName']
        tags = iam.list_role_tags(RoleName=name).get('Tags', [])
        if not scoped(name, tags):
            continue
        for pol in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
            if destroy or pol != name + '-canonical':
                iam.delete_role_policy(RoleName=name, PolicyName=pol)
        for pol in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=pol['PolicyArn'])
        if destroy:
            for profile in pages('iam', 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if scoped(profile['InstanceProfileName'], profile.get('Tags', [])):
                    iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
    for pol in list(pages('iam', 'list_policies', 'Policies', Scope='Local')):
        tags = iam.list_policy_tags(PolicyArn=pol['Arn']).get('Tags', [])
        if not scoped(pol['PolicyName'], tags):
            continue
        entities = iam.list_entities_for_policy(PolicyArn=pol['Arn'])
        if destroy:
            for role in entities.get('PolicyRoles', []):
                # Only detach from owned roles; do not change baseline identities.
                if scoped(role['RoleName']):
                    iam.detach_role_policy(RoleName=role['RoleName'], PolicyArn=pol['Arn'])
            for user in entities.get('PolicyUsers', []):
                if scoped(user['UserName']):
                    iam.detach_user_policy(UserName=user['UserName'], PolicyArn=pol['Arn'])
            for group in entities.get('PolicyGroups', []):
                if scoped(group['GroupName']):
                    iam.detach_group_policy(GroupName=group['GroupName'], PolicyArn=pol['Arn'])
            entities = iam.list_entities_for_policy(PolicyArn=pol['Arn'])
        if not any(entities.get(k) for k in ('PolicyRoles', 'PolicyUsers', 'PolicyGroups')):
            remove_policy(pol['Arn'])


def kms_owned():
    kms = client('kms')
    for k in pages('kms', 'list_keys', 'Keys'):
        desc = kms.describe_key(KeyId=k['KeyId'])['KeyMetadata']
        tags = kms.list_resource_tags(KeyId=k['KeyId']).get('Tags', [])
        tags = [{'Key': t['TagKey'], 'Value': t['TagValue']} for t in tags]
        if scoped(desc.get('Description', ''), tags):
            yield desc


def preflight():
    iam_hygiene()
    kms = client('kms')
    state_path = ROOT / 'infra/terraform.tfstate'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    tracked_keys = {i['attributes']['id'] for r in state.get('resources', []) if r['type'] == 'aws_kms_key' for i in r.get('instances', [])}
    for k in kms_owned():
        if k['KeyState'] == 'PendingDeletion' and k['KeyId'] in tracked_keys:
            kms.cancel_key_deletion(KeyId=k['KeyId'])
            kms.enable_key(KeyId=k['KeyId'])
        elif k['KeyState'] == 'Disabled' and k['KeyId'] in tracked_keys:
            kms.enable_key(KeyId=k['KeyId'])
    print('Operational policy and KMS hygiene complete')


def schema():
    with db(manifest()) as conn:
        conn.execute((ROOT / 'schema.sql').read_text())
    print('PostgreSQL schema, constraints, triggers, and indexes repaired')


def preserve():
    plan = json.loads((ROOT / 'infra/deployment.plan.json').read_text())
    for r in plan.get('resource_changes', []):
        if r['type'] in ('aws_db_instance', 'aws_dynamodb_table', 'aws_s3_bucket') and 'delete' in r['change']['actions']:
            raise RuntimeError('Deployment would destroy a durable store: ' + r['address'])


def network_hygiene():
    # EC2 normally removes its default egress at SG creation, but some local
    # implementations return success while retaining it. Enforce declared rules.
    m = manifest()
    ec2 = client('ec2')
    groups = m['network']['security_group_ids']
    cidr = ec2.describe_vpcs(VpcIds=[m['network']['vpc_id']])['Vpcs'][0]['CidrBlock']
    for workload, gid in groups.items():
        g = ec2.describe_security_groups(GroupIds=[gid])['SecurityGroups'][0]
        if workload in ('rds', 'valkey'):
            unwanted = g.get('IpPermissionsEgress', [])
        elif workload == 'alb':
            unwanted = [p for p in g.get('IpPermissionsEgress', []) if not (
                p.get('IpProtocol') == 'tcp' and p.get('FromPort') == 8080 and p.get('ToPort') == 8080
                and all(ip.get('CidrIp') == cidr for ip in p.get('IpRanges', []))
                and not p.get('Ipv6Ranges') and not p.get('PrefixListIds'))]
        else:
            unwanted = []
        if unwanted:
            ec2.revoke_security_group_egress(GroupId=gid, IpPermissions=unwanted)


def schedule_state(name, state):
    s = client('scheduler')
    old = s.get_schedule(Name=name)
    allowed = ('Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone', 'StartDate', 'EndDate',
        'Description', 'FlexibleTimeWindow', 'Target', 'KmsKeyArn', 'ActionAfterCompletion')
    args = {k: old[k] for k in allowed if k in old}
    args['Name'] = name
    args['State'] = state
    s.update_schedule(**args)


def mapping_state(uuid, enabled):
    l = client('lambda')
    l.update_event_source_mapping(UUID=uuid, Enabled=enabled)
    deadline = time.monotonic() + 60
    while True:
        state = l.get_event_source_mapping(UUID=uuid)['State']
        if state == ('Enabled' if enabled else 'Disabled'):
            return
        if time.monotonic() > deadline:
            raise RuntimeError('Event source mapping did not converge')
        time.sleep(1)


def invoke(name, payload):
    result = client('lambda').invoke(FunctionName=name, InvocationType='RequestResponse', Payload=json.dumps(payload).encode())
    body = result['Payload'].read()
    if result.get('FunctionError'):
        raise RuntimeError('Worker invocation failed: ' + body.decode()[:512])
    return json.loads(body or b'{}')


def ddb_scan(table):
    return list(pages('dynamodb', 'scan', 'Items', TableName=table, ConsistentRead=True))


def batch_write(table, requests):
    d = client('dynamodb')
    for start in range(0, len(requests), 25):
        pending = {table: requests[start:start + 25]}
        deadline = time.monotonic() + 60
        while pending:
            pending = d.batch_write_item(RequestItems=pending).get('UnprocessedItems', {})
            if pending:
                if time.monotonic() > deadline:
                    raise RuntimeError('DynamoDB batch write did not complete')
                time.sleep(0.2)


def audit_versions(bucket):
    for page in client('s3').get_paginator('list_object_versions').paginate(Bucket=bucket):
        yield from [('version', v) for v in page.get('Versions', [])]
        yield from [('marker', v) for v in page.get('DeleteMarkers', [])]


def delete_versions(bucket, objects):
    s3 = client('s3')
    for start in range(0, len(objects), 1000):
        out = s3.delete_objects(Bucket=bucket, Delete={'Objects': objects[start:start + 1000], 'Quiet': True})
        if out.get('Errors'):
            raise RuntimeError('Could not purge audit versions')


def expected_projection(events, settlements):
    expected = {}
    def item(values):
        return {k: {'N' if isinstance(v, int) else 'S': str(v)} for k, v in values.items() if v is not None}
    latest = {}
    for row in events:
        e = row['payload']
        d = e['data']
        sid = e['aggregateId']
        pk = 'SETTLEMENT#' + sid
        sk = f"EVENT#{e['aggregateVersion']:08d}"
        expected[(pk, sk)] = item({
            'PK': pk, 'SK': sk, 'settlement_id': sid, 'event_id': e['eventId'], 'version': e['aggregateVersion'],
            'event_type': e['eventType'], 'status': d['status'], 'clearing_stage': d['clearingStage'],
            'occurred_at': e['occurredAt'], 'correlation_id': e['correlationId'], 'envelope': json.dumps(e),
            'entry_id': d.get('entryId'), 'memo': d.get('memo')})
        latest[sid] = e
    for s in settlements:
        sid = str(s['settlement_id'])
        pk = 'SETTLEMENT#' + sid
        expected[(pk, 'STATE')] = item({
            'PK': pk, 'SK': 'STATE', 'GSI1PK': 'ACCOUNT#' + s['account_id'], 'GSI1SK': pk,
            'settlement_id': sid, 'account_id': s['account_id'], 'reference': s['reference'],
            'debit_party': s['debit_party'], 'credit_party': s['credit_party'], 'status': s['current_status'],
            'clearing_stage': s['current_stage'], 'version': s['version'], 'entry_count': s['entry_count'],
            'updated_at': latest[sid]['occurredAt'], 'last_entry_id': str(s['last_entry_id']) if s['last_entry_id'] else None,
            'last_memo': s['last_memo']})
    return expected


def same_projection(actual, expected):
    if actual.keys() != expected.keys():
        return False
    for key, value in expected.items():
        try:
            if key == 'envelope':
                if json.loads(actual[key]['S']) != json.loads(value['S']):
                    return False
            elif key in ('occurred_at', 'updated_at'):
                if datetime.fromisoformat(actual[key]['S'].replace('Z', '+00:00')) != datetime.fromisoformat(value['S'].replace('Z', '+00:00')):
                    return False
            elif actual[key] != value:
                return False
        except (ValueError, KeyError, TypeError):
            return False
    return True


def drain_queue(m):
    deadline = time.monotonic() + 90
    sqs = client('sqs')
    quiet = 0
    while time.monotonic() < deadline:
        attrs = sqs.get_queue_attributes(QueueUrl=m['messaging']['queue_url'], AttributeNames=['ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', 'ApproximateNumberOfMessagesDelayed'])['Attributes']
        quiet = quiet + 1 if all(int(v) == 0 for v in attrs.values()) else 0
        if quiet >= 2:
            return
        time.sleep(1)
    raise RuntimeError('SQS backlog did not drain')


def reconcile():
    m = manifest()
    table = m['projections']['table_name']
    bucket = m['audit']['bucket_name']
    queue = m['messaging']['queue_url']
    uuid = m['messaging']['event_source_mapping_uuid']
    schedules = [m['schedules']['outbox_schedule_name'], m['schedules']['archive_schedule_name']]
    # Quiesce derived writers only. API requests can read and queue writes until the
    # brief database lock is released. Finally restores normal worker operation.
    try:
        for s in schedules:
            schedule_state(s, 'DISABLED')
        mapping_state(uuid, False)
        time.sleep(4)  # Allow the bounded (3s) in-flight worker invocations to finish.
        with db(m) as conn:
            conn.execute('SET LOCAL lock_timeout = \'60s\'')
            conn.execute('LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
            events = conn.execute('SELECT payload FROM clearledger.events ORDER BY settlement_id, aggregate_version').fetchall()
            settlements = conn.execute('SELECT * FROM clearledger.settlements ORDER BY settlement_id').fetchall()
            outbox = conn.execute('SELECT * FROM clearledger.outbox ORDER BY seq').fetchall()
            # Recover missed delivery without resetting successful delivery stamps.
            for row in outbox:
                if row['published_at'] is None:
                    client('sqs').send_message(QueueUrl=queue, MessageBody=json.dumps(row['payload'], separators=(',', ':')))
                    conn.execute('UPDATE clearledger.outbox SET published_at = GREATEST(clock_timestamp(),created_at), attempts = attempts + 1, last_error = NULL WHERE seq = %s', (row['seq'],))
            # Consume the whole backlog before the final repair, including forged
            # valid envelopes and poison messages, while authoritative writes wait.
            mapping_state(uuid, True)
            drain_queue(m)
            mapping_state(uuid, False)
            time.sleep(4)
            # Retain canonical items, removing only orphan or divergent items that
            # the worker's conditional writes cannot otherwise repair.
            expected = expected_projection(events, settlements)
            old_items = ddb_scan(table)
            divergent = [x for x in old_items if (x['PK']['S'], x['SK']['S']) not in expected
                or not same_projection(x, expected[(x['PK']['S'], x['SK']['S'])])]
            batch_write(table, [{'DeleteRequest': {'Key': {'PK': x['PK'], 'SK': x['SK']}}} for x in divergent])
            present = {(x['PK']['S'], x['SK']['S']) for x in old_items} - {(x['PK']['S'], x['SK']['S']) for x in divergent}
            repair_ids = {pk.removeprefix('SETTLEMENT#') for pk, sk in expected.keys() - present}
            replay = [e for e in events if e['payload']['aggregateId'] in repair_ids]
            for start in range(0, len(replay), 5):
                records = [{'messageId': f'recovery-{start+i}', 'body': json.dumps(e['payload'], separators=(',', ':'))}
                    for i, e in enumerate(replay[start:start + 5])]
                response = invoke(m['workers']['projector']['function_name'], {'Records': records})
                if response.get('batchItemFailures'):
                    raise RuntimeError('Projector rejected authoritative events')
            items = ddb_scan(table)
            if {(x['PK']['S'], x['SK']['S']) for x in items} != expected.keys() or any(
                not same_projection(x, expected[(x['PK']['S'], x['SK']['S'])]) for x in items):
                raise RuntimeError('Projection attribute reconciliation failed')
            # Keep valid existing archive slices. Replace corrupt, overlapping, or
            # incomplete batches, then fill uncovered contiguous sequence intervals.
            by_seq = {r['seq']: r for r in outbox}
            covered = set()
            versions = list(audit_versions(bucket))
            purge = []
            for kind, v in sorted(versions, key=lambda kv: kv[1]['Key']):
                key = v['Key']
                match = re.fullmatch(r'ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson', key)
                valid = kind == 'version' and v.get('IsLatest', False) and match is not None
                if valid:
                    first, last = int(match[1]), int(match[2])
                    valid = first <= last and all(seq in by_seq and seq not in covered for seq in range(first, last + 1))
                if valid:
                    raw = client('s3').get_object(Bucket=bucket, Key=key, VersionId=v['VersionId'])['Body'].read()
                    try:
                        decoded = [json.loads(line) for line in raw.splitlines()]
                        valid = hashlib.sha256(raw).hexdigest()[:16] == match[3] and decoded == [by_seq[i]['payload'] for i in range(first, last + 1)]
                    except (ValueError, UnicodeError):
                        valid = False
                if valid:
                    covered.update(range(first, last + 1))
                else:
                    purge.append({'Key': key, 'VersionId': v['VersionId']})
            delete_versions(bucket, purge)
            missing = [r for r in outbox if r['seq'] not in covered]
            batches = []
            for r in missing:
                if not batches or len(batches[-1]) == 100 or batches[-1][-1]['seq'] + 1 != r['seq']:
                    batches.append([])
                batches[-1].append(r)
            for batch in batches:
                raw = b''.join((json.dumps(r['payload'], sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode() for r in batch)
                key = f"ledger-audit/batch-{batch[0]['seq']:08d}-{batch[-1]['seq']:08d}-{hashlib.sha256(raw).hexdigest()[:16]}.ndjson"
                client('s3').put_object(Bucket=bucket, Key=key, Body=raw, ContentType='application/x-ndjson',
                    ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
                covered.update(r['seq'] for r in batch)
            if covered != set(by_seq):
                raise RuntimeError('Audit coverage reconciliation failed')
            conn.execute('UPDATE clearledger.outbox SET archived_at = GREATEST(clock_timestamp(),published_at) WHERE archived_at IS NULL')
            # Warm exact API projection JSON and remove all stray cache keys.
            r = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], decode_responses=True, socket_timeout=5)
            valid_cache = {f"clearledger:settlement:{s['settlement_id']}" for s in settlements}
            for key in r.scan_iter(count=100):
                if key not in valid_cache:
                    r.delete(key)
            pipe = r.pipeline(transaction=True)
            latest = {e['payload']['aggregateId']: e['payload'] for e in events}
            for s in settlements:
                e = latest[str(s['settlement_id'])]
                projection = {
                    'settlementId': str(s['settlement_id']), 'accountId': s['account_id'], 'reference': s['reference'],
                    'debitParty': s['debit_party'], 'creditParty': s['credit_party'], 'status': s['current_status'],
                    'clearingStage': s['current_stage'], 'lastEntryId': str(s['last_entry_id']) if s['last_entry_id'] else None,
                    'lastMemo': s['last_memo'], 'version': s['version'], 'entryCount': s['entry_count'], 'updatedAt': e['occurredAt']}
                pipe.set(f"clearledger:settlement:{s['settlement_id']}", json.dumps(projection, separators=(',', ':')), ex=90)
            pipe.execute()
            print(f"Reconciled {len(settlements)} settlements, {len(events)} events, and {len(outbox)} audit records")
    finally:
        mapping_state(uuid, True)
        for s in schedules:
            schedule_state(s, 'ENABLED')


def ready():
    m = manifest()
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(m['service_url'] + '/health/ready', timeout=5) as response:
                if response.status == 200:
                    print('ClearLedger is ready at ' + m['service_url'])
                    return
        except (OSError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError('API readiness deadline exceeded')


def empty_bucket(bucket):
    delete_versions(bucket, [{'Key': v['Key'], 'VersionId': v['VersionId']} for _, v in audit_versions(bucket)])
    # Unversioned objects and interrupted multipart uploads also block deletion.
    objs = [{'Key': o['Key']} for o in pages('s3', 'list_objects_v2', 'Contents', Bucket=bucket)]
    delete_versions(bucket, objs)
    for u in pages('s3', 'list_multipart_uploads', 'Uploads', Bucket=bucket):
        client('s3').abort_multipart_upload(Bucket=bucket, Key=u['Key'], UploadId=u['UploadId'])


def cleanup_before():
    iam_hygiene(destroy=True)
    # Delete owned queues up front so Terraform's refresh observes absence.
    # The local GetQueueAttributes deletion waiter otherwise stalls separately
    # for the main queue and DLQ even after successful DeleteQueue responses.
    sqs = client('sqs')
    for url in pages('sqs', 'list_queues', 'QueueUrls'):
        if scoped(url.rsplit('/', 1)[-1], sqs.list_queue_tags(QueueUrl=url).get('Tags', {})):
            sqs.delete_queue(QueueUrl=url)
    for b in client('s3').list_buckets().get('Buckets', []):
        tags = absent(client('s3').get_bucket_tagging, Bucket=b['Name'])
        if scoped(b['Name'], (tags or {}).get('TagSet', [])):
            empty_bucket(b['Name'])
    print('Teardown policy attachments and bucket contents cleaned')


def cleanup_after():
    # Dependency-ordered sweep also covers operational resources absent from state.
    s = client('scheduler')
    for row in pages('scheduler', 'list_schedules', 'Schedules'):
        if scoped(row['Name']):
            s.delete_schedule(Name=row['Name'], GroupName=row.get('GroupName', 'default'))
    for group in pages('scheduler', 'list_schedule_groups', 'ScheduleGroups'):
        if scoped(group['Name']):
            s.delete_schedule_group(Name=group['Name'])
    l = client('lambda')
    for f in pages('lambda', 'list_functions', 'Functions'):
        tags = l.list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if scoped(f['FunctionName'], tags):
            for esm in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                absent(l.delete_event_source_mapping, UUID=esm['UUID'])
            l.delete_function(FunctionName=f['FunctionName'])
    ecs = client('ecs')
    for arn in pages('ecs', 'list_clusters', 'clusterArns'):
        name = arn.rsplit('/', 1)[-1]
        tags = ecs.list_tags_for_resource(resourceArn=arn).get('tags', [])
        tags = [{'Key': t['key'], 'Value': t['value']} for t in tags]
        if scoped(name, tags):
            for svc in pages('ecs', 'list_services', 'serviceArns', cluster=arn):
                ecs.update_service(cluster=arn, service=svc, desiredCount=0)
                ecs.delete_service(cluster=arn, service=svc, force=True)
            for task in pages('ecs', 'list_tasks', 'taskArns', cluster=arn):
                ecs.stop_task(cluster=arn, task=task)
            ecs.delete_cluster(cluster=arn)
    for arn in pages('ecs', 'list_task_definitions', 'taskDefinitionArns'):
        if scoped(arn.split('task-definition/')[-1].split(':')[0]):
            ecs.deregister_task_definition(taskDefinition=arn)
            absent(ecs.delete_task_definitions, taskDefinitions=[arn])
    elb = client('elbv2')
    for lb in pages('elbv2', 'describe_load_balancers', 'LoadBalancers'):
        tags = elb.describe_tags(ResourceArns=[lb['LoadBalancerArn']])['TagDescriptions'][0]['Tags']
        if scoped(lb['LoadBalancerName'], tags):
            elb.delete_load_balancer(LoadBalancerArn=lb['LoadBalancerArn'])
    for tg in pages('elbv2', 'describe_target_groups', 'TargetGroups'):
        tags = elb.describe_tags(ResourceArns=[tg['TargetGroupArn']])['TagDescriptions'][0]['Tags']
        if scoped(tg['TargetGroupName'], tags):
            elb.delete_target_group(TargetGroupArn=tg['TargetGroupArn'])
    rds = client('rds')
    for d in pages('rds', 'describe_db_instances', 'DBInstances'):
        tags = rds.list_tags_for_resource(ResourceName=d['DBInstanceArn'])['TagList']
        if scoped(d['DBInstanceIdentifier'], tags):
            rds.delete_db_instance(DBInstanceIdentifier=d['DBInstanceIdentifier'], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
            rds.get_waiter('db_instance_deleted').wait(DBInstanceIdentifier=d['DBInstanceIdentifier'], WaiterConfig={'Delay': 2, 'MaxAttempts': 90})
    for group in pages('rds', 'describe_db_subnet_groups', 'DBSubnetGroups'):
        if scoped(group['DBSubnetGroupName']):
            rds.delete_db_subnet_group(DBSubnetGroupName=group['DBSubnetGroupName'])
    for snap in pages('rds', 'describe_db_snapshots', 'DBSnapshots', SnapshotType='manual'):
        if scoped(snap['DBSnapshotIdentifier']) or scoped(snap['DBInstanceIdentifier']):
            rds.delete_db_snapshot(DBSnapshotIdentifier=snap['DBSnapshotIdentifier'])
    cache = client('elasticache')
    for group in pages('elasticache', 'describe_replication_groups', 'ReplicationGroups'):
        if scoped(group['ReplicationGroupId']):
            cache.delete_replication_group(ReplicationGroupId=group['ReplicationGroupId'])
    for cluster in pages('elasticache', 'describe_cache_clusters', 'CacheClusters'):
        if scoped(cluster['CacheClusterId']) and not cluster.get('ReplicationGroupId'):
            cache.delete_cache_cluster(CacheClusterId=cluster['CacheClusterId'])
    for group in pages('elasticache', 'describe_cache_subnet_groups', 'CacheSubnetGroups'):
        if scoped(group['CacheSubnetGroupName']):
            cache.delete_cache_subnet_group(CacheSubnetGroupName=group['CacheSubnetGroupName'])
    for table in pages('dynamodb', 'list_tables', 'TableNames'):
        desc = client('dynamodb').describe_table(TableName=table)['Table']
        tags = client('dynamodb').list_tags_of_resource(ResourceArn=desc['TableArn']).get('Tags', [])
        if scoped(table, tags):
            client('dynamodb').delete_table(TableName=table)
    sqs = client('sqs')
    for url in pages('sqs', 'list_queues', 'QueueUrls'):
        if scoped(url.rsplit('/', 1)[-1], sqs.list_queue_tags(QueueUrl=url).get('Tags', {})):
            sqs.delete_queue(QueueUrl=url)
    s3 = client('s3')
    for b in s3.list_buckets().get('Buckets', []):
        if scoped(b['Name']):
            empty_bucket(b['Name'])
            s3.delete_bucket(Bucket=b['Name'])
    cognito = client('cognito-idp')
    for pool in pages('cognito-idp', 'list_user_pools', 'UserPools', MaxResults=60):
        desc = cognito.describe_user_pool(UserPoolId=pool['Id'])['UserPool']
        if scoped(pool['Name'], desc.get('UserPoolTags', {})):
            cognito.delete_user_pool(UserPoolId=pool['Id'])
    logs = client('logs')
    for group in pages('logs', 'describe_log_groups', 'logGroups'):
        name = group['logGroupName']
        owned_path = any(part.startswith(P + '-') or part == P for part in name.split('/'))
        if name.startswith(f'/clearledger/{P}/') or scoped(name) or owned_path:
            logs.delete_log_group(logGroupName=name)
    iam_hygiene(destroy=True)
    iam = client('iam')
    for profile in pages('iam', 'list_instance_profiles', 'InstanceProfiles'):
        if scoped(profile['InstanceProfileName'], profile.get('Tags', [])):
            for role in profile['Roles']:
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=role['RoleName'])
            iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
    for role in pages('iam', 'list_roles', 'Roles'):
        if scoped(role['RoleName'], iam.list_role_tags(RoleName=role['RoleName']).get('Tags', [])):
            iam.delete_role(RoleName=role['RoleName'])
    kms = client('kms')
    owned_keys = list(kms_owned())
    owned_ids = {k['KeyId'] for k in owned_keys}
    for alias in pages('kms', 'list_aliases', 'Aliases'):
        if alias['AliasName'].startswith(f'alias/{P}-') or alias.get('TargetKeyId') in owned_ids:
            kms.delete_alias(AliasName=alias['AliasName'])
    for k in owned_keys:
        if k['KeyState'] != 'PendingDeletion':
            kms.schedule_key_deletion(KeyId=k['KeyId'], PendingWindowInDays=10)
    cleanup_network()
    print('Prefix-scoped operational inventory sweep complete')


def cleanup_network():
    ec2 = client('ec2')
    vpcs = [v for v in ec2.describe_vpcs()['Vpcs'] if scoped(next((t['Value'] for t in v.get('Tags', []) if t['Key'] == 'Name'), ''), v.get('Tags', []))]
    for v in vpcs:
        vid = v['VpcId']
        filters = [{'Name': 'vpc-id', 'Values': [vid]}]
        for nat in pages('ec2', 'describe_nat_gateways', 'NatGateways', Filter=filters):
            ec2.delete_nat_gateway(NatGatewayId=nat['NatGatewayId'])
        for endpoint in pages('ec2', 'describe_vpc_endpoints', 'VpcEndpoints', Filters=filters):
            ec2.delete_vpc_endpoints(VpcEndpointIds=[endpoint['VpcEndpointId']])
        for interface in ec2.describe_network_interfaces(Filters=filters)['NetworkInterfaces']:
            if interface.get('Attachment'):
                ec2.detach_network_interface(AttachmentId=interface['Attachment']['AttachmentId'], Force=True)
            ec2.delete_network_interface(NetworkInterfaceId=interface['NetworkInterfaceId'])
        for group in ec2.describe_security_groups(Filters=filters)['SecurityGroups']:
            if group['GroupName'] != 'default':
                if group.get('IpPermissions'):
                    ec2.revoke_security_group_ingress(GroupId=group['GroupId'], IpPermissions=group['IpPermissions'])
                if group.get('IpPermissionsEgress'):
                    ec2.revoke_security_group_egress(GroupId=group['GroupId'], IpPermissions=group['IpPermissionsEgress'])
        for group in ec2.describe_security_groups(Filters=filters)['SecurityGroups']:
            if group['GroupName'] != 'default':
                ec2.delete_security_group(GroupId=group['GroupId'])
        for subnet in ec2.describe_subnets(Filters=filters)['Subnets']:
            ec2.delete_subnet(SubnetId=subnet['SubnetId'])
        for rt in ec2.describe_route_tables(Filters=filters)['RouteTables']:
            if not any(a.get('Main') for a in rt.get('Associations', [])):
                for a in rt.get('Associations', []):
                    ec2.disassociate_route_table(AssociationId=a['RouteTableAssociationId'])
                ec2.delete_route_table(RouteTableId=rt['RouteTableId'])
        for ig in ec2.describe_internet_gateways(Filters=[{'Name': 'attachment.vpc-id', 'Values': [vid]}])['InternetGateways']:
            ec2.detach_internet_gateway(InternetGatewayId=ig['InternetGatewayId'], VpcId=vid)
            ec2.delete_internet_gateway(InternetGatewayId=ig['InternetGatewayId'])
        ec2.delete_vpc(VpcId=vid)


if __name__ == '__main__':
    command = sys.argv[1]
    if command == 'manifest':
        manifest(sys.argv[2])
    else:
        {'preflight': preflight, 'preserve': preserve, 'network-hygiene': network_hygiene, 'schema': schema, 'reconcile': reconcile, 'ready': ready,
         'cleanup-before': cleanup_before, 'cleanup-after': cleanup_after}[command]()
