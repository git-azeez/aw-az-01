import sys,json,time
sys.path.insert(0,'/workspace/submission')
import lifecycle as l
import redis
m=l.manifest()
p=l.PREFIX
l.schedules(m,False)
l.mapping(m,False)
time.sleep(4)
conn=l.db();conn.autocommit=True
l.sql(conn,'UPDATE clearledger.outbox SET published_at=NULL,archived_at=NULL WHERE seq=1')
conn.close()
table=m['projections']['table_name']
items=l.scan_table(table)
state=next(i for i in items if i['SK']['S']=='STATE')
state['version']={'N':'999'}
state['GSI1PK']={'S':'ACCOUNT#WRONG'}
state['reference']={'S':'CORRUPTED'}
l.client('dynamodb').put_item(TableName=table,Item=state)
l.client('dynamodb').put_item(TableName=table,Item={'PK':{'S':'SETTLEMENT#orphan'},'SK':{'S':'STATE'},'version':{'N':'999'}})
event=next(i for i in items if i['SK']['S']=='EVENT#00000001')
event['memo']={'S':'CORRUPTED'}
l.client('dynamodb').put_item(TableName=table,Item=event)
l.client('dynamodb').put_item(TableName=table,Item={'PK':state['PK'],'SK':{'S':'STRAY'}})
cache=redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'])
cache.set('stray-key','bad')
cache.set('clearledger:settlement:orphan','{}')
cache.set('clearledger:settlement:'+state['settlement_id']['S'],'{"version":999}')
s3=l.client('s3');b=m['audit']['bucket_name']
s3.put_object(Bucket=b,Key='foreign.txt',Body=b'corrupt')
s3.put_object(Bucket=b,Key='foreign.txt',Body=b'corrupt v2')
s3.delete_object(Bucket=b,Key='foreign.txt')
for role in l.ROLE_KEYS:
    name=p+'-'+role
    l.client('iam').put_role_policy(RoleName=name,PolicyName=p+'-oob',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}))
policy=l.client('iam').create_policy(PolicyName=p+'-oob-managed',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}))['Policy']
l.client('iam').create_policy_version(PolicyArn=policy['Arn'],PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'*'}]}),SetAsDefault=True)
l.client('iam').attach_role_policy(RoleName=p+'-projector',PolicyArn=policy['Arn'])
for role in ('rds','valkey','alb'):
    l.client('ec2').authorize_security_group_egress(GroupId=m['network']['security_group_ids'][role],IpPermissions=[{'IpProtocol':'-1','IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
l.client('logs').put_retention_policy(logGroupName=m['logs']['api_log_group'],retentionInDays=1)
l.client('lambda').update_function_configuration(FunctionName=m['workers']['outbox_relay']['function_name'],Environment={'Variables':{'AWS_ENDPOINT_URL':l.C['aws_endpoint_url'],'OUTBOX_BATCH_SIZE':'1'}})
l.client('sqs').set_queue_attributes(QueueUrl=m['messaging']['dlq_url'],Attributes={'MessageRetentionPeriod':'60'})
l.client('sqs').delete_queue(QueueUrl=m['messaging']['queue_url'])
l.client('scheduler').delete_schedule(Name=m['schedules']['archive_schedule_name'])
print('Injected queue/schedule deletion, IAM/SG/log/Lambda drift, divergent projections/cache, versioned archive corruption and unpublished outbox')
