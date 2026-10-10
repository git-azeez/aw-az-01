"""Prefix/tag-scoped inventory cleanup, including resources created during drills."""
import json
import sys
import time

from botocore.exceptions import ClientError
from operations import ROOT, PREFIX, client, owned, pages, missing, remove_policy, delete_versions

PROTECTED = set()
ERRORS = []


def scoped(name, tags=(), *ids):
    return owned(name, tags) and not any(x in PROTECTED for x in (name, *ids) if isinstance(x, str))


def attempt(fn, **kwargs):
    try:
        return fn(**kwargs)
    except ClientError as exc:
        if missing(exc) or exc.response['Error']['Code'] in ('LoadBalancerNotFound', 'TargetGroupNotFound', 'CacheClusterNotFound', 'InvalidGroup.NotFound', 'InvalidSubnetID.NotFound', 'InvalidVpcID.NotFound', 'InvalidRouteTableID.NotFound', 'InvalidInternetGatewayID.NotFound'):
            return None
        ERRORS.append((fn.__name__, exc.response['Error']['Code']))
        return None


def tags(c, method, field='Tags', **kwargs):
    return getattr(c, method)(**kwargs).get(field, [])


def empty_bucket(s3, bucket):
    items = []
    for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
        items.extend({'Key': x['Key'], 'VersionId': x['VersionId']} for x in page.get('Versions', []) + page.get('DeleteMarkers', []))
    delete_versions(s3, bucket, items)
    items = [{'Key': x['Key']} for x in pages(s3, 'list_objects_v2', 'Contents', Bucket=bucket)]
    delete_versions(s3, bucket, items)


def sweep():
    scheduler = client('scheduler')
    for s in pages(scheduler, 'list_schedules', 'Schedules'):
        if scoped(s['Name'], (), s['Arn']):
            attempt(scheduler.delete_schedule, Name=s['Name'], GroupName=s.get('GroupName','default'))
    lam = client('lambda')
    functions = list(pages(lam, 'list_functions', 'Functions'))
    function_arns = {f['FunctionArn'] for f in functions if scoped(f['FunctionName'], lam.list_tags(Resource=f['FunctionArn']).get('Tags',{}), f['FunctionArn'])}
    for mapping in pages(lam, 'list_event_source_mappings', 'EventSourceMappings'):
        if mapping['UUID'] not in PROTECTED and (mapping['FunctionArn'] in function_arns or owned(mapping['FunctionArn'].split(':function:')[-1])):
            attempt(lam.delete_event_source_mapping, UUID=mapping['UUID'])
    for f in functions:
        if f['FunctionArn'] in function_arns:
            attempt(lam.delete_function, FunctionName=f['FunctionName'])
    ecs = client('ecs')
    for arn in pages(ecs, 'list_clusters', 'clusterArns'):
        desc = ecs.describe_clusters(clusters=[arn], include=['TAGS'])['clusters'][0]
        name = desc['clusterName']
        is_owned = owned(name, desc.get('tags', []))
        # Remove operational services within deployment-owned clusters even if
        # they predate their own Terraform registration.
        if not is_owned:
            continue
        for service_arn in pages(ecs, 'list_services', 'serviceArns', cluster=arn):
            if service_arn not in PROTECTED:
                attempt(ecs.delete_service, cluster=arn, service=service_arn, force=True)
        if arn not in PROTECTED:
            for task in pages(ecs, 'list_tasks', 'taskArns', cluster=arn):
                attempt(ecs.stop_task, cluster=arn, task=task, reason='ClearLedger prefix-scoped teardown')
            attempt(ecs.delete_cluster, cluster=arn)
    for arn in pages(ecs, 'list_task_definitions', 'taskDefinitionArns'):
        name = arn.split('/')[-1].split(':')[0]
        if scoped(name, (), arn):
            attempt(ecs.deregister_task_definition, taskDefinition=arn)
    elb = client('elbv2')
    for lb in pages(elb, 'describe_load_balancers', 'LoadBalancers'):
        arn = lb['LoadBalancerArn']
        ts = elb.describe_tags(ResourceArns=[arn])['TagDescriptions'][0]['Tags']
        if scoped(lb['LoadBalancerName'], ts, arn):
            for listener in pages(elb,'describe_listeners','Listeners',LoadBalancerArn=arn):
                attempt(elb.delete_listener, ListenerArn=listener['ListenerArn'])
            attempt(elb.delete_load_balancer, LoadBalancerArn=arn)
    for tg in pages(elb, 'describe_target_groups', 'TargetGroups'):
        arn = tg['TargetGroupArn']
        ts = elb.describe_tags(ResourceArns=[arn])['TagDescriptions'][0]['Tags']
        if scoped(tg['TargetGroupName'], ts, arn):
            attempt(elb.delete_target_group, TargetGroupArn=arn)
    cache = client('elasticache')
    for rg in pages(cache, 'describe_replication_groups', 'ReplicationGroups'):
        ts = cache.list_tags_for_resource(ResourceName=rg['ARN']).get('TagList',[])
        if scoped(rg['ReplicationGroupId'], ts, rg['ARN']):
            attempt(cache.delete_replication_group, ReplicationGroupId=rg['ReplicationGroupId'], RetainPrimaryCluster=False)
    for cluster in pages(cache, 'describe_cache_clusters', 'CacheClusters'):
        name = cluster['CacheClusterId']
        # Terraform replication-group children have implicit ownership.
        if not cluster.get('ReplicationGroupId') and scoped(name):
            attempt(cache.delete_cache_cluster, CacheClusterId=name)
    for sg in pages(cache, 'describe_cache_subnet_groups', 'CacheSubnetGroups'):
        if scoped(sg['CacheSubnetGroupName']):
            attempt(cache.delete_cache_subnet_group, CacheSubnetGroupName=sg['CacheSubnetGroupName'])
    rds = client('rds')
    for db in pages(rds, 'describe_db_instances', 'DBInstances'):
        ts = rds.list_tags_for_resource(ResourceName=db['DBInstanceArn']).get('TagList',[])
        if scoped(db['DBInstanceIdentifier'],ts,db['DBInstanceArn'],db.get('DbiResourceId')):
            if db.get('DeletionProtection'):
                rds.modify_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'], DeletionProtection=False, ApplyImmediately=True)
            attempt(rds.delete_db_instance, DBInstanceIdentifier=db['DBInstanceIdentifier'],SkipFinalSnapshot=True,DeleteAutomatedBackups=True)
    for group in pages(rds, 'describe_db_subnet_groups', 'DBSubnetGroups'):
        ts = rds.list_tags_for_resource(ResourceName=group['DBSubnetGroupArn']).get('TagList',[]) if group.get('DBSubnetGroupArn') else []
        if scoped(group['DBSubnetGroupName'], ts, group.get('DBSubnetGroupArn')):
            attempt(rds.delete_db_subnet_group, DBSubnetGroupName=group['DBSubnetGroupName'])
    for snapshot in pages(rds, 'describe_db_snapshots', 'DBSnapshots', SnapshotType='manual'):
        if scoped(snapshot['DBSnapshotIdentifier']):
            attempt(rds.delete_db_snapshot, DBSnapshotIdentifier=snapshot['DBSnapshotIdentifier'])
    ddb = client('dynamodb')
    for name in pages(ddb, 'list_tables', 'TableNames'):
        d = ddb.describe_table(TableName=name)['Table']
        ts = ddb.list_tags_of_resource(ResourceArn=d['TableArn']).get('Tags',[])
        if scoped(name,ts,d['TableArn']):
            attempt(ddb.delete_table,TableName=name)
    sqs = client('sqs')
    for url in pages(sqs, 'list_queues', 'QueueUrls'):
        if scoped(url.rsplit('/',1)[-1], sqs.list_queue_tags(QueueUrl=url).get('Tags',{}),url):
            attempt(sqs.delete_queue,QueueUrl=url)
    s3 = client('s3')
    for bucket in s3.list_buckets()['Buckets']:
        name = bucket['Name']
        try:
            ts = s3.get_bucket_tagging(Bucket=name).get('TagSet',[])
        except ClientError as e:
            if e.response['Error']['Code'] != 'NoSuchTagSet':
                raise
            ts = []
        if scoped(name,ts,'arn:aws:s3:::'+name):
            empty_bucket(s3,name)
            attempt(s3.delete_bucket,Bucket=name)
    cognito = client('cognito-idp')
    for pool in pages(cognito,'list_user_pools','UserPools',MaxResults=60):
        p = cognito.describe_user_pool(UserPoolId=pool['Id'])['UserPool']
        if scoped(pool['Name'],p.get('UserPoolTags',{}),pool['Id'],p.get('Arn')):
            for c in pages(cognito,'list_user_pool_clients','UserPoolClients',UserPoolId=pool['Id'],MaxResults=60):
                attempt(cognito.delete_user_pool_client,UserPoolId=pool['Id'],ClientId=c['ClientId'])
            attempt(cognito.delete_user_pool,UserPoolId=pool['Id'])
    logs = client('logs')
    for group in pages(logs,'describe_log_groups','logGroups'):
        name = group['logGroupName']
        ts = logs.list_tags_log_group(logGroupName=name).get('tags',{})
        if scoped(name,ts,group.get('arn')):
            attempt(logs.delete_log_group,logGroupName=name)
    iam = client('iam')
    for role in pages(iam,'list_roles','Roles'):
        name = role['RoleName']
        ts = iam.list_role_tags(RoleName=name).get('Tags',[])
        if scoped(name,ts,role['Arn']):
            for p in pages(iam,'list_attached_role_policies','AttachedPolicies',RoleName=name):
                iam.detach_role_policy(RoleName=name,PolicyArn=p['PolicyArn'])
            for p in pages(iam,'list_role_policies','PolicyNames',RoleName=name):
                iam.delete_role_policy(RoleName=name,PolicyName=p)
            for profile in pages(iam,'list_instance_profiles_for_role','InstanceProfiles',RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'],RoleName=name)
                if owned(profile['InstanceProfileName']):
                    attempt(iam.delete_instance_profile,InstanceProfileName=profile['InstanceProfileName'])
            attempt(iam.delete_role,RoleName=name)
    for p in pages(iam,'list_policies','Policies',Scope='Local'):
        ts = iam.list_policy_tags(PolicyArn=p['Arn']).get('Tags',[])
        if scoped(p['PolicyName'],ts,p['Arn']):
            remove_policy(iam,p['Arn'])
    kms = client('kms')
    for alias in pages(kms,'list_aliases','Aliases'):
        if scoped(alias['AliasName'],(),alias['AliasArn']):
            attempt(kms.delete_alias,AliasName=alias['AliasName'])
    for k in pages(kms,'list_keys','Keys'):
        ts = kms.list_resource_tags(KeyId=k['KeyId']).get('Tags',[])
        d = kms.describe_key(KeyId=k['KeyId'])['KeyMetadata']
        if scoped(d.get('Description',''),ts,k['KeyId'],k['KeyArn']) and d['KeyState']!='PendingDeletion':
            attempt(kms.schedule_key_deletion,KeyId=k['KeyId'],PendingWindowInDays=10)
    network()


def network():
    ec2 = client('ec2')
    vpcs = [v for v in ec2.describe_vpcs()['Vpcs'] if owned(next((t['Value'] for t in v.get('Tags',[]) if t['Key']=='Name'),''),v.get('Tags',[]))]
    vpc_ids = {v['VpcId'] for v in vpcs if v['VpcId'] not in PROTECTED}
    for eni in ec2.describe_network_interfaces()['NetworkInterfaces']:
        if eni['VpcId'] in vpc_ids and not eni.get('RequesterManaged'):
            if eni.get('Attachment'):
                attempt(ec2.detach_network_interface,AttachmentId=eni['Attachment']['AttachmentId'],Force=True)
            attempt(ec2.delete_network_interface,NetworkInterfaceId=eni['NetworkInterfaceId'])
    for sg in ec2.describe_security_groups()['SecurityGroups']:
        name = sg.get('GroupName','')
        if sg['GroupId'] in PROTECTED or name=='default':
            continue
        if sg['VpcId'] in vpc_ids or scoped(name,sg.get('Tags',[]),sg['GroupId']):
            for field, method in [('IpPermissions',ec2.revoke_security_group_ingress),('IpPermissionsEgress',ec2.revoke_security_group_egress)]:
                if sg.get(field):
                    attempt(method,GroupId=sg['GroupId'],IpPermissions=sg[field])
            attempt(ec2.delete_security_group,GroupId=sg['GroupId'])
    for rt in ec2.describe_route_tables()['RouteTables']:
        name = next((t['Value'] for t in rt.get('Tags',[]) if t['Key']=='Name'),'')
        if rt['RouteTableId'] in PROTECTED:
            continue
        if rt['VpcId'] in vpc_ids or scoped(name,rt.get('Tags',[]),rt['RouteTableId']):
            for a in rt.get('Associations',[]):
                if not a.get('Main'):
                    attempt(ec2.disassociate_route_table,AssociationId=a['RouteTableAssociationId'])
            if not any(a.get('Main') for a in rt.get('Associations',[])):
                attempt(ec2.delete_route_table,RouteTableId=rt['RouteTableId'])
    for subnet in ec2.describe_subnets()['Subnets']:
        name = next((t['Value'] for t in subnet.get('Tags',[]) if t['Key']=='Name'),'')
        if subnet['SubnetId'] not in PROTECTED and (subnet['VpcId'] in vpc_ids or scoped(name,subnet.get('Tags',[]),subnet['SubnetId'])):
            attempt(ec2.delete_subnet,SubnetId=subnet['SubnetId'])
    for igw in ec2.describe_internet_gateways()['InternetGateways']:
        name = next((t['Value'] for t in igw.get('Tags',[]) if t['Key']=='Name'),'')
        if igw['InternetGatewayId'] not in PROTECTED and (scoped(name,igw.get('Tags',[]),igw['InternetGatewayId']) or any(a['VpcId'] in vpc_ids for a in igw.get('Attachments',[]))):
            for a in igw.get('Attachments',[]):
                attempt(ec2.detach_internet_gateway,InternetGatewayId=igw['InternetGatewayId'],VpcId=a['VpcId'])
            attempt(ec2.delete_internet_gateway,InternetGatewayId=igw['InternetGatewayId'])
    for vpc in vpc_ids:
        attempt(ec2.delete_vpc,VpcId=vpc)


def protect_state():
    state_path = ROOT / 'infra/terraform.tfstate'
    if not state_path.exists():
        return
    state = json.loads(state_path.read_text())
    for resource in state.get('resources',[]):
        if resource.get('mode')!='managed':
            continue
        for instance in resource.get('instances',[]):
            attrs = instance.get('attributes',{})
            for key in ('id','arn','name','identifier','family','function_name','bucket','replication_group_id','user_pool_id','uuid'):
                if isinstance(attrs.get(key),str):
                    PROTECTED.add(attrs[key])


def verify():
    state = json.loads((ROOT / 'infra/terraform.tfstate').read_text())
    if any(r.get('mode')=='managed' and r.get('instances') for r in state.get('resources',[])):
        raise RuntimeError('Terraform managed resources remain')
    # A final scoped sweep verifies all list endpoints and retries eventual deletes.
    sweep()
    if ERRORS:
        raise RuntimeError(f'Cleanup errors: {ERRORS}')
    kms = client('kms')
    pending = []
    for key in pages(kms,'list_keys','Keys'):
        d = kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        ts = kms.list_resource_tags(KeyId=key['KeyId']).get('Tags',[])
        if owned(d.get('Description',''),ts):
            if d['KeyState']!='PendingDeletion':
                raise RuntimeError('An active deployment-owned KMS key remains')
            pending.append(key['KeyId'])
    if pending:
        print(f'KMS: {len(pending)} retired deployment keys remain in the control plane as PendingDeletion (native deletion window).')


if __name__=='__main__':
    mode = sys.argv[1]
    if mode=='extras':
        protect_state()
        sweep()
        if ERRORS:
            raise RuntimeError(f'Operational cleanup errors: {ERRORS}')
    elif mode=='all':
        for retry in range(6):
            ERRORS.clear()
            sweep()
            if not ERRORS:
                break
            time.sleep(5)
        if ERRORS:
            raise RuntimeError(f'Prefix cleanup errors: {ERRORS}')
    elif mode=='verify':
        verify()
    print(f'Prefix-scoped inventory cleanup ({mode}) complete.')
