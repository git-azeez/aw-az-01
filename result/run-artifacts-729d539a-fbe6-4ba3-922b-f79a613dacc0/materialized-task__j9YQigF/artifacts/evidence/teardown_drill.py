import json, pathlib, sys
import boto3

c = json.loads(pathlib.Path('/workspace/config/config.json').read_text()); p = c['resource_prefix']
session = boto3.Session(region_name=c['region'], aws_access_key_id='test', aws_secret_access_key='test')
def cli(service): return session.client(service, endpoint_url=c['aws_endpoint_url'])
def inventory():
    output = {}
    simple = [('s3','list_buckets','Buckets','Name'),('dynamodb','list_tables','TableNames',None),('sqs','list_queues','QueueUrls',None),('iam','list_roles','Roles','RoleName'),('scheduler','list_schedules','Schedules','Name'),('logs','describe_log_groups','logGroups','logGroupName'),('ec2','describe_vpcs','Vpcs','VpcId'),('ec2','describe_subnets','Subnets','SubnetId'),('ec2','describe_security_groups','SecurityGroups','GroupId'),('ec2','describe_route_tables','RouteTables','RouteTableId'),('ec2','describe_internet_gateways','InternetGateways','InternetGatewayId'),('rds','describe_db_instances','DBInstances','DBInstanceIdentifier'),('elasticache','describe_replication_groups','ReplicationGroups','ReplicationGroupId'),('lambda','list_functions','Functions','FunctionName'),('ecs','list_clusters','clusterArns',None),('elbv2','describe_load_balancers','LoadBalancers','LoadBalancerName'),('elbv2','describe_target_groups','TargetGroups','TargetGroupName')]
    for service, operation, field, name in simple:
        output[service+':'+operation] = sorted(x[name] if name else x for x in getattr(cli(service),operation)().get(field, []))
    output['iam:policies'] = sorted(x['PolicyName'] for x in cli('iam').list_policies(Scope='Local')['Policies'])
    output['kms:aliases'] = sorted(x['AliasName'] for x in cli('kms').list_aliases()['Aliases'])
    output['kms:activekeys'] = sorted(x['KeyId'] for x in cli('kms').list_keys()['Keys'] if cli('kms').describe_key(KeyId=x['KeyId'])['KeyMetadata']['KeyState'] != 'PendingDeletion')
    output['cognito:pools'] = sorted(x['Id'] for x in cli('cognito-idp').list_user_pools(MaxResults=60)['UserPools'])
    return output

if sys.argv[1] == 'snapshot':
    existing = inventory()
    # Snapshot everything outside the managed deployment using actual state IDs.
    state = json.loads(pathlib.Path('/workspace/submission/infra/terraform.tfstate').read_text())
    own_ids = {i['attributes'].get('id') for r in state['resources'] if r.get('mode') == 'managed' for i in r['instances']}
    own_ids |= {i['attributes'].get('key_id') for r in state['resources'] if r.get('mode') == 'managed' for i in r['instances']}
    own_ids |= {i['attributes'].get('identifier') for r in state['resources'] if r.get('mode') == 'managed' for i in r['instances']}
    own_ids |= {i['attributes'].get('name') for r in state['resources'] if r.get('mode') == 'managed' for i in r['instances']}
    for field in ['default_route_table_id','default_security_group_id','default_network_acl_id']:
        own_ids |= {i['attributes'].get(field) for r in state['resources'] if r.get('mode') == 'managed' for i in r['instances']}
    for field in existing:
        existing[field] = [x for x in existing[field] if p not in x and x not in own_ids]
    pathlib.Path('/workspace/evidence/baseline_inventory.json').write_text(json.dumps(existing, indent=2))
    # OOB resources exercise cleanup beyond Terraform state, including tag-only ownership.
    tags = [{'Key':'ClearLedgerDeployment','Value':p}]
    iam = cli('iam')
    role = p+'-breakglass'
    iam.create_role(RoleName=role, AssumeRolePolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sts:AssumeRole','Principal':{'Service':'ecs-tasks.amazonaws.com'}}]}), Tags=tags)
    rogue = json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]})
    iam.put_role_policy(RoleName=role, PolicyName=p+'-breakglass-inline', PolicyDocument=rogue)
    policy = iam.create_policy(PolicyName=p+'-breakglass-policy', PolicyDocument=rogue, Tags=tags)['Policy']['Arn']
    iam.create_policy_version(PolicyArn=policy, PolicyDocument=rogue, SetAsDefault=True)
    iam.attach_role_policy(RoleName=role, PolicyArn=policy)
    s3 = cli('s3'); bucket=p+'-operational'
    s3.create_bucket(Bucket=bucket)
    s3.put_bucket_tagging(Bucket=bucket, Tagging={'TagSet':tags})
    s3.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={'Status':'Enabled'})
    for _ in range(2): s3.put_object(Bucket=bucket, Key='operational', Body=b'old version')
    s3.delete_object(Bucket=bucket, Key='operational')
    cli('dynamodb').create_table(TableName='operational-tagged-'+p, AttributeDefinitions=[{'AttributeName':'id','AttributeType':'S'}], KeySchema=[{'AttributeName':'id','KeyType':'HASH'}], BillingMode='PAY_PER_REQUEST', Tags=tags)
    cli('sqs').create_queue(QueueName=p+'-operational', tags={'ClearLedgerDeployment':p})
    cli('logs').create_log_group(logGroupName='/clearledger/'+p, tags={'ClearLedgerDeployment':p})
    kms=cli('kms')
    key=kms.create_key(Description=p+'-operational', Tags=[{'TagKey':'ClearLedgerDeployment','TagValue':p}])['KeyMetadata']['KeyId']
    kms.create_alias(AliasName='alias/'+p+'-operational', TargetKeyId=key)
    kms.schedule_key_deletion(KeyId=key, PendingWindowInDays=10)
    print('Baseline snapshot saved; injected prefix- and tag-scoped operational teardown resources.')
else:
    baseline = json.loads(pathlib.Path('/workspace/evidence/baseline_inventory.json').read_text())
    after = inventory()
    diffs = {k:{'added':sorted(set(after[k])-set(baseline[k])),'removed':sorted(set(baseline[k])-set(after[k]))} for k in baseline if after[k]!=baseline[k]}
    assert not diffs, diffs
    print('Teardown inventory matches baseline across networking, compute, database, queues, derived stores, identity, schedules, logs and active KMS keys; no managed state remains.')
