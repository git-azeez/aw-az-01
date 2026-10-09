#!/usr/bin/env python3
"""Operational reconciliation only: cloud resource creation belongs to Terraform."""
import sys
import subprocess

if __name__ == '__main__' and sys.argv[1] == 'dependencies':
    try:
        import boto3, psycopg2, redis, jsonschema
    except ImportError:
        subprocess.run([sys.executable, '-m', 'pip', 'install', '--user', '--break-system-packages',
                        'boto3', 'psycopg2-binary', 'redis', 'jsonschema'], check=True)
    sys.exit(0)

import json
import time
import hashlib
import re
import urllib.request
from pathlib import Path
from datetime import datetime
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import psycopg2
import psycopg2.extras
import redis
import jsonschema
from boto3.dynamodb.types import TypeDeserializer, TypeSerializer

ROOT = Path(__file__).resolve().parent
C = json.loads(Path('/workspace/config/config.json').read_text())
PREFIX = C['resource_prefix']
if PREFIX.startswith('cl-base-') or len(PREFIX) < 4:
    raise RuntimeError('invalid deployment prefix')
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])

def client(service):
    return SESSION.client(service, endpoint_url=C['aws_endpoint_url'], config=Config(
        retries={'max_attempts': 5, 'mode': 'standard'}, connect_timeout=5, read_timeout=65,
        s3={'addressing_style': 'path'}))

def pages(c, op, key, **args):
    if c.can_paginate(op):
        for page in c.get_paginator(op).paginate(**args):
            yield from page.get(key, [])
    else:
        yield from getattr(c, op)(**args).get(key, [])

def missing_call(fn, **kwargs):
    try:
        return fn(**kwargs)
    except ClientError as e:
        if e.response['Error']['Code'] in ('NoSuchEntity', 'ResourceNotFoundException', 'ResourceNotFound',
                'NoSuchBucket', 'AWS.SimpleQueueService.NonExistentQueue', 'QueueDoesNotExist', 'NotFoundException'):
            return None
        raise

def scoped(name, tags=None):
    if name.startswith('cl-base-') or '/cl-base-' in name or name.startswith('alias/cl-base-'):
        return False
    tags = tags or []
    if isinstance(tags, dict):
        tags = [{'Key': k, 'Value': v} for k, v in tags.items()]
    return name == PREFIX or name.startswith(PREFIX + '-') or name.startswith('alias/' + PREFIX + '-') or name.startswith('/clearledger/' + PREFIX + '/') or ('/' + PREFIX + '-') in name or any(t.get('Key', t.get('TagKey', t.get('key'))) == 'ClearLedgerDeployment' and t.get('Value', t.get('TagValue', t.get('value'))) == PREFIX for t in tags)

def policies(all_roles=False):
    iam = client('iam')
    for r in pages(iam, 'list_roles', 'Roles'):
        name = r['RoleName']
        tags = iam.list_role_tags(RoleName=name).get('Tags', [])
        if not scoped(name, tags):
            continue
        if not all_roles and name not in [PREFIX + '-' + k for k in ['ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler']]:
            continue
        for p in pages(iam, 'list_role_policies', 'PolicyNames', RoleName=name):
            if all_roles or p != PREFIX + '-canonical':
                iam.delete_role_policy(RoleName=name, PolicyName=p)
        for p in pages(iam, 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=p['PolicyArn'])

def manifest():
    m = json.loads(subprocess.check_output(['terraform', '-chdir=' + str(ROOT / 'infra'), 'output', '-json', 'manifest']))
    jsonschema.validate(m, json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text()))
    temp = ROOT / 'manifest.json.tmp'
    temp.write_text(json.dumps(m, indent=2) + '\n')
    temp.chmod(0o600)
    temp.replace(ROOT / 'manifest.json')

def load():
    m = json.loads((ROOT / 'manifest.json').read_text())
    if m['resource_prefix'] != PREFIX:
        raise RuntimeError('manifest prefix mismatch')
    return m

def db(m):
    d = m['database']
    return psycopg2.connect(host=d['endpoint'], port=d['port'], dbname=C['db_name'],
                            user=C['db_username'], password=C['db_password'], connect_timeout=5)

def migrate():
    deadline = time.monotonic() + 120
    while True:
        try:
            conn = db(load())
            break
        except psycopg2.OperationalError:
            if time.monotonic() > deadline:
                raise
            time.sleep(2)
    with conn:
        with conn.cursor() as cur:
            cur.execute((ROOT / 'schema.sql').read_text())
    conn.close()
    print('PostgreSQL schema and invariants initialized.')

def ready():
    url = load()['service_url'] + '/health/ready'
    deadline = time.monotonic() + 150
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    print('API readiness: HTTP 200')
                    return
        except (OSError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError('API did not become ready: ' + url)

def invoke(m, worker, payload=None):
    r = client('lambda').invoke(FunctionName=m['workers'][worker]['function_name'],
        InvocationType='RequestResponse', Payload=json.dumps(payload or {}).encode())
    body = r['Payload'].read()
    if r.get('FunctionError'):
        raise RuntimeError(worker + ' invocation failed: ' + body.decode()[:1000])
    value = json.loads(body or b'{}')
    if isinstance(value, dict) and value.get('batchItemFailures'):
        raise RuntimeError(worker + ' failed records')
    return value

def query(conn, sql, args=()):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, args)
        return cur.fetchall()

def update(conn, sql, args=()):
    with conn.cursor() as cur:
        cur.execute(sql, args)

def drain(m, conn, worker, predicate):
    deadline = time.monotonic() + 180
    while query(conn, 'SELECT count(*) AS n FROM clearledger.outbox WHERE ' + predicate)[0]['n']:
        invoke(m, worker)
        if time.monotonic() > deadline:
            raise RuntimeError(worker + ' backlog did not drain')

def wait_queue(m):
    sqs = client('sqs'); deadline = time.monotonic() + 120; empty = 0
    while time.monotonic() < deadline:
        a = sqs.get_queue_attributes(QueueUrl=m['messaging']['queue_url'], AttributeNames=[
            'ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', 'ApproximateNumberOfMessagesDelayed'])['Attributes']
        empty = empty + 1 if all(int(v) == 0 for v in a.values()) else 0
        if empty >= 2:
            return
        time.sleep(1)
    raise RuntimeError('projector queue did not finish processing during reconciliation')

def plain(item):
    decode = TypeDeserializer()
    return {k: decode.deserialize(v) for k, v in item.items()}

def same(actual, expected):
    # Envelope strings and RFC3339 offsets have equivalent wire representations.
    if set(actual) != set(expected):
        return False
    for k, v in expected.items():
        a = actual[k]
        if k == 'envelope':
            try:
                if json.loads(a) != v:
                    return False
            except (ValueError, TypeError):
                return False
        elif k in ('updated_at', 'occurred_at'):
            try:
                if datetime.fromisoformat(a.replace('Z', '+00:00')) != datetime.fromisoformat(v.replace('Z', '+00:00')):
                    return False
            except (ValueError, TypeError):
                return False
        elif a != v:
            return False
    return True

def projection_expected(events):
    expected = {}
    for e in events:
        p = e['payload']; d = p['data']; sid = str(e['settlement_id']); v = e['aggregate_version']
        pk = 'SETTLEMENT#' + sid
        item = dict(PK=pk, SK=f'EVENT#{v:08d}', settlement_id=sid, event_id=str(e['event_id']), version=v,
                    event_type=e['event_type'], status=d['status'], clearing_stage=d['clearingStage'],
                    occurred_at=p['occurredAt'], correlation_id=e['correlation_id'], envelope=p)
        for source, target in [('entryId', 'entry_id'), ('memo', 'memo')]:
            if d.get(source) is not None:
                item[target] = d[source]
        expected[(pk, item['SK'])] = item
        state = dict(PK=pk, SK='STATE', GSI1PK='ACCOUNT#' + d['accountId'], GSI1SK=pk,
            settlement_id=sid, account_id=d['accountId'], reference=d['reference'], debit_party=d['debitParty'],
            credit_party=d['creditParty'], status=d['status'], clearing_stage=d['clearingStage'],
            version=v, entry_count=v-1, updated_at=p['occurredAt'])
        for source, target in [('entryId', 'last_entry_id'), ('memo', 'last_memo')]:
            if d.get(source) is not None:
                state[target] = d[source]
        expected[(pk, 'STATE')] = state
    return expected

def projections(m, conn):
    events = query(conn, 'SELECT * FROM clearledger.events ORDER BY settlement_id,aggregate_version')
    expected = projection_expected(events)
    ddb = client('dynamodb'); table = m['projections']['table_name']
    actual = { (i['PK']['S'], i['SK']['S']): plain(i) for i in pages(ddb, 'scan', 'Items', TableName=table, ConsistentRead=True) }
    bad_partitions = {pk for (pk, sk), item in actual.items() if (pk, sk) not in expected or not same(item, expected[(pk, sk)])}
    bad_partitions.update(pk for pk, sk in expected if (pk, sk) not in actual)
    # Delete only divergent partitions. The immutable worker recreates canonical wire attributes.
    for pk, sk in actual:
        if pk in bad_partitions:
            ddb.delete_item(TableName=table, Key={'PK': {'S': pk}, 'SK': {'S': sk}})
    for start in range(0, len(events), 5):
        records = [{'messageId': str(e['event_id']), 'body': json.dumps(e['payload'])}
                   for e in events[start:start+5] if 'SETTLEMENT#' + str(e['settlement_id']) in bad_partitions]
        if records:
            invoke(m, 'projector', {'Records': records})
    actual = {(i['PK']['S'], i['SK']['S']): plain(i) for i in pages(ddb, 'scan', 'Items', TableName=table, ConsistentRead=True)}
    # Worker replay can retain a previous optional memo when the latest event
    # clears it. Complete the exact snapshot with an operational replacement
    # write, without changing the workload binary or its IAM write boundaries.
    serializer = TypeSerializer()
    for key, value in expected.items():
        if key not in actual or not same(actual[key], value):
            wire = dict(value)
            if 'envelope' in wire:
                wire['envelope'] = json.dumps(wire['envelope'], sort_keys=True, separators=(',', ':'), ensure_ascii=False)
            ddb.put_item(TableName=table, Item={k: serializer.serialize(v) for k, v in wire.items()})
    actual = {(i['PK']['S'], i['SK']['S']): plain(i) for i in pages(ddb, 'scan', 'Items', TableName=table, ConsistentRead=True)}
    if set(actual) != set(expected) or any(not same(actual[k], v) for k, v in expected.items()):
        differences = [(k, actual.get(k), v) for k, v in expected.items() if k not in actual or not same(actual[k], v)]
        raise RuntimeError('projection reconciliation failed: ' + str(differences[:1]))
    # Empty derived caches are valid, and cannot retain divergent/orphan values or bad TTLs.
    cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
    for key in cache.scan_iter(match='clearledger:settlement:*', count=500):
        cache.delete(key)
    print(f'Projection reconciliation: {len(events)} events, {len(bad_partitions)} repaired partitions.')

def versions(s3, bucket):
    for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
        yield from [('version', v) for v in page.get('Versions', [])]
        yield from [('marker', v) for v in page.get('DeleteMarkers', [])]

def purge(s3, bucket, entries):
    entries = list(entries)
    for start in range(0, len(entries), 1000):
        r = s3.delete_objects(Bucket=bucket, Delete={'Objects': entries[start:start+1000], 'Quiet': True})
        if r.get('Errors'):
            raise RuntimeError('S3 purge failed: ' + str(r['Errors']))

def empty_bucket(s3, bucket):
    purge(s3, bucket, ({'Key': v['Key'], 'VersionId': v['VersionId']} for _, v in versions(s3, bucket)))
    purge(s3, bucket, ({'Key': v['Key']} for v in pages(s3, 'list_objects_v2', 'Contents', Bucket=bucket)))

def archive(m, conn):
    s3 = client('s3'); bucket = m['audit']['bucket_name']
    rows = query(conn, 'SELECT seq,event_id,payload FROM clearledger.outbox ORDER BY seq')
    by_event = {str(r['event_id']): r for r in rows}
    seen = set(); invalid = set()
    for obj in pages(s3, 'list_objects_v2', 'Contents', Bucket=bucket):
        key = obj['Key']; good = False
        try:
            match = re.fullmatch(r'ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson', key)
            body = s3.get_object(Bucket=bucket, Key=key)['Body'].read()
            records = [json.loads(line) for line in body.splitlines()]
            selected = [by_event[r['eventId']] for r in records]
            seqs = [r['seq'] for r in selected]
            ids = [r['eventId'] for r in records]
            good = bool(match and seqs and seqs == sorted(set(seqs)) and
                int(match[1]) == seqs[0] and int(match[2]) == seqs[-1] and
                match[3] == hashlib.sha256(body).hexdigest()[:16] and
                all(r == ref['payload'] for r, ref in zip(records, selected)) and not seen.intersection(ids))
        except (ValueError, KeyError, TypeError):
            good = False
        if good:
            seen.update(ids)
        else:
            invalid.add(key)
    purge(s3, bucket, ({'Key': v['Key'], 'VersionId': v['VersionId']} for kind, v in versions(s3, bucket)
                       if v['Key'] in invalid or kind == 'marker' or not v['IsLatest']))
    missing = [str(r['event_id']) for r in rows if str(r['event_id']) not in seen]
    if missing:
        update(conn, 'UPDATE clearledger.outbox SET archived_at=NULL WHERE event_id=ANY(%s::uuid[])', (missing,))
    if seen:
        update(conn, 'UPDATE clearledger.outbox SET archived_at=GREATEST(now(),published_at) WHERE event_id=ANY(%s::uuid[]) AND archived_at IS NULL', (list(seen),))
    conn.commit()
    drain(m, conn, 'audit_archiver', 'published_at IS NOT NULL AND archived_at IS NULL')
    purge(s3, bucket, ({'Key': v['Key'], 'VersionId': v['VersionId']} for kind, v in versions(s3, bucket) if kind == 'marker' or not v['IsLatest']))
    # Verify the completed archive rather than merely trusting archival timestamps.
    got = []
    for obj in pages(s3, 'list_objects_v2', 'Contents', Bucket=bucket):
        body = s3.get_object(Bucket=bucket, Key=obj['Key'])['Body'].read()
        records = [json.loads(line) for line in body.splitlines()]
        seqs = [by_event[r['eventId']]['seq'] for r in records]
        key = f'ledger-audit/batch-{seqs[0]:08d}-{seqs[-1]:08d}-{hashlib.sha256(body).hexdigest()[:16]}.ndjson'
        if obj['Key'] != key or seqs != sorted(set(seqs)) or any(r != by_event[r['eventId']]['payload'] for r in records):
            raise RuntimeError('noncanonical archive batch')
        got.extend(r['eventId'] for r in records)
    if len(got) != len(set(got)) or set(got) != set(by_event):
        raise RuntimeError('archive is not one-to-one with outbox')
    print(f'Audit reconciliation: {len(got)} events, all obsolete versions purged.')

def reconcile():
    m = load(); conn = db(m); conn.autocommit = True
    drain(m, conn, 'outbox_relay', 'published_at IS NULL')
    # A short write barrier supplies a stable authoritative snapshot during repair.
    # Reads remain available; concurrent API writes wait and proceed after commit.
    barrier = db(m)
    try:
        update(barrier, "SET lock_timeout='20s'; LOCK TABLE clearledger.settlements,clearledger.events IN SHARE MODE")
        drain(m, conn, 'outbox_relay', 'published_at IS NULL')
        wait_queue(m)
        projections(m, conn)
        archive(m, conn)
    finally:
        barrier.rollback(); barrier.close(); conn.close()

def protect():
    plan = json.loads(subprocess.check_output(['terraform', '-chdir=' + str(ROOT / 'infra'), 'show', '-json', 'deploy.tfplan']))
    for r in plan.get('resource_changes', []):
        if r['type'] in ('aws_db_instance', 'aws_dynamodb_table', 'aws_s3_bucket') and 'delete' in r['change']['actions']:
            raise RuntimeError('refusing data-store replacement: ' + r['address'])

def guardrails():
    # The local EC2 implementation can retain its default egress rule after
    # CreateSecurityGroup. Remove that rule even on the very first deployment.
    m = load(); ec2 = client('ec2')
    for owner in ['alb', 'rds', 'valkey']:
        gid = m['network']['security_group_ids'][owner]
        groups = ec2.describe_security_groups(GroupIds=[gid])['SecurityGroups']
        for rule in groups[0].get('IpPermissionsEgress', []):
            forbidden = dict(IpProtocol=rule['IpProtocol'])
            for k in ['FromPort', 'ToPort']:
                if k in rule:
                    forbidden[k] = rule[k]
            for field, attr, cidr in [('IpRanges','CidrIp','0.0.0.0/0'), ('Ipv6Ranges','CidrIpv6','::/0')]:
                values = [v for v in rule.get(field, []) if v[attr] == cidr]
                if values:
                    forbidden[field] = values
            if 'IpRanges' in forbidden or 'Ipv6Ranges' in forbidden:
                ec2.revoke_security_group_egress(GroupId=gid, IpPermissions=[forbidden])
    policies()

def before_destroy():
    policies(True)
    scheduler = client('scheduler')
    for s in pages(scheduler, 'list_schedules', 'Schedules'):
        if scoped(s['Name']):
            missing_call(scheduler.delete_schedule, Name=s['Name'], GroupName=s.get('GroupName', 'default'))
    lam = client('lambda')
    for f in pages(lam, 'list_functions', 'Functions'):
        if scoped(f['FunctionName']):
            for e in pages(lam, 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                missing_call(lam.delete_event_source_mapping, UUID=e['UUID'])

def cleanup():
    # All enumeration is prefix/tag scoped; baseline resources are explicitly excluded.
    policies(True)
    lam = client('lambda')
    for f in pages(lam, 'list_functions', 'Functions'):
        if scoped(f['FunctionName'], lam.list_tags(Resource=f['FunctionArn']).get('Tags')):
            for mapping in pages(lam, 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                missing_call(lam.delete_event_source_mapping, UUID=mapping['UUID'])
            lam.delete_function(FunctionName=f['FunctionName'])
    ecs = client('ecs')
    for status in ['ACTIVE', 'INACTIVE']:
        for arn in pages(ecs, 'list_task_definitions', 'taskDefinitionArns', status=status):
            family = arn.rsplit('/', 1)[-1].split(':')[0]
            if scoped(family):
                if status == 'ACTIVE':
                    ecs.deregister_task_definition(taskDefinition=arn)
                ecs.delete_task_definitions(taskDefinitions=[arn])
    iam = client('iam')
    for r in list(pages(iam, 'list_roles', 'Roles')):
        name = r['RoleName']
        if scoped(name, iam.list_role_tags(RoleName=name).get('Tags')):
            for profile in pages(iam, 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if scoped(profile['InstanceProfileName']):
                    iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
            iam.delete_role(RoleName=name)
    for p in list(pages(iam, 'list_policies', 'Policies', Scope='Local')):
        arn = p['Arn']
        if scoped(p['PolicyName'], iam.list_policy_tags(PolicyArn=arn).get('Tags')):
            entities = iam.list_entities_for_policy(PolicyArn=arn)
            for kind, op, namekey in [('PolicyRoles','detach_role_policy','RoleName'), ('PolicyUsers','detach_user_policy','UserName'), ('PolicyGroups','detach_group_policy','GroupName')]:
                for entity in entities.get(kind, []):
                    getattr(iam, op)(**{namekey: entity[namekey], 'PolicyArn': arn})
            for v in pages(iam, 'list_policy_versions', 'Versions', PolicyArn=arn):
                if not v['IsDefaultVersion']:
                    iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
            iam.delete_policy(PolicyArn=arn)
    s3 = client('s3')
    for b in s3.list_buckets().get('Buckets', []):
        name = b['Name']; tags = []
        try:
            tags = s3.get_bucket_tagging(Bucket=name).get('TagSet', [])
        except ClientError as e:
            if e.response['Error']['Code'] not in ('NoSuchTagSet','NoSuchBucket'):
                raise
        if scoped(name, tags):
            empty_bucket(s3, name); s3.delete_bucket(Bucket=name)
    ddb = client('dynamodb')
    for name in pages(ddb, 'list_tables', 'TableNames'):
        arn = ddb.describe_table(TableName=name)['Table']['TableArn']
        if scoped(name, ddb.list_tags_of_resource(ResourceArn=arn).get('Tags')):
            ddb.delete_table(TableName=name)
    sqs = client('sqs')
    for url in pages(sqs, 'list_queues', 'QueueUrls'):
        if scoped(url.rsplit('/',1)[-1], sqs.list_queue_tags(QueueUrl=url).get('Tags')):
            sqs.delete_queue(QueueUrl=url)
    scheduler = client('scheduler')
    for s in pages(scheduler, 'list_schedules', 'Schedules'):
        if scoped(s['Name'], scheduler.list_tags_for_resource(ResourceArn=s['Arn']).get('Tags')):
            scheduler.delete_schedule(Name=s['Name'], GroupName=s.get('GroupName','default'))
    for g in pages(scheduler, 'list_schedule_groups', 'ScheduleGroups'):
        if scoped(g['Name'], scheduler.list_tags_for_resource(ResourceArn=g['Arn']).get('Tags')):
            scheduler.delete_schedule_group(Name=g['Name'])
    logs = client('logs')
    for g in pages(logs, 'describe_log_groups', 'logGroups'):
        name = g['logGroupName']
        if scoped(name, logs.list_tags_log_group(logGroupName=name).get('tags')):
            logs.delete_log_group(logGroupName=name)
    kms = client('kms')
    alias_keys = set()
    for a in pages(kms, 'list_aliases', 'Aliases'):
        if scoped(a['AliasName']):
            if a.get('TargetKeyId'):
                alias_keys.add(a['TargetKeyId'])
            kms.delete_alias(AliasName=a['AliasName'])
    for k in pages(kms, 'list_keys', 'Keys'):
        metadata = kms.describe_key(KeyId=k['KeyId'])['KeyMetadata']
        if metadata.get('KeyManager') == 'CUSTOMER' and (k['KeyId'] in alias_keys or scoped(metadata.get('Description',''), kms.list_resource_tags(KeyId=k['KeyId']).get('Tags'))) and metadata['KeyState'] != 'PendingDeletion':
            kms.schedule_key_deletion(KeyId=k['KeyId'], PendingWindowInDays=10)
    # Some local control planes leave autogenerated VPC defaults after DeleteVpc.
    # Ownership comes from the exported Terraform manifest, never from an orphan
    # heuristic that could select a baseline resource.
    if (ROOT / 'manifest.json').exists():
        m = json.loads((ROOT / 'manifest.json').read_text())
        if m.get('resource_prefix') == PREFIX:
            ec2 = client('ec2'); vid = m['network']['vpc_id']
            if not ec2.describe_vpcs(Filters=[{'Name':'vpc-id','Values':[vid]}])['Vpcs']:
                for g in ec2.describe_security_groups(Filters=[{'Name':'vpc-id','Values':[vid]}])['SecurityGroups']:
                    ec2.delete_security_group(GroupId=g['GroupId'])
                for r in ec2.describe_route_tables(Filters=[{'Name':'vpc-id','Values':[vid]}])['RouteTables']:
                    ec2.delete_route_table(RouteTableId=r['RouteTableId'])
                for a in ec2.describe_network_acls(Filters=[{'Name':'vpc-id','Values':[vid]}])['NetworkAcls']:
                    try:
                        ec2.delete_network_acl(NetworkAclId=a['NetworkAclId'])
                    except ClientError as e:
                        if not a.get('IsDefault') or e.response['Error']['Code'] != 'InvalidParameterValue':
                            raise
    print('Prefix-scoped operational resources cleaned up.')

def empty_state():
    state = json.loads(subprocess.check_output(['terraform', '-chdir=' + str(ROOT / 'infra'), 'show', '-json']))
    def managed(module):
        return [r for r in module.get('resources', []) if r['mode']=='managed'] + [r for ch in module.get('child_modules', []) for r in managed(ch)]
    if managed(state.get('values', {}).get('root_module', {})):
        raise RuntimeError('managed resources remain in Terraform state')
    print('Terraform state has zero managed resources.')

commands = {'policies': policies, 'manifest': manifest, 'migrate': migrate, 'ready': ready,
            'reconcile': reconcile, 'protect': protect, 'guardrails': guardrails, 'before-destroy': before_destroy,
            'cleanup': cleanup, 'empty-state': empty_state}
if __name__ == '__main__':
    commands[sys.argv[1]]()
