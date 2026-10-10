import sys,json,uuid
sys.path.insert(0,'/workspace/submission')
import ops
m=ops.manifest();p=m['resource_prefix']
ddb=ops.client('dynamodb');table=m['projections']['table_name']
items=ddb.scan(TableName=table)['Items']
for item in items:
 if item['SK']['S']=='STATE':
  item['version']={'N':'999'};item['GSI1PK']={'S':'ACCOUNT#wrong'};item['reference']={'S':'corrupt'}
  ddb.put_item(TableName=table,Item=item)
 elif item['SK']['S']=='EVENT#00000001':
  item['memo']={'S':'corrupt'};ddb.put_item(TableName=table,Item=item)
ddb.put_item(TableName=table,Item={'PK':{'S':'SETTLEMENT#orphan'},'SK':{'S':'STATE'}})
ddb.put_item(TableName=table,Item={'PK':items[0]['PK'],'SK':{'S':'EXTRANEOUS'}})
cache=ops.redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'])
cache.set('clearledger:settlement:orphan','{}')
for i in items:
 if i['SK']['S']=='STATE':cache.set('clearledger:settlement:'+i['settlement_id']['S'],'{"version":999}')
s3=ops.client('s3');bucket=m['audit']['bucket_name'];versions=ops.versions(bucket)
for v in versions:
 if v['IsLatest'] and not v['marker']:
  s3.put_object(Bucket=bucket,Key=v['Key'],Body=b'corrupted\n')
s3.put_object(Bucket=bucket,Key='outside/rogue.ndjson',Body=b'{}\n')
s3.delete_object(Bucket=bucket,Key='outside/rogue.ndjson')
with ops.db(m) as conn:
 with conn.cursor() as cur:cur.execute('UPDATE clearledger.outbox SET published_at=NULL,archived_at=NULL')
 conn.commit()
sqs=ops.client('sqs')
sqs.set_queue_attributes(QueueUrl=m['messaging']['dlq_url'],Attributes={'MessageRetentionPeriod':'60'})
sqs.delete_queue(QueueUrl=m['messaging']['queue_url'])
lamb=ops.client('lambda');lamb.delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
lamb.update_function_configuration(FunctionName=m['workers']['outbox_relay']['function_name'],Environment={'Variables':{'OUTBOX_BATCH_SIZE':'1'}})
for key in ('api_log_group','projector_log_group','relay_log_group','archiver_log_group'):
 ops.client('logs').put_retention_policy(logGroupName=m['logs'][key],retentionInDays=1)
sch=ops.client('scheduler');sch.delete_schedule(Name=m['schedules']['outbox_schedule_name'])
r=sch.get_schedule(Name=m['schedules']['archive_schedule_name'])
sch.update_schedule(Name=r['Name'],ScheduleExpression='rate(9 minutes)',State='DISABLED',FlexibleTimeWindow=r['FlexibleTimeWindow'],Target=r['Target'])
iam=ops.client('iam')
for arn in m['iam'].values():
 name=arn.rsplit('/',1)[1]
 iam.put_role_policy(RoleName=name,PolicyName=p+'-rogue',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}))
 iam.attach_role_policy(RoleName=name,PolicyArn='arn:aws:iam::aws:policy/AdministratorAccess')
for role in ('alb','rds','valkey'):
 ops.client('ec2').authorize_security_group_egress(GroupId=m['network']['security_group_ids'][role],IpPermissions=[{'IpProtocol':'-1','IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
print('Recovery drift injected; durable store IDs:',m['database']['instance_id'],table,bucket)
