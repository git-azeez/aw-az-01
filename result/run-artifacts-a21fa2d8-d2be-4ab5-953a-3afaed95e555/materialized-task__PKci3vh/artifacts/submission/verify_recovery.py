"""Explicitly invoked destructive recovery drill for the deployed test ledger."""
import sys
from operations import *
from psycopg2 import sql
m = manifest()
if sys.argv[1] == 'inject':
    with connection(m) as db, db.cursor() as cur:
        cur.execute("SELECT indexname FROM pg_indexes WHERE schemaname='clearledger' AND indexname LIKE 'idx_clearledger_%'")
        for (name,) in cur.fetchall(): cur.execute(sql.SQL('DROP INDEX clearledger.{}').format(sql.Identifier(name)))
        cur.execute('ALTER TABLE clearledger.events DISABLE TRIGGER guard_event')
        cur.execute('UPDATE clearledger.outbox SET published_at=NULL,archived_at=NULL')
    kms = client('kms')
    kms.schedule_key_deletion(KeyId=m['kms']['database_arn'], PendingWindowInDays=10)
    kms.disable_key(KeyId=m['kms']['projection_arn'])
    kms.disable_key_rotation(KeyId=m['kms']['audit_arn'])
    kms.untag_resource(KeyId=m['kms']['audit_arn'], TagKeys=['ClearLedgerDeployment','ClearLedgerKeyUsage'])
    client('rds').remove_tags_from_resource(ResourceName=m['database']['instance_arn'], TagKeys=['ClearLedgerDeployment'])
    client('ecs').update_cluster_settings(cluster=m['compute']['cluster_name'],settings=[{'name':'containerInsights','value':'disabled'}])
    client('elbv2').modify_target_group(TargetGroupArn=m['ingress']['target_group_arn'], HealthCheckPath='/bad', HealthCheckIntervalSeconds=30)
    client('dynamodb').update_continuous_backups(TableName=m['projections']['table_name'], PointInTimeRecoverySpecification={'PointInTimeRecoveryEnabled':False})
    client('s3').delete_public_access_block(Bucket=m['audit']['bucket_name'])
    client('iam').put_role_policy(RoleName=PREFIX+'-ecs_task',PolicyName='rogue',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}))
    client('ec2').authorize_security_group_ingress(GroupId=m['network']['security_group_ids']['ecs'], IpPermissions=[{'IpProtocol':'tcp','FromPort':8080,'ToPort':8080,'IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
    client('ec2').authorize_security_group_egress(GroupId=m['network']['security_group_ids']['rds'], IpPermissions=[{'IpProtocol':'tcp','FromPort':443,'ToPort':443,'IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
    ddb=client('dynamodb'); table=m['projections']['table_name']
    for i in scan_table(m):
        i['status']={'S':'BROKEN'}; i['stray']={'S':'should disappear'}
        if i['SK']['S']=='STATE': i['version']={'N':'9000'}
        ddb.put_item(TableName=table,Item=i)
    ddb.put_item(TableName=table, Item=encoded({'PK':'ORPHAN','SK':'STRAY'}))
    cache=redis.Redis(host=m['cache']['endpoint'])
    cache.set('stray','bad'); cache.set('clearledger:settlement:orphan','bad')
    for kind,v in list(versions(m['audit']['bucket_name'])):
        if kind=='version': client('s3').put_object(Bucket=m['audit']['bucket_name'], Key=v['Key'], Body=b'corrupt\n')
    client('s3').put_object(Bucket=m['audit']['bucket_name'],Key='wrong/key',Body=b'orphan')
    client('s3').delete_object(Bucket=m['audit']['bucket_name'],Key='wrong/key')
    print('Injected schema, KMS, IAM, network, ALB, ECS, PITR, public-access, projection, cache and audit drift')
else:
    with connection(m) as db, db.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute('SELECT payload FROM clearledger.events ORDER BY settlement_id,aggregate_version')
        expected, states=canonical_items(cur.fetchall())
        actual={(i['PK']['S'],i['SK']['S']):i for i in scan_table(m)}
        assert actual==expected
        cur.execute("SELECT count(*) AS n FROM pg_indexes WHERE schemaname='clearledger' AND indexname LIKE 'idx_clearledger_%'")
        assert cur.fetchone()['n']==6
        cur.execute("SELECT count(*) AS n FROM pg_trigger WHERE tgrelid='clearledger.events'::regclass AND NOT tgisinternal AND tgenabled<>'O'")
        assert cur.fetchone()['n']==0
        cur.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL')
        assert cur.fetchone()['n']==0
    cache=redis.Redis(host=m['cache']['endpoint'])
    assert set(k.decode() for k in cache.scan_iter())=={'clearledger:settlement:'+sid for sid in states}
    for sid,v in states.items():
        assert json.loads(cache.get('clearledger:settlement:'+sid))==v
        assert 0<cache.ttl('clearledger:settlement:'+sid)<=90
    assert all(k=='version' and v['IsLatest'] for k,v in versions(m['audit']['bucket_name']))
    for key in m['kms'].values():
        assert client('kms').describe_key(KeyId=key)['KeyMetadata']['KeyState']=='Enabled'
        assert client('kms').get_key_rotation_status(KeyId=key)['KeyRotationEnabled']
    assert client('iam').list_role_policies(RoleName=PREFIX+'-ecs_task')['PolicyNames']==[PREFIX+'-ecs_task-canonical']
    assert client('dynamodb').describe_continuous_backups(TableName=m['projections']['table_name'])['ContinuousBackupsDescription']['PointInTimeRecoveryDescription']['PointInTimeRecoveryStatus']=='ENABLED'
    print('PASS: injected drift repaired; authoritative events preserved and derived stores converged')
