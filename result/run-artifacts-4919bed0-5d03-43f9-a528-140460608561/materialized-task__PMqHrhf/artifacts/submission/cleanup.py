"""Prefix/tag-scoped operational cleanup, including resources outside Terraform."""
import json
import sys
import time

from botocore.exceptions import ClientError
from operations import ROOT, P, client, pages, scoped, delete_policy, object_versions

MANAGED = set()
if sys.argv[1] == 'extras':
    path = ROOT / 'infra/terraform.tfstate'
    if path.exists():
        for resource in json.loads(path.read_text()).get('resources', []):
            if resource.get('mode') != 'managed':
                continue
            for instance in resource.get('instances', []):
                for key, value in instance.get('attributes', {}).items():
                    if isinstance(value, str) and (key in ('id', 'arn', 'name', 'identifier', 'bucket',
                        'function_name', 'replication_group_id', 'family') or key.endswith('_arn')):
                        MANAGED.add(value)


def eligible(name, tags=None, *ids):
    return scoped(name, tags) and not any(str(x) in MANAGED for x in (name, *ids))


ERRORS = []


def remove(fn, **kw):
    try:
        fn(**kw)
    except ClientError as e:
        code = e.response['Error']['Code']
        if not any(word in code.lower() for word in ('notfound', 'nosuch', 'nonexistent')):
            ERRORS.append((fn.__name__, code))


def tags_or_empty(c, method, key, **kw):
    try:
        return getattr(c, method)(**kw).get(key, [])
    except ClientError as e:
        if e.response['Error']['Code'] in ('NoSuchTagSet', 'NoSuchTagSetError', 'ResourceNotFoundException'):
            return []
        raise


def sweep():
    scheduler = client('scheduler')
    for s in pages(scheduler, 'list_schedules', 'Schedules'):
        if eligible(s['Name'], None, s['Arn']):
            remove(scheduler.delete_schedule, Name=s['Name'], GroupName=s.get('GroupName', 'default'))
    lam = client('lambda')
    funcs = pages(lam, 'list_functions', 'Functions')
    for f in funcs:
        tags = lam.list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if eligible(f['FunctionName'], tags, f['FunctionArn']):
            for mapping in pages(lam, 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionArn']):
                remove(lam.delete_event_source_mapping, UUID=mapping['UUID'])
            remove(lam.delete_function, FunctionName=f['FunctionName'])
    # Detached mappings may survive a deleted function or queue in the local plane.
    for mapping in pages(lam, 'list_event_source_mappings', 'EventSourceMappings'):
        name = mapping.get('FunctionArn', '').split(':function:')[-1]
        if eligible(name, None, mapping['UUID'], mapping.get('FunctionArn')):
            remove(lam.delete_event_source_mapping, UUID=mapping['UUID'])
    ecs = client('ecs')
    for arn in pages(ecs, 'list_clusters', 'clusterArns'):
        info = ecs.describe_clusters(clusters=[arn], include=['TAGS'])['clusters'][0]
        tags = {t['key']: t['value'] for t in info.get('tags', [])}
        cluster_owned = eligible(info['clusterName'], tags, arn)
        for service_arn in pages(ecs, 'list_services', 'serviceArns', cluster=arn):
            s = ecs.describe_services(cluster=arn, services=[service_arn], include=['TAGS'])['services'][0]
            st = {t['key']: t['value'] for t in s.get('tags', [])}
            if cluster_owned or eligible(s['serviceName'], st, service_arn):
                remove(ecs.update_service, cluster=arn, service=service_arn, desiredCount=0)
                remove(ecs.delete_service, cluster=arn, service=service_arn, force=True)
        if cluster_owned:
            for task in pages(ecs, 'list_tasks', 'taskArns', cluster=arn):
                remove(ecs.stop_task, cluster=arn, task=task, reason='ClearLedger teardown')
            remove(ecs.delete_cluster, cluster=arn)
    inactive = []
    for status in ('ACTIVE', 'INACTIVE'):
        for arn in pages(ecs, 'list_task_definitions', 'taskDefinitionArns', status=status):
            family = arn.split('task-definition/')[-1].rsplit(':', 1)[0]
            if eligible(family, None, arn):
                if status == 'ACTIVE': remove(ecs.deregister_task_definition, taskDefinition=arn)
                inactive.append(arn)
    for i in range(0, len(inactive), 10):
        remove(ecs.delete_task_definitions, taskDefinitions=inactive[i:i+10])
    elb = client('elbv2')
    for lb in pages(elb, 'describe_load_balancers', 'LoadBalancers'):
        arn = lb['LoadBalancerArn']
        tags = elb.describe_tags(ResourceArns=[arn])['TagDescriptions'][0].get('Tags', [])
        if eligible(lb['LoadBalancerName'], tags, arn):
            for listener in pages(elb, 'describe_listeners', 'Listeners', LoadBalancerArn=arn):
                remove(elb.delete_listener, ListenerArn=listener['ListenerArn'])
            remove(elb.delete_load_balancer, LoadBalancerArn=arn)
    for tg in pages(elb, 'describe_target_groups', 'TargetGroups'):
        arn = tg['TargetGroupArn']
        tags = elb.describe_tags(ResourceArns=[arn])['TagDescriptions'][0].get('Tags', [])
        if eligible(tg['TargetGroupName'], tags, arn):
            remove(elb.delete_target_group, TargetGroupArn=arn)
    rds = client('rds')
    for db in pages(rds, 'describe_db_instances', 'DBInstances'):
        tags = rds.list_tags_for_resource(ResourceName=db['DBInstanceArn']).get('TagList', [])
        if eligible(db['DBInstanceIdentifier'], tags, db['DBInstanceArn'], db.get('DbiResourceId')):
            if db.get('DeletionProtection'):
                remove(rds.modify_db_instance, DBInstanceIdentifier=db['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
            remove(rds.delete_db_instance, DBInstanceIdentifier=db['DBInstanceIdentifier'], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    for group in pages(rds, 'describe_db_subnet_groups', 'DBSubnetGroups'):
        tags = rds.list_tags_for_resource(ResourceName=group['DBSubnetGroupArn']).get('TagList', [])
        if eligible(group['DBSubnetGroupName'], tags, group['DBSubnetGroupArn']):
            remove(rds.delete_db_subnet_group, DBSubnetGroupName=group['DBSubnetGroupName'])
    cache = client('elasticache')
    for group in pages(cache, 'describe_replication_groups', 'ReplicationGroups'):
        tags = cache.list_tags_for_resource(ResourceName=group['ARN']).get('TagList', [])
        if eligible(group['ReplicationGroupId'], tags, group['ARN']):
            remove(cache.delete_replication_group, ReplicationGroupId=group['ReplicationGroupId'], RetainPrimaryCluster=False)
    for cluster in pages(cache, 'describe_cache_clusters', 'CacheClusters'):
        if not cluster.get('ReplicationGroupId') and eligible(cluster['CacheClusterId']):
            remove(cache.delete_cache_cluster, CacheClusterId=cluster['CacheClusterId'])
    for group in pages(cache, 'describe_cache_subnet_groups', 'CacheSubnetGroups'):
        if eligible(group['CacheSubnetGroupName']):
            remove(cache.delete_cache_subnet_group, CacheSubnetGroupName=group['CacheSubnetGroupName'])
    ddb = client('dynamodb')
    for table in pages(ddb, 'list_tables', 'TableNames'):
        arn = ddb.describe_table(TableName=table)['Table']['TableArn']
        tags = ddb.list_tags_of_resource(ResourceArn=arn).get('Tags', [])
        if eligible(table, tags, arn): remove(ddb.delete_table, TableName=table)
    s3 = client('s3')
    for bucket in pages(s3, 'list_buckets', 'Buckets'):
        name = bucket['Name']
        tags = tags_or_empty(s3, 'get_bucket_tagging', 'TagSet', Bucket=name)
        if eligible(name, tags, 'arn:aws:s3:::' + name):
            for _, obj in list(object_versions(s3, name)):
                remove(s3.delete_object, Bucket=name, Key=obj['Key'], VersionId=obj['VersionId'])
            for obj in pages(s3, 'list_objects_v2', 'Contents', Bucket=name):
                remove(s3.delete_object, Bucket=name, Key=obj['Key'])
            for upload in pages(s3, 'list_multipart_uploads', 'Uploads', Bucket=name):
                remove(s3.abort_multipart_upload, Bucket=name, Key=upload['Key'], UploadId=upload['UploadId'])
            remove(s3.delete_bucket, Bucket=name)
    sqs = client('sqs')
    for url in pages(sqs, 'list_queues', 'QueueUrls'):
        tags = sqs.list_queue_tags(QueueUrl=url).get('Tags', {})
        if eligible(url.rsplit('/', 1)[-1], tags, url): remove(sqs.delete_queue, QueueUrl=url)
    auth = client('cognito-idp')
    for pool in pages(auth, 'list_user_pools', 'UserPools', MaxResults=60):
        detail = auth.describe_user_pool(UserPoolId=pool['Id'])['UserPool']
        if eligible(pool['Name'], detail.get('UserPoolTags', {}), pool['Id'], detail.get('Arn')):
            if detail.get('Domain'): remove(auth.delete_user_pool_domain, Domain=detail['Domain'], UserPoolId=pool['Id'])
            remove(auth.delete_user_pool, UserPoolId=pool['Id'])
    logs = client('logs')
    for group in pages(logs, 'describe_log_groups', 'logGroups'):
        tags = logs.list_tags_log_group(logGroupName=group['logGroupName']).get('tags', {})
        if eligible(group['logGroupName'], tags, group.get('arn')):
            remove(logs.delete_log_group, logGroupName=group['logGroupName'])
    iam = client('iam')
    for role in pages(iam, 'list_roles', 'Roles'):
        name = role['RoleName']; tags = iam.list_role_tags(RoleName=name).get('Tags', [])
        if eligible(name, tags, role['Arn']):
            for pol in pages(iam, 'list_role_policies', 'PolicyNames', RoleName=name):
                remove(iam.delete_role_policy, RoleName=name, PolicyName=pol)
            for pol in pages(iam, 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
                remove(iam.detach_role_policy, RoleName=name, PolicyArn=pol['PolicyArn'])
            for profile in pages(iam, 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                remove(iam.remove_role_from_instance_profile, InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if scoped(profile['InstanceProfileName']): remove(iam.delete_instance_profile, InstanceProfileName=profile['InstanceProfileName'])
            remove(iam.delete_role, RoleName=name)
    for pol in pages(iam, 'list_policies', 'Policies', Scope='Local'):
        tags = iam.list_policy_tags(PolicyArn=pol['Arn']).get('Tags', [])
        if eligible(pol['PolicyName'], tags, pol['Arn']):
            entities = iam.list_entities_for_policy(PolicyArn=pol['Arn'])
            for role in entities.get('PolicyRoles', []):
                remove(iam.detach_role_policy, RoleName=role['RoleName'], PolicyArn=pol['Arn'])
            for user in entities.get('PolicyUsers', []):
                remove(iam.detach_user_policy, UserName=user['UserName'], PolicyArn=pol['Arn'])
            for group in entities.get('PolicyGroups', []):
                remove(iam.detach_group_policy, GroupName=group['GroupName'], PolicyArn=pol['Arn'])
            remove(delete_policy, iam=iam, arn=pol['Arn'])
    kms = client('kms'); owned_keys = set()
    for alias in pages(kms, 'list_aliases', 'Aliases'):
        if eligible(alias['AliasName'], None, alias.get('AliasArn')):
            if alias.get('TargetKeyId'): owned_keys.add(alias['TargetKeyId'])
            remove(kms.delete_alias, AliasName=alias['AliasName'])
    for key in pages(kms, 'list_keys', 'Keys'):
        tags = pages(kms, 'list_resource_tags', 'Tags', KeyId=key['KeyId'])
        meta = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        if key['KeyId'] in owned_keys or eligible(meta.get('Description', ''), tags, key['KeyId'], key['KeyArn']):
            if meta['KeyState'] != 'PendingDeletion':
                remove(kms.schedule_key_deletion, KeyId=key['KeyId'], PendingWindowInDays=10)
    ec2 = client('ec2')
    vpcs = ec2.describe_vpcs()['Vpcs']
    owned_vpcs = {v['VpcId'] for v in vpcs if eligible(v['VpcId'], v.get('Tags'), v['VpcId'])}
    for sg in ec2.describe_security_groups()['SecurityGroups']:
        if eligible(sg['GroupName'], sg.get('Tags'), sg['GroupId']):
            if sg.get('IpPermissions'): remove(ec2.revoke_security_group_ingress, GroupId=sg['GroupId'], IpPermissions=sg['IpPermissions'])
            if sg.get('IpPermissionsEgress'): remove(ec2.revoke_security_group_egress, GroupId=sg['GroupId'], IpPermissions=sg['IpPermissionsEgress'])
            remove(ec2.delete_security_group, GroupId=sg['GroupId'])
    for subnet in ec2.describe_subnets()['Subnets']:
        if eligible(subnet['SubnetId'], subnet.get('Tags'), subnet['SubnetId']):
            remove(ec2.delete_subnet, SubnetId=subnet['SubnetId'])
    for table in ec2.describe_route_tables()['RouteTables']:
        if eligible(table['RouteTableId'], table.get('Tags'), table['RouteTableId']):
            for a in table.get('Associations', []):
                if not a.get('Main'): remove(ec2.disassociate_route_table, AssociationId=a['RouteTableAssociationId'])
            remove(ec2.delete_route_table, RouteTableId=table['RouteTableId'])
    for gateway in ec2.describe_internet_gateways()['InternetGateways']:
        if eligible(gateway['InternetGatewayId'], gateway.get('Tags'), gateway['InternetGatewayId']):
            for a in gateway.get('Attachments', []):
                remove(ec2.detach_internet_gateway, InternetGatewayId=gateway['InternetGatewayId'], VpcId=a['VpcId'])
            remove(ec2.delete_internet_gateway, InternetGatewayId=gateway['InternetGatewayId'])
    for vpc in owned_vpcs:
        remove(ec2.delete_vpc, VpcId=vpc)


for attempt in range(4):
    ERRORS.clear()
    sweep()
    if not ERRORS: break
    time.sleep(3)
if ERRORS:
    raise RuntimeError('Cleanup failed: ' + repr(ERRORS))
print('Prefix-scoped operational resource cleanup complete (' + sys.argv[1] + ').')
