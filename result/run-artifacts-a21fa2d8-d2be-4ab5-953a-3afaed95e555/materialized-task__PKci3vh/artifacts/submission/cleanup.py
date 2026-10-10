"""Prefix/tag-scoped teardown, including operational resources outside Terraform."""
import json
import sys
import time
from operations import ROOT, PREFIX, client, pages, absent, delete_policy, versions
from botocore.exceptions import ClientError

BEFORE = sys.argv[1] == 'before'
STATE = json.loads((ROOT / 'infra/terraform.tfstate').read_text()) if (ROOT / 'infra/terraform.tfstate').exists() else {}
MANAGED = {}
for resource in STATE.get('resources', []):
    if resource['mode'] != 'managed': continue
    for instance in resource.get('instances', []):
        a = instance['attributes']
        MANAGED.setdefault(resource['type'], set()).update(a[k] for k in ('id', 'arn', 'name', 'identifier', 'bucket', 'function_name', 'replication_group_id', 'family') if isinstance(a.get(k), str))

TAGGED = set()
try:
    TAGGED = {r['ResourceARN'] for r in pages('resourcegroupstaggingapi', 'get_resources', 'ResourceTagMappingList', TagFilters=[{'Key': 'ClearLedgerDeployment', 'Values': [PREFIX]}])}
except ClientError as e:
    if e.response['Error']['Code'] not in ('NotImplemented', 'NotImplementedException', 'UnknownOperationException'): raise

def owned(name, tags=None):
    # Baseline names win even if someone has incorrectly tagged a baseline resource.
    if 'cl-base-' in name: return False
    if isinstance(tags, list): tags = {t.get('Key', t.get('TagKey', t.get('key'))): t.get('Value', t.get('TagValue', t.get('value'))) for t in tags}
    return (name.startswith(PREFIX) or '/'+PREFIX in name or ':'+PREFIX in name or
            name in TAGGED or (tags or {}).get('ClearLedgerDeployment') == PREFIX or (tags or {}).get('Name', '').startswith(PREFIX+'-'))

def extra(kind, *ids):
    return not BEFORE or not any(i in MANAGED.get(kind, set()) for i in ids)

def call(service, method, **args):
    try:
        return getattr(client(service), method)(**args)
    except ClientError as e:
        if not absent(e): raise
        return {}

def empty_bucket(bucket):
    s3 = client('s3')
    for u in pages('s3', 'list_multipart_uploads', 'Uploads', Bucket=bucket):
        s3.abort_multipart_upload(Bucket=bucket, Key=u['Key'], UploadId=u['UploadId'])
    entries = [{'Key': v['Key'], 'VersionId': v['VersionId']} for _, v in versions(bucket)]
    entries += [{'Key': v['Key']} for v in pages('s3', 'list_objects_v2', 'Contents', Bucket=bucket) if not entries]
    for start in range(0, len(entries), 1000):
        result = s3.delete_objects(Bucket=bucket, Delete={'Objects': entries[start:start+1000], 'Quiet': True})
        if result.get('Errors'): raise RuntimeError(result['Errors'])

def stop_producers():
    for s in pages('scheduler', 'list_schedules', 'Schedules'):
        if owned(s['Name']) or owned(s['Arn']):
            if extra('aws_scheduler_schedule', s['Arn'], s['Name']):
                call('scheduler', 'delete_schedule', Name=s['Name'], GroupName=s['GroupName'])
            else:
                old = client('scheduler').get_schedule(Name=s['Name'], GroupName=s['GroupName'])
                args = {k: old[k] for k in ('Name', 'GroupName', 'ScheduleExpression', 'ScheduleExpressionTimezone', 'FlexibleTimeWindow', 'Target') if k in old}
                client('scheduler').update_schedule(**args, State='DISABLED')
    for mapping in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings'):
        if owned(mapping['FunctionArn']) or owned(mapping.get('EventSourceArn', '')):
            if extra('aws_lambda_event_source_mapping', mapping['UUID']):
                call('lambda', 'delete_event_source_mapping', UUID=mapping['UUID'])
            else:
                call('lambda', 'update_event_source_mapping', UUID=mapping['UUID'], Enabled=False)
    for arn in pages('ecs', 'list_clusters', 'clusterArns'):
        cluster = client('ecs').describe_clusters(clusters=[arn], include=['TAGS'])['clusters'][0]
        if not owned(arn, cluster.get('tags')): continue
        for service in pages('ecs', 'list_services', 'serviceArns', cluster=arn):
            client('ecs').update_service(cluster=arn, service=service, desiredCount=0)
            if extra('aws_ecs_service', service):
                call('ecs', 'delete_service', cluster=arn, service=service, force=True)
        for task in pages('ecs', 'list_tasks', 'taskArns', cluster=arn):
            call('ecs', 'stop_task', cluster=arn, task=task, reason='ClearLedger deployment teardown')
        if extra('aws_ecs_cluster', arn): call('ecs', 'delete_cluster', cluster=arn)
    time.sleep(4)

def iam_cleanup():
    iam = client('iam')
    for p in pages('iam', 'list_instance_profiles', 'InstanceProfiles'):
        p = iam.get_instance_profile(InstanceProfileName=p['InstanceProfileName'])['InstanceProfile']
        if owned(p['InstanceProfileName'], p.get('Tags')) or any(owned(r['RoleName']) for r in p['Roles']):
            for r in p['Roles']:
                if owned(r['RoleName']) or owned(p['InstanceProfileName'], p.get('Tags')):
                    iam.remove_role_from_instance_profile(InstanceProfileName=p['InstanceProfileName'], RoleName=r['RoleName'])
            if owned(p['InstanceProfileName'], p.get('Tags')):
                iam.delete_instance_profile(InstanceProfileName=p['InstanceProfileName'])
    for r in pages('iam', 'list_roles', 'Roles'):
        r = iam.get_role(RoleName=r['RoleName'])['Role']
        if not owned(r['RoleName'], r.get('Tags')): continue
        name = r['RoleName']
        for p in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=p['PolicyArn'])
        for p in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
            if extra('aws_iam_role_policy', f'{name}:{p}'):
                iam.delete_role_policy(RoleName=name, PolicyName=p)
        if extra('aws_iam_role', name): iam.delete_role(RoleName=name)
    for p in pages('iam', 'list_policies', 'Policies', Scope='Local'):
        tags = list(pages('iam', 'list_policy_tags', 'Tags', PolicyArn=p['Arn']))
        if not owned(p['PolicyName'], tags) or not extra('aws_iam_policy', p['Arn']): continue
        entities = iam.list_entities_for_policy(PolicyArn=p['Arn'])
        for r in entities.get('PolicyRoles', []): iam.detach_role_policy(RoleName=r['RoleName'], PolicyArn=p['Arn'])
        for u in entities.get('PolicyUsers', []): iam.detach_user_policy(UserName=u['UserName'], PolicyArn=p['Arn'])
        for g in entities.get('PolicyGroups', []): iam.detach_group_policy(GroupName=g['GroupName'], PolicyArn=p['Arn'])
        delete_policy(p['Arn'])

def application_cleanup():
    cognito = client('cognito-idp')
    for p in pages('cognito-idp', 'list_user_pools', 'UserPools', MaxResults=60):
        pool = cognito.describe_user_pool(UserPoolId=p['Id'])['UserPool']
        if not owned(pool['Name'], pool.get('UserPoolTags')): continue
        domains = {pool[field] for field in ('Domain', 'CustomDomain') if pool.get(field)}
        for r in STATE.get('resources', []):
            if r['type'] == 'aws_cognito_user_pool_domain':
                domains.update(i['attributes']['domain'] for i in r['instances'] if i['attributes']['user_pool_id']==p['Id'])
        # AWS reports Domain on DescribeUserPool. Some local control-plane versions
        # omit it; recover recorded requests and conventional pool-derived names.
        if not domains:
            for event in pages('cloudtrail', 'lookup_events', 'Events', LookupAttributes=[{'AttributeKey':'EventName','AttributeValue':'CreateUserPoolDomain'}]):
                request = json.loads(event.get('CloudTrailEvent', '{}')).get('requestParameters', {})
                if request.get('userPoolId', request.get('UserPoolId')) == p['Id']:
                    domains.add(request.get('domain', request.get('Domain')))
            bases = {pool['Name'], PREFIX}
            for suffix in ('-pool', '-user-pool', '-userpool', '-users', '-auth', '-cognito'):
                if pool['Name'].endswith(suffix): bases.add(pool['Name'][:-len(suffix)])
            candidates = bases | {b+'-domain' for b in bases}
            for domain in candidates:
                desc = call('cognito-idp', 'describe_user_pool_domain', Domain=domain).get('DomainDescription', {})
                if desc.get('UserPoolId') == p['Id']: domains.add(domain)
        for domain in domains:
            if domain: cognito.delete_user_pool_domain(Domain=domain, UserPoolId=p['Id'])
        if extra('aws_cognito_user_pool', p['Id']): cognito.delete_user_pool(UserPoolId=p['Id'])
    for f in pages('lambda', 'list_functions', 'Functions'):
        tags = client('lambda').list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if owned(f['FunctionName'], tags) and extra('aws_lambda_function', f['FunctionName']):
            call('lambda', 'delete_function', FunctionName=f['FunctionName'])
    for group in pages('logs', 'describe_log_groups', 'logGroups'):
        tags = client('logs').list_tags_log_group(logGroupName=group['logGroupName']).get('tags', {})
        if owned(group['logGroupName'], tags) and extra('aws_cloudwatch_log_group', group['logGroupName']):
            call('logs', 'delete_log_group', logGroupName=group['logGroupName'])
    for rule in pages('events', 'list_rules', 'Rules'):
        tags = client('events').list_tags_for_resource(ResourceARN=rule['Arn']).get('Tags', [])
        if owned(rule['Name'], tags):
            targets = list(pages('events', 'list_targets_by_rule', 'Targets', Rule=rule['Name']))
            if targets: client('events').remove_targets(Rule=rule['Name'], Ids=[t['Id'] for t in targets], Force=True)
            client('events').delete_rule(Name=rule['Name'], Force=True)
    for s in pages('scheduler', 'list_schedule_groups', 'ScheduleGroups'):
        if owned(s['Name']): call('scheduler', 'delete_schedule_group', Name=s['Name'])

def data_cleanup():
    s3 = client('s3')
    for b in pages('s3', 'list_buckets', 'Buckets'):
        try: tags = s3.get_bucket_tagging(Bucket=b['Name']).get('TagSet', [])
        except ClientError as e:
            if e.response['Error']['Code'] != 'NoSuchTagSet': raise
            tags = []
        if owned(b['Name'], tags):
            empty_bucket(b['Name'])
            if extra('aws_s3_bucket', b['Name']): s3.delete_bucket(Bucket=b['Name'])
    for q in pages('sqs', 'list_queues', 'QueueUrls'):
        tags = client('sqs').list_queue_tags(QueueUrl=q).get('Tags', {})
        if owned(q, tags) and extra('aws_sqs_queue', q): call('sqs', 'delete_queue', QueueUrl=q)
    for name in pages('dynamodb', 'list_tables', 'TableNames'):
        desc = client('dynamodb').describe_table(TableName=name)['Table']
        tags = client('dynamodb').list_tags_of_resource(ResourceArn=desc['TableArn']).get('Tags', [])
        if owned(name, tags) and extra('aws_dynamodb_table', name):
            call('dynamodb', 'delete_table', TableName=name)
    for db in pages('rds', 'describe_db_instances', 'DBInstances'):
        tags = client('rds').list_tags_for_resource(ResourceName=db['DBInstanceArn']).get('TagList', [])
        if owned(db['DBInstanceIdentifier'], tags) and db.get('DeletionProtection'):
            client('rds').modify_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
        if owned(db['DBInstanceIdentifier'], tags) and extra('aws_db_instance', db['DBInstanceIdentifier'], db['DBInstanceArn']):
            if db.get('DeletionProtection'): client('rds').modify_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
            client('rds').delete_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
            client('rds').get_waiter('db_instance_deleted').wait(DBInstanceIdentifier=db['DBInstanceIdentifier'], WaiterConfig={'Delay': 2, 'MaxAttempts': 60})
    for snap in pages('rds', 'describe_db_snapshots', 'DBSnapshots'):
        tags = client('rds').list_tags_for_resource(ResourceName=snap['DBSnapshotArn']).get('TagList', [])
        if owned(snap['DBSnapshotIdentifier'], tags): call('rds', 'delete_db_snapshot', DBSnapshotIdentifier=snap['DBSnapshotIdentifier'])
    for group in pages('rds', 'describe_db_subnet_groups', 'DBSubnetGroups'):
        tags = client('rds').list_tags_for_resource(ResourceName=group['DBSubnetGroupArn']).get('TagList', [])
        if owned(group['DBSubnetGroupName'], tags) and extra('aws_db_subnet_group', group['DBSubnetGroupName']):
            call('rds', 'delete_db_subnet_group', DBSubnetGroupName=group['DBSubnetGroupName'])
    for group in pages('elasticache', 'describe_replication_groups', 'ReplicationGroups'):
        tags = client('elasticache').list_tags_for_resource(ResourceName=group['ARN']).get('TagList', [])
        if owned(group['ReplicationGroupId'], tags) and extra('aws_elasticache_replication_group', group['ReplicationGroupId']):
            call('elasticache', 'delete_replication_group', ReplicationGroupId=group['ReplicationGroupId'], RetainPrimaryCluster=False)
    for cache in pages('elasticache', 'describe_cache_clusters', 'CacheClusters'):
        tags = client('elasticache').list_tags_for_resource(ResourceName=cache['ARN']).get('TagList', []) if cache.get('ARN') else []
        if owned(cache['CacheClusterId'], tags) and not cache.get('ReplicationGroupId'):
            call('elasticache', 'delete_cache_cluster', CacheClusterId=cache['CacheClusterId'])
    for group in pages('elasticache', 'describe_cache_subnet_groups', 'CacheSubnetGroups'):
        tags = client('elasticache').list_tags_for_resource(ResourceName=group['ARN']).get('TagList', []) if group.get('ARN') else []
        if owned(group['CacheSubnetGroupName'], tags) and extra('aws_elasticache_subnet_group', group['CacheSubnetGroupName']):
            call('elasticache', 'delete_cache_subnet_group', CacheSubnetGroupName=group['CacheSubnetGroupName'])

def networking_cleanup():
    elb = client('elbv2')
    for lb in pages('elbv2', 'describe_load_balancers', 'LoadBalancers'):
        tags = elb.describe_tags(ResourceArns=[lb['LoadBalancerArn']])['TagDescriptions'][0].get('Tags', [])
        if owned(lb['LoadBalancerName'], tags) and extra('aws_lb', lb['LoadBalancerArn']):
            elb.delete_load_balancer(LoadBalancerArn=lb['LoadBalancerArn'])
    for tg in pages('elbv2', 'describe_target_groups', 'TargetGroups'):
        tags = elb.describe_tags(ResourceArns=[tg['TargetGroupArn']])['TagDescriptions'][0].get('Tags', [])
        if owned(tg['TargetGroupName'], tags) and extra('aws_lb_target_group', tg['TargetGroupArn']):
            elb.delete_target_group(TargetGroupArn=tg['TargetGroupArn'])
    ec2 = client('ec2')
    groups = ec2.describe_security_groups()['SecurityGroups']
    for sg in groups:
        if owned(sg['GroupName'], sg.get('Tags')) and extra('aws_security_group', sg['GroupId']):
            if sg['IpPermissions']: ec2.revoke_security_group_ingress(GroupId=sg['GroupId'], IpPermissions=sg['IpPermissions'])
            if sg['IpPermissionsEgress']: ec2.revoke_security_group_egress(GroupId=sg['GroupId'], IpPermissions=sg['IpPermissionsEgress'])
    for sg in groups:
        if owned(sg['GroupName'], sg.get('Tags')) and extra('aws_security_group', sg['GroupId']):
            ec2.delete_security_group(GroupId=sg['GroupId'])
    for rt in ec2.describe_route_tables()['RouteTables']:
        if owned(rt['RouteTableId'], rt.get('Tags')) and extra('aws_route_table', rt['RouteTableId']):
            for a in rt.get('Associations', []):
                if not a.get('Main'): ec2.disassociate_route_table(AssociationId=a['RouteTableAssociationId'])
            if not any(a.get('Main') for a in rt.get('Associations', [])):
                ec2.delete_route_table(RouteTableId=rt['RouteTableId'])
    for sub in ec2.describe_subnets()['Subnets']:
        if owned(sub['SubnetId'], sub.get('Tags')) and extra('aws_subnet', sub['SubnetId']): ec2.delete_subnet(SubnetId=sub['SubnetId'])
    for gw in ec2.describe_internet_gateways()['InternetGateways']:
        if owned(gw['InternetGatewayId'], gw.get('Tags')) and extra('aws_internet_gateway', gw['InternetGatewayId']):
            for a in gw.get('Attachments', []): ec2.detach_internet_gateway(InternetGatewayId=gw['InternetGatewayId'], VpcId=a['VpcId'])
            ec2.delete_internet_gateway(InternetGatewayId=gw['InternetGatewayId'])
    for vpc in ec2.describe_vpcs()['Vpcs']:
        if owned(vpc['VpcId'], vpc.get('Tags')) and extra('aws_vpc', vpc['VpcId']): ec2.delete_vpc(VpcId=vpc['VpcId'])

def keys_and_task_definitions():
    ecs = client('ecs')
    for status in ('ACTIVE', 'INACTIVE'):
        for arn in pages('ecs', 'list_task_definitions', 'taskDefinitionArns', status=status):
            td = ecs.describe_task_definition(taskDefinition=arn, include=['TAGS'])
            if owned(arn, td.get('tags')) and extra('aws_ecs_task_definition', arn):
                if status == 'ACTIVE': ecs.deregister_task_definition(taskDefinition=arn)
                result = ecs.delete_task_definitions(taskDefinitions=[arn])
                if result.get('failures'): raise RuntimeError(result['failures'])
    kms = client('kms')
    alias_keys = set()
    for a in pages('kms', 'list_aliases', 'Aliases'):
        if owned(a['AliasName']):
            alias_keys.add(a.get('TargetKeyId'))
            if extra('aws_kms_alias', a['AliasName']): kms.delete_alias(AliasName=a['AliasName'])
    for k in pages('kms', 'list_keys', 'Keys'):
        meta = kms.describe_key(KeyId=k['KeyId'])['KeyMetadata']
        if meta.get('KeyManager') == 'AWS': continue
        tags = list(pages('kms', 'list_resource_tags', 'Tags', KeyId=k['KeyId']))
        if (owned(meta.get('Description', ''), tags) or owned(k['KeyArn'], tags) or k['KeyId'] in alias_keys) and extra('aws_kms_key', k['KeyId']):
            if meta['KeyState'] != 'PendingDeletion': kms.schedule_key_deletion(KeyId=k['KeyId'], PendingWindowInDays=10)

stop_producers()
application_cleanup()
data_cleanup()
iam_cleanup()
networking_cleanup()
keys_and_task_definitions()
print(f'Prefix-scoped cleanup ({sys.argv[1]}) complete', flush=True)
