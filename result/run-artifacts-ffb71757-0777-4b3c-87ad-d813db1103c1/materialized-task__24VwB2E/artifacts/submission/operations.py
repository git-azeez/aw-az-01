"""Control-plane hygiene and transactional-source-driven recovery.

Cloud resource creation belongs exclusively to Terraform. These operations only
remove drift, invoke the supplied binaries, and repair derived data.
"""
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
import psycopg
from psycopg.rows import dict_row
import redis

ROOT = Path(__file__).resolve().parent
C = json.loads(Path('/workspace/config/config.json').read_text())
PREFIX = C['resource_prefix']
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=C['region'])


def client(service):
    return SESSION.client(service, endpoint_url=C['aws_endpoint_url'], config=Config(
        retries={'max_attempts': 5, 'mode': 'standard'}, connect_timeout=5, read_timeout=60,
        s3={'addressing_style': 'path'}))


def pages(c, operation, key, **kw):
    if c.can_paginate(operation):
        return [x for page in c.get_paginator(operation).paginate(**kw) for x in page.get(key, [])]
    return getattr(c, operation)(**kw).get(key, [])


def absent_ok(fn, **kw):
    try:
        return fn(**kw)
    except ClientError as e:
        if e.response['Error']['Code'] not in ('NoSuchEntity', 'NoSuchEntityException', 'ResourceNotFoundException',
                                              'NoSuchBucket', 'QueueDoesNotExist', 'AWS.SimpleQueueService.NonExistentQueue',
                                              'NotFoundException', 'NotFound', '404'):
            raise


def scoped(name, tags=()):
    # Baseline resources are never eligible, even if accidentally retagged.
    if name.startswith('cl-base-') or '/cl-base-' in name:
        return False
    if isinstance(tags, dict):
        tagged = tags.get('ClearLedgerDeployment') == PREFIX
    else:
        tagged = any(t.get('Key') == 'ClearLedgerDeployment' and t.get('Value') == PREFIX for t in tags)
    return any(part.startswith(PREFIX) for part in name.split('/')) or tagged


def delete_policy(iam, arn):
    for v in pages(iam, 'list_policy_versions', 'Versions', PolicyArn=arn):
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    iam.delete_policy(PolicyArn=arn)


def clean_iam(destroy=False):
    iam = client('iam')
    canonical_roles = {f'{PREFIX}-{r}' for r in ('ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler')}
    for role in pages(iam, 'list_roles', 'Roles'):
        name = role['RoleName']
        tags = pages(iam, 'list_role_tags', 'Tags', RoleName=name)
        if name not in canonical_roles and not (destroy and scoped(name, tags)):
            continue
        for policy in pages(iam, 'list_role_policies', 'PolicyNames', RoleName=name):
            if destroy or policy != f'{name}-canonical':
                iam.delete_role_policy(RoleName=name, PolicyName=policy)
        for policy in pages(iam, 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])
        if destroy and name not in canonical_roles:
            for profile in pages(iam, 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if scoped(profile['InstanceProfileName']):
                    iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
            iam.delete_role(RoleName=name)
    for policy in pages(iam, 'list_policies', 'Policies', Scope='Local'):
        tags = pages(iam, 'list_policy_tags', 'Tags', PolicyArn=policy['Arn'])
        if not scoped(policy['PolicyName'], tags):
            continue
        if destroy:
            entities = iam.list_entities_for_policy(PolicyArn=policy['Arn'])
            for role in entities.get('PolicyRoles', []):
                if scoped(role['RoleName']):
                    iam.detach_role_policy(RoleName=role['RoleName'], PolicyArn=policy['Arn'])
        detail = iam.get_policy(PolicyArn=policy['Arn'])['Policy']
        if detail.get('AttachmentCount', 0) == 0:
            delete_policy(iam, policy['Arn'])


def manifest():
    raw = subprocess.check_output(['terraform', f'-chdir={ROOT / "infra"}', 'output', '-json', 'manifest'])
    m = json.loads(raw)
    jsonschema.validate(m, json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text()))
    tmp = ROOT / 'manifest.json.tmp'
    tmp.write_text(json.dumps(m, indent=2) + '\n')
    tmp.chmod(0o600)
    tmp.replace(ROOT / 'manifest.json')
    return m


def database(m):
    return psycopg.connect(host=m['database']['endpoint'], port=m['database']['port'],
                          dbname=C['db_name'], user=C['db_username'], password=C['db_password'],
                          connect_timeout=5, autocommit=True, row_factory=dict_row)


def invoke(m, worker, payload=None):
    result = client('lambda').invoke(FunctionName=m['workers'][worker]['function_name'],
                                     InvocationType='RequestResponse', Payload=json.dumps(payload or {}).encode())
    body = result['Payload'].read()
    if result.get('FunctionError'):
        raise RuntimeError(f'{worker} invocation failed: {body[:1024]!r}')
    parsed = json.loads(body or b'{}')
    if isinstance(parsed, dict) and parsed.get('batchItemFailures'):
        raise RuntimeError(f'{worker} returned partial failures')
    return parsed


def schedules(m, enabled):
    scheduler = client('scheduler')
    for key in ('outbox_schedule_name', 'archive_schedule_name'):
        s = scheduler.get_schedule(Name=m['schedules'][key])
        args = {k: s[k] for k in ('Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone',
                                 'FlexibleTimeWindow', 'Target', 'Description', 'StartDate', 'EndDate',
                                 'KmsKeyArn', 'ActionAfterCompletion') if k in s}
        scheduler.update_schedule(**args, State='ENABLED' if enabled else 'DISABLED')


def mapping(m, enabled):
    lam = client('lambda')
    uid = m['messaging']['event_source_mapping_uuid']
    lam.update_event_source_mapping(UUID=uid, Enabled=enabled)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        state = lam.get_event_source_mapping(UUID=uid)['State']
        if state == ('Enabled' if enabled else 'Disabled'):
            return
        time.sleep(0.5)
    raise RuntimeError('event source mapping did not settle')


def wait_queue(m):
    sqs = client('sqs')
    deadline = time.monotonic() + 90
    quiet = 0
    while time.monotonic() < deadline:
        attrs = sqs.get_queue_attributes(QueueUrl=m['messaging']['queue_url'], AttributeNames=[
            'ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible', 'ApproximateNumberOfMessagesDelayed'])['Attributes']
        quiet = quiet + 1 if all(int(v) == 0 for v in attrs.values()) else 0
        if quiet >= 3:
            return
        time.sleep(1)
    raise RuntimeError('main SQS queue failed to drain')


def delete_versions(s3, bucket, predicate=lambda v: True):
    versions = pages(s3, 'list_object_versions', 'Versions', Bucket=bucket)
    markers = pages(s3, 'list_object_versions', 'DeleteMarkers', Bucket=bucket)
    objects = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in versions if predicate(v)]
    objects.extend({'Key': v['Key'], 'VersionId': v['VersionId']} for v in markers)
    for start in range(0, len(objects), 1000):
        result = s3.delete_objects(Bucket=bucket, Delete={'Objects': objects[start:start+1000], 'Quiet': True})
        if result.get('Errors'):
            raise RuntimeError(f'S3 version deletion failed: {result["Errors"]}')


def audit_valid(s3, bucket, rows):
    by_seq = {r['seq']: r for r in rows}
    seen = set()
    for obj in pages(s3, 'list_objects_v2', 'Contents', Bucket=bucket):
        match = re.fullmatch(r'ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson', obj['Key'])
        if not match:
            return False
        first, last, digest = int(match[1]), int(match[2]), match[3]
        raw = s3.get_object(Bucket=bucket, Key=obj['Key'])['Body'].read()
        if hashlib.sha256(raw).hexdigest()[:16] != digest:
            return False
        seqs = [seq for seq in by_seq if first <= seq <= last]
        if not seqs or seqs[0] != first or seqs[-1] != last or seen.intersection(seqs):
            return False
        try:
            values = [json.loads(line) for line in raw.splitlines()]
        except (ValueError, UnicodeError):
            return False
        if values != [by_seq[seq]['payload'] for seq in seqs]:
            return False
        seen.update(seqs)
    return seen == set(by_seq)


def reconcile_audit(m, db):
    s3 = client('s3')
    bucket = m['audit']['bucket_name']
    rows = db.execute('SELECT seq,payload,archived_at FROM clearledger.outbox ORDER BY seq').fetchall()
    if not audit_valid(s3, bucket, rows) or any(r['archived_at'] is None for r in rows):
        # Rebuild complete ranges: filling isolated holes could overlap retained batches.
        delete_versions(s3, bucket)
        db.execute('UPDATE clearledger.outbox SET archived_at = NULL WHERE archived_at IS NOT NULL')
        while db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE archived_at IS NULL').fetchone()['n']:
            before = db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE archived_at IS NULL').fetchone()['n']
            invoke(m, 'audit_archiver')
            after = db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE archived_at IS NULL').fetchone()['n']
            if after >= before:
                raise RuntimeError('audit archiver made no progress')
        if not audit_valid(s3, bucket, rows):
            raise RuntimeError('audit archive failed exact source reconciliation')
    delete_versions(s3, bucket, lambda v: not v['IsLatest'])


def compact(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=False)


def reconcile_projection(m, db, repair=True):
    events = db.execute('SELECT payload,occurred_at FROM clearledger.events ORDER BY settlement_id,aggregate_version').fetchall()
    expected = {}
    cache = {}
    ser = TypeSerializer()
    for row in events:
        e = row['payload']; d = e['data']; sid = e['aggregateId']; version = e['aggregateVersion']
        pk = f'SETTLEMENT#{sid}'
        occurred_at = row['occurred_at'].isoformat()
        event = dict(PK=pk, SK=f'EVENT#{version:08d}', settlement_id=sid, event_id=e['eventId'],
                     version=version, event_type=e['eventType'], status=d['status'], clearing_stage=d['clearingStage'],
                     occurred_at=occurred_at, correlation_id=e['correlationId'], envelope=compact(e))
        for source, dest in [('entryId','entry_id'),('memo','memo')]:
            if d.get(source) is not None:
                event[dest] = d[source]
        state = dict(PK=pk, SK='STATE', GSI1PK='ACCOUNT#'+d['accountId'], GSI1SK=pk,
                     settlement_id=sid, account_id=d['accountId'], reference=d['reference'],
                     debit_party=d['debitParty'], credit_party=d['creditParty'], status=d['status'],
                     clearing_stage=d['clearingStage'], version=version, entry_count=version-1, updated_at=occurred_at)
        for source, dest in [('entryId','last_entry_id'),('memo','last_memo')]:
            if d.get(source) is not None:
                state[dest] = d[source]
        expected[(pk,event['SK'])] = {k:ser.serialize(v) for k,v in event.items()}
        expected[(pk,'STATE')] = {k:ser.serialize(v) for k,v in state.items()}
        projection = dict(settlementId=sid, accountId=d['accountId'], reference=d['reference'],
            debitParty=d['debitParty'], creditParty=d['creditParty'], status=d['status'], clearingStage=d['clearingStage'],
            version=version, entryCount=version-1, updatedAt=occurred_at.replace('+00:00','Z'))
        for source, dest in [('entryId','lastEntryId'),('memo','lastMemo')]:
            if d.get(source) is not None:
                projection[dest] = d[source]
        cache[f'clearledger:settlement:{sid}'] = projection
    ddb = client('dynamodb'); table = m['projections']['table_name']
    actual = {(i['PK']['S'],i['SK']['S']):i for i in pages(ddb,'scan','Items',TableName=table,ConsistentRead=True)}
    writes = []
    for key, item in actual.items():
        if key not in expected:
            writes.append({'DeleteRequest': {'Key': {'PK':item['PK'],'SK':item['SK']}}})
    for key, item in expected.items():
        if actual.get(key) != item:
            writes.append({'PutRequest': {'Item':item}})
    if writes and not repair:
        raise RuntimeError(f'DynamoDB verification found {len(writes)} divergent items')
    for offset in range(0,len(writes),25):
        pending = {table:writes[offset:offset+25]}
        for attempt in range(10):
            pending = ddb.batch_write_item(RequestItems=pending).get('UnprocessedItems',{})
            if not pending:
                break
            time.sleep(min(2, 0.1 * 2**attempt))
        if pending:
            raise RuntimeError('DynamoDB writes remained unprocessed')
    verified = {(i['PK']['S'],i['SK']['S']):i for i in pages(ddb,'scan','Items',TableName=table,ConsistentRead=True)}
    if verified != expected:
        raise RuntimeError('DynamoDB exact reconciliation failed')
    return cache


def populate_cache(m, expected):
    r = redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'],decode_responses=True,socket_timeout=5)
    stray = [k for k in r.scan_iter(count=500) if k not in expected]
    for offset in range(0,len(stray),500):
        r.delete(*stray[offset:offset+500])
    with r.pipeline(transaction=True) as pipe:
        for key, value in expected.items():
            pipe.set(key,compact(value),ex=90)
        pipe.execute()
    for key, value in expected.items():
        if json.loads(r.get(key) or 'null') != value or not 0 < r.ttl(key) <= 90:
            raise RuntimeError('cache reconciliation verification failed')


def ready(m):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(m['service_url']+'/health/ready',timeout=4) as response:
                if response.status == 200:
                    return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError('API readiness deadline exceeded')


def deploy():
    m = manifest()
    clean_iam()
    with database(m) as db:
        db.execute((ROOT/'schema.sql').read_text())
    ready(m)
    # A short database write barrier gives a single authoritative cut while reads
    # remain online. Workers use another connection and may stamp outbox metadata.
    schedules(m, False)
    try:
        with database(m) as barrier, database(m) as db:
            barrier.execute('BEGIN')
            barrier.execute("SET LOCAL lock_timeout = '60s'")
            barrier.execute('LOCK TABLE clearledger.settlements,clearledger.events IN SHARE MODE')
            while True:
                before = db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL').fetchone()['n']
                if not before:
                    break
                invoke(m,'outbox_relay')
                after = db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL').fetchone()['n']
                if after >= before:
                    raise RuntimeError('outbox relay made no progress')
            wait_queue(m)
            mapping(m,False)
            try:
                reconcile_audit(m,db)
                cache = reconcile_projection(m,db)
                ready(m)
            finally:
                mapping(m,True)
            populate_cache(m,cache)
            barrier.execute('COMMIT')
    finally:
        schedules(m,True)
    print('ClearLedger deployed; API ready; outbox, projections, cache, and audit archive reconciled.')


def check_plan():
    plan = json.loads(subprocess.check_output(['terraform',f'-chdir={ROOT/"infra"}','show','-json',str(ROOT/'infra/deploy.plan')]))
    for resource in plan.get('resource_changes',[]):
        if resource['type'] in ('aws_db_instance','aws_dynamodb_table','aws_s3_bucket') and 'delete' in resource['change']['actions']:
            raise RuntimeError(f'Refusing destructive deployment plan for {resource["address"]}')


def pre_destroy():
    clean_iam(destroy=True)
    scheduler = client('scheduler')
    for schedule in pages(scheduler,'list_schedules','Schedules'):
        if scoped(schedule['Name']):
            scheduler.delete_schedule(Name=schedule['Name'],GroupName=schedule.get('GroupName','default'))
    lam = client('lambda')
    for function in pages(lam,'list_functions','Functions'):
        if scoped(function['FunctionName']):
            for esm in pages(lam,'list_event_source_mappings','EventSourceMappings',FunctionName=function['FunctionName']):
                absent_ok(lam.delete_event_source_mapping,UUID=esm['UUID'])
    s3 = client('s3')
    for b in s3.list_buckets()['Buckets']:
        name = b['Name']
        try:
            tags = s3.get_bucket_tagging(Bucket=name).get('TagSet',[])
        except ClientError as e:
            if e.response['Error']['Code'] != 'NoSuchTagSet':
                raise
            tags = []
        if scoped(name,tags):
            delete_versions(s3,name)
            for obj in pages(s3,'list_objects_v2','Contents',Bucket=name):
                s3.delete_object(Bucket=name,Key=obj['Key'])


def post_destroy():
    # Remove prefix/tag-scoped operational leftovers that never entered state.
    pre_destroy()
    lam = client('lambda')
    for function in pages(lam,'list_functions','Functions'):
        tags = lam.list_tags(Resource=function['FunctionArn']).get('Tags',{})
        if scoped(function['FunctionName'],tags):
            lam.delete_function(FunctionName=function['FunctionName'])
    s3 = client('s3')
    for b in s3.list_buckets()['Buckets']:
        try:
            tags = s3.get_bucket_tagging(Bucket=b['Name']).get('TagSet',[])
        except ClientError:
            tags = []
        if scoped(b['Name'],tags):
            s3.delete_bucket(Bucket=b['Name'])
    ddb = client('dynamodb')
    for name in pages(ddb,'list_tables','TableNames'):
        arn = ddb.describe_table(TableName=name)['Table']['TableArn']
        tags = ddb.list_tags_of_resource(ResourceArn=arn).get('Tags',[])
        if scoped(name,tags):
            ddb.delete_table(TableName=name)
    sqs = client('sqs')
    for url in pages(sqs,'list_queues','QueueUrls'):
        tags = sqs.list_queue_tags(QueueUrl=url).get('Tags',{})
        if scoped(url.rsplit('/',1)[-1],tags):
            sqs.delete_queue(QueueUrl=url)
    logs = client('logs')
    for group in pages(logs,'describe_log_groups','logGroups'):
        name = group['logGroupName']
        tags = logs.list_tags_log_group(logGroupName=name).get('tags',{})
        if scoped(name,tags):
            logs.delete_log_group(logGroupName=name)
    kms = client('kms')
    aliases = pages(kms,'list_aliases','Aliases')
    key_ids = {a['TargetKeyId'] for a in aliases if a.get('TargetKeyId') and scoped(a['AliasName'])}
    for alias in aliases:
        if scoped(alias['AliasName']):
            kms.delete_alias(AliasName=alias['AliasName'])
    for key in pages(kms,'list_keys','Keys'):
        metadata = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        if metadata.get('KeyManager') != 'CUSTOMER':
            continue
        tags = kms.list_resource_tags(KeyId=key['KeyId']).get('Tags',[])
        tags = [{'Key':t['TagKey'],'Value':t['TagValue']} for t in tags]
        if key['KeyId'] in key_ids or scoped(metadata.get('Description',''),tags):
            if metadata['KeyState'] != 'PendingDeletion':
                kms.schedule_key_deletion(KeyId=key['KeyId'],PendingWindowInDays=10)
    state = json.loads(subprocess.check_output(['terraform',f'-chdir={ROOT/"infra"}','show','-json']))
    def count(module):
        return sum(r.get('mode') == 'managed' for r in module.get('resources',[])) + sum(count(x) for x in module.get('child_modules',[]))
    if count(state.get('values',{}).get('root_module',{})):
        raise RuntimeError('managed resources remain in Terraform state')
    print('ClearLedger teardown complete; managed state is empty.')


if __name__ == '__main__':
    {'deploy':deploy,'check-plan':check_plan,'pre-destroy':pre_destroy,'post-destroy':post_destroy}[sys.argv[1]]()
