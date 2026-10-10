#!/usr/bin/env python3
"""Lifecycle repair operations; resource creation is exclusively Terraform-owned."""
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
import psycopg2
import psycopg2.extras
import redis

ROOT = Path(__file__).resolve().parent
C = json.loads(Path('/workspace/config/config.json').read_text())
P = C['resource_prefix']
if P.startswith('cl-base-') or not re.fullmatch(r'[a-z][a-z0-9-]{3,23}', P):
    raise RuntimeError('Invalid or baseline deployment prefix')
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])
CLIENTS = {}


def client(service):
    if service not in CLIENTS:
        CLIENTS[service] = SESSION.client(service, endpoint_url=C['aws_endpoint_url'],
            config=Config(retries={'max_attempts': 5, 'mode': 'standard'}, connect_timeout=5, read_timeout=70,
                          s3={'addressing_style': 'path'}))
    return CLIENTS[service]


def pages(service, operation, key, **args):
    c = client(service)
    if c.can_paginate(operation):
        return [x for page in c.get_paginator(operation).paginate(**args) for x in page.get(key, [])]
    return getattr(c, operation)(**args).get(key, [])


def optional(call, **args):
    try:
        return call(**args)
    except ClientError as e:
        if e.response['Error']['Code'] in ('NoSuchEntity', 'ResourceNotFoundException', 'ResourceNotFound',
                'QueueDoesNotExist', 'AWS.SimpleQueueService.NonExistentQueue', 'NoSuchBucket', 'NotFoundException',
                'DBInstanceNotFound', 'ReplicationGroupNotFoundFault', 'CacheClusterNotFound', 'InvalidGroup.NotFound', 'NoSuchTagSet'):
            return None
        raise


def scoped(name, tags=None):
    if name.startswith('cl-base-') or name.startswith('/clearledger/cl-base-') or name.startswith('alias/cl-base-'):
        return False
    if isinstance(tags, list):
        tags = {x.get('Key', x.get('TagKey')): x.get('Value', x.get('TagValue')) for x in tags}
    return (name == P or name.startswith(P + '-') or name.startswith('/clearledger/' + P + '/')
            or name == '/clearledger/' + P or name.startswith('alias/' + P + '-')
            or (tags or {}).get('ClearLedgerDeployment') == P)


def manifest():
    return json.loads((ROOT / 'manifest.json').read_text())


def db(m):
    d = m['database']
    return psycopg2.connect(host=d['endpoint'], port=d['port'], dbname=C['db_name'], user=C['db_username'],
                           password=C['db_password'], connect_timeout=5)


def clean_role(name, keep_canonical=False):
    iam = client('iam')
    role = optional(iam.get_role, RoleName=name)
    if role and role['Role'].get('PermissionsBoundary'):
        iam.delete_role_permissions_boundary(RoleName=name)
    for policy in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
        if not keep_canonical or policy != P + '-canonical':
            iam.delete_role_policy(RoleName=name, PolicyName=policy)
    for attached in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
        iam.detach_role_policy(RoleName=name, PolicyArn=attached['PolicyArn'])
    for profile in pages('iam', 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
        iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
        if scoped(profile['InstanceProfileName'], profile.get('Tags')):
            iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])


def preflight():
    state = ROOT / 'infra/terraform.tfstate'
    if state.exists():
        s = json.loads(state.read_text())
        old = s.get('outputs', {}).get('manifest', {}).get('value', {}).get('resource_prefix')
        if old and old != P and s.get('resources'):
            raise RuntimeError('Active state belongs to another deployment prefix')
    iam = client('iam')
    for suffix in ('ecs-execution', 'ecs-task', 'projector', 'relay', 'archiver', 'scheduler'):
        name = P + '-' + suffix
        if optional(iam.get_role, RoleName=name):
            clean_role(name, keep_canonical=True)
    ec2 = client('ec2')
    groups = ec2.describe_security_groups(Filters=[{'Name': 'tag:ClearLedgerDeployment', 'Values': [P]}])['SecurityGroups']
    for g in groups:
        if g['GroupName'] not in [P + '-' + x for x in ('alb', 'rds', 'valkey')]:
            continue
        for rule in g.get('IpPermissionsEgress', []):
            bad4 = [r for r in rule.get('IpRanges', []) if r['CidrIp'] == '0.0.0.0/0']
            bad6 = [r for r in rule.get('Ipv6Ranges', []) if r['CidrIpv6'] == '::/0']
            if bad4 or bad6:
                revoke = {k: v for k, v in rule.items() if k in ('IpProtocol', 'FromPort', 'ToPort')}
                revoke.update(IpRanges=bad4, Ipv6Ranges=bad6)
                ec2.revoke_security_group_egress(GroupId=g['GroupId'], IpPermissions=[revoke])


def invoke(m, worker, payload=None):
    r = client('lambda').invoke(FunctionName=m['workers'][worker]['function_name'],
                               InvocationType='RequestResponse', Payload=json.dumps(payload or {}).encode())
    body = r['Payload'].read()
    if r.get('FunctionError'):
        # Worker error bodies may contain credentials; report only the function name.
        raise RuntimeError('Worker invocation failed: ' + worker)
    return json.loads(body) if body else {}


def sql_rows(conn, sql, args=None):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, args)
        return [dict(r) for r in cur.fetchall()]


def scalar(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchone()[0]


def drain(m, conn, column, worker):
    where = 'published_at IS NULL' if column == 'published_at' else 'published_at IS NOT NULL AND archived_at IS NULL'
    deadline = time.monotonic() + 180
    while scalar(conn, 'SELECT count(*) FROM clearledger.outbox WHERE ' + where):
        conn.commit()
        invoke(m, worker)
        if time.monotonic() > deadline:
            raise RuntimeError('Timed out draining ' + worker)
    conn.commit()


def attr_item(values):
    return {k: ({'N': str(v)} if isinstance(v, int) else {'S': v}) for k, v in values.items() if v is not None}


def expected_projection(settlements, events):
    expected = {}
    latest = {}
    for e in events:
        p = e['payload']; d = p['data']; sid = str(e['settlement_id']); v = e['aggregate_version']
        vals = {'PK': 'SETTLEMENT#' + sid, 'SK': f'EVENT#{v:08d}', 'settlement_id': sid,
                'event_id': str(e['event_id']), 'version': v, 'event_type': e['event_type'],
                'status': d['status'], 'clearing_stage': d['clearingStage'], 'occurred_at': p['occurredAt'],
                'correlation_id': e['correlation_id'], 'envelope': json.dumps(p, separators=(',', ':'), ensure_ascii=False),
                'entry_id': d.get('entryId'), 'memo': d.get('memo')}
        expected[(vals['PK'], vals['SK'])] = attr_item(vals)
        latest[sid] = p
    for s in settlements:
        sid = str(s['settlement_id']); p = latest[sid]
        vals = {'PK': 'SETTLEMENT#' + sid, 'SK': 'STATE', 'GSI1PK': 'ACCOUNT#' + s['account_id'],
                'GSI1SK': 'SETTLEMENT#' + sid, 'settlement_id': sid, 'account_id': s['account_id'],
                'reference': s['reference'], 'debit_party': s['debit_party'], 'credit_party': s['credit_party'],
                'status': s['current_status'], 'clearing_stage': s['current_stage'], 'version': s['version'],
                'entry_count': s['entry_count'], 'updated_at': p['occurredAt'],
                'last_entry_id': str(s['last_entry_id']) if s['last_entry_id'] else None, 'last_memo': s['last_memo']}
        expected[(vals['PK'], vals['SK'])] = attr_item(vals)
    return expected


def equivalent(actual, expected):
    if set(actual) != set(expected):
        return False
    for k in expected:
        if k == 'envelope':
            try:
                if json.loads(actual[k]['S']) != json.loads(expected[k]['S']):
                    return False
            except (KeyError, ValueError):
                return False
        elif actual[k] != expected[k]:
            return False
    return True


def projections(m, conn):
    # Briefly block settlement writers while repairing a consistent authoritative snapshot.
    # Projector writes are append-only / monotonic and cannot regress the repaired snapshot.
    with conn.cursor() as cur:
        cur.execute("SET LOCAL lock_timeout = '20s'")
        cur.execute('LOCK TABLE clearledger.settlements IN SHARE MODE')
    ss = sql_rows(conn, 'SELECT * FROM clearledger.settlements ORDER BY settlement_id')
    es = sql_rows(conn, 'SELECT * FROM clearledger.events ORDER BY settlement_id, aggregate_version')
    expected = expected_projection(ss, es)
    dynamo = client('dynamodb'); table = m['projections']['table_name']
    actual = pages('dynamodb', 'scan', 'Items', TableName=table, ConsistentRead=True)
    for item in actual:
        key = (item['PK']['S'], item['SK']['S'])
        if key not in expected:
            dynamo.delete_item(TableName=table, Key={k: item[k] for k in ('PK', 'SK')})
    indexed = {(i['PK']['S'], i['SK']['S']): i for i in actual}
    for key, item in expected.items():
        if not equivalent(indexed.get(key, {}), item):
            dynamo.put_item(TableName=table, Item=item)
    # Invalidation is safer than retaining potentially stale cached state during recovery.
    cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
    for key in cache.scan_iter(match='clearledger:settlement:*', count=500):
        cache.delete(key)
    verify = pages('dynamodb', 'scan', 'Items', TableName=table, ConsistentRead=True)
    if len(verify) != len(expected) or any(not equivalent(i, expected.get((i['PK']['S'], i['SK']['S']), {})) for i in verify):
        raise RuntimeError('Projection verification failed')
    conn.commit()


def versions(bucket):
    s3 = client('s3')
    result = []
    for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
        result.extend(dict(x, marker=False) for x in page.get('Versions', []))
        result.extend(dict(x, marker=True) for x in page.get('DeleteMarkers', []))
    return result


def delete_versions(bucket, items):
    for start in range(0, len(items), 1000):
        batch = items[start:start+1000]
        if not batch:
            continue
        result = client('s3').delete_objects(Bucket=bucket, Delete={'Objects': [
            {'Key': x['Key'], 'VersionId': x['VersionId']} for x in batch], 'Quiet': True})
        if result.get('Errors'):
            raise RuntimeError('Unable to purge audit object versions')


def inspect_archive(m, rows):
    bucket = m['audit']['bucket_name']; s3 = client('s3')
    by_id = {str(r['event_id']): r for r in rows}
    seen = set(); bad_keys = set(); all_versions = versions(bucket)
    # Stable ordering makes duplicate batch selection deterministic.
    current = sorted([x for x in all_versions if x['IsLatest'] and not x['marker']], key=lambda x: x['Key'])
    for obj in current:
        key = obj['Key']; ids = []
        try:
            match = re.fullmatch(r'ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson', key)
            if not match:
                raise ValueError('key')
            raw = s3.get_object(Bucket=bucket, Key=key, VersionId=obj['VersionId'])['Body'].read()
            if hashlib.sha256(raw).hexdigest()[:16] != match[3]:
                raise ValueError('digest')
            payloads = [json.loads(line) for line in raw.splitlines()]
            seqs = []
            for payload in payloads:
                eid = payload['eventId']; row = by_id[eid]
                if payload != row['payload'] or row['published_at'] is None or eid in seen or eid in ids:
                    raise ValueError('content or duplicate')
                ids.append(eid); seqs.append(row['seq'])
            if not seqs or seqs != sorted(set(seqs)) or seqs[0] != int(match[1]) or seqs[-1] != int(match[2]):
                raise ValueError('order')
            seen.update(ids)
        except (ValueError, KeyError, TypeError):
            bad_keys.add(key)
    delete_versions(bucket, [x for x in all_versions if x['marker'] or not x['IsLatest'] or x['Key'] in bad_keys])
    return seen


def audit(m, conn):
    # Relay first, preserve valid batches, remove corruption and all historical versions,
    # then reset only missing archival markers and let the original archiver regenerate.
    for attempt in range(4):
        rows = sql_rows(conn, 'SELECT * FROM clearledger.outbox ORDER BY seq')
        seen = inspect_archive(m, rows)
        with conn.cursor() as cur:
            missing = [r['seq'] for r in rows if str(r['event_id']) not in seen]
            if missing:
                cur.execute('UPDATE clearledger.outbox SET archived_at=NULL WHERE seq=ANY(%s) AND archived_at IS NOT NULL', (missing,))
            present = [r['seq'] for r in rows if str(r['event_id']) in seen and r['archived_at'] is None]
            if present:
                cur.execute('UPDATE clearledger.outbox SET archived_at=GREATEST(now(),published_at) WHERE seq=ANY(%s) AND archived_at IS NULL', (present,))
        conn.commit()
        drain(m, conn, 'published_at', 'outbox_relay')
        drain(m, conn, 'archived_at', 'audit_archiver')
        rows = sql_rows(conn, 'SELECT * FROM clearledger.outbox ORDER BY seq')
        seen = inspect_archive(m, rows)
        conn.commit()
        if seen == {str(r['event_id']) for r in rows} and all(r['archived_at'] is not None for r in rows):
            return
    raise RuntimeError('Audit convergence failed')


def reconcile():
    m = manifest()
    with db(m) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_lock(hashtext('clearledger-recovery'))")
        conn.commit()
        drain(m, conn, 'published_at', 'outbox_relay')
        audit(m, conn)
        projections(m, conn)
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_unlock(hashtext('clearledger-recovery'))")
        conn.commit()
    print('PostgreSQL, projections, cache and versioned audit archive reconciled.')


def ready():
    url = manifest()['service_url'] + '/health/ready'
    end = time.monotonic() + 180
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    print('ClearLedger is ready: ' + manifest()['service_url'])
                    return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(2)
    raise RuntimeError('API readiness timed out')


def teardown_prepare():
    preflight()
    iam = client('iam')
    for role in pages('iam', 'list_roles', 'Roles'):
        tags = iam.list_role_tags(RoleName=role['RoleName']).get('Tags', [])
        if scoped(role['RoleName'], tags):
            clean_role(role['RoleName'], keep_canonical=True)
    # Stop schedules before bucket cleanup; Terraform still tracks the same schedules.
    scheduler = client('scheduler')
    for sched in pages('scheduler', 'list_schedules', 'Schedules'):
        if scoped(sched['Name']):
            scheduler.delete_schedule(Name=sched['Name'], GroupName=sched.get('GroupName', 'default'))
    s3 = client('s3')
    for b in s3.list_buckets().get('Buckets', []):
        tags = optional(s3.get_bucket_tagging, Bucket=b['Name']) if not b['Name'].startswith('cl-base-') else None
        if scoped(b['Name'], (tags or {}).get('TagSet', [])):
            delete_versions(b['Name'], versions(b['Name']))


def teardown():
    # Clean prefix/tag-scoped operational resources absent from Terraform state.
    scheduler = client('scheduler')
    for sched in pages('scheduler', 'list_schedules', 'Schedules'):
        if scoped(sched['Name']):
            optional(scheduler.delete_schedule, Name=sched['Name'], GroupName=sched.get('GroupName', 'default'))
    for group in pages('scheduler', 'list_schedule_groups', 'ScheduleGroups'):
        if scoped(group['Name']):
            optional(scheduler.delete_schedule_group, Name=group['Name'])
    lamb = client('lambda')
    for f in pages('lambda', 'list_functions', 'Functions'):
        tags = lamb.list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if scoped(f['FunctionName'], tags):
            for mapping in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                optional(lamb.delete_event_source_mapping, UUID=mapping['UUID'])
            optional(lamb.delete_function, FunctionName=f['FunctionName'])
    sqs = client('sqs')
    for url in pages('sqs', 'list_queues', 'QueueUrls'):
        tags = sqs.list_queue_tags(QueueUrl=url).get('Tags', {})
        if scoped(url.rsplit('/',1)[-1], tags):
            optional(sqs.delete_queue, QueueUrl=url)
    ddb = client('dynamodb')
    for name in pages('dynamodb', 'list_tables', 'TableNames'):
        info = ddb.describe_table(TableName=name)['Table']
        tags = ddb.list_tags_of_resource(ResourceArn=info['TableArn']).get('Tags', [])
        if scoped(name, tags):
            optional(ddb.delete_table, TableName=name)
    s3 = client('s3')
    for bucket in s3.list_buckets().get('Buckets', []):
        name = bucket['Name']
        if name.startswith('cl-base-'):
            continue
        try:
            tags = s3.get_bucket_tagging(Bucket=name).get('TagSet', [])
        except ClientError as e:
            if e.response['Error']['Code'] != 'NoSuchTagSet':
                raise
            tags = []
        if scoped(name, tags):
            delete_versions(name, versions(name))
            for upload in pages('s3', 'list_multipart_uploads', 'Uploads', Bucket=name):
                s3.abort_multipart_upload(Bucket=name, Key=upload['Key'], UploadId=upload['UploadId'])
            s3.delete_bucket(Bucket=name)
    iam = client('iam')
    for role in pages('iam', 'list_roles', 'Roles'):
        name = role['RoleName']; tags = iam.list_role_tags(RoleName=name).get('Tags', [])
        if scoped(name, tags):
            clean_role(name)
            iam.delete_role(RoleName=name)
    for policy in pages('iam', 'list_policies', 'Policies', Scope='Local'):
        arn = policy['Arn']; tags = iam.list_policy_tags(PolicyArn=arn).get('Tags', [])
        if scoped(policy['PolicyName'], tags):
            entities = iam.list_entities_for_policy(PolicyArn=arn)
            for role in entities.get('PolicyRoles', []):
                # A scoped operational policy must not remain attached to any role.
                iam.detach_role_policy(RoleName=role['RoleName'], PolicyArn=arn)
            for user in entities.get('PolicyUsers', []):
                iam.detach_user_policy(UserName=user['UserName'], PolicyArn=arn)
            for group in entities.get('PolicyGroups', []):
                iam.detach_group_policy(GroupName=group['GroupName'], PolicyArn=arn)
            for v in iam.list_policy_versions(PolicyArn=arn)['Versions']:
                if not v['IsDefaultVersion']:
                    iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
            iam.delete_policy(PolicyArn=arn)
    logs = client('logs')
    for group in pages('logs', 'describe_log_groups', 'logGroups'):
        if group['logGroupName'].startswith('/clearledger/cl-base-'):
            continue
        tags = logs.list_tags_log_group(logGroupName=group['logGroupName']).get('tags', {})
        if scoped(group['logGroupName'], tags):
            logs.delete_log_group(logGroupName=group['logGroupName'])
    kms = client('kms'); selected = set()
    for alias in pages('kms', 'list_aliases', 'Aliases'):
        if scoped(alias['AliasName']):
            if alias.get('TargetKeyId'):
                selected.add(alias['TargetKeyId'])
            kms.delete_alias(AliasName=alias['AliasName'])
    for key in pages('kms', 'list_keys', 'Keys'):
        meta = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        if meta.get('KeyManager') != 'CUSTOMER':
            continue
        tags = kms.list_resource_tags(KeyId=key['KeyId']).get('Tags', [])
        if key['KeyId'] in selected or scoped(meta.get('Description',''), tags):
            if meta['KeyState'] != 'PendingDeletion':
                kms.schedule_key_deletion(KeyId=key['KeyId'], PendingWindowInDays=10)
    print('Prefix-scoped operational resources cleaned up.')


def main():
    mode = sys.argv[1]
    if mode == 'preflight':
        preflight()
    elif mode == 'guard-plan':
        plan = json.loads((ROOT/'infra/deployment.plan.json').read_text())
        for change in plan.get('resource_changes', []):
            if change['type'] in ('aws_db_instance','aws_dynamodb_table','aws_s3_bucket') and 'delete' in change['change']['actions']:
                raise RuntimeError('Deployment refuses destructive replacement of durable data store: ' + change['address'])
    elif mode == 'clean-plan':
        for name in ('deployment.plan', 'deployment.plan.json'):
            (ROOT/'infra'/name).unlink(missing_ok=True)
    elif mode == 'manifest':
        data = json.loads((ROOT/'manifest.json.tmp').read_text())
        schema = json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text())
        jsonschema.Draft202012Validator(schema).validate(data)
        if (ROOT/'manifest.json.tmp').stat().st_size > 1024*1024:
            raise RuntimeError('Manifest size limit exceeded')
    elif mode == 'schema':
        m = manifest(); end = time.monotonic()+120
        while True:
            try:
                conn = db(m)
                break
            except psycopg2.OperationalError:
                if time.monotonic() > end:
                    raise RuntimeError('PostgreSQL did not become available') from None
                time.sleep(2)
        try:
            with conn.cursor() as cur:
                cur.execute((ROOT/'schema.sql').read_text())
            conn.commit()
        finally:
            conn.close()
    elif mode == 'reconcile':
        reconcile()
    elif mode == 'ready':
        ready()
    elif mode == 'teardown-prepare':
        teardown_prepare()
    elif mode == 'teardown':
        teardown()
    elif mode == 'empty-state':
        state = json.loads((ROOT/'infra/terraform.tfstate').read_text())
        if any(r.get('mode') == 'managed' and r.get('instances') for r in state.get('resources', [])):
            raise RuntimeError('Managed resources remain in Terraform state')
        print('Terraform state has zero managed resources.')
    else:
        raise RuntimeError('Unknown operation')


if __name__ == '__main__':
    main()
