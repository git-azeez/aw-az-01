"""Operator-side lifecycle repair. Resource creation belongs exclusively to Terraform."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time

import boto3
from boto3.dynamodb.types import TypeSerializer, TypeDeserializer
from botocore.config import Config
from botocore.exceptions import ClientError
import jsonschema
import psycopg
from psycopg.rows import dict_row
import redis
import requests

ROOT = Path(__file__).resolve().parent
CFG = json.loads(Path('/workspace/config/config.json').read_text())
PREFIX = CFG['resource_prefix']
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=CFG['region'])


def client(service):
    return SESSION.client(service, endpoint_url=CFG['aws_endpoint_url'], config=Config(
        retries={'max_attempts': 4, 'mode': 'standard'}, connect_timeout=5, read_timeout=30,
        s3={'addressing_style': 'path'}))


def manifest():
    return json.loads((ROOT / 'manifest.json').read_text())


def owned(name, tags=()):
    if name.startswith('cl-base-') or '/cl-base-' in name:
        return False
    if name.startswith(PREFIX + '-') or name.startswith('alias/' + PREFIX + '-') or f'/{PREFIX}/' in name:
        return True
    if isinstance(tags, dict):
        return tags.get('ClearLedgerDeployment') == PREFIX
    return any(t.get('Key', t.get('key')) == 'ClearLedgerDeployment' and t.get('Value', t.get('value')) == PREFIX for t in tags)


def missing(exc):
    return isinstance(exc, ClientError) and exc.response['Error']['Code'] in (
        'NoSuchEntity', 'ResourceNotFoundException', 'ResourceNotFound', 'NotFoundException',
        'DBInstanceNotFound', 'DBInstanceNotFoundFault', 'NoSuchBucket', 'QueueDoesNotExist',
        'AWS.SimpleQueueService.NonExistentQueue', 'ReplicationGroupNotFoundFault')


def pages(c, method, field, **kwargs):
    if c.can_paginate(method):
        for p in c.get_paginator(method).paginate(**kwargs):
            yield from p.get(field, [])
    else:
        yield from getattr(c, method)(**kwargs).get(field, [])


def remove_policy(iam, arn):
    for entity_type, field in [('Role', 'PolicyRoles'), ('User', 'PolicyUsers'), ('Group', 'PolicyGroups')]:
        for e in pages(iam, 'list_entities_for_policy', field, PolicyArn=arn):
            getattr(iam, f'detach_{entity_type.lower()}_policy')(**{f'{entity_type}Name': e[f'{entity_type}Name'], 'PolicyArn': arn})
    for version in pages(iam, 'list_policy_versions', 'Versions', PolicyArn=arn):
        if not version['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=version['VersionId'])
    iam.delete_policy(PolicyArn=arn)


def policies():
    iam = client('iam')
    for role in ('ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler'):
        name = f'{PREFIX}-{role}'
        try:
            for p in pages(iam, 'list_role_policies', 'PolicyNames', RoleName=name):
                if p != f'{name}-canonical':
                    iam.delete_role_policy(RoleName=name, PolicyName=p)
            for p in pages(iam, 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
                iam.detach_role_policy(RoleName=name, PolicyArn=p['PolicyArn'])
        except ClientError as exc:
            if not missing(exc):
                raise
    for p in pages(iam, 'list_policies', 'Policies', Scope='Local'):
        if owned(p['PolicyName']) and p.get('AttachmentCount', 0) == 0:
            remove_policy(iam, p['Arn'])
    # Restore keys scheduled for deletion during a recovery drill before Terraform
    # tries to re-enable them or reconcile their rotation settings.
    kms = client('kms')
    state_path = ROOT / 'infra/terraform.tfstate'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    for resource in state.get('resources', []):
        if resource.get('type') != 'aws_kms_key':
            continue
        for instance in resource.get('instances', []):
            key = instance['attributes']['id']
            try:
                metadata = kms.describe_key(KeyId=key)['KeyMetadata']
                if metadata['KeyState'] == 'PendingDeletion':
                    kms.cancel_key_deletion(KeyId=key)
                    kms.enable_key(KeyId=key)
            except ClientError as exc:
                if not missing(exc):
                    raise


def connect():
    d = manifest()['database']
    return psycopg.connect(host=d['endpoint'], port=d['port'], dbname=CFG['db_name'],
                           user=CFG['db_username'], password=CFG['db_password'],
                           connect_timeout=5, row_factory=dict_row)


def schema():
    deadline = time.monotonic() + 120
    while True:
        try:
            with connect() as db:
                db.execute((ROOT / 'schema.sql').read_text().replace('\\set ON_ERROR_STOP on\n', ''))
            break
        except psycopg.OperationalError:
            if time.monotonic() > deadline:
                raise
            time.sleep(2)
    print('PostgreSQL schema, constraints, indexes, and enabled triggers verified.')


def schedule_state(scheduler, name, state):
    s = scheduler.get_schedule(Name=name)
    keys = ['Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone', 'StartDate',
            'EndDate', 'Description', 'FlexibleTimeWindow', 'Target', 'KmsKeyArn', 'ActionAfterCompletion']
    args = {k: s[k] for k in keys if k in s}
    args['State'] = state
    scheduler.update_schedule(**args)


@contextlib.contextmanager
def pause_workers(m):
    scheduler, lam = client('scheduler'), client('lambda')
    uuid = m['messaging']['event_source_mapping_uuid']
    names = [m['schedules']['outbox_schedule_name'], m['schedules']['archive_schedule_name']]
    try:
        for name in names:
            schedule_state(scheduler, name, 'DISABLED')
        lam.update_event_source_mapping(UUID=uuid, Enabled=False)
        deadline = time.monotonic() + 60
        while lam.get_event_source_mapping(UUID=uuid)['State'] not in ('Disabled', 'disabled'):
            if time.monotonic() > deadline:
                raise TimeoutError('Projector mapping did not pause')
            time.sleep(1)
        # Wait longer than the configured worker timeout for in-flight invocations.
        time.sleep(4)
        yield
    finally:
        lam.update_event_source_mapping(UUID=uuid, Enabled=True)
        for name in names:
            schedule_state(scheduler, name, 'ENABLED')


def canonical_json(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def timestamp(t):
    return t.isoformat().replace('+00:00', 'Z')


def canonical_items(settlements, events):
    result = {}
    for s in settlements:
        sid = str(s['settlement_id'])
        item = dict(PK=f'SETTLEMENT#{sid}', SK='STATE', GSI1PK=f"ACCOUNT#{s['account_id']}",
                    GSI1SK=f'SETTLEMENT#{sid}', settlement_id=sid, account_id=s['account_id'],
                    reference=s['reference'], debit_party=s['debit_party'], credit_party=s['credit_party'],
                    status=s['current_status'], clearing_stage=s['current_stage'], version=s['version'],
                    entry_count=s['entry_count'], updated_at=timestamp(s['updated_at']))
        if s['last_entry_id'] is not None:
            item['last_entry_id'] = str(s['last_entry_id'])
        if s['last_memo'] is not None:
            item['last_memo'] = s['last_memo']
        result[(item['PK'], item['SK'])] = item
    for e in events:
        sid, d = str(e['settlement_id']), e['payload']['data']
        item = dict(PK=f'SETTLEMENT#{sid}', SK=f"EVENT#{e['aggregate_version']:08d}", settlement_id=sid,
                    event_id=str(e['event_id']), version=e['aggregate_version'], event_type=e['event_type'],
                    status=d['status'], clearing_stage=d['clearingStage'], occurred_at=timestamp(e['occurred_at']),
                    correlation_id=e['correlation_id'], envelope=canonical_json(e['payload']))
        if d.get('entryId') is not None:
            item['entry_id'] = d['entryId']
        if d.get('memo') is not None:
            item['memo'] = d['memo']
        result[(item['PK'], item['SK'])] = item
    return result


def repair_dynamodb(m, settlements, events):
    ddb, ser, deser = client('dynamodb'), TypeSerializer(), TypeDeserializer()
    table = m['projections']['table_name']
    expected = canonical_items(settlements, events)
    actual = {}
    for item in pages(ddb, 'scan', 'Items', TableName=table, ConsistentRead=True):
        decoded = {k: deser.deserialize(v) for k, v in item.items()}
        actual[(decoded['PK'], decoded['SK'])] = decoded
    for key in actual.keys() - expected.keys():
        ddb.delete_item(TableName=table, Key={'PK': {'S': key[0]}, 'SK': {'S': key[1]}})
    for key, item in expected.items():
        if actual.get(key) != item:
            ddb.put_item(TableName=table, Item={k: ser.serialize(v) for k, v in item.items()})
    verified = { (x['PK']['S'], x['SK']['S']): {k: deser.deserialize(v) for k, v in x.items()}
                 for x in pages(ddb, 'scan', 'Items', TableName=table, ConsistentRead=True) }
    if verified != expected:
        raise RuntimeError('DynamoDB failed authoritative convergence')


def delete_versions(s3, bucket, versions):
    for start in range(0, len(versions), 1000):
        response = s3.delete_objects(Bucket=bucket, Delete={'Objects': versions[start:start+1000], 'Quiet': True})
        if response.get('Errors'):
            raise RuntimeError('S3 object version deletion failed')


def repair_archive(m, db, outbox):
    s3, bucket = client('s3'), m['audit']['bucket_name']
    by_seq = {r['seq']: r['payload'] for r in outbox}
    versions, markers = [], []
    for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
        versions.extend(page.get('Versions', []))
        markers.extend(page.get('DeleteMarkers', []))
    keep, covered = set(), set()
    pattern = re.compile(r'^ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson$')
    for v in sorted(versions, key=lambda x: x['Key']):
        match = pattern.fullmatch(v['Key'])
        if not v['IsLatest'] or not match:
            continue
        first, last = int(match[1]), int(match[2])
        if first > last or last-first+1 > len(by_seq):
            continue
        seqs = set(range(first, last+1))
        if first > last or not seqs.issubset(by_seq) or seqs & covered:
            continue
        body = s3.get_object(Bucket=bucket, Key=v['Key'], VersionId=v['VersionId'])['Body'].read()
        try:
            payloads = [json.loads(line) for line in body.splitlines()]
        except (ValueError, UnicodeError):
            continue
        if hashlib.sha256(body).hexdigest()[:16] != match[3] or payloads != [by_seq[s] for s in range(first,last+1)]:
            continue
        covered |= seqs
        keep.add((v['Key'], v['VersionId']))
    purge = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in versions if (v['Key'],v['VersionId']) not in keep]
    purge += [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in markers]
    delete_versions(s3, bucket, purge)
    pending = sorted(by_seq.keys() - covered)
    while pending:
        batch = [pending.pop(0)]
        while pending and pending[0] == batch[-1]+1 and len(batch)<100:
            batch.append(pending.pop(0))
        body = (''.join(canonical_json(by_seq[s])+'\n' for s in batch)).encode()
        key = f'ledger-audit/batch-{batch[0]:08d}-{batch[-1]:08d}-{hashlib.sha256(body).hexdigest()[:16]}.ndjson'
        s3.put_object(Bucket=bucket, Key=key, Body=body, ContentType='application/x-ndjson',
                      ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
        covered.update(batch)
    if covered != set(by_seq):
        raise RuntimeError('Audit archive is missing events')
    db.execute('UPDATE clearledger.outbox SET archived_at=greatest(clock_timestamp(),published_at) WHERE archived_at IS NULL')


def repair_cache(m, settlements):
    cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
    expected = {f"clearledger:settlement:{s['settlement_id']}" for s in settlements}
    for key in cache.scan_iter(count=1000):
        if key.decode() not in expected:
            cache.delete(key)
    pipe = cache.pipeline(transaction=True)
    for s in settlements:
        body = dict(settlementId=str(s['settlement_id']), accountId=s['account_id'], reference=s['reference'],
                    debitParty=s['debit_party'], creditParty=s['credit_party'], status=s['current_status'],
                    clearingStage=s['current_stage'], lastEntryId=str(s['last_entry_id']) if s['last_entry_id'] else None,
                    lastMemo=s['last_memo'], version=s['version'], entryCount=s['entry_count'], updatedAt=timestamp(s['updated_at']))
        pipe.set(f"clearledger:settlement:{s['settlement_id']}", canonical_json(body), ex=90)
    pipe.execute()
    if {k.decode() for k in cache.scan_iter()} != expected:
        raise RuntimeError('Valkey contains unexpected keys')


def reconcile():
    m = manifest()
    with pause_workers(m):
        with connect() as db:
            db.execute("SET LOCAL lock_timeout='30s'")
            db.execute('SELECT pg_advisory_xact_lock(748294102)')
            # API writes block briefly rather than being lost or raced by snapshot repair.
            db.execute('LOCK TABLE clearledger.settlements, clearledger.events, clearledger.outbox, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
            settlements = db.execute('SELECT * FROM clearledger.settlements ORDER BY settlement_id').fetchall()
            events = db.execute('SELECT * FROM clearledger.events ORDER BY seq').fetchall()
            sqs = client('sqs')
            for row in db.execute('SELECT * FROM clearledger.outbox WHERE published_at IS NULL ORDER BY seq').fetchall():
                sqs.send_message(QueueUrl=m['messaging']['queue_url'], MessageBody=canonical_json(row['payload']))
                db.execute('UPDATE clearledger.outbox SET published_at=greatest(clock_timestamp(),created_at), attempts=attempts+1,last_error=NULL WHERE seq=%s', (row['seq'],))
            outbox = db.execute('SELECT * FROM clearledger.outbox ORDER BY seq').fetchall()
            repair_dynamodb(m, settlements, events)
            repair_archive(m, db, outbox)
            # Queue deliveries are duplicates of already reconciled records. Drain valid
            # committed events now, retaining poison messages for the normal DLQ flow.
            known = {str(e['event_id']): e['payload'] for e in events}
            for _ in range(1000):
                messages = sqs.receive_message(QueueUrl=m['messaging']['queue_url'], MaxNumberOfMessages=10, WaitTimeSeconds=0).get('Messages', [])
                if not messages:
                    break
                deletions = []
                for n, msg in enumerate(messages):
                    try:
                        payload = json.loads(msg['Body'])
                    except ValueError:
                        continue
                    if isinstance(payload, dict) and known.get(payload.get('eventId')) == payload:
                        deletions.append({'Id': str(n), 'ReceiptHandle': msg['ReceiptHandle']})
                if deletions:
                    sqs.delete_message_batch(QueueUrl=m['messaging']['queue_url'], Entries=deletions)
                else:
                    break
            repair_cache(m, settlements)
    print('Outbox, DynamoDB, Valkey, and versioned S3 archive reconciled against PostgreSQL.')


def ready():
    deadline = time.monotonic()+120
    url = manifest()['service_url'] + '/health/ready'
    while time.monotonic()<deadline:
        try:
            if requests.get(url, timeout=5).status_code == 200:
                print('API health/ready: HTTP 200.')
                return
        except requests.RequestException:
            pass
        time.sleep(2)
    raise TimeoutError('API did not become ready')


def validate(path):
    schema = json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text())
    jsonschema.Draft202012Validator(schema).validate(json.loads(Path(path).read_text()))


def protect():
    plan = json.loads((ROOT / 'infra/deploy.plan.json').read_text())
    for change in plan.get('resource_changes', []):
        if change['type'] in ('aws_db_instance', 'aws_dynamodb_table', 'aws_s3_bucket') and 'delete' in change['change']['actions']:
            raise RuntimeError(f"Refusing data-losing replacement of {change['address']}")


def active_prefix():
    path = ROOT / 'infra/terraform.tfstate'
    if path.exists():
        state = json.loads(path.read_text())
        previous = state.get('outputs', {}).get('manifest', {}).get('value', {}).get('resource_prefix')
        if previous and previous != PREFIX:
            raise RuntimeError('Configuration prefix does not match the active Terraform state')


if __name__ == '__main__':
    commands = {'policies': policies, 'schema': schema, 'reconcile': reconcile, 'ready': ready,
                'protect': protect, 'active-prefix': active_prefix, 'validate': lambda: validate(sys.argv[2])}
    commands[sys.argv[1]]()
