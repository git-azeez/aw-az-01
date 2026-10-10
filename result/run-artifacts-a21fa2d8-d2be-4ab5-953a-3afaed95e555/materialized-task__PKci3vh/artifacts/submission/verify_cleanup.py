"""Seed disposable, out-of-band operational dependencies for teardown verification."""
from operations import *
name = PREFIX+'-ops'
tags = {'ClearLedgerDeployment': PREFIX}
taglist = [{'Key': k, 'Value': v} for k,v in tags.items()]
iam=client('iam')
role=iam.create_role(RoleName=name, Tags=taglist, AssumeRolePolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]}))['Role']
iam.create_instance_profile(InstanceProfileName=name, Tags=taglist)
iam.add_role_to_instance_profile(InstanceProfileName=name, RoleName=name)
policy=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:ListBucket','Resource':'arn:aws:s3:::'+name}]})
p=iam.create_policy(PolicyName=name, PolicyDocument=policy, Tags=taglist)['Policy']
iam.create_policy_version(PolicyArn=p['Arn'], PolicyDocument=policy, SetAsDefault=True)
iam.attach_role_policy(RoleName=name, PolicyArn=p['Arn'])
iam.put_role_policy(RoleName=name, PolicyName=name, PolicyDocument=policy)
s3=client('s3'); s3.create_bucket(Bucket=name)
s3.put_bucket_tagging(Bucket=name, Tagging={'TagSet':taglist})
s3.put_bucket_versioning(Bucket=name, VersioningConfiguration={'Status':'Enabled'})
for body in (b'first', b'second'): s3.put_object(Bucket=name,Key='versioned',Body=body)
s3.delete_object(Bucket=name,Key='versioned')
s3.create_multipart_upload(Bucket=name,Key='incomplete')
pool=client('cognito-idp').create_user_pool(PoolName=name, UserPoolTags=tags)['UserPool']
client('cognito-idp').create_user_pool_domain(Domain=name, UserPoolId=pool['Id'])
client('sqs').create_queue(QueueName=name,tags=tags)
client('dynamodb').create_table(TableName=name,BillingMode='PAY_PER_REQUEST',AttributeDefinitions=[{'AttributeName':'PK','AttributeType':'S'}],KeySchema=[{'AttributeName':'PK','KeyType':'HASH'}],Tags=taglist)
client('logs').create_log_group(logGroupName='/clearledger/'+name+'/operations',tags=tags)
client('ecs').register_task_definition(family=name,networkMode='awsvpc',requiresCompatibilities=['FARGATE'],cpu='256',memory='512',containerDefinitions=[{'name':'api','image':C['api_image'],'essential':True}],tags=[{'key':k,'value':v} for k,v in tags.items()])
key=client('kms').create_key(Description=name,Tags=[{'TagKey':k,'TagValue':v} for k,v in tags.items()])['KeyMetadata']
client('kms').create_alias(AliasName='alias/'+name,TargetKeyId=key['KeyId'])
print('Seeded scoped multipart uploads, object versions, Cognito domain, IAM profile and versioned policies, queue, table, logs, task definition and KMS key')
