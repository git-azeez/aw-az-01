import json, pathlib, uuid
import boto3, psycopg, redis

c = json.loads(pathlib.Path('/workspace/config/config.json').read_text())
m = json.loads(pathlib.Path('/workspace/submission/manifest.json').read_text())
p = c['resource_prefix']
session = boto3.Session(region_name=c['region'], aws_access_key_id='test', aws_secret_access_key='test')
def cli(service): return session.client(service, endpoint_url=c['aws_endpoint_url'])
sid = json.loads(pathlib.Path('/workspace/evidence/verified_settlement.json').read_text())['settlement_id']
ddb = cli('dynamodb'); table = m['projections']['table_name']
ddb.update_item(TableName=table, Key={'PK': {'S':'SETTLEMENT#'+sid},'SK':{'S':'STATE'}}, UpdateExpression='SET GSI1PK = :bad, #v = :v', ExpressionAttributeNames={'#v':'version'}, ExpressionAttributeValues={':bad':{'S':'ACCOUNT#wrong'}, ':v':{'N':'999'}})
ddb.put_item(TableName=table, Item={'PK':{'S':'SETTLEMENT#orphan'},'SK':{'S':'STATE'},'version':{'N':'999'}})
ddb.put_item(TableName=table, Item={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'STRAY'}})
ddb.update_item(TableName=table, Key={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'EVENT#00000002'}}, UpdateExpression='SET memo = :bad', ExpressionAttributeValues={':bad':{'S':'corrupt'}})
cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'])
cache.set('clearledger:settlement:orphan', '{}')
cache.set('clearledger:settlement:'+sid, '{"version":999}')
s3 = cli('s3'); bucket = m['audit']['bucket_name']
objects = s3.list_objects_v2(Bucket=bucket).get('Contents', [])
for obj in objects:
    s3.put_object(Bucket=bucket, Key=obj['Key'], Body=b'{"corrupt":true}\n')
s3.put_object(Bucket=bucket, Key='outside-audit.txt', Body=b'bad')
s3.delete_object(Bucket=bucket, Key='outside-audit.txt')
with psycopg.connect(host=m['database']['endpoint'], port=m['database']['port'], user=c['db_username'], password=c['db_password'], dbname=c['db_name'], autocommit=True) as db:
    db.execute('UPDATE clearledger.outbox SET published_at = NULL, archived_at = NULL')
lam = cli('lambda')
lam.delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
env = lam.get_function_configuration(FunctionName=m['workers']['projector']['function_name'])['Environment']['Variables']
env['PROJECTION_TABLE'] = 'missing-projections'
lam.update_function_configuration(FunctionName=m['workers']['projector']['function_name'], Environment={'Variables':env})
for name in [m['schedules']['outbox_schedule_name'], m['schedules']['archive_schedule_name']]:
    cli('scheduler').delete_schedule(Name=name)
for url in [m['messaging']['queue_url'], m['messaging']['dlq_url']]:
    cli('sqs').delete_queue(QueueUrl=url)
for group in m['logs'].values(): cli('logs').put_retention_policy(logGroupName=group, retentionInDays=1)
iam = cli('iam')
policy = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}
extra = iam.create_policy(PolicyName=p+'-drill-extra', PolicyDocument=json.dumps(policy))['Policy']['Arn']
iam.create_policy_version(PolicyArn=extra, PolicyDocument=json.dumps(policy), SetAsDefault=True)
for arn in m['iam'].values():
    name = arn.rsplit('/',1)[-1]
    iam.put_role_policy(RoleName=name, PolicyName=p+'-rogue', PolicyDocument=json.dumps(policy))
    iam.attach_role_policy(RoleName=name, PolicyArn=extra)
ec2 = cli('ec2')
for name in ['alb','rds','valkey']:
    ec2.authorize_security_group_egress(GroupId=m['network']['security_group_ids'][name], IpPermissions=[{'IpProtocol':'-1','IpRanges':[{'CidrIp':'0.0.0.0/0'}],'Ipv6Ranges':[{'CidrIpv6':'::/0'}]}])
print('Injected deleted queues/mapping/schedules, IAM/log/Lambda/security-group drift, unpublished outbox, and corrupt DynamoDB/Valkey/versioned S3 data.')
