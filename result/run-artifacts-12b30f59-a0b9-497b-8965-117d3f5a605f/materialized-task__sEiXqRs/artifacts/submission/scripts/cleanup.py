#!/usr/bin/env python3
"""Prefix-scoped teardown sweep for ClearLedger.

Removes every cloud resource whose name/identifier starts with <resource_prefix>
or that carries the tag ClearLedgerDeployment=<resource_prefix>. Baseline
resources (e.g. cl-base-*) never match and are never touched.

Usage: cleanup.py <resource_prefix> <region> [--empty-buckets-only]
"""
import os
import sys
import time

import boto3
from botocore.config import Config

PREFIX = sys.argv[1]
REGION = sys.argv[2]
EMPTY_ONLY = '--empty-buckets-only' in sys.argv
TAG_KEY = 'ClearLedgerDeployment'
ENDPOINT = os.environ.get('AWS_ENDPOINT_URL') or 'http://aws:4566'
CFG = Config(retries={'max_attempts': 6, 'mode': 'standard'}, connect_timeout=10, read_timeout=60)


def client(name):
    return boto3.client(name, endpoint_url=ENDPOINT, region_name=REGION, config=CFG,
                        aws_access_key_id=os.environ.get('AWS_ACCESS_KEY_ID', 'test'),
                        aws_secret_access_key=os.environ.get('AWS_SECRET_ACCESS_KEY', 'test'))


def log(msg):
    print(f'[cleanup] {msg}', file=sys.stderr, flush=True)


def mine(name):
    return isinstance(name, str) and name.startswith(PREFIX)


def tagged(tags):
    if isinstance(tags, dict):
        return tags.get(TAG_KEY) == PREFIX
    for t in tags or []:
        if (t.get('Key') or t.get('key') or t.get('TagKey')) == TAG_KEY and \
                (t.get('Value') or t.get('value') or t.get('TagValue')) == PREFIX:
            return True
    return False


def safe(desc, fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as exc:  # noqa: BLE001
        msg = str(exc)
        if not any(s in msg for s in ('NotFound', 'NoSuch', 'does not exist', 'not found', 'ResourceNotFound')):
            log(f'{desc}: {msg[:200]}')
        return None


# ---------------------------------------------------------------------------
def sweep_s3(delete_bucket=True):
    s3 = client('s3')
    for b in (safe('s3 list', s3.list_buckets) or {}).get('Buckets', []):
        name = b['Name']
        if not mine(name):
            continue
        while True:
            resp = safe('s3 versions', s3.list_object_versions, Bucket=name) or {}
            objs = [{'Key': o['Key'], 'VersionId': o['VersionId']}
                    for o in (resp.get('Versions') or []) + (resp.get('DeleteMarkers') or [])]
            if not objs:
                break
            for i in range(0, len(objs), 500):
                if safe('s3 delete objects', s3.delete_objects, Bucket=name,
                        Delete={'Objects': objs[i:i + 500], 'Quiet': True}) is None:
                    for o in objs[i:i + 500]:
                        safe('s3 delete object', s3.delete_object, Bucket=name, **o)
        cont = safe('s3 list', s3.list_objects_v2, Bucket=name) or {}
        for o in cont.get('Contents', []) or []:
            safe('s3 delete', s3.delete_object, Bucket=name, Key=o['Key'])
        if delete_bucket:
            log(f'deleting bucket {name}')
            safe('s3 delete bucket', s3.delete_bucket, Bucket=name)


def sweep_ecs():
    ecs = client('ecs')
    for arn in (safe('ecs list', ecs.list_clusters) or {}).get('clusterArns', []):
        name = arn.split('/')[-1]
        if not mine(name):
            continue
        svcs = (safe('ecs services', ecs.list_services, cluster=arn, maxResults=100) or {}).get('serviceArns', [])
        for s in svcs:
            safe('ecs scale', ecs.update_service, cluster=arn, service=s, desiredCount=0)
            log(f'deleting ECS service {s.split("/")[-1]}')
            safe('ecs delete service', ecs.delete_service, cluster=arn, service=s, force=True)
        for t in (safe('ecs tasks', ecs.list_tasks, cluster=arn) or {}).get('taskArns', []):
            safe('ecs stop', ecs.stop_task, cluster=arn, task=t, reason='clearledger destroy')
        for _ in range(30):
            if safe('ecs delete cluster', ecs.delete_cluster, cluster=arn) is not None:
                log(f'deleted ECS cluster {name}')
                break
            time.sleep(3)
    for status in ('ACTIVE', 'INACTIVE'):
        token = None
        while True:
            kw = {'familyPrefix': PREFIX, 'status': status, 'maxResults': 100}
            if token:
                kw['nextToken'] = token
            resp = safe('ecs taskdefs', ecs.list_task_definitions, **kw) or {}
            arns = [a for a in resp.get('taskDefinitionArns', []) if mine(a.split('/')[-1])]
            for a in arns:
                if status == 'ACTIVE':
                    safe('ecs deregister', ecs.deregister_task_definition, taskDefinition=a)
            for i in range(0, len(arns), 10):
                safe('ecs delete taskdefs', ecs.delete_task_definitions, taskDefinitions=arns[i:i + 10])
            token = resp.get('nextToken')
            if not token:
                break


def sweep_elb():
    elb = client('elbv2')
    for lb in (safe('elb list', elb.describe_load_balancers) or {}).get('LoadBalancers', []):
        if not mine(lb['LoadBalancerName']):
            continue
        for ls in (safe('elb listeners', elb.describe_listeners, LoadBalancerArn=lb['LoadBalancerArn']) or {}).get('Listeners', []):
            safe('elb delete listener', elb.delete_listener, ListenerArn=ls['ListenerArn'])
        log(f'deleting load balancer {lb["LoadBalancerName"]}')
        safe('elb delete', elb.delete_load_balancer, LoadBalancerArn=lb['LoadBalancerArn'])
    for tg in (safe('elb tgs', elb.describe_target_groups) or {}).get('TargetGroups', []):
        if mine(tg['TargetGroupName']):
            log(f'deleting target group {tg["TargetGroupName"]}')
            safe('elb delete tg', elb.delete_target_group, TargetGroupArn=tg['TargetGroupArn'])


def sweep_lambda():
    lam = client('lambda')
    marker = None
    while True:
        kw = {'Marker': marker} if marker else {}
        resp = safe('lambda esm', lam.list_event_source_mappings, **kw) or {}
        for m in resp.get('EventSourceMappings', []):
            fn = (m.get('FunctionArn') or '').split(':function:')[-1].split(':')[0]
            src = (m.get('EventSourceArn') or '').split(':')[-1]
            if mine(fn) or mine(src):
                log(f'deleting event source mapping {m["UUID"]}')
                safe('lambda delete esm', lam.delete_event_source_mapping, UUID=m['UUID'])
        marker = resp.get('NextMarker')
        if not marker:
            break
    marker = None
    while True:
        kw = {'Marker': marker} if marker else {}
        resp = safe('lambda list', lam.list_functions, **kw) or {}
        for f in resp.get('Functions', []):
            if mine(f['FunctionName']):
                log(f'deleting function {f["FunctionName"]}')
                safe('lambda delete', lam.delete_function, FunctionName=f['FunctionName'])
        marker = resp.get('NextMarker')
        if not marker:
            break


def sweep_scheduler():
    sch = client('scheduler')
    groups = [g['Name'] for g in (safe('scheduler groups', sch.list_schedule_groups) or {}).get('ScheduleGroups', [])]
    if 'default' not in groups:
        groups.append('default')
    for g in groups:
        token = None
        while True:
            kw = {'GroupName': g}
            if token:
                kw['NextToken'] = token
            resp = safe('scheduler list', sch.list_schedules, **kw) or {}
            for s in resp.get('Schedules', []):
                if mine(s['Name']) or mine(g):
                    log(f'deleting schedule {g}/{s["Name"]}')
                    safe('scheduler delete', sch.delete_schedule, Name=s['Name'], GroupName=g)
            token = resp.get('NextToken')
            if not token:
                break
        if mine(g):
            safe('scheduler delete group', sch.delete_schedule_group, Name=g)


def sweep_sqs():
    sqs = client('sqs')
    for url in (safe('sqs list', sqs.list_queues, QueueNamePrefix=PREFIX) or {}).get('QueueUrls', []) or []:
        if mine(url.rsplit('/', 1)[-1]):
            log(f'deleting queue {url.rsplit("/", 1)[-1]}')
            safe('sqs delete', sqs.delete_queue, QueueUrl=url)


def sweep_dynamodb():
    ddb = client('dynamodb')
    kw = {}
    while True:
        resp = safe('ddb list', ddb.list_tables, **kw) or {}
        for t in resp.get('TableNames', []):
            if mine(t):
                log(f'deleting table {t}')
                safe('ddb delete', ddb.delete_table, TableName=t)
        if not resp.get('LastEvaluatedTableName'):
            break
        kw['ExclusiveStartTableName'] = resp['LastEvaluatedTableName']


def sweep_rds():
    rds = client('rds')
    pending = []
    for db in (safe('rds list', rds.describe_db_instances) or {}).get('DBInstances', []):
        if mine(db['DBInstanceIdentifier']):
            log(f'deleting DB instance {db["DBInstanceIdentifier"]}')
            safe('rds modify', rds.modify_db_instance, DBInstanceIdentifier=db['DBInstanceIdentifier'],
                 DeletionProtection=False, ApplyImmediately=True)
            safe('rds delete', rds.delete_db_instance, DBInstanceIdentifier=db['DBInstanceIdentifier'],
                 SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
            pending.append(db['DBInstanceIdentifier'])
    for snap in (safe('rds snaps', rds.describe_db_snapshots) or {}).get('DBSnapshots', []):
        if mine(snap['DBSnapshotIdentifier']) or mine(snap.get('DBInstanceIdentifier')):
            safe('rds delete snapshot', rds.delete_db_snapshot, DBSnapshotIdentifier=snap['DBSnapshotIdentifier'])
    for _ in range(60):
        live = [d['DBInstanceIdentifier'] for d in (safe('rds list', rds.describe_db_instances) or {}).get('DBInstances', [])
                if d['DBInstanceIdentifier'] in pending]
        if not live:
            break
        time.sleep(3)
    for g in (safe('rds subnet groups', rds.describe_db_subnet_groups) or {}).get('DBSubnetGroups', []):
        if mine(g['DBSubnetGroupName']):
            log(f'deleting DB subnet group {g["DBSubnetGroupName"]}')
            safe('rds delete subnet group', rds.delete_db_subnet_group, DBSubnetGroupName=g['DBSubnetGroupName'])
    for g in (safe('rds param groups', rds.describe_db_parameter_groups) or {}).get('DBParameterGroups', []):
        if mine(g['DBParameterGroupName']):
            safe('rds delete pg', rds.delete_db_parameter_group, DBParameterGroupName=g['DBParameterGroupName'])


def sweep_elasticache():
    ec = client('elasticache')
    pending = []
    for rg in (safe('ec rgs', ec.describe_replication_groups) or {}).get('ReplicationGroups', []):
        if mine(rg['ReplicationGroupId']):
            log(f'deleting replication group {rg["ReplicationGroupId"]}')
            safe('ec delete rg', ec.delete_replication_group, ReplicationGroupId=rg['ReplicationGroupId'])
            pending.append(rg['ReplicationGroupId'])
    for cc in (safe('ec clusters', ec.describe_cache_clusters) or {}).get('CacheClusters', []):
        if mine(cc['CacheClusterId']) and not cc.get('ReplicationGroupId'):
            log(f'deleting cache cluster {cc["CacheClusterId"]}')
            safe('ec delete cluster', ec.delete_cache_cluster, CacheClusterId=cc['CacheClusterId'])
    for _ in range(40):
        live = [r['ReplicationGroupId'] for r in (safe('ec rgs', ec.describe_replication_groups) or {}).get('ReplicationGroups', [])
                if r['ReplicationGroupId'] in pending]
        if not live:
            break
        time.sleep(3)
    for g in (safe('ec subnet groups', ec.describe_cache_subnet_groups) or {}).get('CacheSubnetGroups', []):
        if mine(g['CacheSubnetGroupName']):
            log(f'deleting cache subnet group {g["CacheSubnetGroupName"]}')
            safe('ec delete subnet group', ec.delete_cache_subnet_group, CacheSubnetGroupName=g['CacheSubnetGroupName'])
    for g in (safe('ec param groups', ec.describe_cache_parameter_groups) or {}).get('CacheParameterGroups', []):
        if mine(g['CacheParameterGroupName']):
            safe('ec delete pg', ec.delete_cache_parameter_group, CacheParameterGroupName=g['CacheParameterGroupName'])


def sweep_cognito():
    cog = client('cognito-idp')
    for p in (safe('cognito list', cog.list_user_pools, MaxResults=60) or {}).get('UserPools', []):
        if not mine(p.get('Name')):
            continue
        desc = (safe('cognito describe', cog.describe_user_pool, UserPoolId=p['Id']) or {}).get('UserPool', {})
        if desc.get('Domain'):
            safe('cognito delete domain', cog.delete_user_pool_domain, Domain=desc['Domain'], UserPoolId=p['Id'])
        if desc.get('DeletionProtection') == 'ACTIVE':
            safe('cognito unprotect', cog.update_user_pool, UserPoolId=p['Id'], DeletionProtection='INACTIVE')
        log(f'deleting user pool {p["Name"]}')
        safe('cognito delete', cog.delete_user_pool, UserPoolId=p['Id'])


def sweep_logs():
    logs = client('logs')
    patterns = [f'/clearledger/{PREFIX}/', f'/clearledger/{PREFIX}', PREFIX, f'/aws/lambda/{PREFIX}',
                f'/ecs/{PREFIX}', f'/aws/ecs/{PREFIX}']
    seen = set()
    for pat in patterns:
        token = None
        while True:
            kw = {'logGroupNamePrefix': pat}
            if token:
                kw['nextToken'] = token
            resp = safe('logs list', logs.describe_log_groups, **kw) or {}
            for g in resp.get('logGroups', []):
                n = g['logGroupName']
                if n in seen:
                    continue
                if n == f'/clearledger/{PREFIX}' or n.startswith(f'/clearledger/{PREFIX}/') or mine(n) \
                        or n.startswith(f'/aws/lambda/{PREFIX}') or n.startswith(f'/ecs/{PREFIX}') \
                        or n.startswith(f'/aws/ecs/{PREFIX}'):
                    seen.add(n)
                    log(f'deleting log group {n}')
                    safe('logs delete', logs.delete_log_group, logGroupName=n)
            token = resp.get('nextToken')
            if not token:
                break


def delete_policy(iam, arn):
    ents = safe('iam entities', iam.list_entities_for_policy, PolicyArn=arn) or {}
    for r in ents.get('PolicyRoles', []):
        safe('iam detach', iam.detach_role_policy, RoleName=r['RoleName'], PolicyArn=arn)
    for u in ents.get('PolicyUsers', []):
        safe('iam detach user', iam.detach_user_policy, UserName=u['UserName'], PolicyArn=arn)
    for g in ents.get('PolicyGroups', []):
        safe('iam detach group', iam.detach_group_policy, GroupName=g['GroupName'], PolicyArn=arn)
    for v in (safe('iam versions', iam.list_policy_versions, PolicyArn=arn) or {}).get('Versions', []):
        if not v.get('IsDefaultVersion'):
            safe('iam delete version', iam.delete_policy_version, PolicyArn=arn, VersionId=v['VersionId'])
    safe('iam delete policy', iam.delete_policy, PolicyArn=arn)


def sweep_iam():
    iam = client('iam')
    roles = []
    marker = None
    while True:
        kw = {'Marker': marker} if marker else {}
        resp = safe('iam roles', iam.list_roles, **kw) or {}
        roles.extend(resp.get('Roles', []))
        if not resp.get('IsTruncated'):
            break
        marker = resp.get('Marker')
    for r in roles:
        name = r['RoleName']
        is_mine = mine(name)
        if not is_mine:
            tags = (safe('iam role tags', iam.list_role_tags, RoleName=name) or {}).get('Tags', [])
            is_mine = tagged(tags)
        if not is_mine:
            continue
        for p in (safe('iam attached', iam.list_attached_role_policies, RoleName=name) or {}).get('AttachedPolicies', []):
            safe('iam detach', iam.detach_role_policy, RoleName=name, PolicyArn=p['PolicyArn'])
        for p in (safe('iam inline', iam.list_role_policies, RoleName=name) or {}).get('PolicyNames', []):
            safe('iam delete inline', iam.delete_role_policy, RoleName=name, PolicyName=p)
        for ip in (safe('iam ips', iam.list_instance_profiles_for_role, RoleName=name) or {}).get('InstanceProfiles', []):
            safe('iam remove ip', iam.remove_role_from_instance_profile, InstanceProfileName=ip['InstanceProfileName'], RoleName=name)
        log(f'deleting role {name}')
        safe('iam delete role', iam.delete_role, RoleName=name)
    marker = None
    while True:
        kw = {'Scope': 'Local', 'MaxItems': 100}
        if marker:
            kw['Marker'] = marker
        resp = safe('iam policies', iam.list_policies, **kw) or {}
        for p in resp.get('Policies', []):
            if mine(p['PolicyName']):
                log(f'deleting managed policy {p["PolicyName"]}')
                delete_policy(iam, p['Arn'])
        if not resp.get('IsTruncated'):
            break
        marker = resp.get('Marker')
    for ip in (safe('iam ips', iam.list_instance_profiles) or {}).get('InstanceProfiles', []):
        if mine(ip['InstanceProfileName']):
            for r in ip.get('Roles', []):
                safe('iam remove ip role', iam.remove_role_from_instance_profile,
                     InstanceProfileName=ip['InstanceProfileName'], RoleName=r['RoleName'])
            safe('iam delete ip', iam.delete_instance_profile, InstanceProfileName=ip['InstanceProfileName'])


def sweep_kms():
    kms = client('kms')
    aliases = (safe('kms aliases', kms.list_aliases) or {}).get('Aliases', [])
    alias_targets = set()
    for a in aliases:
        if a['AliasName'].startswith(f'alias/{PREFIX}'):
            if a.get('TargetKeyId'):
                alias_targets.add(a['TargetKeyId'])
            log(f'deleting alias {a["AliasName"]}')
            safe('kms delete alias', kms.delete_alias, AliasName=a['AliasName'])
    marker = None
    while True:
        kw = {'Marker': marker} if marker else {}
        resp = safe('kms keys', kms.list_keys, **kw) or {}
        for k in resp.get('Keys', []):
            kid = k['KeyId']
            meta = (safe('kms describe', kms.describe_key, KeyId=kid) or {}).get('KeyMetadata', {})
            if meta.get('KeyManager') == 'AWS' or meta.get('KeyState') in ('PendingDeletion', 'PendingReplicaDeletion'):
                continue
            tags = (safe('kms tags', kms.list_resource_tags, KeyId=kid) or {}).get('Tags', [])
            if tagged(tags) or kid in alias_targets:
                log(f'scheduling deletion of KMS key {kid}')
                safe('kms schedule deletion', kms.schedule_key_deletion, KeyId=kid, PendingWindowInDays=7)
        if not resp.get('Truncated'):
            break
        marker = resp.get('NextMarker')


def sweep_ec2():
    ec2 = client('ec2')
    vpcs = (safe('ec2 vpcs', ec2.describe_vpcs) or {}).get('Vpcs', [])
    mine_vpcs = []
    for v in vpcs:
        name = next((t['Value'] for t in v.get('Tags', []) if t['Key'] == 'Name'), '')
        if (tagged(v.get('Tags')) or mine(name)) and not v.get('IsDefault'):
            mine_vpcs.append(v['VpcId'])
    # security groups with the prefix (in any VPC) or in our VPCs
    sgs = (safe('ec2 sgs', ec2.describe_security_groups) or {}).get('SecurityGroups', [])
    doomed_sgs = [g for g in sgs if g['GroupName'] != 'default' and
                  (mine(g['GroupName']) or tagged(g.get('Tags')) or g.get('VpcId') in mine_vpcs)]
    for vpc in mine_vpcs:
        for eni in (safe('ec2 enis', ec2.describe_network_interfaces,
                         Filters=[{'Name': 'vpc-id', 'Values': [vpc]}]) or {}).get('NetworkInterfaces', []):
            att = eni.get('Attachment')
            if att and att.get('AttachmentId'):
                safe('ec2 detach eni', ec2.detach_network_interface, AttachmentId=att['AttachmentId'], Force=True)
            safe('ec2 delete eni', ec2.delete_network_interface, NetworkInterfaceId=eni['NetworkInterfaceId'])
    for g in doomed_sgs:
        if g.get('IpPermissions'):
            safe('ec2 revoke ingress', ec2.revoke_security_group_ingress, GroupId=g['GroupId'], IpPermissions=g['IpPermissions'])
        if g.get('IpPermissionsEgress'):
            safe('ec2 revoke egress', ec2.revoke_security_group_egress, GroupId=g['GroupId'], IpPermissions=g['IpPermissionsEgress'])
    for g in doomed_sgs:
        log(f'deleting security group {g["GroupName"]}')
        safe('ec2 delete sg', ec2.delete_security_group, GroupId=g['GroupId'])
    for vpc in mine_vpcs:
        flt = [{'Name': 'vpc-id', 'Values': [vpc]}]
        for igw in (safe('ec2 igws', ec2.describe_internet_gateways,
                         Filters=[{'Name': 'attachment.vpc-id', 'Values': [vpc]}]) or {}).get('InternetGateways', []):
            safe('ec2 detach igw', ec2.detach_internet_gateway, InternetGatewayId=igw['InternetGatewayId'], VpcId=vpc)
            safe('ec2 delete igw', ec2.delete_internet_gateway, InternetGatewayId=igw['InternetGatewayId'])
        for rt in (safe('ec2 rts', ec2.describe_route_tables, Filters=flt) or {}).get('RouteTables', []):
            main = any(a.get('Main') for a in rt.get('Associations', []))
            for a in rt.get('Associations', []):
                if not a.get('Main') and a.get('RouteTableAssociationId'):
                    safe('ec2 disassociate', ec2.disassociate_route_table, AssociationId=a['RouteTableAssociationId'])
            if not main:
                safe('ec2 delete rt', ec2.delete_route_table, RouteTableId=rt['RouteTableId'])
        for sn in (safe('ec2 subnets', ec2.describe_subnets, Filters=flt) or {}).get('Subnets', []):
            safe('ec2 delete subnet', ec2.delete_subnet, SubnetId=sn['SubnetId'])
        log(f'deleting VPC {vpc}')
        safe('ec2 delete vpc', ec2.delete_vpc, VpcId=vpc)
    # orphaned prefix-tagged IGWs (detached)
    for igw in (safe('ec2 igws', ec2.describe_internet_gateways) or {}).get('InternetGateways', []):
        name = next((t['Value'] for t in igw.get('Tags', []) if t['Key'] == 'Name'), '')
        if tagged(igw.get('Tags')) or mine(name):
            for a in igw.get('Attachments', []):
                safe('ec2 detach igw', ec2.detach_internet_gateway, InternetGatewayId=igw['InternetGatewayId'], VpcId=a['VpcId'])
            safe('ec2 delete igw', ec2.delete_internet_gateway, InternetGatewayId=igw['InternetGatewayId'])


def report_leftovers():
    tagging = client('resourcegroupstaggingapi')
    resp = safe('tagging', tagging.get_resources, TagFilters=[{'Key': TAG_KEY, 'Values': [PREFIX]}]) or {}
    left = [r['ResourceARN'] for r in resp.get('ResourceTagMappingList', [])]
    if left:
        log(f'{len(left)} tagged resource(s) still reported by the tagging API')
        for a in left[:25]:
            log(f'  {a}')


def main():
    if EMPTY_ONLY:
        sweep_s3(delete_bucket=False)
        return
    for fn in (sweep_scheduler, sweep_lambda, sweep_ecs, sweep_elb, sweep_sqs, sweep_dynamodb, sweep_s3,
               sweep_elasticache, sweep_rds, sweep_cognito, sweep_logs, sweep_iam, sweep_kms, sweep_ec2):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            log(f'{fn.__name__} failed: {exc}')
    report_leftovers()


if __name__ == '__main__':
    main()
