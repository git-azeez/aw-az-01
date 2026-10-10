"""Optional lifecycle test. Destroys this deployment and verifies baseline isolation."""
import json
import subprocess

from ops import C, P, ROOT, client, pages


def inventory():
    result = {}
    specs = [
        ('ec2','describe_vpcs','Vpcs','VpcId'),
        ('ec2','describe_subnets','Subnets','SubnetId'),
        ('ec2','describe_security_groups','SecurityGroups','GroupId'),
        ('ec2','describe_route_tables','RouteTables','RouteTableId'),
        ('ec2','describe_internet_gateways','InternetGateways','InternetGatewayId'),
        ('elbv2','describe_load_balancers','LoadBalancers','LoadBalancerArn'),
        ('elbv2','describe_target_groups','TargetGroups','TargetGroupArn'),
        ('rds','describe_db_instances','DBInstances','DBInstanceIdentifier'),
        ('rds','describe_db_subnet_groups','DBSubnetGroups','DBSubnetGroupName'),
        ('dynamodb','list_tables','TableNames',None),
        ('elasticache','describe_replication_groups','ReplicationGroups','ReplicationGroupId'),
        ('elasticache','describe_cache_subnet_groups','CacheSubnetGroups','CacheSubnetGroupName'),
        ('sqs','list_queues','QueueUrls',None),
        ('lambda','list_functions','Functions','FunctionName'),
        ('lambda','list_event_source_mappings','EventSourceMappings','UUID'),
        ('scheduler','list_schedules','Schedules','Name'),
        ('cognito-idp','list_user_pools','UserPools','Name'),
        ('iam','list_roles','Roles','RoleName'),
        ('logs','describe_log_groups','logGroups','logGroupName'),
        ('s3','list_buckets','Buckets','Name'),
        ('ecs','list_clusters','clusterArns',None),
    ]
    for service, operation, key, field in specs:
        kwargs = {'MaxResults':60} if operation == 'list_user_pools' else {}
        items = list(pages(service,operation,key,**kwargs))
        ids = [i[field] if field else i for i in items]
        result[service+'/'+operation] = sorted(ids)
    result['kms/enabled_keys'] = sorted(k['KeyId'] for k in pages('kms','list_keys','Keys') if client('kms').describe_key(KeyId=k['KeyId'])['KeyMetadata']['KeyState'] != 'PendingDeletion')
    return result


before = inventory()
# Resources injected to test both naming and tagging scope, including dependencies.
tags = [{'Key':'ClearLedgerDeployment','Value':P}]
client('sqs').create_queue(QueueName=P+'-outofband',tags={'ClearLedgerDeployment':P})
client('s3').create_bucket(Bucket=P+'-outofband')
client('s3').put_bucket_versioning(Bucket=P+'-outofband',VersioningConfiguration={'Status':'Enabled'})
client('s3').put_object(Bucket=P+'-outofband',Key='test',Body=b'data')
client('logs').create_log_group(logGroupName='/clearledger/'+P+'/outofband',tags={'ClearLedgerDeployment':P})
client('iam').create_role(RoleName=P+'-outofband',Tags=tags,AssumeRolePolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]}))
policy=client('iam').create_policy(PolicyName=P+'-outofband',Tags=tags,PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sqs:SendMessage','Resource':'arn:aws:sqs:'+C['region']+':000000000000:'+P+'-outofband'}]}))['Policy']
client('iam').attach_role_policy(RoleName=P+'-outofband',PolicyArn=policy['Arn'])
key=client('kms').create_key(Description=P+'-outofband',Tags=[{'TagKey':'ClearLedgerDeployment','TagValue':P}])['KeyMetadata']
client('kms').create_alias(AliasName='alias/'+P+'-outofband',TargetKeyId=key['KeyId'])
client('dynamodb').create_table(TableName=P+'-outofband',BillingMode='PAY_PER_REQUEST',KeySchema=[{'AttributeName':'id','KeyType':'HASH'}],AttributeDefinitions=[{'AttributeName':'id','AttributeType':'S'}],Tags=tags)

subprocess.run([str(ROOT/'destroy.sh')],check=True,timeout=900)
after=inventory()
# All baseline (cl-base-*) resources and default VPC objects must survive. All other
# pre-test objects here were part of our initially empty ClearLedger deployment.
for service, ids in after.items():
    if service.startswith('ec2/'):
        assert not set(ids)-set(before[service]), (service,ids)
    else:
        assert all('cl-base-' in i for i in ids), (service,ids)
assert not json.loads((ROOT/'infra/terraform.tfstate').read_text()).get('resources')
print('Teardown and out-of-band cleanup passed.')
