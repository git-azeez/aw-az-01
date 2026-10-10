#!/usr/bin/env python3
"""Terraform control plane; bounded, prefix-scoped operational convergence."""
import collections
import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.request
import urllib.parse

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import jsonschema
import psycopg
from psycopg.rows import dict_row
import redis

ROOT = pathlib.Path(__file__).resolve().parent
INFRA = ROOT / 'infra'
C = json.loads(pathlib.Path('/workspace/config/config.json').read_text())
PREFIX = C['resource_prefix']
if not re.fullmatch(r'[a-z][a-z0-9-]{3,24}', PREFIX) or PREFIX.startswith('cl-base-'):
    raise ValueError('Invalid or baseline resource_prefix')
os.environ.update(AWS_ENDPOINT_URL=C['aws_endpoint_url'], AWS_REGION=C['region'],
                  AWS_DEFAULT_REGION=C['region'], AWS_ACCESS_KEY_ID='test', AWS_SECRET_ACCESS_KEY='test')
DEADLINE = time.monotonic() + (650 if sys.argv[1] == 'deploy' else 850)
SESSION = boto3.Session(region_name=C['region'], aws_access_key_id='test', aws_secret_access_key='test')
CLIENTS = {}


def remaining():
    value = DEADLINE - time.monotonic()
    if value <= 0:
        raise TimeoutError('Lifecycle deadline exceeded')
    return value


def client(service):
    if service not in CLIENTS:
        CLIENTS[service] = SESSION.client(service, endpoint_url=C['aws_endpoint_url'],
            config=Config(connect_timeout=5, read_timeout=35, retries={'max_attempts': 3},
                          s3={'addressing_style': 'path'}))
    return CLIENTS[service]


def pages(service, operation, field, **kwargs):
    cli = client(service)
    if cli.can_paginate(operation):
        for page in cli.get_paginator(operation).paginate(**kwargs):
            yield from page.get(field, [])
    else:
        yield from getattr(cli, operation)(**kwargs).get(field, [])


def absent(exc):
    return isinstance(exc, ClientError) and exc.response['Error']['Code'] in {
        'NoSuchEntity', 'NoSuchEntityException', 'ResourceNotFoundException', 'ResourceNotFound',
        'QueueDoesNotExist', 'AWS.SimpleQueueService.NonExistentQueue', 'NoSuchBucket',
        'DBInstanceNotFound', 'DBInstanceNotFoundFault', 'InvalidGroup.NotFound', 'NotFoundException'}


def optional(fn, **kwargs):
    try:
        return fn(**kwargs)
    except ClientError as exc:
        if not absent(exc):
            raise
        return None


def scoped(name, tags=()):
    if name.startswith('cl-base-') or '/cl-base-' in name:
        return False
    if isinstance(tags, dict):
        tagged = tags.get('ClearLedgerDeployment') == PREFIX
    else:
        tagged = any(t.get('Key') == 'ClearLedgerDeployment' and t.get('Value') == PREFIX for t in tags)
    log_prefix = '/clearledger/' + PREFIX
    service_path_owned = any(segment == PREFIX or segment.startswith(PREFIX + '-') for segment in name.split('/'))
    return (service_path_owned or name == PREFIX or name.startswith(PREFIX + '-') or name == log_prefix
            or name.startswith(log_prefix + '/') or name.startswith(log_prefix + '-') or tagged)


def tf(*args, json_output=False):
    remaining()
    result = subprocess.run(['terraform', '-chdir=' + str(INFRA), *args],
        capture_output=True, text=True, timeout=remaining())
    # Do not send plans or credentials to the lifecycle stdout/logs.
    if result.returncode:
        message = result.stderr[-12000:]
        for secret in [C['db_password'], urllib.parse.quote(C['db_password'], safe='')]:
            message = message.replace(secret, '<redacted>')
        raise RuntimeError('Terraform failed: ' + message)
    return json.loads(result.stdout) if json_output else result.stdout


def check_state_owner():
    path = INFRA / 'terraform.tfstate'
    if not path.exists():
        return
    for resource in json.loads(path.read_text()).get('resources', []):
        if resource.get('mode') != 'managed':
            continue
        for instance in resource.get('instances', []):
            attributes = instance.get('attributes', {})
            tags = attributes.get('tags_all') or attributes.get('tags') or {}
            owner = tags.get('ClearLedgerDeployment')
            if owner and owner != PREFIX:
                raise RuntimeError('Terraform state belongs to another deployment: ' + owner)


def apply():
    tf('init', '-input=false', '-no-color')
    # A saved plan makes the nonreplacement check apply to the actual applied plan.
    for _ in range(2):
        plan = INFRA / '.lifecycle.tfplan'
        tf('plan', '-input=false', '-no-color', '-out=' + str(plan))
        document = tf('show', '-json', str(plan), json_output=True)
        changes = document.get('resource_changes', [])
        for change in changes:
            if change['type'] in {'aws_db_instance', 'aws_dynamodb_table', 'aws_s3_bucket'} and 'delete' in change['change']['actions']:
                raise RuntimeError('Refusing destructive replacement of ' + change['address'])
        if all(x['change']['actions'] == ['no-op'] for x in changes):
            break
        tf('apply', '-input=false', '-no-color', str(plan))
    plan.unlink(missing_ok=True)


def iam_reconcile():
    iam = client('iam')
    for role in ['ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler']:
        name = PREFIX + '-' + role
        if optional(iam.get_role, RoleName=name) is None:
            continue
        for policy in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
            if policy != name + '-canonical':
                iam.delete_role_policy(RoleName=name, PolicyName=policy)
        for policy in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])


def manifest():
    m = tf('output', '-json', 'manifest', json_output=True)
    schema = json.loads(pathlib.Path('/workspace/contracts/schemas/manifest.schema.json').read_text())
    jsonschema.Draft202012Validator(schema).validate(m)
    path = ROOT / '.manifest.tmp'
    path.write_text(json.dumps(m, indent=2) + '\n')
    path.chmod(0o600)
    path.replace(ROOT / 'manifest.json')
    return m


def database(m):
    db = m['database']
    while True:
        try:
            return psycopg.connect(host=db['endpoint'], port=db['port'], dbname=C['db_name'],
                user=C['db_username'], password=C['db_password'], connect_timeout=5,
                autocommit=True, row_factory=dict_row)
        except psycopg.OperationalError:
            remaining()
            time.sleep(2)


def invoke(m, worker, payload=None):
    remaining()
    response = client('lambda').invoke(FunctionName=m['workers'][worker]['function_name'],
        InvocationType='RequestResponse', Payload=json.dumps(payload or {}).encode())
    raw = response['Payload'].read()
    if response.get('FunctionError'):
        raise RuntimeError(worker + ' invocation failed')
    result = json.loads(raw or b'{}')
    if result.get('batchItemFailures'):
        raise RuntimeError(worker + ' rejected authoritative events')
    return result


def schedule_state(name, enabled):
    cli = client('scheduler')
    schedule = cli.get_schedule(Name=name)
    fields = ['Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone',
              'FlexibleTimeWindow', 'Target', 'StartDate', 'EndDate', 'Description', 'KmsKeyArn',
              'ActionAfterCompletion']
    args = {k: schedule[k] for k in fields if k in schedule}
    args['State'] = 'ENABLED' if enabled else 'DISABLED'
    cli.update_schedule(**args)


def mapping_state(uuid, enabled):
    cli = client('lambda')
    cli.update_event_source_mapping(UUID=uuid, Enabled=enabled)
    while cli.get_event_source_mapping(UUID=uuid)['State'] != ('Enabled' if enabled else 'Disabled'):
        remaining()
        time.sleep(1)


@contextlib.contextmanager
def paused(m):
    names = [m['schedules']['outbox_schedule_name'], m['schedules']['archive_schedule_name']]
    try:
        for name in names:
            schedule_state(name, False)
        mapping_state(m['messaging']['event_source_mapping_uuid'], False)
        # Workers have a 3-second timeout; allow already-running invocations to finish.
        time.sleep(4)
        yield
    finally:
        mapping_state(m['messaging']['event_source_mapping_uuid'], True)
        for name in names:
            schedule_state(name, True)


def scan_table(m):
    return {(x['PK']['S'], x['SK']['S']): x for x in pages('dynamodb', 'scan', 'Items',
        TableName=m['projections']['table_name'], ConsistentRead=True)}


def equal_item(a, b):
    if set(a) != set(b):
        return False
    for key in a:
        if key == 'envelope':
            if 'S' in a[key] and 'S' in b[key]:
                if json.loads(a[key]['S']) != json.loads(b[key]['S']):
                    return False
            elif a[key] != b[key]:
                return False
        elif key in {'updated_at', 'occurred_at'}:
            if datetime.datetime.fromisoformat(a[key]['S'].replace('Z', '+00:00')) != datetime.datetime.fromisoformat(b[key]['S'].replace('Z', '+00:00')):
                return False
        elif a[key] != b[key]:
            return False
    return True


def expected_items(settlements, events):
    expected = {}
    by_id = collections.defaultdict(list)
    for e in events:
        by_id[str(e['settlement_id'])].append(e)
        p = e['payload']; d = p['data']; sid = str(e['settlement_id'])
        item = {k: {'S': str(v)} for k, v in {
            'PK': 'SETTLEMENT#' + sid, 'SK': 'EVENT#%08d' % e['aggregate_version'],
            'settlement_id': sid, 'event_id': str(e['event_id']), 'event_type': e['event_type'],
            'status': d['status'], 'clearing_stage': d['clearingStage'],
            'occurred_at': p['occurredAt'], 'correlation_id': e['correlation_id'],
            'envelope': json.dumps(p, separators=(',', ':'), ensure_ascii=False)}.items()}
        item['version'] = {'N': str(e['aggregate_version'])}
        for source, target in [('entryId', 'entry_id'), ('memo', 'memo')]:
            if d.get(source) is not None:
                item[target] = {'S': d[source]}
        expected[(item['PK']['S'], item['SK']['S'])] = item
    for s in settlements:
        sid = str(s['settlement_id']); p = by_id[sid][-1]['payload']
        item = {k: {'S': str(v)} for k, v in {
            'PK': 'SETTLEMENT#' + sid, 'SK': 'STATE', 'GSI1PK': 'ACCOUNT#' + s['account_id'],
            'GSI1SK': 'SETTLEMENT#' + sid, 'settlement_id': sid, 'account_id': s['account_id'],
            'reference': s['reference'], 'debit_party': s['debit_party'], 'credit_party': s['credit_party'],
            'status': s['current_status'], 'clearing_stage': s['current_stage'],
            'updated_at': p['occurredAt']}.items()}
        for k in ['version', 'entry_count']:
            item[k] = {'N': str(s[k])}
        for k in ['last_entry_id', 'last_memo']:
            if s[k] is not None:
                item[k] = {'S': str(s[k])}
        expected[(item['PK']['S'], 'STATE')] = item
    return expected, by_id


def projections(m, settlements, events):
    cli = client('dynamodb'); table = m['projections']['table_name']
    expected, by_id = expected_items(settlements, events)
    actual = scan_table(m)
    damaged = {pk for (pk, sk), value in expected.items() if (pk, sk) not in actual or not equal_item(actual[(pk, sk)], value)}
    for key, item in actual.items():
        if key not in expected or key[0] in damaged:
            cli.delete_item(TableName=table, Key={k: item[k] for k in ['PK', 'SK']})
    for pk in sorted(damaged):
        records = by_id[pk.removeprefix('SETTLEMENT#')]
        for offset in range(0, len(records), 5):
            invoke(m, 'projector', {'Records': [
                {'messageId': str(e['event_id']), 'body': json.dumps(e['payload']),
                 'eventSource': 'aws:sqs', 'eventSourceARN': m['messaging']['queue_arn'],
                 'awsRegion': C['region'], 'attributes': {}, 'messageAttributes': {}}
                for e in records[offset:offset+5]]})
    actual = scan_table(m)
    if set(actual) != set(expected) or any(not equal_item(actual[k], expected[k]) for k in expected):
        raise RuntimeError('Projector output does not match authoritative projection')
    # Invalidation is sufficient: the next API read fills a fresh, 90-second cache entry.
    cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
    for key in cache.scan_iter(match='clearledger:settlement:*', count=500):
        cache.delete(key)
    return len(expected)


def versions(bucket):
    for page in client('s3').get_paginator('list_object_versions').paginate(Bucket=bucket):
        yield from [('version', x) for x in page.get('Versions', [])]
        yield from [('marker', x) for x in page.get('DeleteMarkers', [])]


def purge_versions(bucket, predicate=lambda kind, value: True):
    cli = client('s3')
    objects = [{'Key': x['Key'], 'VersionId': x['VersionId']} for kind, x in versions(bucket) if predicate(kind, x)]
    for offset in range(0, len(objects), 1000):
        result = cli.delete_objects(Bucket=bucket, Delete={'Objects': objects[offset:offset+1000], 'Quiet': True})
        if result.get('Errors'):
            raise RuntimeError('Failed to purge audit object versions')


def archive(m, db):
    bucket = m['audit']['bucket_name']; cli = client('s3')
    rows = db.execute('SELECT * FROM clearledger.outbox ORDER BY seq').fetchall()
    authority = {str(r['event_id']): r for r in rows}; seen = set(); keep = set()
    # Retain valid batches, even when a historical batch has less than 100 rows.
    for obj in sorted(pages('s3', 'list_objects_v2', 'Contents', Bucket=bucket), key=lambda x: x['Key']):
        key = obj['Key']; valid = False; ids = []
        try:
            body = cli.get_object(Bucket=bucket, Key=key)['Body'].read()
            match = re.fullmatch(r'ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson', key)
            payloads = [json.loads(line) for line in body.splitlines()]
            ids = [p['eventId'] for p in payloads]
            seqs = [authority[e]['seq'] for e in ids]
            valid = bool(match and payloads and len(set(ids)) == len(ids) and not seen.intersection(ids)
                and seqs == sorted(set(seqs)) and int(match[1]) == seqs[0] and int(match[2]) == seqs[-1]
                and hashlib.sha256(body).hexdigest()[:16] == match[3]
                and all(p == authority[p['eventId']]['payload'] for p in payloads))
        except (ValueError, KeyError, TypeError):
            valid = False
        if valid:
            keep.add(key); seen.update(ids)
    purge_versions(bucket, lambda kind, x: kind == 'marker' or not x.get('IsLatest') or x['Key'] not in keep)
    missing = set(authority) - seen
    if missing:
        db.execute('UPDATE clearledger.outbox SET archived_at = NULL WHERE event_id = ANY(%s::uuid[])', (list(missing),))
    # Valid archive bodies are authoritative evidence for a previously lost archival stamp.
    if seen:
        db.execute('UPDATE clearledger.outbox SET archived_at = GREATEST(now(),published_at) WHERE archived_at IS NULL AND event_id = ANY(%s::uuid[])', (list(seen),))
    previous = None
    while True:
        count = db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE archived_at IS NULL').fetchone()['n']
        if not count:
            break
        if count == previous:
            raise RuntimeError('Audit archiver made no progress')
        previous = count
        invoke(m, 'audit_archiver')
    purge_versions(bucket, lambda kind, x: kind == 'marker' or not x.get('IsLatest'))
    found = []; all_seq = []
    for obj in pages('s3', 'list_objects_v2', 'Contents', Bucket=bucket):
        body = cli.get_object(Bucket=bucket, Key=obj['Key'])['Body'].read()
        payloads = [json.loads(line) for line in body.splitlines()]
        seqs = [authority[p['eventId']]['seq'] for p in payloads]
        canonical = 'ledger-audit/batch-%08d-%08d-%s.ndjson' % (seqs[0], seqs[-1], hashlib.sha256(body).hexdigest()[:16])
        if obj['Key'] != canonical or seqs != sorted(set(seqs)) or any(p != authority[p['eventId']]['payload'] for p in payloads):
            raise RuntimeError('Noncanonical audit archive')
        found.extend(p['eventId'] for p in payloads); all_seq.extend(seqs)
    if collections.Counter(found) != collections.Counter(authority.keys()):
        raise RuntimeError('Audit archive is not one-to-one with the outbox')
    return len(found)


def ready(m):
    while True:
        remaining()
        try:
            with urllib.request.urlopen(m['service_url'] + '/health/ready', timeout=5) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.HTTPError):
            pass
        time.sleep(2)


def deploy():
    print('Applying ClearLedger infrastructure...', flush=True)
    check_state_owner()
    iam_reconcile()
    apply()
    m = manifest()
    iam_reconcile()
    with database(m) as db:
        db.execute((INFRA / 'schema.sql').read_text())
        print('Schema initialized; reconciling derived stores...', flush=True)
        with paused(m):
            # Block new commits for a consistent recovery cut. Reads and the worker
            # updates on outbox remain available. No committed source rows are removed.
            db.execute('BEGIN')
            db.execute("SET LOCAL lock_timeout = '20s'")
            db.execute('LOCK TABLE clearledger.settlements, clearledger.events, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
            try:
                previous = None
                while True:
                    count = db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL').fetchone()['n']
                    if not count:
                        break
                    if previous == count:
                        raise RuntimeError('Outbox relay made no progress')
                    previous = count
                    invoke(m, 'outbox_relay')
                settlements = db.execute('SELECT * FROM clearledger.settlements ORDER BY settlement_id').fetchall()
                events = db.execute('SELECT * FROM clearledger.events ORDER BY settlement_id,aggregate_version').fetchall()
                items = projections(m, settlements, events)
                # Reset archival stamps in a separate connection so the unchanged
                # pre-built archiver can see and update them while the cut is held.
                with database(m) as operational:
                    records = archive(m, operational)
                db.execute('COMMIT')
            except BaseException:
                db.execute('ROLLBACK')
                raise
    ready(m)
    print('ClearLedger ready: %s (%d projection items, %d audit events)' % (m['service_url'], items, records), flush=True)


def remove_role(name):
    iam = client('iam')
    if iam.get_role(RoleName=name)['Role'].get('PermissionsBoundary'):
        iam.delete_role_permissions_boundary(RoleName=name)
    for policy in list(pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name)):
        iam.detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])
    for policy in list(pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name)):
        iam.delete_role_policy(RoleName=name, PolicyName=policy)
    for profile in list(pages('iam', 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name)):
        iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
        if scoped(profile['InstanceProfileName'], profile.get('Tags', [])):
            iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
    iam.delete_role(RoleName=name)


def cleanup_iam(destroy_roles=False):
    iam = client('iam')
    canonical = {PREFIX + '-' + x for x in ['ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler']}
    for role in list(pages('iam', 'list_roles', 'Roles')):
        name = role['RoleName']
        tags = role.get('Tags', []) or iam.list_role_tags(RoleName=name).get('Tags', [])
        if scoped(name, tags):
            if destroy_roles or name not in canonical:
                remove_role(name)
            else:
                for policy in list(pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name)):
                    iam.detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])
    for policy in list(pages('iam', 'list_policies', 'Policies', Scope='Local')):
        arn = policy['Arn']; tags = iam.list_policy_tags(PolicyArn=arn).get('Tags', [])
        if not scoped(policy['PolicyName'], tags):
            continue
        for usage in ['PermissionsPolicy', 'PermissionsBoundary']:
            entities = iam.list_entities_for_policy(PolicyArn=arn, PolicyUsageFilter=usage)
            for role in entities.get('PolicyRoles', []):
                if usage == 'PermissionsBoundary':
                    iam.delete_role_permissions_boundary(RoleName=role['RoleName'])
                else:
                    iam.detach_role_policy(RoleName=role['RoleName'], PolicyArn=arn)
            for user in entities.get('PolicyUsers', []):
                if usage == 'PermissionsBoundary':
                    iam.delete_user_permissions_boundary(UserName=user['UserName'])
                else:
                    iam.detach_user_policy(UserName=user['UserName'], PolicyArn=arn)
            for group in entities.get('PolicyGroups', []):
                iam.detach_group_policy(GroupName=group['GroupName'], PolicyArn=arn)
        for version in iam.list_policy_versions(PolicyArn=arn)['Versions']:
            if not version['IsDefaultVersion']:
                iam.delete_policy_version(PolicyArn=arn, VersionId=version['VersionId'])
        iam.delete_policy(PolicyArn=arn)


def cleanup_operational(before=False):
    # All inventory decisions use a deployment prefix boundary or ownership tag.
    sched = client('scheduler')
    for schedule in list(pages('scheduler', 'list_schedules', 'Schedules')):
        name = schedule['Name']
        if scoped(name):
            sched.delete_schedule(Name=name, GroupName=schedule.get('GroupName', 'default'))
    # Delete queues before Terraform's refresh. The local SQS deletion waiter
    # can otherwise consume its full timeout after the queue is already absent.
    sqs = client('sqs')
    for url in list(pages('sqs', 'list_queues', 'QueueUrls')):
        tags = optional(sqs.list_queue_tags, QueueUrl=url)
        if scoped(url.rsplit('/', 1)[-1], (tags or {}).get('Tags', {})):
            optional(sqs.delete_queue, QueueUrl=url)
    s3 = client('s3')
    for bucket in s3.list_buckets()['Buckets']:
        name = bucket['Name']
        try:
            tags = s3.get_bucket_tagging(Bucket=name).get('TagSet', [])
        except ClientError as exc:
            if exc.response['Error']['Code'] not in {'NoSuchTagSet', 'NoSuchBucket'}:
                raise
            tags = []
        if scoped(name, tags):
            purge_versions(name)
            objects = [{'Key': x['Key']} for x in pages('s3', 'list_objects_v2', 'Contents', Bucket=name)]
            for offset in range(0, len(objects), 1000):
                s3.delete_objects(Bucket=name, Delete={'Objects': objects[offset:offset+1000]})
            if not before:
                s3.delete_bucket(Bucket=name)
    cleanup_iam(destroy_roles=not before)
    if before:
        return
    ddb = client('dynamodb')
    for name in list(pages('dynamodb', 'list_tables', 'TableNames')):
        table = ddb.describe_table(TableName=name)['Table']
        tags = ddb.list_tags_of_resource(ResourceArn=table['TableArn']).get('Tags', [])
        if scoped(name, tags):
            optional(ddb.delete_table, TableName=name)
    sqs = client('sqs')
    for url in list(pages('sqs', 'list_queues', 'QueueUrls')):
        tags = optional(sqs.list_queue_tags, QueueUrl=url)
        if scoped(url.rsplit('/', 1)[-1], (tags or {}).get('Tags', {})):
            optional(sqs.delete_queue, QueueUrl=url)
    logs = client('logs')
    for group in list(pages('logs', 'describe_log_groups', 'logGroups')):
        name = group['logGroupName']
        tags = logs.list_tags_log_group(logGroupName=name).get('tags', {})
        if scoped(name, tags):
            logs.delete_log_group(logGroupName=name)
    kms = client('kms'); key_ids = set()
    aliases = list(pages('kms', 'list_aliases', 'Aliases'))
    deleted_aliases = set()
    for alias in aliases:
        if scoped(alias['AliasName'].removeprefix('alias/')):
            if alias.get('TargetKeyId'):
                key_ids.add(alias['TargetKeyId'])
            kms.delete_alias(AliasName=alias['AliasName'])
            deleted_aliases.add(alias['AliasName'])
    for key in list(pages('kms', 'list_keys', 'Keys')):
        metadata = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        if metadata.get('KeyManager') != 'CUSTOMER':
            continue
        tags = kms.list_resource_tags(KeyId=key['KeyId']).get('Tags', [])
        tags = [{'Key': t['TagKey'], 'Value': t['TagValue']} for t in tags]
        if key['KeyId'] in key_ids or scoped(metadata.get('Description', ''), tags):
            for alias in aliases:
                if alias.get('TargetKeyId') == key['KeyId'] and alias['AliasName'] not in deleted_aliases and not alias['AliasName'].startswith('alias/aws/'):
                    kms.delete_alias(AliasName=alias['AliasName'])
                    deleted_aliases.add(alias['AliasName'])
            if metadata.get('KeyState') != 'PendingDeletion':
                kms.schedule_key_deletion(KeyId=key['KeyId'], PendingWindowInDays=10)
    # Additional worker functions/mappings and schedule groups from operational drills.
    lam = client('lambda')
    for function in list(pages('lambda', 'list_functions', 'Functions')):
        tags = lam.list_tags(Resource=function['FunctionArn']).get('Tags', {})
        if scoped(function['FunctionName'], tags):
            for mapping in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings', FunctionName=function['FunctionName']):
                optional(lam.delete_event_source_mapping, UUID=mapping['UUID'])
            lam.delete_function(FunctionName=function['FunctionName'])
    for group in list(pages('scheduler', 'list_schedule_groups', 'ScheduleGroups')):
        if scoped(group['Name']):
            sched.delete_schedule_group(Name=group['Name'])


def destroy():
    print('Removing prefix-scoped operational attachments and archive versions...', flush=True)
    check_state_owner()
    iam_reconcile()
    ownership_path = ROOT / '.ownership.json'
    owned_vpcs = set()
    if ownership_path.exists():
        receipt = json.loads(ownership_path.read_text())
        if receipt.get('resource_prefix') == PREFIX:
            owned_vpcs.update(receipt.get('vpc_ids', []))
    manifest_path = ROOT / 'manifest.json'
    if manifest_path.exists():
        old_manifest = json.loads(manifest_path.read_text())
        if old_manifest.get('resource_prefix') == PREFIX:
            owned_vpcs.add(old_manifest['network']['vpc_id'])
    for vpc in client('ec2').describe_vpcs()['Vpcs']:
        if scoped(vpc['VpcId'], vpc.get('Tags', [])):
            owned_vpcs.add(vpc['VpcId'])
    ownership_path.write_text(json.dumps({'resource_prefix': PREFIX, 'vpc_ids': sorted(owned_vpcs)}))
    cleanup_operational(before=True)
    tf('init', '-input=false', '-no-color')
    tf('destroy', '-auto-approve', '-input=false', '-no-color')
    cleanup_operational()
    # The local control plane retains automatically generated default VPC
    # objects after DeleteVpc. Only clean objects from our recorded, gone VPCs.
    ec2 = client('ec2')
    existing_vpcs = {v['VpcId'] for v in ec2.describe_vpcs()['Vpcs']}
    gone_vpcs = owned_vpcs - existing_vpcs
    for group in ec2.describe_security_groups()['SecurityGroups']:
        if group.get('VpcId') in gone_vpcs and not group['GroupName'].startswith('cl-base-'):
            ec2.delete_security_group(GroupId=group['GroupId'])
    for table in ec2.describe_route_tables()['RouteTables']:
        if table.get('VpcId') in gone_vpcs:
            ec2.delete_route_table(RouteTableId=table['RouteTableId'])
    state = json.loads((INFRA / 'terraform.tfstate').read_text())
    if any(r.get('mode') == 'managed' and r.get('instances') for r in state.get('resources', [])):
        raise RuntimeError('Managed resources remain in Terraform state')
    print('ClearLedger teardown complete for ' + PREFIX, flush=True)


if __name__ == '__main__':
    try:
        {'deploy': deploy, 'destroy': destroy}[sys.argv[1]]()
    except Exception as error:
        message = str(error).replace(C['db_password'], '<redacted>')
        print('ClearLedger lifecycle failed: ' + message, file=sys.stderr)
        sys.exit(1)
