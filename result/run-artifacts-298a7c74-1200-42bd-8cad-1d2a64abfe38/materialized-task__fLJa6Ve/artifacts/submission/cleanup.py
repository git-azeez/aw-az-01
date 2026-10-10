"""Dependency-ordered, prefix/tag-scoped inventory sweep for teardown."""
import time


def sweep(config, client, pages, attempt, resources, extra_only):
    prefix = config['resource_prefix']
    managed = set()
    if extra_only:
        for resource in resources:
            for instance in resource.get('instances', []):
                attrs = instance['attributes']
                for key in ['id', 'arn', 'name', 'identifier', 'bucket', 'function_name', 'family', 'replication_group_id', 'user_pool_id']:
                    if isinstance(attrs.get(key), str):
                        managed.add(attrs[key])

    def selected(name, tags=None, identifiers=()):
        if name and (name.startswith('cl-base-') or '/cl-base-' in name):
            return False
        if isinstance(tags, list):
            tags = {t['Key']: t['Value'] for t in tags}
        tags = tags or {}
        scoped = name and (name.startswith(prefix + '-') or name.startswith('alias/' + prefix + '-') or
                           name.startswith('/clearledger/' + prefix + '/') or
                           any(segment.startswith(prefix + '-') for segment in name.split('/')))
        scoped = scoped or tags.get('ClearLedgerDeployment') == prefix
        return bool(scoped and not (extra_only and any(i in managed for i in [name, *identifiers])))

    def tags(service, fn, key, **kwargs):
        r = attempt(getattr(client(service), fn), **kwargs)
        return r.get(key, {}) if r else {}

    # Schedules and event source mappings must stop before consumers/data stores.
    scheduler = client('scheduler')
    for s in list(pages('scheduler', 'list_schedules', 'Schedules')):
        if selected(s['Name'], identifiers=[s['Arn']]):
            scheduler.delete_schedule(Name=s['Name'], GroupName=s.get('GroupName', 'default'))
    for g in list(pages('scheduler', 'list_schedule_groups', 'ScheduleGroups')):
        if selected(g['Name'], tags('scheduler', 'list_tags_for_resource', 'Tags', ResourceArn=g['Arn']), [g['Arn']]):
            scheduler.delete_schedule_group(Name=g['Name'])
    lam = client('lambda')
    for mapping in list(pages('lambda', 'list_event_source_mappings', 'EventSourceMappings')):
        name = mapping['FunctionArn'].rsplit(':', 1)[-1]
        if mapping['UUID'] not in managed and (selected(name) or (not extra_only and name.startswith(prefix + '-'))):
            attempt(lam.delete_event_source_mapping, UUID=mapping['UUID'])
    for f in list(pages('lambda', 'list_functions', 'Functions')):
        if selected(f['FunctionName'], tags('lambda', 'list_tags', 'Tags', Resource=f['FunctionArn']), [f['FunctionArn']]):
            lam.delete_function(FunctionName=f['FunctionName'])

    ecs = client('ecs')
    for arn in list(pages('ecs', 'list_clusters', 'clusterArns')):
        name = arn.rsplit('/', 1)[-1]
        cluster_tags = tags('ecs', 'list_tags_for_resource', 'tags', resourceArn=arn)
        # ECS uses lowercase tag field names.
        cluster_tags = {t['key']: t['value'] for t in cluster_tags} if isinstance(cluster_tags, list) else cluster_tags
        own_cluster = selected(name, cluster_tags, [arn])
        for service_arn in list(pages('ecs', 'list_services', 'serviceArns', cluster=arn)):
            sname = service_arn.rsplit('/', 1)[-1]
            if own_cluster or selected(sname, identifiers=[service_arn]):
                attempt(ecs.update_service, cluster=arn, service=service_arn, desiredCount=0)
                attempt(ecs.delete_service, cluster=arn, service=service_arn, force=True)
        if own_cluster:
            for task in pages('ecs', 'list_tasks', 'taskArns', cluster=arn):
                attempt(ecs.stop_task, cluster=arn, task=task, reason='ClearLedger teardown')
            attempt(ecs.delete_cluster, cluster=arn)
    for arn in list(pages('ecs', 'list_task_definitions', 'taskDefinitionArns')):
        family = arn.split('/')[-1].rsplit(':', 1)[0]
        if selected(family, identifiers=[arn]):
            attempt(ecs.deregister_task_definition, taskDefinition=arn)

    elb = client('elbv2')
    for lb in list(pages('elbv2', 'describe_load_balancers', 'LoadBalancers')):
        arn = lb['LoadBalancerArn']
        lb_tags = elb.describe_tags(ResourceArns=[arn])['TagDescriptions'][0]['Tags']
        own_lb = selected(lb['LoadBalancerName'], lb_tags, [arn])
        if own_lb or lb['LoadBalancerName'].startswith(prefix + '-'):
            for listener in list(pages('elbv2', 'describe_listeners', 'Listeners', LoadBalancerArn=arn)):
                la = listener['ListenerArn']
                if own_lb or la not in managed:
                    attempt(elb.delete_listener, ListenerArn=la)
        if own_lb:
            attempt(elb.delete_load_balancer, LoadBalancerArn=arn)
    for tg in list(pages('elbv2', 'describe_target_groups', 'TargetGroups')):
        arn = tg['TargetGroupArn']
        if selected(tg['TargetGroupName'], elb.describe_tags(ResourceArns=[arn])['TagDescriptions'][0]['Tags'], [arn]):
            attempt(elb.delete_target_group, TargetGroupArn=arn)

    rds = client('rds')
    for d in list(pages('rds', 'describe_db_instances', 'DBInstances')):
        arn = d['DBInstanceArn']
        if selected(d['DBInstanceIdentifier'], tags('rds', 'list_tags_for_resource', 'TagList', ResourceName=arn), [arn]):
            if d.get('DeletionProtection'):
                rds.modify_db_instance(DBInstanceIdentifier=d['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
            attempt(rds.delete_db_instance, DBInstanceIdentifier=d['DBInstanceIdentifier'], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    for s in list(pages('rds', 'describe_db_snapshots', 'DBSnapshots')):
        if selected(s['DBSnapshotIdentifier'], tags('rds', 'list_tags_for_resource', 'TagList', ResourceName=s['DBSnapshotArn'])):
            attempt(rds.delete_db_snapshot, DBSnapshotIdentifier=s['DBSnapshotIdentifier'])
    for group in list(pages('rds', 'describe_db_subnet_groups', 'DBSubnetGroups')):
        if selected(group['DBSubnetGroupName'], tags('rds', 'list_tags_for_resource', 'TagList', ResourceName=group['DBSubnetGroupArn'])):
            attempt(rds.delete_db_subnet_group, DBSubnetGroupName=group['DBSubnetGroupName'])
    for group in list(pages('rds', 'describe_db_parameter_groups', 'DBParameterGroups')):
        if selected(group['DBParameterGroupName'], tags('rds', 'list_tags_for_resource', 'TagList', ResourceName=group['DBParameterGroupArn'])):
            attempt(rds.delete_db_parameter_group, DBParameterGroupName=group['DBParameterGroupName'])

    cache = client('elasticache')
    deleted_groups = set()
    for g in list(pages('elasticache', 'describe_replication_groups', 'ReplicationGroups')):
        if selected(g['ReplicationGroupId'], tags('elasticache', 'list_tags_for_resource', 'TagList', ResourceName=g['ARN']), [g['ARN']]):
            attempt(cache.delete_replication_group, ReplicationGroupId=g['ReplicationGroupId'])
            deleted_groups.add(g['ReplicationGroupId'])
    for g in list(pages('elasticache', 'describe_cache_clusters', 'CacheClusters')):
        if not g.get('ReplicationGroupId') and selected(g['CacheClusterId'], tags('elasticache', 'list_tags_for_resource', 'TagList', ResourceName=g['ARN'])):
            attempt(cache.delete_cache_cluster, CacheClusterId=g['CacheClusterId'])
    for g in list(pages('elasticache', 'describe_cache_subnet_groups', 'CacheSubnetGroups')):
        if selected(g['CacheSubnetGroupName'], tags('elasticache', 'list_tags_for_resource', 'TagList', ResourceName=g['ARN'])):
            attempt(cache.delete_cache_subnet_group, CacheSubnetGroupName=g['CacheSubnetGroupName'])

    sqs = client('sqs')
    for url in list(pages('sqs', 'list_queues', 'QueueUrls')):
        name = url.rsplit('/', 1)[-1]
        if selected(name, tags('sqs', 'list_queue_tags', 'Tags', QueueUrl=url), [url]):
            attempt(sqs.delete_queue, QueueUrl=url)
    dynamo = client('dynamodb')
    for name in list(pages('dynamodb', 'list_tables', 'TableNames')):
        table = dynamo.describe_table(TableName=name)['Table']
        if selected(name, tags('dynamodb', 'list_tags_of_resource', 'Tags', ResourceArn=table['TableArn']), [table['TableArn']]):
            if table.get('DeletionProtectionEnabled'):
                dynamo.update_table(TableName=name, DeletionProtectionEnabled=False)
            attempt(dynamo.delete_table, TableName=name)
    s3 = client('s3')
    for bucket in list(pages('s3', 'list_buckets', 'Buckets')):
        name = bucket['Name']
        try:
            bt = tags('s3', 'get_bucket_tagging', 'TagSet', Bucket=name)
        except Exception as e:
            if 'NoSuchTagSet' not in str(e):
                raise
            bt = {}
        if selected(name, bt):
            objects = []
            for page in s3.get_paginator('list_object_versions').paginate(Bucket=name):
                objects.extend({'Key': v['Key'], 'VersionId': v['VersionId']} for v in page.get('Versions', []) + page.get('DeleteMarkers', []))
            for n in range(0, len(objects), 1000):
                s3.delete_objects(Bucket=name, Delete={'Objects': objects[n:n + 1000], 'Quiet': True})
            # Also handles buckets whose versioning was never enabled.
            current = [{'Key': o['Key']} for o in pages('s3', 'list_objects_v2', 'Contents', Bucket=name)]
            for n in range(0, len(current), 1000):
                s3.delete_objects(Bucket=name, Delete={'Objects': current[n:n + 1000], 'Quiet': True})
            attempt(s3.delete_bucket, Bucket=name)

    cognito = client('cognito-idp')
    for pool in list(pages('cognito-idp', 'list_user_pools', 'UserPools', MaxResults=60)):
        detail = cognito.describe_user_pool(UserPoolId=pool['Id'])['UserPool']
        if selected(pool['Name'], detail.get('UserPoolTags'), [pool['Id'], detail['Arn']]):
            if detail.get('DeletionProtection') == 'ACTIVE':
                cognito.update_user_pool(UserPoolId=pool['Id'], DeletionProtection='INACTIVE')
            if detail.get('Domain'):
                attempt(cognito.delete_user_pool_domain, Domain=detail['Domain'], UserPoolId=pool['Id'])
            attempt(cognito.delete_user_pool, UserPoolId=pool['Id'])
        elif pool['Name'].startswith(prefix + '-'):
            for c in pages('cognito-idp', 'list_user_pool_clients', 'UserPoolClients', UserPoolId=pool['Id'], MaxResults=60):
                if selected(c['ClientName'], identifiers=[c['ClientId']]):
                    attempt(cognito.delete_user_pool_client, UserPoolId=pool['Id'], ClientId=c['ClientId'])

    logs = client('logs')
    for group in list(pages('logs', 'describe_log_groups', 'logGroups')):
        if selected(group['logGroupName'], tags('logs', 'list_tags_log_group', 'tags', logGroupName=group['logGroupName']), [group['arn']]):
            attempt(logs.delete_log_group, logGroupName=group['logGroupName'])

    iam = client('iam')
    for role in list(pages('iam', 'list_roles', 'Roles')):
        name = role['RoleName']
        if selected(name, tags('iam', 'list_role_tags', 'Tags', RoleName=name), [role['Arn']]):
            for p in pages('iam', 'list_role_policies', 'PolicyNames', RoleName=name):
                iam.delete_role_policy(RoleName=name, PolicyName=p)
            for p in pages('iam', 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
                iam.detach_role_policy(RoleName=name, PolicyArn=p['PolicyArn'])
            for profile in pages('iam', 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if selected(profile['InstanceProfileName'], identifiers=[profile['Arn']]):
                    iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
            attempt(iam.delete_role, RoleName=name)
    for policy in list(pages('iam', 'list_policies', 'Policies', Scope='Local')):
        arn = policy['Arn']
        if selected(policy['PolicyName'], tags('iam', 'list_policy_tags', 'Tags', PolicyArn=arn), [arn]):
            entities = iam.list_entities_for_policy(PolicyArn=arn)
            for role in entities.get('PolicyRoles', []):
                iam.detach_role_policy(RoleName=role['RoleName'], PolicyArn=arn)
            for user in entities.get('PolicyUsers', []):
                iam.detach_user_policy(UserName=user['UserName'], PolicyArn=arn)
            for group in entities.get('PolicyGroups', []):
                iam.detach_group_policy(GroupName=group['GroupName'], PolicyArn=arn)
            for v in iam.list_policy_versions(PolicyArn=arn)['Versions']:
                if not v['IsDefaultVersion']:
                    iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
            attempt(iam.delete_policy, PolicyArn=arn)
    for profile in list(pages('iam', 'list_instance_profiles', 'InstanceProfiles')):
        if selected(profile['InstanceProfileName'], tags('iam', 'list_instance_profile_tags', 'Tags', InstanceProfileName=profile['InstanceProfileName']), [profile['Arn']]):
            for role in profile.get('Roles', []):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=role['RoleName'])
            attempt(iam.delete_instance_profile, InstanceProfileName=profile['InstanceProfileName'])

    kms = client('kms')
    for alias in list(pages('kms', 'list_aliases', 'Aliases')):
        if selected(alias['AliasName'], identifiers=[alias['AliasArn']]):
            attempt(kms.delete_alias, AliasName=alias['AliasName'])
    for key in list(pages('kms', 'list_keys', 'Keys')):
        metadata = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        if metadata.get('KeyManager') != 'CUSTOMER':
            continue
        kt = tags('kms', 'list_resource_tags', 'Tags', KeyId=key['KeyId'])
        # KMS uses TagKey/TagValue rather than Key/Value.
        kt = {t['TagKey']: t['TagValue'] for t in kt} if isinstance(kt, list) else kt
        if selected(metadata.get('Description', ''), kt, [key['KeyId'], key['KeyArn']]) and metadata['KeyState'] != 'PendingDeletion':
            attempt(kms.schedule_key_deletion, KeyId=key['KeyId'], PendingWindowInDays=10)

    ec2 = client('ec2')
    # Network resources can be scoped either by their Name or deployment tag.
    def own_ec2(r, id_key):
        rt = {t['Key']: t['Value'] for t in r.get('Tags', [])}
        return selected(rt.get('Name', ''), rt, [r[id_key]])
    vpcs = ec2.describe_vpcs()['Vpcs']
    owned_vpcs = {v['VpcId'] for v in vpcs if own_ec2(v, 'VpcId')}
    for eip in ec2.describe_addresses()['Addresses']:
        if own_ec2(eip, 'AllocationId'):
            if eip.get('AssociationId'):
                attempt(ec2.disassociate_address, AssociationId=eip['AssociationId'])
            attempt(ec2.release_address, AllocationId=eip['AllocationId'])
    for nat in pages('ec2', 'describe_nat_gateways', 'NatGateways'):
        if own_ec2(nat, 'NatGatewayId') or nat.get('VpcId') in owned_vpcs:
            if nat['State'] != 'deleted':
                attempt(ec2.delete_nat_gateway, NatGatewayId=nat['NatGatewayId'])
    for eni in ec2.describe_network_interfaces()['NetworkInterfaces']:
        if own_ec2(eni, 'NetworkInterfaceId') or eni.get('VpcId') in owned_vpcs:
            if eni.get('Attachment'):
                attempt(ec2.detach_network_interface, AttachmentId=eni['Attachment']['AttachmentId'], Force=True)
            attempt(ec2.delete_network_interface, NetworkInterfaceId=eni['NetworkInterfaceId'])
    for group in ec2.describe_security_groups()['SecurityGroups']:
        if group['GroupName'] == 'default':
            continue
        if own_ec2(group, 'GroupId') or selected(group['GroupName'], identifiers=[group['GroupId']]) or group.get('VpcId') in owned_vpcs:
            for field, method in [('IpPermissions', ec2.revoke_security_group_ingress), ('IpPermissionsEgress', ec2.revoke_security_group_egress)]:
                if group.get(field):
                    attempt(method, GroupId=group['GroupId'], IpPermissions=group[field])
    for group in ec2.describe_security_groups()['SecurityGroups']:
        if group['GroupName'] != 'default' and (own_ec2(group, 'GroupId') or selected(group['GroupName'], identifiers=[group['GroupId']]) or group.get('VpcId') in owned_vpcs):
            attempt(ec2.delete_security_group, GroupId=group['GroupId'])
    for subnet in ec2.describe_subnets()['Subnets']:
        if own_ec2(subnet, 'SubnetId') or subnet.get('VpcId') in owned_vpcs:
            attempt(ec2.delete_subnet, SubnetId=subnet['SubnetId'])
    for table in ec2.describe_route_tables()['RouteTables']:
        if own_ec2(table, 'RouteTableId') or table.get('VpcId') in owned_vpcs:
            if any(a.get('Main') for a in table.get('Associations', [])):
                continue
            for assoc in table.get('Associations', []):
                attempt(ec2.disassociate_route_table, AssociationId=assoc['RouteTableAssociationId'])
            attempt(ec2.delete_route_table, RouteTableId=table['RouteTableId'])
    for gateway in ec2.describe_internet_gateways()['InternetGateways']:
        if own_ec2(gateway, 'InternetGatewayId') or any(a['VpcId'] in owned_vpcs for a in gateway['Attachments']):
            for attachment in gateway['Attachments']:
                attempt(ec2.detach_internet_gateway, InternetGatewayId=gateway['InternetGatewayId'], VpcId=attachment['VpcId'])
            attempt(ec2.delete_internet_gateway, InternetGatewayId=gateway['InternetGatewayId'])
    for vpc in vpcs:
        if vpc['VpcId'] in owned_vpcs:
            attempt(ec2.delete_vpc, VpcId=vpc['VpcId'])
