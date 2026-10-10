"""Live smoke and recovery drill. Run explicitly, never as part of deployment."""
import datetime
import json
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import redis
from operations import ROOT, manifest, client, database, pages, canonical_items, projection, object_versions


def request(m, method, path, body=None, token=None, idem=None):
    headers = {'Content-Type': 'application/json', 'X-Correlation-Id': 'verification-' + uuid.uuid4().hex}
    if token: headers['Authorization'] = 'Bearer ' + token
    if idem: headers['Idempotency-Key'] = idem
    req = urllib.request.Request(m['service_url'] + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as e:
        response = e
    return response.status, dict(response.headers), json.loads(response.read())


def tokens(m):
    result = {}
    for name, c in m['auth']['clients'].items():
        data = urllib.parse.urlencode(dict(grant_type='client_credentials', client_id=c['client_id'], client_secret=c['client_secret'], scope=c['scope'])).encode()
        result[name] = json.load(urllib.request.urlopen(m['auth']['token_endpoint'], data=data))['access_token']
    return result


def smoke(m):
    tok = tokens(m); sid = str(uuid.uuid4()); key = uuid.uuid4().hex
    body = dict(settlementId=sid, accountId='account-smoke', reference='verification', debitParty='BANK-A', creditParty='BANK-B', expectedVersion=0)
    assert request(m, 'POST', '/v1/settlements', body, idem=key)[0] == 401
    assert request(m, 'POST', '/v1/settlements', body, tok['read'], key)[0] == 403
    created = request(m, 'POST', '/v1/settlements', body, tok['write'], key)
    assert created[0] == 201, created
    replay = request(m, 'POST', '/v1/settlements', body, tok['write'], key)
    assert replay[0] == 200 and replay[2]['idempotentReplay'], replay
    version = 1
    for index, (status, expected) in enumerate([('CLEARED', 202), ('RESERVED', 400), ('CLEARED', 202), ('DISPUTED', 202), ('SETTLED', 400), ('RECONCILED', 202), ('RECONCILED', 400)]):
        body = dict(entryId=str(uuid.uuid4()), status=status, clearingStage=status + '@BANK-B', memo='Verified entry',
            occurredAt=(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=index+1)).isoformat(), expectedVersion=version)
        response = request(m, 'POST', '/v1/settlements/' + sid + '/entries', body, tok['write'], uuid.uuid4().hex)
        assert response[0] == expected, response
        if expected == 202: version += 1
    assert request(m, 'GET', '/v1/settlements/' + sid, token=tok['admin'])[0] == 403
    for _ in range(30):
        response = request(m, 'GET', '/v1/settlements/' + sid + '/ledger', token=tok['read'])
        if response[0] == 200 and response[2]['version'] == version and len(response[2]['events']) == version:
            break
        time.sleep(1)
    else: raise AssertionError(response)
    response = client('lambda').invoke(FunctionName=m['workers']['audit_archiver']['function_name'], Payload=b'{}')
    assert not response.get('FunctionError'), response['Payload'].read()
    print('Live smoke passed: OAuth isolation, idempotency, forward/same/disputed/terminal transitions and asynchronous projection.')
    return sid


def drill(m, sid):
    lam = client('lambda'); sqs = client('sqs'); ddb = client('dynamodb'); s3 = client('s3')
    lam.update_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'], Enabled=False)
    sqs.set_queue_attributes(QueueUrl=m['messaging']['queue_url'], Attributes={'VisibilityTimeout': '27'})
    client('logs').put_retention_policy(logGroupName=m['logs']['relay_log_group'], retentionInDays=1)
    client('iam').put_role_policy(RoleName=m['iam']['ecs_task_role_arn'].rsplit('/', 1)[1], PolicyName='out-of-band', PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'*'}]}))
    ec2 = client('ec2')
    ec2.authorize_security_group_egress(GroupId=m['network']['security_group_ids']['rds'], IpPermissions=[{'IpProtocol':'tcp','FromPort':443,'ToPort':443,'IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
    with database(m) as conn:
        conn.execute('ALTER TABLE clearledger.events DISABLE TRIGGER event_guard')
        conn.execute('ALTER TABLE clearledger.settlements DROP CONSTRAINT settlements_values')
        conn.execute('DROP INDEX clearledger.idx_clearledger_outbox_unarchived')
        conn.execute('UPDATE clearledger.outbox SET published_at=NULL, archived_at=NULL')
    table = m['projections']['table_name']
    for key in [('SETTLEMENT#' + sid, 'STATE'), ('SETTLEMENT#' + sid, 'EVENT#00000001'), ('ORPHAN', 'stray')]:
        ddb.put_item(TableName=table, Item={'PK': {'S':key[0]}, 'SK':{'S':key[1]}, 'version':{'N':'9999'}, 'corrupt':{'S':'true'}})
    cache = redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'])
    cache.set('stray', 'bad'); cache.set('clearledger:settlement:' + sid, '{}')
    bucket=m['audit']['bucket_name']
    s3.put_object(Bucket=bucket, Key='stray', Body=b'bad')
    for _, obj in list(object_versions(s3,bucket)):
        if obj['Key'].startswith('ledger-audit/'):
            s3.put_object(Bucket=bucket, Key=obj['Key'], Body=b'bad')
            s3.delete_object(Bucket=bucket, Key=obj['Key'])
    subprocess.run([str(ROOT / 'deploy.sh')], check=True)
    m = manifest(); tok = tokens(m)
    response = request(m, 'GET', '/v1/settlements/' + sid, token=tok['read'])
    assert response[0] == 200 and response[1].get('x-clearledger-source') == 'cache', response
    assert response[2]['status'] == 'RECONCILED' and response[2]['version'] == 5, response
    with database(m) as conn:
        assert conn.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL').fetchone()['n'] == 0
        assert conn.execute("SELECT count(*) AS n FROM pg_trigger WHERE tgrelid='clearledger.events'::regclass AND tgenabled <> 'O'").fetchone()['n'] == 0
    assert sqs.get_queue_attributes(QueueUrl=m['messaging']['queue_url'], AttributeNames=['VisibilityTimeout'])['Attributes']['VisibilityTimeout']=='3'
    assert not ec2.describe_security_groups(GroupIds=[m['network']['security_group_ids']['rds']])['SecurityGroups'][0]['IpPermissionsEgress']
    assert not cache.exists('stray')
    assert all(kind=='Versions' and obj['IsLatest'] and obj['Key'].startswith('ledger-audit/') for kind,obj in object_versions(s3,bucket))
    print('Recovery drill passed: schema, IAM, security group, logs, SQS, mapping, DynamoDB, cache and versioned S3 repaired.')


if __name__ == '__main__':
    m = manifest()
    drill(m, smoke(m))
