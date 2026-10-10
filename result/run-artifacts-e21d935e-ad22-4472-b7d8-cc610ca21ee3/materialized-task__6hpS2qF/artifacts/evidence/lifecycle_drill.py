import sys,json
from pathlib import Path
sys.path.insert(0,'/workspace/submission')
import ops
p=ops.P;m=ops.manifest();tags=[{'Key':'ClearLedgerDeployment','Value':p}]
def inventory():
 result={}
 result['vpcs']=[x['VpcId'] for x in ops.client('ec2').describe_vpcs()['Vpcs'] if not ops.scoped('',x.get('Tags',[]))]
 result['subnets']=[x['SubnetId'] for x in ops.client('ec2').describe_subnets()['Subnets'] if not ops.scoped('',x.get('Tags',[]))]
 result['roles']=[x['RoleName'] for x in ops.pages('iam','list_roles','Roles') if not ops.scoped(x['RoleName'])]
 result['policies']=[x['Arn'] for x in ops.pages('iam','list_policies','Policies',Scope='Local') if not ops.scoped(x['PolicyName'])]
 result['sqs']=[x for x in ops.pages('sqs','list_queues','QueueUrls') if not ops.scoped(x.rsplit('/',1)[-1])]
 result['ddb']=[x for x in ops.pages('dynamodb','list_tables','TableNames') if not ops.scoped(x)]
 result['s3']=[x['Name'] for x in ops.client('s3').list_buckets()['Buckets'] if not ops.scoped(x['Name'])]
 result['schedules']=[x['Name'] for x in ops.pages('scheduler','list_schedules','Schedules') if not ops.scoped(x['Name'])]
 result['logs']=[x['logGroupName'] for x in ops.pages('logs','describe_log_groups','logGroups') if not ops.scoped(x['logGroupName'])]
 result['lambda']=[x['FunctionName'] for x in ops.pages('lambda','list_functions','Functions') if not ops.scoped(x['FunctionName'])]
 result['rds']=[x['DBInstanceIdentifier'] for x in ops.pages('rds','describe_db_instances','DBInstances') if not ops.scoped(x['DBInstanceIdentifier'])]
 result['cache']=[x['ReplicationGroupId'] for x in ops.pages('elasticache','describe_replication_groups','ReplicationGroups') if not ops.scoped(x['ReplicationGroupId'])]
 result['alb']=[x['LoadBalancerName'] for x in ops.pages('elbv2','describe_load_balancers','LoadBalancers') if not ops.scoped(x['LoadBalancerName'])]
 result['cognito']=[x['Name'] for x in ops.pages('cognito-idp','list_user_pools','UserPools',MaxResults=60) if not ops.scoped(x['Name'])]
 result['kms_aliases']=[x['AliasName'] for x in ops.pages('kms','list_aliases','Aliases') if not ops.scoped(x['AliasName'])]
 result['kms_keys']=[]
 for x in ops.pages('kms','list_keys','Keys'):
  meta=ops.client('kms').describe_key(KeyId=x['KeyId'])['KeyMetadata']
  if meta['KeyState']=='PendingDeletion':continue
  t=ops.client('kms').list_resource_tags(KeyId=x['KeyId'])['Tags']
  if not ops.scoped(meta.get('Description',''),t):result['kms_keys'].append(x['KeyId'])
 return {k:sorted(v) for k,v in result.items()}
mode=sys.argv[1]
if mode=='before':
 Path('/workspace/evidence/baseline.json').write_text(json.dumps(inventory(),indent=2))
 print('Baseline inventory recorded')
elif mode=='seed':
 iam=ops.client('iam');policy={'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:ListBucket','Resource':m['audit']['bucket_arn']}]}
 arn=iam.create_policy(PolicyName=p+'-operational-policy',PolicyDocument=json.dumps(policy),Tags=tags)['Policy']['Arn']
 for i in range(3):iam.create_policy_version(PolicyArn=arn,PolicyDocument=json.dumps(policy),SetAsDefault=True)
 name=p+'-breakglass'
 iam.create_role(RoleName=name,AssumeRolePolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]}),Tags=tags)
 iam.attach_role_policy(RoleName=name,PolicyArn=arn)
 iam.put_role_policy(RoleName=name,PolicyName=p+'-inline',PolicyDocument=json.dumps(policy))
 iam.attach_role_policy(RoleName=m['iam']['ecs_task_role_arn'].rsplit('/',1)[1],PolicyArn=arn)
 ops.client('sqs').create_queue(QueueName=p+'-operational-queue',tags={'ClearLedgerDeployment':p})
 ops.client('dynamodb').create_table(TableName=p+'-operational-table',BillingMode='PAY_PER_REQUEST',AttributeDefinitions=[{'AttributeName':'PK','AttributeType':'S'}],KeySchema=[{'AttributeName':'PK','KeyType':'HASH'}],Tags=tags)
 s3=ops.client('s3');bucket=p+'-operational-audit';s3.create_bucket(Bucket=bucket);s3.put_bucket_tagging(Bucket=bucket,Tagging={'TagSet':tags});s3.put_bucket_versioning(Bucket=bucket,VersioningConfiguration={'Status':'Enabled'})
 for i in range(3):s3.put_object(Bucket=bucket,Key='drill',Body=str(i).encode())
 s3.delete_object(Bucket=bucket,Key='drill')
 ops.client('scheduler').create_schedule(Name=p+'-operational-schedule',ScheduleExpression='rate(30 minutes)',FlexibleTimeWindow={'Mode':'OFF'},Target={'Arn':m['workers']['outbox_relay']['function_arn'],'RoleArn':m['iam']['scheduler_role_arn']})
 kms=ops.client('kms');key=kms.create_key(Description=p+'-operational-key',Tags=[{'TagKey':'ClearLedgerDeployment','TagValue':p}])['KeyMetadata']['KeyId'];kms.create_alias(AliasName='alias/'+p+'-operational-key',TargetKeyId=key);kms.schedule_key_deletion(KeyId=key,PendingWindowInDays=10)
 ops.client('logs').create_log_group(logGroupName='/clearledger/'+p+'/operational',tags={'ClearLedgerDeployment':p})
 print('Operational resources and multi-version IAM/S3 drift created')
elif mode=='after':
 expected=json.loads(Path('/workspace/evidence/baseline.json').read_text());actual=inventory();assert expected==actual,(expected,actual)
 # Inventory filters do not hide prefix leftovers; explicitly assert all named operational classes empty.
 assert not [x for x in ops.pages('iam','list_roles','Roles') if ops.scoped(x['RoleName'])]
 assert not [x for x in ops.pages('iam','list_policies','Policies',Scope='Local') if ops.scoped(x['PolicyName'])]
 assert not [x for x in ops.pages('sqs','list_queues','QueueUrls') if ops.scoped(x.rsplit('/',1)[-1])]
 assert not [x for x in ops.pages('dynamodb','list_tables','TableNames') if ops.scoped(x)]
 assert not [x for x in ops.client('s3').list_buckets()['Buckets'] if ops.scoped(x['Name'])]
 assert not [x for x in ops.pages('kms','list_aliases','Aliases') if ops.scoped(x['AliasName'])]
 print('Baseline inventory preserved; operational resources removed; KMS keys pending AWS deletion window.')
