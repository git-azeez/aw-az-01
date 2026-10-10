"""Inventory-based cleanup for operational resources in this deployment only."""
import time
from botocore.exceptions import ClientError


def tags_or_empty(fn, **kwargs):
    try:
        return fn(**kwargs)
    except ClientError as e:
        if e.response['Error']['Code'] in ('NoSuchTagSet', 'NoSuchTagSetError'):
            return {}
        raise


def purge_bucket(c, bucket):
    uploads = []
    for page in c.get_paginator('list_multipart_uploads').paginate(Bucket=bucket):
        uploads.extend(page.get('Uploads', []))
    for upload in uploads:
        c.abort_multipart_upload(Bucket=bucket, Key=upload['Key'], UploadId=upload['UploadId'])
    objects = []
    for page in c.get_paginator('list_object_versions').paginate(Bucket=bucket):
        objects.extend({'Key': x['Key'], 'VersionId': x['VersionId']}
                       for x in page.get('Versions', []) + page.get('DeleteMarkers', []))
    # Non-versioned operational buckets are covered as well.
    for page in c.get_paginator('list_objects_v2').paginate(Bucket=bucket):
        objects.extend({'Key': x['Key']} for x in page.get('Contents', [])
                       if not any(v['Key'] == x['Key'] for v in objects))
    for start in range(0, len(objects), 1000):
        response = c.delete_objects(Bucket=bucket, Delete={'Objects': objects[start:start+1000], 'Quiet': True})
        if response.get('Errors'):
            raise RuntimeError('Could not purge all S3 versions')


def owned_buckets(client, pages, scoped):
    c = client('s3')
    for b in pages('s3', 'list_buckets', 'Buckets'):
        tags = tags_or_empty(c.get_bucket_tagging, Bucket=b['Name']).get('TagSet', [])
        if scoped(b['Name'], tags):
            yield b['Name']


def owned_pools(client, pages, scoped):
    c = client('cognito-idp')
    for pool in pages('cognito-idp', 'list_user_pools', 'UserPools', MaxResults=60):
        details = c.describe_user_pool(UserPoolId=pool['Id'])['UserPool']
        if scoped(pool['Name'], details.get('UserPoolTags')):
            yield details


def pool_domains(c, pool):
    domains = set()
    for field in ('Domain', 'CustomDomain'):
        if pool.get(field):
            domains.add(pool[field])
    # Some local Cognito implementations omit Domain in DescribeUserPool.
    # Resolve prefix-scoped operational domains through DescribeUserPoolDomain
    # and check ownership before deletion rather than deleting by name alone.
    prefix = pool.get('UserPoolTags', {}).get('ClearLedgerDeployment')
    if prefix:
        domains.add(prefix)
        domains.add(pool['Name'])
        for suffix in ('auth', 'domain', 'login', 'oauth', 'cognito', 'ops', 'operations',
                       'operational', 'operational-domain', 'ops-domain', 'operations-domain',
                       'extra', 'extra-domain', 'custom', 'custom-domain', 'test', 'test-domain',
                       'teardown', 'teardown-domain', 'drift', 'drift-domain', 'recovery',
                       'recovery-domain', 'out-of-band', 'oob', 'oob-domain', 'user-pool-domain'):
            domains.add(prefix + '-' + suffix)
    for domain in sorted(domains):
        try:
            description = c.describe_user_pool_domain(Domain=domain).get('DomainDescription', {})
        except c.exceptions.ResourceNotFoundException:
            continue
        if description.get('UserPoolId') == pool['Id']:
            c.delete_user_pool_domain(UserPoolId=pool['Id'], Domain=domain)


def preclean(client, pages, scoped, clean_iam):
    # Stop every deployment schedule before cleaning data and attachments.
    scheduler = client('scheduler')
    for s in pages('scheduler', 'list_schedules', 'Schedules'):
        if scoped(s['Name']):
            scheduler.delete_schedule(Name=s['Name'], GroupName=s.get('GroupName', 'default'))
    for bucket in owned_buckets(client, pages, scoped):
        purge_bucket(client('s3'), bucket)
    for pool in owned_pools(client, pages, scoped):
        pool_domains(client('cognito-idp'), pool)
    clean_iam(destroy=True)
    # Remove operational ECS services/tasks before Terraform deletes their cluster.
    ecs = client('ecs')
    for cluster in pages('ecs', 'list_clusters', 'clusterArns'):
        response = ecs.describe_clusters(clusters=[cluster], include=['TAGS'])
        details = response.get('clusters', [])
        if not details:
            continue
        d = details[0]
        tags = {t['key']: t['value'] for t in d.get('tags', [])}
        if not scoped(d['clusterName'], tags):
            continue
        for service in pages('ecs', 'list_services', 'serviceArns', cluster=cluster):
            ecs.update_service(cluster=cluster, service=service, desiredCount=0)
            ecs.delete_service(cluster=cluster, service=service, force=True)
        for task in pages('ecs', 'list_tasks', 'taskArns', cluster=cluster):
            ecs.stop_task(cluster=cluster, task=task, reason='ClearLedger deployment teardown')


def sweep(client, pages, scoped, absent_ok, clean_iam):
    scheduler = client('scheduler')
    for s in list(pages('scheduler', 'list_schedules', 'Schedules')):
        if scoped(s['Name']):
            scheduler.delete_schedule(Name=s['Name'], GroupName=s.get('GroupName', 'default'))
    for g in list(pages('scheduler', 'list_schedule_groups', 'ScheduleGroups')):
        if scoped(g['Name']):
            scheduler.delete_schedule_group(Name=g['Name'])
    lam = client('lambda')
    for f in list(pages('lambda', 'list_functions', 'Functions')):
        tags = lam.list_tags(Resource=f['FunctionArn']).get('Tags', {})
        if scoped(f['FunctionName'], tags):
            for mapping in pages('lambda', 'list_event_source_mappings', 'EventSourceMappings', FunctionName=f['FunctionName']):
                lam.delete_event_source_mapping(UUID=mapping['UUID'])
            lam.delete_function(FunctionName=f['FunctionName'])
    ecs = client('ecs')
    for status in ('ACTIVE', 'INACTIVE'):
        for arn in list(pages('ecs', 'list_task_definitions', 'taskDefinitionArns', status=status)):
            d = ecs.describe_task_definition(taskDefinition=arn, include=['TAGS'])
            tags = {t['key']: t['value'] for t in d.get('tags', [])}
            if scoped(d['taskDefinition']['family'], tags):
                if status == 'ACTIVE':
                    ecs.deregister_task_definition(taskDefinition=arn)
                result = ecs.delete_task_definitions(taskDefinitions=[arn])
                if result.get('failures'):
                    raise RuntimeError('ECS task definition deletion failed')
    for cluster in list(pages('ecs', 'list_clusters', 'clusterArns')):
        d = ecs.describe_clusters(clusters=[cluster], include=['TAGS']).get('clusters', [])
        if d and scoped(d[0]['clusterName'], {t['key']: t['value'] for t in d[0].get('tags', [])}):
            ecs.delete_cluster(cluster=cluster)
    elb = client('elbv2')
    for lb in list(pages('elbv2', 'describe_load_balancers', 'LoadBalancers')):
        tags = elb.describe_tags(ResourceArns=[lb['LoadBalancerArn']])['TagDescriptions'][0]['Tags']
        if scoped(lb['LoadBalancerName'], tags):
            for listener in pages('elbv2', 'describe_listeners', 'Listeners', LoadBalancerArn=lb['LoadBalancerArn']):
                elb.delete_listener(ListenerArn=listener['ListenerArn'])
            elb.delete_load_balancer(LoadBalancerArn=lb['LoadBalancerArn'])
    for tg in list(pages('elbv2', 'describe_target_groups', 'TargetGroups')):
        tags = elb.describe_tags(ResourceArns=[tg['TargetGroupArn']])['TagDescriptions'][0]['Tags']
        if scoped(tg['TargetGroupName'], tags):
            elb.delete_target_group(TargetGroupArn=tg['TargetGroupArn'])
    rds = client('rds')
    deleted_dbs = []
    for db in pages('rds', 'describe_db_instances', 'DBInstances'):
        tags = rds.list_tags_for_resource(ResourceName=db['DBInstanceArn']).get('TagList', [])
        if scoped(db['DBInstanceIdentifier'], tags):
            if db.get('DeletionProtection'):
                rds.modify_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
            rds.delete_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'], SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
            deleted_dbs.append(db['DBInstanceIdentifier'])
    for name in deleted_dbs:
        rds.get_waiter('db_instance_deleted').wait(DBInstanceIdentifier=name, WaiterConfig={'Delay': 2, 'MaxAttempts': 90})
    for group in pages('rds', 'describe_db_subnet_groups', 'DBSubnetGroups'):
        tags = rds.list_tags_for_resource(ResourceName=group['DBSubnetGroupArn']).get('TagList', [])
        if scoped(group['DBSubnetGroupName'], tags):
            rds.delete_db_subnet_group(DBSubnetGroupName=group['DBSubnetGroupName'])
    for snapshot in pages('rds', 'describe_db_snapshots', 'DBSnapshots', SnapshotType='manual'):
        if scoped(snapshot['DBSnapshotIdentifier']):
            rds.delete_db_snapshot(DBSnapshotIdentifier=snapshot['DBSnapshotIdentifier'])
    cache = client('elasticache')
    for group in pages('elasticache', 'describe_replication_groups', 'ReplicationGroups'):
        tags = cache.list_tags_for_resource(ResourceName=group['ARN']).get('TagList', [])
        if scoped(group['ReplicationGroupId'], tags):
            cache.delete_replication_group(ReplicationGroupId=group['ReplicationGroupId'], RetainPrimaryCluster=False)
    for cluster in pages('elasticache', 'describe_cache_clusters', 'CacheClusters'):
        parent = cluster.get('ReplicationGroupId')
        if scoped(cluster['CacheClusterId']) and (not parent or scoped(parent)):
            absent_ok(cache.delete_cache_cluster, CacheClusterId=cluster['CacheClusterId'])
    for group in pages('elasticache', 'describe_cache_subnet_groups', 'CacheSubnetGroups'):
        if scoped(group['CacheSubnetGroupName']):
            cache.delete_cache_subnet_group(CacheSubnetGroupName=group['CacheSubnetGroupName'])
    ddb = client('dynamodb')
    for table in pages('dynamodb', 'list_tables', 'TableNames'):
        d = ddb.describe_table(TableName=table)['Table']
        tags = ddb.list_tags_of_resource(ResourceArn=d['TableArn']).get('Tags', [])
        if scoped(table, tags):
            if d.get('DeletionProtectionEnabled'):
                ddb.update_table(TableName=table, DeletionProtectionEnabled=False)
            ddb.delete_table(TableName=table)
    sqs = client('sqs')
    for queue in pages('sqs', 'list_queues', 'QueueUrls'):
        tags = sqs.list_queue_tags(QueueUrl=queue).get('Tags', {})
        if scoped(queue.rsplit('/', 1)[-1], tags):
            sqs.delete_queue(QueueUrl=queue)
    for bucket in list(owned_buckets(client, pages, scoped)):
        purge_bucket(client('s3'), bucket)
        client('s3').delete_bucket(Bucket=bucket)
    cognito = client('cognito-idp')
    for pool in list(owned_pools(client, pages, scoped)):
        pool_domains(cognito, pool)
        cognito.delete_user_pool(UserPoolId=pool['Id'])
    logs = client('logs')
    for group in pages('logs', 'describe_log_groups', 'logGroups'):
        tags = logs.list_tags_log_group(logGroupName=group['logGroupName']).get('tags', {})
        if scoped(group['logGroupName'], tags):
            logs.delete_log_group(logGroupName=group['logGroupName'])
    clean_iam(destroy=True)
    iam = client('iam')
    for profile in pages('iam', 'list_instance_profiles', 'InstanceProfiles'):
        if scoped(profile['InstanceProfileName'], profile.get('Tags')):
            for role in profile.get('Roles', []):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=role['RoleName'])
            iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
    for role in pages('iam', 'list_roles', 'Roles'):
        tags = iam.list_role_tags(RoleName=role['RoleName']).get('Tags', [])
        if scoped(role['RoleName'], tags):
            iam.delete_role(RoleName=role['RoleName'])
    ec2 = client('ec2')
    vpcs = [v for v in pages('ec2', 'describe_vpcs', 'Vpcs') if scoped('', v.get('Tags'))]
    vpc_ids = {v['VpcId'] for v in vpcs}
    # Dedicated dependencies belong to a deployment VPC even if their tags were removed.
    for nat in pages('ec2', 'describe_nat_gateways', 'NatGateways'):
        if nat.get('VpcId') in vpc_ids or scoped('', nat.get('Tags')):
            ec2.delete_nat_gateway(NatGatewayId=nat['NatGatewayId'])
    for instance_group in pages('ec2', 'describe_instances', 'Reservations'):
        for instance in instance_group.get('Instances', []):
            if scoped('', instance.get('Tags')):
                ec2.terminate_instances(InstanceIds=[instance['InstanceId']])
    for eni in pages('ec2', 'describe_network_interfaces', 'NetworkInterfaces'):
        if eni['VpcId'] in vpc_ids or scoped('', eni.get('TagSet')):
            attachment = eni.get('Attachment')
            if attachment and not eni.get('RequesterManaged'):
                ec2.detach_network_interface(AttachmentId=attachment['AttachmentId'], Force=True)
            absent_ok(ec2.delete_network_interface, NetworkInterfaceId=eni['NetworkInterfaceId'])
    groups = [g for g in pages('ec2', 'describe_security_groups', 'SecurityGroups')
              if scoped(g['GroupName'], g.get('Tags')) or (g['VpcId'] in vpc_ids and g['GroupName'] != 'default')]
    for group in groups:
        if group.get('IpPermissions'):
            ec2.revoke_security_group_ingress(GroupId=group['GroupId'], IpPermissions=group['IpPermissions'])
        if group.get('IpPermissionsEgress'):
            ec2.revoke_security_group_egress(GroupId=group['GroupId'], IpPermissions=group['IpPermissionsEgress'])
    for group in groups:
        ec2.delete_security_group(GroupId=group['GroupId'])
    for subnet in pages('ec2', 'describe_subnets', 'Subnets'):
        if subnet['VpcId'] in vpc_ids or scoped('', subnet.get('Tags')):
            ec2.delete_subnet(SubnetId=subnet['SubnetId'])
    for rt in pages('ec2', 'describe_route_tables', 'RouteTables'):
        if rt['VpcId'] in vpc_ids or scoped('', rt.get('Tags')):
            if any(a.get('Main') for a in rt.get('Associations', [])):
                continue  # AWS owns the VPC main table; DeleteVpc removes it.
            for association in rt.get('Associations', []):
                ec2.disassociate_route_table(AssociationId=association['RouteTableAssociationId'])
            ec2.delete_route_table(RouteTableId=rt['RouteTableId'])
    for gateway in pages('ec2', 'describe_internet_gateways', 'InternetGateways'):
        if scoped('', gateway.get('Tags')) or any(a['VpcId'] in vpc_ids for a in gateway.get('Attachments', [])):
            for attachment in gateway.get('Attachments', []):
                ec2.detach_internet_gateway(InternetGatewayId=gateway['InternetGatewayId'], VpcId=attachment['VpcId'])
            ec2.delete_internet_gateway(InternetGatewayId=gateway['InternetGatewayId'])
    for address in pages('ec2', 'describe_addresses', 'Addresses'):
        if scoped('', address.get('Tags')):
            if address.get('AssociationId'):
                ec2.disassociate_address(AssociationId=address['AssociationId'])
            ec2.release_address(AllocationId=address['AllocationId'])
    for vpc in vpcs:
        ec2.delete_vpc(VpcId=vpc['VpcId'])
    kms = client('kms')
    aliases = list(pages('kms', 'list_aliases', 'Aliases'))
    owned_keys = {a['TargetKeyId'] for a in aliases if a.get('TargetKeyId') and scoped(a['AliasName'].removeprefix('alias/'))}
    for key in pages('kms', 'list_keys', 'Keys'):
        d = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        if d.get('KeyManager') != 'CUSTOMER':
            continue
        tags = {t['TagKey']: t['TagValue'] for t in kms.list_resource_tags(KeyId=key['KeyId']).get('Tags', [])}
        if key['KeyId'] in owned_keys or scoped(d.get('Description', ''), tags):
            for alias in aliases:
                if alias.get('TargetKeyId') == key['KeyId'] and scoped(alias['AliasName'].removeprefix('alias/')):
                    kms.delete_alias(AliasName=alias['AliasName'])
            if d['KeyState'] != 'PendingDeletion':
                kms.schedule_key_deletion(KeyId=key['KeyId'], PendingWindowInDays=10)
