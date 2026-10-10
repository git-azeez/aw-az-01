"""Prefix/tag-scoped teardown, including drift resources outside Terraform state."""
import json
import time

from ops import ROOT, P, client, pages, scoped, absent_call, tf, repair_roles, delete_policy, versions


def state_ids():
    path = ROOT / 'infra' / 'terraform.tfstate'
    state = json.loads(path.read_text()) if path.exists() else {}
    ids = set()
    for resource in state.get('resources', []):
        if resource.get('mode') != 'managed':
            continue
        for instance in resource.get('instances', []):
            a = instance.get('attributes', {})
            for key in ['id', 'arn', 'name', 'identifier', 'bucket', 'function_name', 'replication_group_id']:
                if isinstance(a.get(key), str):
                    ids.add(a[key])
    return ids


def sweep(preserve):
    def eligible(name, tags=(), *ids):
        return scoped(name, tags) and not any(i in preserve for i in (name, *ids))

    scheduler = client('scheduler')
    for s in pages('scheduler', 'list_schedules', 'Schedules'):
        if eligible(s['Name'], (), s['Arn']):
            scheduler.delete_schedule(Name=s['Name'], GroupName=s.get('GroupName', 'default'))
    lam = client('lambda')
    functions = pages('lambda', 'list_functions', 'Functions')
    function_arns = set()
    for f in functions:
        tags = lam.list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if eligible(f['FunctionName'], tags, f['FunctionArn']):
            function_arns.add(f['FunctionArn'])
    for e in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings'):
        tags = absent_call(lam.list_tags, Resource=e.get('EventSourceMappingArn', '')) if e.get('EventSourceMappingArn') else {}
        if e['UUID'] not in preserve and (e['FunctionArn'] in function_arns or
                scoped(e['FunctionArn'].split(':')[-1]) or scoped(e.get('EventSourceArn', '').split(':')[-1]) or
                scoped('', (tags or {}).get('Tags', {}))):
            absent_call(lam.delete_event_source_mapping, UUID=e['UUID'])
    for f in functions:
        if f['FunctionArn'] in function_arns:
            absent_call(lam.delete_function, FunctionName=f['FunctionName'])

    ecs = client('ecs')
    for arn in pages('ecs', 'list_clusters', 'clusterArns'):
        c = ecs.describe_clusters(clusters=[arn], include=['TAGS'])['clusters'][0]
        owned_cluster = scoped(c['clusterName'], c.get('tags', []))
        for service in pages('ecs', 'list_services', 'serviceArns', cluster=arn):
            s = ecs.describe_services(cluster=arn, services=[service], include=['TAGS'])['services'][0]
            if eligible(s['serviceName'], s.get('tags', []), s['serviceArn']):
                ecs.update_service(cluster=arn, service=service, desiredCount=0)
                ecs.delete_service(cluster=arn, service=service, force=True)
        if eligible(c['clusterName'], c.get('tags', []), arn):
            for task in pages('ecs', 'list_tasks', 'taskArns', cluster=arn):
                ecs.stop_task(cluster=arn, task=task, reason='ClearLedger teardown')
            ecs.delete_cluster(cluster=arn)
        elif owned_cluster:
            # Out-of-band standalone tasks inside our cluster must not pin networking.
            for task in pages('ecs', 'list_tasks', 'taskArns', cluster=arn):
                t = ecs.describe_tasks(cluster=arn, tasks=[task])['tasks'][0]
                if not t.get('group', '').startswith('service:'):
                    ecs.stop_task(cluster=arn, task=task, reason='ClearLedger teardown')
    for status in ['ACTIVE', 'INACTIVE']:
        for arn in pages('ecs', 'list_task_definitions', 'taskDefinitionArns', status=status):
            d = ecs.describe_task_definition(taskDefinition=arn, include=['TAGS'])
            if eligible(d['taskDefinition']['family'], d.get('tags', []), arn):
                if status == 'ACTIVE':
                    ecs.deregister_task_definition(taskDefinition=arn)
                absent_call(ecs.delete_task_definitions, taskDefinitions=[arn])

    elb = client('elbv2')
    for b in pages('elbv2', 'describe_load_balancers', 'LoadBalancers'):
        tags = elb.describe_tags(ResourceArns=[b['LoadBalancerArn']])['TagDescriptions'][0]['Tags']
        owned = eligible(b['LoadBalancerName'], tags, b['LoadBalancerArn'])
        if scoped(b['LoadBalancerName'], tags):
            for listener in pages('elbv2', 'describe_listeners', 'Listeners', LoadBalancerArn=b['LoadBalancerArn']):
                if owned or listener['ListenerArn'] not in preserve:
                    elb.delete_listener(ListenerArn=listener['ListenerArn'])
        if owned:
            elb.delete_load_balancer(LoadBalancerArn=b['LoadBalancerArn'])
    for g in pages('elbv2', 'describe_target_groups', 'TargetGroups'):
        tags = elb.describe_tags(ResourceArns=[g['TargetGroupArn']])['TagDescriptions'][0]['Tags']
        if eligible(g['TargetGroupName'], tags, g['TargetGroupArn']):
            elb.delete_target_group(TargetGroupArn=g['TargetGroupArn'])

    rds = client('rds')
    for d in pages('rds', 'describe_db_instances', 'DBInstances'):
        tags = rds.list_tags_for_resource(ResourceName=d['DBInstanceArn']).get('TagList', [])
        if eligible(d['DBInstanceIdentifier'], tags, d['DBInstanceArn'], d.get('DbiResourceId')):
            if d.get('DeletionProtection'):
                rds.modify_db_instance(DBInstanceIdentifier=d['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
            rds.delete_db_instance(DBInstanceIdentifier=d['DBInstanceIdentifier'], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    for snap in pages('rds', 'describe_db_snapshots', 'DBSnapshots', SnapshotType='manual'):
        tags = rds.list_tags_for_resource(ResourceName=snap['DBSnapshotArn']).get('TagList', [])
        if eligible(snap['DBSnapshotIdentifier'], tags, snap['DBSnapshotArn']):
            rds.delete_db_snapshot(DBSnapshotIdentifier=snap['DBSnapshotIdentifier'])
    for g in pages('rds', 'describe_db_subnet_groups', 'DBSubnetGroups'):
        tags = rds.list_tags_for_resource(ResourceName=g['DBSubnetGroupArn']).get('TagList', [])
        if eligible(g['DBSubnetGroupName'], tags, g['DBSubnetGroupArn']):
            rds.delete_db_subnet_group(DBSubnetGroupName=g['DBSubnetGroupName'])

    cache = client('elasticache')
    groups = pages('elasticache', 'describe_replication_groups', 'ReplicationGroups')
    group_members = {n for g in groups for n in g.get('MemberClusters', [])}
    for g in groups:
        tags = cache.list_tags_for_resource(ResourceName=g['ARN']).get('TagList', [])
        if eligible(g['ReplicationGroupId'], tags, g['ARN']):
            cache.delete_replication_group(ReplicationGroupId=g['ReplicationGroupId'], RetainPrimaryCluster=False)
    for c in pages('elasticache', 'describe_cache_clusters', 'CacheClusters'):
        if c['CacheClusterId'] in group_members:
            continue
        tags = cache.list_tags_for_resource(ResourceName=c['ARN']).get('TagList', []) if c.get('ARN') else []
        if eligible(c['CacheClusterId'], tags, c.get('ARN')):
            cache.delete_cache_cluster(CacheClusterId=c['CacheClusterId'])
    for g in pages('elasticache', 'describe_cache_subnet_groups', 'CacheSubnetGroups'):
        tags = cache.list_tags_for_resource(ResourceName=g['ARN']).get('TagList', []) if g.get('ARN') else []
        if eligible(g['CacheSubnetGroupName'], tags, g.get('ARN')):
            cache.delete_cache_subnet_group(CacheSubnetGroupName=g['CacheSubnetGroupName'])

    ddb = client('dynamodb')
    for name in pages('dynamodb', 'list_tables', 'TableNames'):
        arn = ddb.describe_table(TableName=name)['Table']['TableArn']
        tags = ddb.list_tags_of_resource(ResourceArn=arn).get('Tags', [])
        if eligible(name, tags, arn):
            ddb.delete_table(TableName=name)
    sqs = client('sqs')
    for url in pages('sqs', 'list_queues', 'QueueUrls'):
        tags = sqs.list_queue_tags(QueueUrl=url).get('Tags', {})
        if eligible(url.rsplit('/', 1)[-1], tags, url):
            sqs.delete_queue(QueueUrl=url)
    s3 = client('s3')
    for b in pages('s3', 'list_buckets', 'Buckets'):
        name = b['Name']
        try:
            tags = s3.get_bucket_tagging(Bucket=name).get('TagSet', [])
        except s3.exceptions.ClientError as e:
            if e.response['Error']['Code'] not in ('NoSuchTagSet', 'NoSuchBucket'):
                raise
            tags = []
        if eligible(name, tags, 'arn:aws:s3:::' + name):
            delete = [{'Key': v['Key'], 'VersionId': v['VersionId']} for _, v in versions(name)]
            for start in range(0, len(delete), 1000):
                s3.delete_objects(Bucket=name, Delete={'Objects': delete[start:start+1000], 'Quiet': True})
            # Also handles unversioned emulators that omit null versions from the listing.
            objects = pages('s3', 'list_objects_v2', 'Contents', Bucket=name)
            for start in range(0, len(objects), 1000):
                s3.delete_objects(Bucket=name, Delete={'Objects': [{'Key': o['Key']} for o in objects[start:start+1000]]})
            for upload in pages('s3', 'list_multipart_uploads', 'Uploads', Bucket=name):
                s3.abort_multipart_upload(Bucket=name, Key=upload['Key'], UploadId=upload['UploadId'])
            s3.delete_bucket(Bucket=name)

    cog = client('cognito-idp')
    for p in pages('cognito-idp', 'list_user_pools', 'UserPools', MaxResults=60):
        pool = cog.describe_user_pool(UserPoolId=p['Id'])['UserPool']
        if eligible(p['Name'], pool.get('UserPoolTags', {}), p['Id'], pool['Arn']):
            if pool.get('Domain'):
                cog.delete_user_pool_domain(Domain=pool['Domain'], UserPoolId=p['Id'])
            cog.delete_user_pool(UserPoolId=p['Id'])
        elif scoped(p['Name'], pool.get('UserPoolTags', {})):
            for c in pages('cognito-idp', 'list_user_pool_clients', 'UserPoolClients', UserPoolId=p['Id'], MaxResults=60):
                if c['ClientId'] not in preserve:
                    cog.delete_user_pool_client(UserPoolId=p['Id'], ClientId=c['ClientId'])
            for r in pages('cognito-idp', 'list_resource_servers', 'ResourceServers', UserPoolId=p['Id'], MaxResults=50):
                if r['Identifier'] != 'clearledger':
                    cog.delete_resource_server(UserPoolId=p['Id'], Identifier=r['Identifier'])

    logs = client('logs')
    for g in pages('logs', 'describe_log_groups', 'logGroups'):
        tags = logs.list_tags_log_group(logGroupName=g['logGroupName']).get('tags', {})
        if eligible(g['logGroupName'], tags, g.get('arn')):
            logs.delete_log_group(logGroupName=g['logGroupName'])
    iam = client('iam')
    for role in pages('iam', 'list_roles', 'Roles'):
        name = role['RoleName']; tags = iam.list_role_tags(RoleName=name).get('Tags', [])
        if eligible(name, tags, role['Arn']):
            for profile in pages('iam', 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if scoped(profile['InstanceProfileName'], profile.get('Tags', [])):
                    iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
            for pol in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
                iam.delete_role_policy(RoleName=name, PolicyName=pol)
            for pol in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
                iam.detach_role_policy(RoleName=name, PolicyArn=pol['PolicyArn'])
            iam.delete_role(RoleName=name)
    for pol in pages('iam', 'list_policies', 'Policies', Scope='Local'):
        tags = iam.list_policy_tags(PolicyArn=pol['Arn']).get('Tags', [])
        if eligible(pol['PolicyName'], tags, pol['Arn']):
            entities = iam.list_entities_for_policy(PolicyArn=pol['Arn'])
            for r in entities.get('PolicyRoles', []):
                # Detaching our policy is required even if someone attached it elsewhere.
                iam.detach_role_policy(RoleName=r['RoleName'], PolicyArn=pol['Arn'])
            for u in entities.get('PolicyUsers', []):
                iam.detach_user_policy(UserName=u['UserName'], PolicyArn=pol['Arn'])
            for g in entities.get('PolicyGroups', []):
                iam.detach_group_policy(GroupName=g['GroupName'], PolicyArn=pol['Arn'])
            delete_policy(iam, pol['Arn'])
    kms = client('kms')
    owned_keys = set()
    for k in pages('kms', 'list_keys', 'Keys'):
        tags = kms.list_resource_tags(KeyId=k['KeyId']).get('Tags', [])
        tags = [{'Key': t['TagKey'], 'Value': t['TagValue']} for t in tags]
        if eligible('', tags, k['KeyId'], k['KeyArn']):
            owned_keys.add(k['KeyId'])
    for a in pages('kms', 'list_aliases', 'Aliases'):
        if eligible(a['AliasName'], (), a.get('AliasArn')):
            if a.get('TargetKeyId') not in preserve:
                owned_keys.add(a.get('TargetKeyId'))
            kms.delete_alias(AliasName=a['AliasName'])
    for key in owned_keys - {None}:
        if kms.describe_key(KeyId=key)['KeyMetadata']['KeyState'] != 'PendingDeletion':
            kms.schedule_key_deletion(KeyId=key, PendingWindowInDays=10)

    ec2 = client('ec2')
    vpcs = ec2.describe_vpcs()['Vpcs']
    owned_vpcs = {v['VpcId'] for v in vpcs if eligible('', v.get('Tags', []), v['VpcId'])}
    # Network children are eligible by their own tags/names or membership in an owned VPC.
    def network_owned(obj, key):
        return obj[key] not in preserve and (obj.get('VpcId') in owned_vpcs or eligible(obj.get('GroupName', ''), obj.get('Tags', []), obj[key]))
    for e in ec2.describe_vpc_endpoints()['VpcEndpoints']:
        if network_owned(e, 'VpcEndpointId'):
            ec2.delete_vpc_endpoints(VpcEndpointIds=[e['VpcEndpointId']])
    for n in ec2.describe_nat_gateways()['NatGateways']:
        if network_owned(n, 'NatGatewayId') and n['State'] != 'deleted':
            ec2.delete_nat_gateway(NatGatewayId=n['NatGatewayId'])
    for e in ec2.describe_network_interfaces()['NetworkInterfaces']:
        if network_owned(e, 'NetworkInterfaceId') and not e.get('Attachment'):
            ec2.delete_network_interface(NetworkInterfaceId=e['NetworkInterfaceId'])
    sgs = [s for s in ec2.describe_security_groups()['SecurityGroups'] if network_owned(s, 'GroupId') and s['GroupName'] != 'default']
    for s in sgs:
        if s.get('IpPermissions'):
            ec2.revoke_security_group_ingress(GroupId=s['GroupId'], IpPermissions=s['IpPermissions'])
        if s.get('IpPermissionsEgress'):
            ec2.revoke_security_group_egress(GroupId=s['GroupId'], IpPermissions=s['IpPermissionsEgress'])
    for s in sgs:
        ec2.delete_security_group(GroupId=s['GroupId'])
    for rt in ec2.describe_route_tables()['RouteTables']:
        if network_owned(rt, 'RouteTableId') and not any(a.get('Main') for a in rt.get('Associations', [])):
            for a in rt.get('Associations', []):
                ec2.disassociate_route_table(AssociationId=a['RouteTableAssociationId'])
            ec2.delete_route_table(RouteTableId=rt['RouteTableId'])
    for s in ec2.describe_subnets()['Subnets']:
        if network_owned(s, 'SubnetId'):
            ec2.delete_subnet(SubnetId=s['SubnetId'])
    for g in ec2.describe_internet_gateways()['InternetGateways']:
        if g['InternetGatewayId'] not in preserve and (eligible('', g.get('Tags', []), g['InternetGatewayId']) or any(a['VpcId'] in owned_vpcs for a in g.get('Attachments', []))):
            for a in g.get('Attachments', []):
                ec2.detach_internet_gateway(InternetGatewayId=g['InternetGatewayId'], VpcId=a['VpcId'])
            ec2.delete_internet_gateway(InternetGatewayId=g['InternetGatewayId'])
    for vpc in owned_vpcs:
        ec2.delete_vpc(VpcId=vpc)


def destroy():
    print('Removing prefix-scoped drift resources, then destroying Terraform infrastructure.', flush=True)
    repair_roles()
    # Remove untracked resources first so they cannot hold dependencies on managed resources.
    sweep(state_ids())
    tf('init', '-input=false', '-no-color')
    tf('destroy', '-auto-approve', '-input=false', '-no-color')
    for attempt in range(4):
        try:
            sweep(set())
            break
        except Exception:
            if attempt == 3:
                raise
            time.sleep(3)
    state = json.loads((ROOT / 'infra' / 'terraform.tfstate').read_text())
    assert not [r for r in state.get('resources', []) if r.get('mode') == 'managed']
    print('Teardown complete; Terraform state contains zero managed resources.', flush=True)
