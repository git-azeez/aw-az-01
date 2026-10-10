"""Optional destructive drift drill against this deployment; run with 'drift' or 'outage'."""
import json
import subprocess
import sys

import requests
from botocore.exceptions import ClientError

from ops import ROOT, C, client, manifest, db, Valkey, pages

m = manifest()
before = m['database']['instance_id'], m['database']['instance_arn'], m['projections']['table_arn'], m['audit']['bucket_name']
conn = db(m)
cur = conn.cursor()
cur.execute('SELECT count(*) FROM clearledger.events')
event_count = cur.fetchone()[0]
conn.close()

if sys.argv[1] == 'outage':
    client('lambda').delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
    client('sqs').delete_queue(QueueUrl=m['messaging']['queue_url'])
else:
    ec2 = client('ec2')
    for name, port in [('ecs', 8080), ('rds', 5432), ('valkey', 6379)]:
        try:
            ec2.authorize_security_group_ingress(GroupId=m['network']['security_group_ids'][name],
                                                  IpPermissions=[{'IpProtocol': 'tcp', 'FromPort': port, 'ToPort': port,
                                                                  'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}])
        except ClientError as e:
            if e.response['Error']['Code'] != 'InvalidPermission.Duplicate':
                raise
    client('ecs').update_service(cluster=m['compute']['cluster_name'], service=m['compute']['service_name'], desiredCount=1)
    client('ecs').update_cluster_settings(cluster=m['compute']['cluster_name'], settings=[{'name': 'containerInsights', 'value': 'disabled'}])
    client('elbv2').modify_target_group(TargetGroupArn=m['ingress']['target_group_arn'], HealthCheckPath='/health/live', HealthCheckIntervalSeconds=30)
    client('kms').disable_key(KeyId=m['kms']['messaging_arn'])
    client('kms').disable_key_rotation(KeyId=m['kms']['audit_arn'])
    client('kms').untag_resource(KeyId=m['kms']['projection_arn'], TagKeys=['ClearLedgerDeployment'])
    client('rds').remove_tags_from_resource(ResourceName=m['database']['instance_arn'], TagKeys=['ClearLedgerDeployment'])
    client('sqs').set_queue_attributes(QueueUrl=m['messaging']['queue_url'], Attributes={'VisibilityTimeout': '12', 'RedrivePolicy': json.dumps({'deadLetterTargetArn': m['messaging']['dlq_arn'], 'maxReceiveCount': 9})})
    client('s3').put_bucket_versioning(Bucket=m['audit']['bucket_name'], VersioningConfiguration={'Status': 'Suspended'})
    client('s3').put_bucket_encryption(Bucket=m['audit']['bucket_name'], ServerSideEncryptionConfiguration={'Rules': [{'ApplyServerSideEncryptionByDefault': {'SSEAlgorithm': 'AES256'}}]})
    client('s3').put_public_access_block(Bucket=m['audit']['bucket_name'], PublicAccessBlockConfiguration={k: False for k in ['BlockPublicAcls', 'IgnorePublicAcls', 'BlockPublicPolicy', 'RestrictPublicBuckets']})
    client('dynamodb').update_continuous_backups(TableName=m['projections']['table_name'], PointInTimeRecoverySpecification={'PointInTimeRecoveryEnabled': False})
    role = m['iam']['ecs_task_role_arn'].split('/')[-1]
    client('iam').put_role_policy(RoleName=role, PolicyName=C['resource_prefix']+'-rogue', PolicyDocument=json.dumps({'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]}))
    v = m['auth']['clients']['write']
    client('cognito-idp').update_user_pool_client(UserPoolId=m['auth']['user_pool_id'], ClientId=v['client_id'], AllowedOAuthFlowsUserPoolClient=True, AllowedOAuthFlows=['client_credentials'], AllowedOAuthScopes=['clearledger/read'])
    conn = db(m)
    cur = conn.cursor()
    cur.execute('DROP INDEX clearledger.idx_clearledger_entry_id')
    cur.execute('ALTER TABLE clearledger.settlements DROP CONSTRAINT settlements_header_check')
    cur.execute('ALTER TABLE clearledger.settlements ADD CONSTRAINT settlements_header_check CHECK (version > 0)')
    for table in ['settlements','events','outbox','idempotency_keys']:
        cur.execute(f'ALTER TABLE clearledger.{table} DISABLE TRIGGER USER')
    conn.commit()
    conn.close()
    d = client('dynamodb')
    items = list(pages('dynamodb','scan','Items',TableName=m['projections']['table_name']))
    for item in items:
        if item['SK']['S'] == 'STATE':
            item['version'] = {'N': '999'}
            item['last_memo'] = {'S': 'Corrupt memo'}
            d.put_item(TableName=m['projections']['table_name'],Item=item)
            break
    d.put_item(TableName=m['projections']['table_name'],Item={'PK': {'S':'ORPHAN'},'SK': {'S':'STRAY'}})
    cache = Valkey(m['cache']['endpoint'],m['cache']['port'])
    cache.command('SET','stray-key','bad')
    cache.command('SET','clearledger:settlement:orphan','bad')
    cache.close()
    s3=client('s3')
    objects=s3.list_objects_v2(Bucket=m['audit']['bucket_name']).get('Contents',[])
    if objects:
        s3.put_object(Bucket=m['audit']['bucket_name'],Key=objects[0]['Key'],Body=b'corrupt audit\n')
    s3.put_object(Bucket=m['audit']['bucket_name'],Key='outside/rogue.ndjson',Body=b'bad\n')

subprocess.run([str(ROOT/'deploy.sh')],check=True,timeout=720)
m = manifest()
after = m['database']['instance_id'], m['database']['instance_arn'], m['projections']['table_arn'], m['audit']['bucket_name']
assert before == after, 'Persistent resource identity changed'
conn=db(m)
cur=conn.cursor()
cur.execute('SELECT count(*) FROM clearledger.events')
assert cur.fetchone()[0] == event_count
cur.execute('SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN (\'clearledger.settlements\'::regclass,\'clearledger.events\'::regclass,\'clearledger.outbox\'::regclass,\'clearledger.idempotency_keys\'::regclass) AND tgenabled <> \'O\'')
assert cur.fetchone()[0] == 0
cur.execute('SELECT settlement_id::text FROM clearledger.settlements')
ids=[r[0] for r in cur.fetchall()]
cur.execute('SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL')
assert cur.fetchone()[0] == 0
conn.close()
v=m['auth']['clients']['read']
token=requests.post(m['auth']['token_endpoint'],auth=(v['client_id'],v['client_secret']),data={'grant_type':'client_credentials','scope':v['scope']},timeout=10).json()['access_token']
for sid in ids:
    response=requests.get(m['service_url']+f'/v1/settlements/{sid}',headers={'Authorization':'Bearer '+token},timeout=10)
    assert response.status_code == 200 and response.headers['X-ClearLedger-Source'] == 'cache', (response.status_code,response.text,response.headers)
for page in client('s3').get_paginator('list_object_versions').paginate(Bucket=m['audit']['bucket_name']):
    assert not page.get('DeleteMarkers')
    assert all(v['IsLatest'] and v['Key'].startswith('ledger-audit/batch-') for v in page.get('Versions',[]))
assert all(i['PK']['S'].startswith('SETTLEMENT#') for i in pages('dynamodb','scan','Items',TableName=m['projections']['table_name']))
print('Recovery drill passed:',sys.argv[1])
