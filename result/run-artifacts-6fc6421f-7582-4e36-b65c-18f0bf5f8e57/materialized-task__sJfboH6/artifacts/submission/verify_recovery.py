"""Optional destructive recovery drill: inject drift, deploy, then verify.

Usage: python3 verify_recovery.py inject; ./deploy.sh;
       python3 verify_recovery.py check
Run only against this local deployment. Committed PostgreSQL data is retained.
"""
import hashlib
import json
import sys
import urllib.request
import base64
import redis
import operations as o

m = o.manifest()
snapshot = o.ROOT / '.verification.json'
table = m['projections']['table_name']
bucket = m['audit']['bucket_name']

if sys.argv[1] == 'inject':
    with o.db(m) as conn:
        events = conn.execute('SELECT payload FROM clearledger.events ORDER BY settlement_id,aggregate_version').fetchall()
        settlements = conn.execute('SELECT * FROM clearledger.settlements').fetchall()
        assert settlements, 'Run verify.py first'
        snapshot.write_text(json.dumps({'db': m['database']['instance_arn'], 'table': m['projections']['table_arn'],
            'bucket': bucket, 'events': len(events), 'settlements': len(settlements)}))
        conn.execute('ALTER TABLE clearledger.events DISABLE TRIGGER ALL')
        conn.execute('ALTER TABLE clearledger.settlements DROP CONSTRAINT settlements_domain')
        conn.execute('DROP INDEX clearledger.idx_clearledger_outbox_unpublished')
    d = o.client('dynamodb')
    d.put_item(TableName=table, Item={'PK': {'S': 'SETTLEMENT#orphan'}, 'SK': {'S': 'STRAY'}, 'status': {'S': 'bad'}})
    sid = str(settlements[0]['settlement_id'])
    for sk in ['STATE', 'EVENT#00000001']:
        d.update_item(TableName=table, Key={'PK': {'S': 'SETTLEMENT#' + sid}, 'SK': {'S': sk}},
            UpdateExpression='SET #s=:s, stray=:s', ExpressionAttributeNames={'#s': 'status'}, ExpressionAttributeValues={':s': {'S': 'CORRUPT'}})
    r = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'])
    r.set('stray-key', 'bad')
    r.set('clearledger:settlement:orphan', 'bad')
    r.set('clearledger:settlement:' + sid, '{"version":999}')
    s3 = o.client('s3')
    for _, v in list(o.audit_versions(bucket)):
        if v.get('IsLatest'):
            s3.put_object(Bucket=bucket, Key=v['Key'], Body=b'corrupt\n')
            s3.delete_object(Bucket=bucket, Key=v['Key'])
    s3.put_object(Bucket=bucket, Key='outside-prefix', Body=b'bad')
    iam = o.client('iam')
    role = m['iam']['ecs_task_role_arn'].split('/')[-1]
    bad_policy = json.dumps({'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]})
    iam.put_role_policy(RoleName=role, PolicyName=o.P + '-extra-inline', PolicyDocument=bad_policy)
    pol = iam.create_policy(PolicyName=o.P + '-drill-policy', PolicyDocument=bad_policy)['Policy']['Arn']
    iam.create_policy_version(PolicyArn=pol, PolicyDocument=bad_policy, SetAsDefault=True)
    iam.attach_role_policy(RoleName=role, PolicyArn=pol)
    ec2 = o.client('ec2')
    for key in ['ecs', 'rds', 'valkey']:
        ec2.authorize_security_group_ingress(GroupId=m['network']['security_group_ids'][key],
            IpPermissions=[{'IpProtocol': 'tcp', 'FromPort': 9999, 'ToPort': 9999, 'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}])
    for key in ['rds', 'valkey']:
        ec2.authorize_security_group_egress(GroupId=m['network']['security_group_ids'][key],
            IpPermissions=[{'IpProtocol': 'tcp', 'FromPort': 9999, 'ToPort': 9999, 'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}])
    for name in m['logs'].values():
        o.client('logs').put_retention_policy(logGroupName=name, retentionInDays=1)
    o.schedule_state(m['schedules']['archive_schedule_name'], 'DISABLED')
    o.client('sqs').set_queue_attributes(QueueUrl=m['messaging']['dlq_url'], Attributes={'MessageRetentionPeriod': '60'})
    o.client('lambda').delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
    o.client('sqs').delete_queue(QueueUrl=m['messaging']['queue_url'])
    o.client('kms').disable_key(KeyId=m['kms']['projection_arn'])
    print('Injected schema, IAM, networking, queue, logs, schedule, KMS, DynamoDB, cache, and versioned archive drift')
else:
    before = json.loads(snapshot.read_text())
    assert before['db'] == m['database']['instance_arn']
    assert before['table'] == m['projections']['table_arn']
    assert before['bucket'] == bucket
    with o.db(m) as conn:
        events = conn.execute('SELECT payload FROM clearledger.events ORDER BY settlement_id,aggregate_version').fetchall()
        settlements = conn.execute('SELECT * FROM clearledger.settlements').fetchall()
        outbox = conn.execute('SELECT * FROM clearledger.outbox ORDER BY seq').fetchall()
        assert len(events) == before['events'] and len(settlements) == before['settlements']
        assert all(r['published_at'] is not None and r['archived_at'] is not None for r in outbox)
        assert conn.execute("SELECT count(*) AS n FROM pg_trigger WHERE NOT tgisinternal AND tgrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass) AND tgenabled <> 'O'").fetchone()['n'] == 0
    expected = o.expected_projection(events, settlements)
    items = o.ddb_scan(table)
    assert {(x['PK']['S'], x['SK']['S']) for x in items} == expected.keys()
    assert all(o.same_projection(x, expected[(x['PK']['S'], x['SK']['S'])]) for x in items)
    versions = list(o.audit_versions(bucket))
    assert all(kind == 'version' and v['IsLatest'] for kind, v in versions)
    envelopes = []
    for _, v in versions:
        assert v['Key'].startswith('ledger-audit/batch-')
        raw = o.client('s3').get_object(Bucket=bucket, Key=v['Key'])['Body'].read()
        assert hashlib.sha256(raw).hexdigest()[:16] in v['Key']
        envelopes.extend(json.loads(line) for line in raw.splitlines())
    assert sorted(envelopes, key=lambda p: p['eventId']) == sorted([r['payload'] for r in outbox], key=lambda p: p['eventId'])
    for key in ['ecs', 'rds', 'valkey']:
        g = o.client('ec2').describe_security_groups(GroupIds=[m['network']['security_group_ids'][key]])['SecurityGroups'][0]
        assert all(not any(ip['CidrIp'] == '0.0.0.0/0' for ip in p.get('IpRanges', [])) for p in g['IpPermissions'])
        if key != 'ecs':
            assert not g['IpPermissionsEgress']
    for arn in m['iam'].values():
        role = arn.split('/')[-1]
        assert o.client('iam').list_role_policies(RoleName=role)['PolicyNames'] == [role + '-canonical']
        assert not o.client('iam').list_attached_role_policies(RoleName=role)['AttachedPolicies']
    assert all(not o.scoped(p['PolicyName']) for p in o.pages('iam', 'list_policies', 'Policies', Scope='Local'))
    c = m['auth']['clients']['read']
    req = urllib.request.Request(m['auth']['token_endpoint'], data=b'grant_type=client_credentials&scope=clearledger/read',
        headers={'Authorization': 'Basic ' + base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode(), 'Content-Type': 'application/x-www-form-urlencoded'})
    token = json.load(urllib.request.urlopen(req))['access_token']
    for s in settlements:
        req = urllib.request.Request(m['service_url'] + '/v1/settlements/' + str(s['settlement_id']), headers={'Authorization': 'Bearer ' + token})
        with urllib.request.urlopen(req) as res:
            assert res.headers['X-ClearLedger-Source'] == 'cache'
            assert json.load(res)['version'] == s['version']
    r = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'])
    assert set(r.scan_iter()) == {f"clearledger:settlement:{s['settlement_id']}".encode() for s in settlements}
    assert all(0 < r.ttl(key) <= 90 for key in r.scan_iter())
    snapshot.unlink()
    print('Recovery verified: durable resource identities and committed data preserved; all derived stores and guardrails converged')
