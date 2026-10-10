#!/usr/bin/env python3
"""Administrative lifecycle operations; resource creation belongs to Terraform."""
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import urllib.request

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
import jsonschema
import psycopg2
from psycopg2.extras import RealDictCursor

ROOT = Path(__file__).resolve().parent
CFG = json.loads(Path('/workspace/config/config.json').read_text())
PREFIX = CFG['resource_prefix']
SESSION = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=CFG['region'])
def client(service):
    return SESSION.client(service, endpoint_url=CFG['aws_endpoint_url'], config=Config(retries={'max_attempts': 5, 'mode': 'standard'}, connect_timeout=5, read_timeout=75, s3={'addressing_style': 'path'}))

def pages(c, method, key, **kwargs):
    if c.can_paginate(method):
        return [x for page in c.get_paginator(method).paginate(**kwargs) for x in page.get(key, [])]
    return getattr(c, method)(**kwargs).get(key, [])

def absent(call, **kwargs):
    try:
        return call(**kwargs)
    except ClientError as exc:
        if exc.response['Error']['Code'] in ('NoSuchEntity','NoSuchEntityException','ResourceNotFoundException','ResourceNotFound','NotFoundException','NotFound','AWS.SimpleQueueService.NonExistentQueue','NoSuchBucket','DBInstanceNotFound','ReplicationGroupNotFoundFault','CacheClusterNotFound','InvalidAliasNameException'):
            return None
        raise

def scoped(name, tags=None):
    segments=re.split(r'[/ :]',str(name))
    if any(segment.startswith('cl-base-') for segment in segments):
        return False
    if isinstance(tags, list):
        tags = {t.get('Key', t.get('key')): t.get('Value', t.get('value')) for t in tags}
    return any(segment.startswith(PREFIX) for segment in segments) or (tags or {}).get('ClearLedgerDeployment') == PREFIX

def delete_policy(iam, arn):
    for v in pages(iam, 'list_policy_versions', 'Versions', PolicyArn=arn):
        if not v['IsDefaultVersion']:
            iam.delete_policy_version(PolicyArn=arn, VersionId=v['VersionId'])
    for entity_type, key in [('Role','PolicyRoles'), ('User','PolicyUsers'), ('Group','PolicyGroups')]:
        for entity in pages(iam, 'list_entities_for_policy', key, PolicyArn=arn):
            getattr(iam, 'detach_'+entity_type.lower()+'_policy')(**{entity_type+'Name': entity[entity_type+'Name'], 'PolicyArn': arn})
    absent(iam.delete_policy, PolicyArn=arn)

def reconcile_iam(destroy=False):
    iam = client('iam')
    roles = pages(iam, 'list_roles', 'Roles')
    expected = {f'{PREFIX}-{k.replace("_", "-")}': f'{PREFIX}-canonical-{k}' for k in ['ecs_execution','ecs_task','projector','relay','archiver','scheduler']}
    for r in roles:
        name = r['RoleName']
        tags = iam.list_role_tags(RoleName=name).get('Tags', [])
        if not scoped(name,tags) or (not destroy and name not in expected):
            continue
        for p in pages(iam, 'list_role_policies', 'PolicyNames', RoleName=name):
            if destroy or p != expected[name]:
                iam.delete_role_policy(RoleName=name, PolicyName=p)
        for p in pages(iam, 'list_attached_role_policies', 'AttachedPolicies', RoleName=name):
            iam.detach_role_policy(RoleName=name, PolicyArn=p['PolicyArn'])
        if destroy:
            for profile in pages(iam, 'list_instance_profiles_for_role', 'InstanceProfiles', RoleName=name):
                iam.remove_role_from_instance_profile(InstanceProfileName=profile['InstanceProfileName'], RoleName=name)
                if scoped(profile['InstanceProfileName']):
                    iam.delete_instance_profile(InstanceProfileName=profile['InstanceProfileName'])
            iam.delete_role(RoleName=name)
    for p in pages(iam, 'list_policies', 'Policies', Scope='Local'):
        tags = iam.list_policy_tags(PolicyArn=p['Arn']).get('Tags', [])
        if scoped(p['PolicyName'],tags):
            # No canonical managed policies: Terraform uses dedicated inline policies.
            delete_policy(iam,p['Arn'])

def prepare():
    reconcile_iam()
    ec2 = client('ec2')
    for sg in ec2.describe_security_groups()['SecurityGroups']:
        if scoped(sg['GroupName'],sg.get('Tags')) and sg['GroupName'] in [f'{PREFIX}-rds',f'{PREFIX}-valkey',f'{PREFIX}-alb']:
            bad = []
            for rule in sg.get('IpPermissionsEgress',[]):
                if sg['GroupName'] != f'{PREFIX}-alb' or rule.get('IpProtocol') == '-1' or any(x['CidrIp']=='0.0.0.0/0' for x in rule.get('IpRanges',[])) or any(x['CidrIpv6']=='::/0' for x in rule.get('Ipv6Ranges',[])):
                    bad.append(rule)
            if bad:
                ec2.revoke_security_group_egress(GroupId=sg['GroupId'],IpPermissions=bad)

def checkplan():
    plan=json.loads(subprocess.check_output(['terraform',f'-chdir={ROOT / "infra"}','show','-json',str(ROOT/'infra/deploy.tfplan')]))
    for change in plan.get('resource_changes',[]):
        if change['type'] in ('aws_db_instance','aws_dynamodb_table','aws_s3_bucket') and 'delete' in change['change']['actions']:
            raise RuntimeError('Deployment would destroy authoritative or persistent storage: '+change['address'])

def db_connect(m):
    d = m['database']
    return psycopg2.connect(host=d['endpoint'], port=d['port'], dbname=CFG['db_name'], user=CFG['db_username'], password=CFG['db_password'], connect_timeout=5, application_name='clearledger-lifecycle')

def query(conn, sql, args=()):
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(sql,args)
        return [dict(r) for r in cur.fetchall()] if cur.description else []

def invoke(lam, name):
    r = lam.invoke(FunctionName=name, InvocationType='RequestResponse', Payload=b'{}')
    body = r['Payload'].read()
    if r.get('FunctionError'):
        raise RuntimeError(f'Worker {name} invocation failed: {body[:500]!r}')

def worker_environment(lam,name,variables):
    lam.update_function_configuration(FunctionName=name,Environment={'Variables':variables})
    deadline=time.monotonic()+60
    while time.monotonic()<deadline:
        state=lam.get_function_configuration(FunctionName=name).get('LastUpdateStatus','Successful')
        if state=='Successful': return
        if state=='Failed': raise RuntimeError('Worker configuration update failed')
        time.sleep(1)
    raise RuntimeError('Worker configuration update timed out')

def schedule_state(scheduler, name, state):
    r = scheduler.get_schedule(Name=name)
    kwargs = {k:r[k] for k in ['Name','GroupName','ScheduleExpression','ScheduleExpressionTimezone','StartDate','EndDate','Description','FlexibleTimeWindow','Target','KmsKeyArn','ActionAfterCompletion'] if k in r}
    scheduler.update_schedule(**kwargs,State=state)

def mapping_state(lam, uuid, enabled):
    deadline = time.monotonic()+90
    desired = 'Enabled' if enabled else 'Disabled'
    while time.monotonic()<deadline:
        r = lam.get_event_source_mapping(UUID=uuid)
        if r['State']==desired:
            return
        if r['State'] in ('Enabled','Disabled'):
            lam.update_event_source_mapping(UUID=uuid,Enabled=enabled)
        time.sleep(1)
    raise RuntimeError('Event mapping did not reach '+desired)

def purge_bucket(s3, bucket, keep=None):
    versions = pages(s3,'list_object_versions','Versions',Bucket=bucket)
    markers = pages(s3,'list_object_versions','DeleteMarkers',Bucket=bucket)
    objects = [{'Key':v['Key'],'VersionId':v['VersionId']} for v in versions if keep is None or not v['IsLatest'] or v['Key'] not in keep]
    objects += [{'Key':v['Key'],'VersionId':v['VersionId']} for v in markers]
    for start in range(0,len(objects),1000):
        r = s3.delete_objects(Bucket=bucket,Delete={'Objects':objects[start:start+1000],'Quiet':True})
        if r.get('Errors'):
            raise RuntimeError('S3 version purge failed')
    # Includes unversioned buckets created during operational drills.
    for obj in pages(s3,'list_objects_v2','Contents',Bucket=bucket):
        if keep is None or obj['Key'] not in keep:
            s3.delete_object(Bucket=bucket,Key=obj['Key'])

class Redis:
    """Small RESP client so operational scripts require no extra pip packages."""
    def __init__(self,host,port):
        self.sock = socket.create_connection((host,port),timeout=10)
        self.file = self.sock.makefile('rb')
    def command(self,*args):
        args = [str(x).encode() if not isinstance(x,bytes) else x for x in args]
        self.sock.sendall(b'*'+str(len(args)).encode()+b'\r\n'+b''.join(b'$'+str(len(x)).encode()+b'\r\n'+x+b'\r\n' for x in args))
        return self.read()
    def read(self):
        line=self.file.readline(); kind=line[:1]; data=line[1:-2]
        if kind==b'-': raise RuntimeError('Valkey: '+data.decode())
        if kind==b'+': return data.decode()
        if kind==b':': return int(data)
        if kind==b'$':
            n=int(data)
            if n==-1: return None
            b=self.file.read(n); self.file.read(2); return b.decode()
        if kind==b'*': return [self.read() for _ in range(int(data))]
        raise RuntimeError('Invalid RESP reply')
    def close(self):
        self.file.close(); self.sock.close()

def canonical_items(settlements, events):
    expected = {}
    cache = {}
    latest = {e['settlement_id']:e['payload'] for e in events}
    def attr(v):
        return {'N':str(v)} if isinstance(v,int) else {'S':str(v)}
    def item(values):
        return {k:attr(v) for k,v in values.items() if v is not None}
    for s in settlements:
        sid = str(s['settlement_id']); pk='SETTLEMENT#'+sid
        p = latest[s['settlement_id']]
        state = dict(PK=pk,SK='STATE',GSI1PK='ACCOUNT#'+s['account_id'],GSI1SK=pk,
                     settlement_id=sid,account_id=s['account_id'],reference=s['reference'],debit_party=s['debit_party'],credit_party=s['credit_party'],
                     status=s['current_status'],clearing_stage=s['current_stage'],version=s['version'],entry_count=s['entry_count'],
                     updated_at=s['updated_at'].isoformat(),last_entry_id=s['last_entry_id'],last_memo=s['last_memo'])
        expected[(pk,'STATE')]=item(state)
        cache['clearledger:settlement:'+sid] = dict(settlementId=sid,accountId=s['account_id'],reference=s['reference'],debitParty=s['debit_party'],creditParty=s['credit_party'],
            status=s['current_status'],clearingStage=s['current_stage'],version=s['version'],entryCount=s['entry_count'],updatedAt=p['occurredAt'],
            lastEntryId=str(s['last_entry_id']) if s['last_entry_id'] else None,lastMemo=s['last_memo'])
    for e in events:
        p=e['payload']; d=p['data']; pk='SETTLEMENT#'+str(e['settlement_id']); sk=f'EVENT#{e["aggregate_version"]:08d}'
        expected[(pk,sk)]=item(dict(PK=pk,SK=sk,settlement_id=e['settlement_id'],event_id=e['event_id'],version=e['aggregate_version'],
              event_type=e['event_type'],status=d['status'],clearing_stage=d['clearingStage'],occurred_at=e['occurred_at'].isoformat(),correlation_id=e['correlation_id'],
              envelope=json.dumps(p,separators=(',',':'),sort_keys=True,ensure_ascii=False),entry_id=d.get('entryId'),memo=d.get('memo')))
    return expected,cache

def reconcile_table(ddb,table,expected):
    existing={(x['PK']['S'],x['SK']['S']):x for x in pages(ddb,'scan','Items',TableName=table,ConsistentRead=True)}
    writes=[{'DeleteRequest':{'Key':{'PK':{'S':k[0]},'SK':{'S':k[1]}}}} for k in existing.keys()-expected.keys()]
    writes += [{'PutRequest':{'Item':v}} for k,v in expected.items() if existing.get(k)!=v]
    for start in range(0,len(writes),25):
        pending={table:writes[start:start+25]}
        for retry in range(10):
            pending=ddb.batch_write_item(RequestItems=pending).get('UnprocessedItems',{})
            if not pending: break
            time.sleep(min(2**retry/10,5))
        if pending: raise RuntimeError('DynamoDB did not accept reconciliation batch')
    actual={(x['PK']['S'],x['SK']['S']):x for x in pages(ddb,'scan','Items',TableName=table,ConsistentRead=True)}
    if actual!=expected: raise RuntimeError('Projection verification failed')

def archive_valid(s3,bucket,outbox):
    remaining = {x['payload']['eventId']:x for x in outbox}
    intervals=[]; keys=set()
    for obj in pages(s3,'list_objects_v2','Contents',Bucket=bucket):
        key=obj['Key']; match=re.fullmatch(r'ledger-audit/batch-(\d{8})-(\d{8})-([0-9a-f]{16})\.ndjson',key)
        if not match: return None
        body=s3.get_object(Bucket=bucket,Key=key)['Body'].read()
        if hashlib.sha256(body).hexdigest()[:16]!=match[3]: return None
        try: records=[json.loads(line) for line in body.splitlines()]
        except (ValueError,TypeError): return None
        first,last=int(match[1]),int(match[2])
        if len(records)!=last-first+1: return None
        for seq,p in zip(range(first,last+1),records):
            row=remaining.pop(p.get('eventId'),None)
            if row is None or row['seq']!=seq or row['payload']!=p: return None
        intervals.append((first,last)); keys.add(key)
    intervals.sort()
    if any(a[1]>=b[0] for a,b in zip(intervals,intervals[1:])) or remaining: return None
    return keys

def deploy():
    raw=subprocess.check_output(['terraform',f'-chdir={ROOT / "infra"}','output','-json','manifest'])
    m=json.loads(raw)
    jsonschema.Draft202012Validator(json.loads(Path('/workspace/contracts/schemas/manifest.schema.json').read_text())).validate(m)
    temp=ROOT/'manifest.json.tmp'; temp.write_text(json.dumps(m,indent=2)+'\n'); temp.replace(ROOT/'manifest.json')
    deadline=time.monotonic()+120
    while True:
        try: conn=db_connect(m); break
        except psycopg2.OperationalError:
            if time.monotonic()>deadline: raise RuntimeError('PostgreSQL unavailable')
            time.sleep(2)
    conn.autocommit=True
    with conn.cursor() as cur: cur.execute((ROOT/'schema.sql').read_text())
    lam=client('lambda'); scheduler=client('scheduler'); sqs=client('sqs'); s3=client('s3'); ddb=client('dynamodb')
    schedules=[m['schedules']['outbox_schedule_name'],m['schedules']['archive_schedule_name']]
    uuid=m['messaging']['event_source_mapping_uuid']
    archiver=m['workers']['audit_archiver']['function_name']
    archive_environment=None
    for name in schedules: schedule_state(scheduler,name,'DISABLED')
    try:
        # Lock the authoritative aggregate/event tables for the short recovery window.
        # Readers continue; concurrent API writes wait and resume after convergence.
        conn.autocommit=False
        query(conn,"SET lock_timeout = '120s'; SET statement_timeout = '180s'")
        query(conn,'LOCK TABLE clearledger.settlements, clearledger.events, clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
        worker_conn=db_connect(m); worker_conn.autocommit=True
        try:
            end=time.monotonic()+180
            while query(worker_conn,'SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL')[0]['n']:
                invoke(lam,m['workers']['outbox_relay']['function_name'])
                if time.monotonic()>end: raise RuntimeError('Outbox relay failed to drain')
            # Let the real projector drain deliveries before final canonical repair.
            end=time.monotonic()+60
            while time.monotonic()<end:
                a=sqs.get_queue_attributes(QueueUrl=m['messaging']['queue_url'],AttributeNames=['ApproximateNumberOfMessages','ApproximateNumberOfMessagesNotVisible'])['Attributes']
                if all(int(v)==0 for v in a.values()): break
                time.sleep(1)
            mapping_state(lam,uuid,False)
            time.sleep(4)
            settlements=query(conn,'SELECT * FROM clearledger.settlements ORDER BY settlement_id')
            events=query(conn,'SELECT * FROM clearledger.events ORDER BY settlement_id,aggregate_version')
            outbox=query(worker_conn,'SELECT * FROM clearledger.outbox ORDER BY seq')
            bucket=m['audit']['bucket_name']
            keys=archive_valid(s3,bucket,outbox)
            if keys is None:
                purge_bucket(s3,bucket)
                query(worker_conn,'UPDATE clearledger.outbox SET archived_at=NULL WHERE archived_at IS NOT NULL')
            # PostgreSQL sequences can have holes after rolled-back writes. Single-row
            # batches keep archive intervals contiguous even across those holes.
            if any(b['seq'] != a['seq']+1 for a,b in zip(outbox,outbox[1:])):
                archive_environment=lam.get_function_configuration(FunctionName=archiver)['Environment']['Variables']
                worker_environment(lam,archiver,{**archive_environment,'AUDIT_BATCH_SIZE':'1'})
            end=time.monotonic()+180
            while query(worker_conn,'SELECT count(*) AS n FROM clearledger.outbox WHERE archived_at IS NULL')[0]['n']:
                invoke(lam,m['workers']['audit_archiver']['function_name'])
                if time.monotonic()>end: raise RuntimeError('Audit archiver failed to drain')
            keys=archive_valid(s3,bucket,outbox)
            if keys is None: raise RuntimeError('Audit archive verification failed')
            purge_bucket(s3,bucket,keys)
            expected,cache=canonical_items(settlements,events)
            reconcile_table(ddb,m['projections']['table_name'],expected)
            redis=Redis(m['cache']['endpoint'],m['cache']['port'])
            try:
                cursor='0'; all_keys=[]
                while True:
                    cursor,found=redis.command('SCAN',cursor,'COUNT',1000); all_keys.extend(found)
                    if cursor=='0': break
                for key in all_keys:
                    if key not in cache: redis.command('DEL',key)
                mapping_state(lam,uuid,True)
                for key,payload in cache.items():
                    redis.command('SET',key,json.dumps(payload,separators=(',',':')),'EX',90)
                    if not 0<redis.command('TTL',key)<=90: raise RuntimeError('Invalid cache TTL')
            finally: redis.close()
            conn.commit()
        finally: worker_conn.close()
    finally:
        conn.rollback(); conn.close()
        if archive_environment is not None:
            worker_environment(lam,archiver,archive_environment)
        mapping_state(lam,uuid,True)
        for name in schedules: schedule_state(scheduler,name,'ENABLED')
    deadline=time.monotonic()+120
    while time.monotonic()<deadline:
        try:
            with urllib.request.urlopen(m['service_url']+'/health/ready',timeout=5) as r:
                if r.status==200:
                    print('ClearLedger ready; control plane, projections, cache, and audit archive reconciled.')
                    return
        except (OSError,urllib.error.HTTPError): pass
        time.sleep(2)
    raise RuntimeError('API readiness deadline exceeded')

def predestroy():
    scheduler=client('scheduler'); lam=client('lambda')
    for schedule in pages(scheduler,'list_schedules','Schedules'):
        if scoped(schedule['Name']):
            absent(scheduler.delete_schedule,Name=schedule['Name'],GroupName=schedule.get('GroupName','default'))
    for f in pages(lam,'list_functions','Functions'):
        tags=lam.list_tags(Resource=f['FunctionArn']).get('Tags',{})
        if scoped(f['FunctionName'],tags):
            for esm in pages(lam,'list_event_source_mappings','EventSourceMappings',FunctionName=f['FunctionName']):
                absent(lam.delete_event_source_mapping,UUID=esm['UUID'])
    # Quiesce ECS tasks before deleting dependencies.
    ecs=client('ecs')
    for cluster in pages(ecs,'list_clusters','clusterArns'):
        if scoped(cluster.rsplit('/',1)[-1]):
            for service in pages(ecs,'list_services','serviceArns',cluster=cluster):
                ecs.update_service(cluster=cluster,service=service,desiredCount=0)
    iam=client('iam')
    for r in pages(iam,'list_roles','Roles'):
        if scoped(r['RoleName'],iam.list_role_tags(RoleName=r['RoleName']).get('Tags',[])):
            for p in pages(iam,'list_attached_role_policies','AttachedPolicies',RoleName=r['RoleName']):
                iam.detach_role_policy(RoleName=r['RoleName'],PolicyArn=p['PolicyArn'])
            for p in pages(iam,'list_role_policies','PolicyNames',RoleName=r['RoleName']):
                if not p.startswith(PREFIX+'-canonical-'):
                    iam.delete_role_policy(RoleName=r['RoleName'],PolicyName=p)
    s3=client('s3')
    for b in s3.list_buckets()['Buckets']:
        try: tags=s3.get_bucket_tagging(Bucket=b['Name']).get('TagSet',[])
        except ClientError as exc:
            if exc.response['Error']['Code']!='NoSuchTagSet': raise
            tags=[]
        if scoped(b['Name'],tags): purge_bucket(s3,b['Name'])
    # Delete quiesced queues before Terraform refresh to avoid the provider's
    # long queue-deletion consistency waiter on this local control plane.
    sqs=client('sqs')
    for url in pages(sqs,'list_queues','QueueUrls'):
        if scoped(url,sqs.list_queue_tags(QueueUrl=url).get('Tags',{})):
            sqs.delete_queue(QueueUrl=url)

def cleanup():
    predestroy()
    reconcile_iam(destroy=True)
    lam=client('lambda')
    for f in pages(lam,'list_functions','Functions'):
        if scoped(f['FunctionName'],lam.list_tags(Resource=f['FunctionArn']).get('Tags',{})):
            absent(lam.delete_function,FunctionName=f['FunctionName'])
    ecs=client('ecs')
    for cluster in pages(ecs,'list_clusters','clusterArns'):
        tags=ecs.list_tags_for_resource(resourceArn=cluster).get('tags',[])
        if scoped(cluster,tags):
            for service in pages(ecs,'list_services','serviceArns',cluster=cluster):
                ecs.delete_service(cluster=cluster,service=service,force=True)
            for task in pages(ecs,'list_tasks','taskArns',cluster=cluster):
                ecs.stop_task(cluster=cluster,task=task,reason='ClearLedger teardown')
            ecs.delete_cluster(cluster=cluster)
    for status in ['ACTIVE','INACTIVE']:
        for arn in pages(ecs,'list_task_definitions','taskDefinitionArns',status=status):
            if scoped(arn):
                if status=='ACTIVE': ecs.deregister_task_definition(taskDefinition=arn)
                ecs.delete_task_definitions(taskDefinitions=[arn])
    rds=client('rds')
    for db in pages(rds,'describe_db_instances','DBInstances'):
        tags=rds.list_tags_for_resource(ResourceName=db['DBInstanceArn']).get('TagList',[])
        if scoped(db['DBInstanceIdentifier'],tags):
            if db.get('DeletionProtection'): rds.modify_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'],DeletionProtection=False,ApplyImmediately=True)
            rds.delete_db_instance(DBInstanceIdentifier=db['DBInstanceIdentifier'],SkipFinalSnapshot=True,DeleteAutomatedBackups=True)
            rds.get_waiter('db_instance_deleted').wait(DBInstanceIdentifier=db['DBInstanceIdentifier'],WaiterConfig={'Delay':2,'MaxAttempts':150})
    for g in pages(rds,'describe_db_subnet_groups','DBSubnetGroups'):
        tags=rds.list_tags_for_resource(ResourceName=g['DBSubnetGroupArn']).get('TagList',[])
        if scoped(g['DBSubnetGroupName'],tags): rds.delete_db_subnet_group(DBSubnetGroupName=g['DBSubnetGroupName'])
    cache=client('elasticache')
    for group in pages(cache,'describe_replication_groups','ReplicationGroups'):
        tags=cache.list_tags_for_resource(ResourceName=group['ARN']).get('TagList',[])
        if scoped(group['ReplicationGroupId'],tags):
            cache.delete_replication_group(ReplicationGroupId=group['ReplicationGroupId'],RetainPrimaryCluster=False)
    for cluster in pages(cache,'describe_cache_clusters','CacheClusters'):
        if scoped(cluster['CacheClusterId']) and not cluster.get('ReplicationGroupId'):
            cache.delete_cache_cluster(CacheClusterId=cluster['CacheClusterId'])
    for group in pages(cache,'describe_cache_subnet_groups','CacheSubnetGroups'):
        if scoped(group['CacheSubnetGroupName']): cache.delete_cache_subnet_group(CacheSubnetGroupName=group['CacheSubnetGroupName'])
    cognito=client('cognito-idp')
    for pool in pages(cognito,'list_user_pools','UserPools',MaxResults=60):
        desc=cognito.describe_user_pool(UserPoolId=pool['Id'])['UserPool']
        if scoped(pool['Name'],desc.get('UserPoolTags',{})): cognito.delete_user_pool(UserPoolId=pool['Id'])
    s3=client('s3')
    for b in s3.list_buckets()['Buckets']:
        try: tags=s3.get_bucket_tagging(Bucket=b['Name']).get('TagSet',[])
        except ClientError as exc:
            if exc.response['Error']['Code']!='NoSuchTagSet': raise
            tags=[]
        if scoped(b['Name'],tags):
            purge_bucket(s3,b['Name']); s3.delete_bucket(Bucket=b['Name'])
    ddb=client('dynamodb')
    for table in pages(ddb,'list_tables','TableNames'):
        desc=ddb.describe_table(TableName=table)['Table']
        tags=ddb.list_tags_of_resource(ResourceArn=desc['TableArn']).get('Tags',[])
        if scoped(table,tags): ddb.delete_table(TableName=table)
    sqs=client('sqs')
    for url in pages(sqs,'list_queues','QueueUrls'):
        if scoped(url.rsplit('/',1)[-1],sqs.list_queue_tags(QueueUrl=url).get('Tags',{})):
            sqs.delete_queue(QueueUrl=url)
    logs=client('logs')
    for group in pages(logs,'describe_log_groups','logGroups'):
        name=group['logGroupName']
        tags=logs.list_tags_log_group(logGroupName=name).get('tags',{})
        if scoped(name,tags) or name.startswith('/clearledger/'+PREFIX+'/'):
            logs.delete_log_group(logGroupName=name)
    kms=client('kms')
    aliases=pages(kms,'list_aliases','Aliases')
    named_keys={a.get('TargetKeyId') for a in aliases if a['AliasName'].startswith('alias/'+PREFIX)}
    for a in aliases:
        if a['AliasName'].startswith('alias/'+PREFIX): kms.delete_alias(AliasName=a['AliasName'])
    for key in pages(kms,'list_keys','Keys'):
        desc=kms.describe_key(KeyId=key['KeyId'])['KeyMetadata']
        tags=kms.list_resource_tags(KeyId=key['KeyId']).get('Tags',[])
        tags={t['TagKey']:t['TagValue'] for t in tags}
        if key['KeyId'] in named_keys or scoped(desc.get('Description',''),tags):
            if desc['KeyState']!='PendingDeletion': kms.schedule_key_deletion(KeyId=key['KeyId'],PendingWindowInDays=10)
    # Terraform normally removes networking. Sweep tagged operational additions,
    # including rules referencing other groups before deleting their VPC.
    ec2=client('ec2')
    vpcs=[v for v in ec2.describe_vpcs()['Vpcs'] if scoped('',v.get('Tags'))]
    vpc_ids={v['VpcId'] for v in vpcs}
    groups=[g for g in ec2.describe_security_groups()['SecurityGroups'] if g['GroupName']!='default' and (g['VpcId'] in vpc_ids or scoped(g['GroupName'],g.get('Tags')))]
    for g in groups:
        for kind in ['Ingress','Egress']:
            rules=g.get('IpPermissions'+('' if kind=='Ingress' else 'Egress'),[])
            if rules: getattr(ec2,'revoke_security_group_'+kind.lower())(GroupId=g['GroupId'],IpPermissions=rules)
    for g in groups: ec2.delete_security_group(GroupId=g['GroupId'])
    for subnet in ec2.describe_subnets()['Subnets']:
        if subnet['VpcId'] in vpc_ids or scoped('',subnet.get('Tags')): ec2.delete_subnet(SubnetId=subnet['SubnetId'])
    for route in ec2.describe_route_tables()['RouteTables']:
        if route['VpcId'] in vpc_ids or scoped('',route.get('Tags')):
            if any(a.get('Main') for a in route.get('Associations',[])): continue
            for a in route.get('Associations',[]): ec2.disassociate_route_table(AssociationId=a['RouteTableAssociationId'])
            ec2.delete_route_table(RouteTableId=route['RouteTableId'])
    for gateway in ec2.describe_internet_gateways()['InternetGateways']:
        attachments=[a for a in gateway.get('Attachments',[]) if a['VpcId'] in vpc_ids]
        if attachments or scoped('',gateway.get('Tags')):
            for a in attachments: ec2.detach_internet_gateway(InternetGatewayId=gateway['InternetGatewayId'],VpcId=a['VpcId'])
            ec2.delete_internet_gateway(InternetGatewayId=gateway['InternetGatewayId'])
    for v in vpcs: ec2.delete_vpc(VpcId=v['VpcId'])
    print('ClearLedger prefix-scoped teardown complete.')

if __name__=='__main__':
    {'prepare':prepare,'checkplan':checkplan,'deploy':deploy,'predestroy':predestroy,'cleanup':cleanup}[sys.argv[1]]()
