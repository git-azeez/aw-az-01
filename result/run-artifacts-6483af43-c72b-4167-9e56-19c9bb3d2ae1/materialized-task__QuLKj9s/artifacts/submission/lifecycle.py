"""Declarative provisioning with prefix-scoped repair and PostgreSQL-led recovery."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import jsonschema
import psycopg2

ROOT = Path(__file__).resolve().parent
CFG = json.loads(Path('/workspace/config/config.json').read_text())
PREFIX = CFG['resource_prefix']
if PREFIX.startswith('cl-base-') or len(PREFIX) < 4:
    raise RuntimeError('resource_prefix must identify a non-baseline deployment')
ENV = dict(os.environ, AWS_ACCESS_KEY_ID='test', AWS_SECRET_ACCESS_KEY='test',
           AWS_REGION=CFG['region'], AWS_DEFAULT_REGION=CFG['region'],
           AWS_ENDPOINT_URL=CFG['aws_endpoint_url'], TF_VAR_config=json.dumps(CFG))
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=CFG['region'])
CLIENTS = {}


def client(service):
    if service not in CLIENTS:
        CLIENTS[service] = SESSION.client(service, endpoint_url=CFG['aws_endpoint_url'],
            config=Config(connect_timeout=5, read_timeout=30, retries={'max_attempts': 4},
                          s3={'addressing_style': 'path'}))
    return CLIENTS[service]


def pages(service, operation, result, **kwargs):
    c = client(service)
    if c.can_paginate(operation):
        for page in c.get_paginator(operation).paginate(**kwargs):
            yield from page.get(result, [])
    else:
        yield from getattr(c, operation)(**kwargs).get(result, [])


def absent_ok(fn, **kwargs):
    try:
        return fn(**kwargs)
    except ClientError as e:
        code = e.response['Error']['Code']
        if any(x in code.lower() for x in ('notfound', 'not_found', 'nosuch', 'nonexistent')):
            return None
        raise


def scoped(name='', tags=None):
    if str(name).startswith('cl-base-'):
        return False
    if (str(name).startswith(PREFIX + '-') or str(name).startswith('/clearledger/' + PREFIX + '/')
            or any(part.startswith(PREFIX + '-') for part in str(name).split('/'))):
        return True
    if isinstance(tags, list):
        tags = {t.get('Key'): t.get('Value') for t in tags}
    return (tags or {}).get('ClearLedgerDeployment') == PREFIX


def tf(*args, capture=False):
    result = subprocess.run(['terraform', *args], cwd=ROOT / 'infra', env=ENV,
                            text=True, stdout=subprocess.PIPE if capture else None, check=True)
    return result.stdout


def state_resources():
    path = ROOT / 'infra/terraform.tfstate'
    return json.loads(path.read_text()).get('resources', []) if path.exists() else []


def repair_keys():
    kms = client('kms')
    canonical = {}
    for r in state_resources():
        if r['type'] == 'aws_kms_key':
            for i in r['instances']:
                canonical[i['attributes']['id']] = i['index_key']
    for alias in pages('kms', 'list_aliases', 'Aliases'):
        for usage in ('database', 'messaging', 'projection', 'audit'):
            if alias['AliasName'] == f'alias/{PREFIX}-{usage}' and alias.get('TargetKeyId'):
                canonical[alias['TargetKeyId']] = usage
    for key, usage in canonical.items():
        response = absent_ok(kms.describe_key, KeyId=key)
        if not response:
            continue
        status = response['KeyMetadata']['KeyState']
        if status == 'PendingDeletion':
            kms.cancel_key_deletion(KeyId=key)
            status = 'Disabled'
        if status == 'Disabled':
            kms.enable_key(KeyId=key)
        kms.enable_key_rotation(KeyId=key)
        kms.tag_resource(KeyId=key, Tags=[{'TagKey': 'ClearLedgerDeployment', 'TagValue': PREFIX},
                         {'TagKey': 'ClearLedgerKeyUsage', 'TagValue': usage},
                         {'TagKey': 'Name', 'TagValue': f'{PREFIX}-{usage}'}])


def delete_policy(arn):
    iam = client('iam')
    for v in pages('iam', 'list_policy_versions', 'Versions', PolicyArn=arn):
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    # Operational policies can have attachments to multiple deployment roles/profiles.
    for kind, arg in [('PolicyRoles', 'RoleName'), ('PolicyUsers', 'UserName'), ('PolicyGroups', 'GroupName')]:
        for entity in pages('iam', 'list_entities_for_policy', kind, PolicyArn=arn):
            getattr(iam, {'RoleName': 'detach_role_policy', 'UserName': 'detach_user_policy',
                          'GroupName': 'detach_group_policy'}[arg])(**{arg: entity[arg], 'PolicyArn': arn})
    iam.delete_policy(PolicyArn=arn)


def clean_iam(destroy=False):
    iam = client('iam')
    canonical = {f'{PREFIX}-{r}': f'{PREFIX}-{r}-canonical' for r in
                 ('ecs_execution', 'ecs_task', 'projector', 'relay', 'archiver', 'scheduler')}
    for role in pages('iam', 'list_roles', 'Roles'):
        name = role['RoleName']
        tags = iam.list_role_tags(RoleName=name).get('Tags', [])
        if not scoped(name, tags) or (not destroy and name not in canonical):
            continue
        for policy in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
            if destroy or policy != canonical[name]:
                iam.delete_role_policy(RoleName=name, PolicyName=policy)
        for policy in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])
        if destroy:
            for profile in pages('iam', 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if scoped(profile['InstanceProfileName'], profile.get('Tags')):
                    iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
    for policy in list(pages('iam', 'list_policies', 'Policies', Scope='Local')):
        tags = iam.list_policy_tags(PolicyArn=policy['Arn']).get('Tags', [])
        if scoped(policy['PolicyName'], tags):
            delete_policy(policy['Arn'])


def manifest():
    value = json.loads(tf('output', '-json', 'manifest', capture=True))
    schema = json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text())
    jsonschema.validate(value, schema)
    tmp = ROOT / 'manifest.json.tmp'
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.chmod(0o600)
    tmp.replace(ROOT / 'manifest.json')
    return value


def database(m):
    db = m['database']
    deadline = time.monotonic() + 90
    while True:
        try:
            return psycopg2.connect(host=db['endpoint'], port=db['port'], dbname=CFG['db_name'],
                user=CFG['db_username'], password=CFG['db_password'], connect_timeout=5,
                application_name='clearledger-deployment')
        except psycopg2.OperationalError:
            if time.monotonic() >= deadline:
                raise RuntimeError('PostgreSQL did not become reachable') from None
            time.sleep(2)


def schedule_state(m, enabled):
    c = client('scheduler')
    for field in ('outbox_schedule_name', 'archive_schedule_name'):
        name = m['schedules'][field]
        s = c.get_schedule(Name=name)
        keep = ('Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone',
                'StartDate', 'EndDate', 'Description', 'KmsKeyArn', 'FlexibleTimeWindow', 'Target',
                'ActionAfterCompletion')
        args = {k: s[k] for k in keep if k in s}
        args['State'] = 'ENABLED' if enabled else 'DISABLED'
        c.update_schedule(**args)


def mapping_state(m, enabled):
    c = client('lambda')
    uuid = m['messaging']['event_source_mapping_uuid']
    c.update_event_source_mapping(UUID=uuid, Enabled=enabled)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        state = c.get_event_source_mapping(UUID=uuid)['State']
        if state == ('Enabled' if enabled else 'Disabled'):
            return
        time.sleep(0.5)
    raise RuntimeError('Event source mapping did not settle')


def invoke_projector(m, messages):
    records = [{'messageId': x['MessageId'], 'receiptHandle': x['ReceiptHandle'], 'body': x['Body'],
        'attributes': x.get('Attributes', {}), 'messageAttributes': x.get('MessageAttributes', {}),
        'eventSource': 'aws:sqs', 'eventSourceARN': m['messaging']['queue_arn'],
        'awsRegion': CFG['region']} for x in messages]
    response = client('lambda').invoke(FunctionName=m['workers']['projector']['function_name'],
        InvocationType='RequestResponse', Payload=json.dumps({'Records': records}).encode())
    payload = json.loads(response['Payload'].read())
    if response.get('FunctionError'):
        raise RuntimeError('Projector failed during reconciliation')
    failed = {x['itemIdentifier'] for x in payload.get('batchItemFailures', [])}
    entries = [{'Id': str(i), 'ReceiptHandle': x['ReceiptHandle']}
               for i, x in enumerate(messages) if x['MessageId'] not in failed]
    if entries:
        result = client('sqs').delete_message_batch(QueueUrl=m['messaging']['queue_url'], Entries=entries)
        if result.get('Failed'):
            raise RuntimeError('SQS acknowledgement failed')


def drain(m):
    sqs = client('sqs')
    queue = m['messaging']['queue_url']
    deadline = time.monotonic() + 120
    empty = 0
    while time.monotonic() < deadline:
        messages = sqs.receive_message(QueueUrl=queue, MaxNumberOfMessages=5, WaitTimeSeconds=1,
            VisibilityTimeout=3, MessageSystemAttributeNames=['All'], MessageAttributeNames=['All']).get('Messages', [])
        if messages:
            invoke_projector(m, messages)
            empty = 0
        else:
            attrs = sqs.get_queue_attributes(QueueUrl=queue, AttributeNames=[
                'ApproximateNumberOfMessages', 'ApproximateNumberOfMessagesNotVisible',
                'ApproximateNumberOfMessagesDelayed'])['Attributes']
            empty = empty + 1 if all(int(v) == 0 for v in attrs.values()) else 0
            if empty >= 2:
                return
    raise RuntimeError('Main SQS queue did not drain')


def wait_ready(m):
    deadline = time.monotonic() + 100
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(m['service_url'] + '/health/ready', timeout=3) as r:
                if r.status == 200:
                    return
        except Exception:
            pass
        time.sleep(1)
    raise RuntimeError('API readiness did not reach HTTP 200')


def deploy():
    tf('init', '-input=false', '-no-color')
    repair_keys()
    clean_iam()
    tf('apply', '-input=false', '-auto-approve', '-no-color')
    # The local EC2 implementation can retain its default outbound rule on
    # creation. A refreshed apply removes it using the declared inline rules.
    tf('apply', '-input=false', '-auto-approve', '-no-color', '-compact-warnings')
    m = manifest()
    with database(m) as conn:
        with conn.cursor() as cur:
            # psql meta-command is used only when this file is run directly.
            sql = (ROOT / 'schema.sql').read_text().replace('\\set ON_ERROR_STOP on\n', '')
            cur.execute(sql)
    wait_ready(m)
    schedule_state(m, False)
    mapping_state(m, False)
    try:
        time.sleep(4)  # Allow already-running 3-second worker invocations to finish.
        from reconcile import converge
        with database(m) as conn:
            converge(conn, m, client, drain)
    finally:
        schedule_state(m, True)
        mapping_state(m, True)
    wait_ready(m)
    print('ClearLedger deployed; control plane and derived stores reconciled.', flush=True)


def destroy():
    tf('init', '-input=false', '-no-color')
    from teardown import preclean, sweep
    repair_keys()
    canonical = set()
    mapping_ids = set()
    for r in state_resources():
        for instance in r.get('instances', []):
            attrs = instance.get('attributes', {})
            for key in ('id', 'arn', 'name', 'identifier', 'family', 'description', 'function_name',
                        'replication_group_id', 'bucket', 'user_pool_id'):
                if isinstance(attrs.get(key), str):
                    canonical.add(attrs[key])
            canonical.update(str(v) for v in attrs.get('tags_all', {}).values() if v != PREFIX)
            if r['type'] == 'aws_lambda_event_source_mapping':
                mapping_ids.add(attrs['id'])
    for mapping in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings'):
        function = mapping.get('FunctionArn', '').split(':function:')[-1].split(':')[0]
        if scoped(function) and mapping['UUID'] not in mapping_ids:
            client('lambda').delete_event_source_mapping(UUID=mapping['UUID'])
    preclean(client, pages, scoped, clean_iam)
    def operational_scope(name='', tags=None):
        normalized = {t.get('Key'): t.get('Value') for t in tags} if isinstance(tags, list) else (tags or {})
        if name in canonical or name.removeprefix('alias/') in canonical or normalized.get('Name') in canonical:
            return False
        return scoped(name, tags)
    # Remove unmanaged dependencies first so they cannot pin managed VPCs,
    # subnet groups, IAM roles, or ECS clusters during Terraform destruction.
    sweep(client, pages, operational_scope, absent_ok, clean_iam)
    tf('destroy', '-input=false', '-auto-approve', '-no-color')
    sweep(client, pages, scoped, absent_ok, clean_iam)
    if any(r.get('mode') == 'managed' and r.get('instances') for r in state_resources()):
        raise RuntimeError('Managed resources remain in Terraform state')
    print('ClearLedger teardown complete.', flush=True)


if __name__ == '__main__':
    {'deploy': deploy, 'destroy': destroy}[sys.argv[1]]()
