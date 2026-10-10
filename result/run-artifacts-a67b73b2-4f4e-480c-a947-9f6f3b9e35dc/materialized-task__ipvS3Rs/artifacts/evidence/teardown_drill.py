import sys,json
from pathlib import Path
sys.path.insert(0,'/workspace/submission')
import lifecycle as l
p=l.PREFIX;m=l.manifest();tags=[{'Key':'ClearLedgerDeployment','Value':p}]
iam=l.client('iam')
role=iam.create_role(RoleName=p+'-breakglass',AssumeRolePolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]}),Tags=tags)['Role']
pol=iam.create_policy(PolicyName=p+'-breakglass-policy',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}),Tags=tags)['Policy']
for action in ['s3:*','dynamodb:*']:
    iam.create_policy_version(PolicyArn=pol['Arn'],PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':action,'Resource':'*'}]}),SetAsDefault=True)
iam.attach_role_policy(RoleName=role['RoleName'],PolicyArn=pol['Arn'])
iam.attach_role_policy(RoleName=p+'-relay',PolicyArn=pol['Arn'])
iam.put_role_policy(RoleName=role['RoleName'],PolicyName='emergency',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}))
s3=l.client('s3');b=p+'-operational'
s3.create_bucket(Bucket=b)
s3.put_bucket_tagging(Bucket=b,Tagging={'TagSet':tags})
s3.put_bucket_versioning(Bucket=b,VersioningConfiguration={'Status':'Enabled'})
for i in range(3):s3.put_object(Bucket=b,Key='operational-object',Body=str(i).encode())
s3.delete_object(Bucket=b,Key='operational-object')
l.client('dynamodb').create_table(TableName=p+'-operational',BillingMode='PAY_PER_REQUEST',KeySchema=[{'AttributeName':'PK','KeyType':'HASH'}],AttributeDefinitions=[{'AttributeName':'PK','AttributeType':'S'}],Tags=tags)
l.client('sqs').create_queue(QueueName=p+'-operational',tags={'ClearLedgerDeployment':p})
l.client('scheduler').create_schedule(Name=p+'-operational',ScheduleExpression='rate(1 minute)',State='DISABLED',FlexibleTimeWindow={'Mode':'OFF'},Target={'Arn':m['workers']['outbox_relay']['function_arn'],'RoleArn':m['iam']['scheduler_role_arn']})
key=l.client('kms').create_key(Description=p+'-operational',Tags=[{'TagKey':'ClearLedgerDeployment','TagValue':p}])['KeyMetadata']
l.client('kms').create_alias(AliasName='alias/'+p+'-operational',TargetKeyId=key['KeyId'])
l.client('logs').create_log_group(logGroupName='/clearledger/'+p+'/operational',tags={'ClearLedgerDeployment':p})
print('Created prefix-scoped teardown drill resources, multi-version policies and non-empty versioned bucket')
