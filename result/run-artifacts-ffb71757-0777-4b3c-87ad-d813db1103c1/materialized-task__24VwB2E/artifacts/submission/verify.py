"""Opt-in live contract checks and recovery drill; never called by deployment."""
import datetime
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import operations as o


def token(m, scope):
    c = m['auth']['clients'][scope]
    data = urllib.parse.urlencode(dict(grant_type='client_credentials', client_id=c['client_id'],
        client_secret=c['client_secret'], scope=c['scope'])).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(m['auth']['token_endpoint'],data=data)))['access_token']


def request(m, path, bearer=None, body=None, key=None):
    headers = {'X-Correlation-Id':'operational-verification'}
    if bearer:
        headers['Authorization'] = 'Bearer '+bearer
    if key:
        headers['Idempotency-Key'] = key
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    try:
        r = urllib.request.urlopen(urllib.request.Request(m['service_url']+path,data=data,headers=headers),timeout=15)
    except urllib.error.HTTPError as error:
        r = error
    return r.status,dict(r.headers),json.load(r)


def smoke(m):
    write, read, admin = [token(m,s) for s in ('write','read','admin')]
    sid = str(uuid.uuid4()); key = 'smoke-create-'+sid
    create = dict(settlementId=sid,accountId='smoke-account',reference='live-verification',debitParty='BankA',creditParty='BankB',expectedVersion=0)
    assert request(m,'/v1/settlements',None,create,key)[0] == 401
    assert request(m,'/v1/settlements',read,create,key)[0] == 403
    assert request(m,'/v1/settlements',admin,create,key)[0] == 403
    r = request(m,'/v1/settlements',write,create,key)
    assert r[0] == 201,r
    assert request(m,'/v1/settlements',write,create,key)[0] == 200
    path = '/v1/settlements/'+sid
    version = 1
    for status in ('CLEARED','RESERVED','CLEARED','DISPUTED','SETTLED','RECONCILED','RECONCILED'):
        body = dict(entryId=str(uuid.uuid4()),status=status,clearingStage='clearing-desk',memo='verified entry',
                    occurredAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),expectedVersion=version)
        r = request(m,path+'/entries',write,body,'smoke-entry-'+body['entryId'])
        expected = 400 if status in ('RESERVED','SETTLED') or (status == 'RECONCILED' and version == 5) else 202
        assert r[0] == expected,(status,version,r)
        if expected == 202:
            version += 1
    assert version == 5
    for _ in range(40):
        r = request(m,path,read)
        if r[0] == 200 and r[2]['version'] == version:
            break
        time.sleep(0.5)
    assert r[0] == 200 and r[2]['version'] == 5,r
    ledger = request(m,path+'/ledger',read)
    assert ledger[0] == 200 and len(ledger[2]['events']) == 5,ledger
    assert request(m,path,write)[0] == 403
    assert request(m,path,admin)[0] == 403
    with o.database(m) as db:
        for statement in [
            'UPDATE clearledger.events SET correlation_id=correlation_id',
            'DELETE FROM clearledger.events',
            'DELETE FROM clearledger.outbox',
            'UPDATE clearledger.idempotency_keys SET status_code=status_code',
            "UPDATE clearledger.settlements SET reference='changed'",
        ]:
            try:
                db.execute(statement)
            except o.psycopg.Error as e:
                assert e.sqlstate == '23514',(statement,e)
            else:
                raise AssertionError('immutable operation accepted: '+statement)
    instances = {request(m,'/health/live')[2]['instance'] for _ in range(12)}
    assert len(instances) >= 2,instances
    print('Live checks passed: OAuth scope isolation, writes, idempotency, lifecycle transitions, append-only guards, ledger, and two API instances.')


def corrupt(m):
    # A reproducible source-preserving repair drill.
    ddb = o.client('dynamodb'); table = m['projections']['table_name']
    for item in o.pages(ddb,'scan','Items',TableName=table):
        if item['SK']['S'] == 'STATE':
            item['version'] = {'N':'9999'}
            item['GSI1PK'] = {'S':'ACCOUNT#wrong'}
        else:
            item['memo'] = {'S':'corrupted'}
        ddb.put_item(TableName=table,Item=item)
    ddb.put_item(TableName=table,Item={'PK':{'S':'ORPHAN'},'SK':{'S':'STRAY'}})
    r = o.redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'])
    r.set('stray-key','bad'); r.set('clearledger:settlement:orphan','{}')
    s3 = o.client('s3'); bucket = m['audit']['bucket_name']
    for value in (b'wrong',b'also-wrong'):
        s3.put_object(Bucket=bucket,Key='stray-audit',Body=value)
    s3.delete_object(Bucket=bucket,Key='stray-audit')
    sqs = o.client('sqs')
    sqs.set_queue_attributes(QueueUrl=m['messaging']['queue_url'],Attributes={'VisibilityTimeout':'45'})
    sqs.set_queue_attributes(QueueUrl=m['messaging']['dlq_url'],Attributes={'MessageRetentionPeriod':'1000'})
    o.client('logs').put_retention_policy(logGroupName=m['logs']['api_log_group'],retentionInDays=1)
    o.client('lambda').update_function_configuration(FunctionName=m['workers']['outbox_relay']['function_name'],Environment={'Variables':{'DRIFT':'true'}})
    iam = o.client('iam')
    policy = json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'*'}]})
    extra = iam.create_policy(PolicyName=o.PREFIX+'-drill-extra',PolicyDocument=policy)['Policy']
    iam.create_policy_version(PolicyArn=extra['Arn'],PolicyDocument=policy,SetAsDefault=True)
    for arn in m['iam'].values():
        name = arn.rsplit('/',1)[-1]
        iam.put_role_policy(RoleName=name,PolicyName='drill-extra',PolicyDocument=policy)
        iam.attach_role_policy(RoleName=name,PolicyArn=extra['Arn'])
    ec2 = o.client('ec2')
    for k in ('rds','valkey','alb'):
        ec2.authorize_security_group_egress(GroupId=m['network']['security_group_ids'][k],IpPermissions=[{'IpProtocol':'-1','IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
    with o.database(m) as db:
        db.execute('UPDATE clearledger.outbox SET published_at=NULL,archived_at=NULL')
    (o.ROOT/'drill-snapshot.json').write_text(json.dumps({'database':m['database']['instance_id'],'table':m['projections']['table_name'],'bucket':bucket}))
    print('Recovery drill injected. Run deploy.sh, then verify.py repaired.')


def repaired(m):
    with o.database(m) as db:
        assert db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL').fetchone()['n'] == 0
        rows = db.execute('SELECT seq,payload FROM clearledger.outbox ORDER BY seq').fetchall()
        assert o.audit_valid(o.client('s3'),m['audit']['bucket_name'],rows)
        expected = o.reconcile_projection(m,db,repair=False)
    versions = o.pages(o.client('s3'),'list_object_versions','Versions',Bucket=m['audit']['bucket_name'])
    markers = o.pages(o.client('s3'),'list_object_versions','DeleteMarkers',Bucket=m['audit']['bucket_name'])
    assert all(v['IsLatest'] for v in versions) and not markers
    iam = o.client('iam')
    for arn in m['iam'].values():
        name = arn.rsplit('/',1)[-1]
        assert o.pages(iam,'list_role_policies','PolicyNames',RoleName=name) == [name+'-canonical']
        assert not o.pages(iam,'list_attached_role_policies','AttachedPolicies',RoleName=name)
    for role in ('rds','valkey'):
        group = o.client('ec2').describe_security_groups(GroupIds=[m['network']['security_group_ids'][role]])['SecurityGroups'][0]
        assert not group.get('IpPermissionsEgress')
    r = o.redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'],decode_responses=True)
    assert set(r.scan_iter()) == set(expected)
    read = token(m,'read')
    for key,value in expected.items():
        response = request(m,'/v1/settlements/'+value['settlementId'],read)
        assert response[0] == 200 and response[2] == value,response
        assert next(v for k,v in response[1].items() if k.lower() == 'x-clearledger-source') == 'cache'
    print('Recovery checks passed: source records retained, outbox drained, canonical archive and projections, active cache hits.')


if __name__ == '__main__':
    import sys
    m = json.loads((o.ROOT/'manifest.json').read_text())
    {'smoke':smoke,'corrupt':corrupt,'repaired':repaired}[sys.argv[1]](m)
