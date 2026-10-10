"""Deliberate repair drill against this deployment; deploy.sh must restore all mutations."""
import json
import subprocess
import uuid
import redis
from ops import ROOT, P, client, database, versions, expected_items, reconcile_ddb


def verify_recovery():
    m = json.loads((ROOT / 'manifest.json').read_text())
    before = (m['database']['instance_arn'], m['projections']['table_arn'], m['audit']['bucket_arn'])
    with database(m) as db:
        with db.cursor() as cur:
            cur.execute('SELECT count(*) FROM clearledger.events')
            count = cur.fetchone()[0]
            assert count > 0, 'Run verify.py first'
            cur.execute('ALTER TABLE clearledger.settlements DROP CONSTRAINT settlements_domain')
            cur.execute('ALTER TABLE clearledger.settlements ADD CONSTRAINT settlements_domain CHECK (true)')
            cur.execute('ALTER TABLE clearledger.settlements DISABLE TRIGGER USER')
            cur.execute('DROP INDEX clearledger.idx_clearledger_entry_id')
            cur.execute('UPDATE clearledger.outbox SET archived_at=NULL, published_at=NULL')
    ddb = client('dynamodb'); table = m['projections']['table_name']
    for item in ddb.scan(TableName=table)['Items']:
        if item['SK']['S'] == 'STATE':
            item['version'] = {'N': '99999'}; item['last_memo'] = {'S': 'corrupt'}
            ddb.put_item(TableName=table, Item=item)
        else:
            ddb.delete_item(TableName=table, Key={k: item[k] for k in ['PK', 'SK']})
    ddb.put_item(TableName=table, Item={'PK': {'S': 'SETTLEMENT#orphan'}, 'SK': {'S': 'STRAY'}})
    r = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'])
    r.set('stray-key', 'invalid')
    r.set('clearledger:settlement:' + str(uuid.uuid4()), '{}')
    s3 = client('s3'); b = m['audit']['bucket_name']
    for obj in s3.list_objects_v2(Bucket=b).get('Contents', []):
        s3.put_object(Bucket=b, Key=obj['Key'], Body=b'corrupt')
        s3.delete_object(Bucket=b, Key=obj['Key'])
    s3.put_object(Bucket=b, Key='orphan.txt', Body=b'orphan')
    ec2 = client('ec2')
    ec2.authorize_security_group_ingress(GroupId=m['network']['security_group_ids']['ecs'],
        IpPermissions=[{'IpProtocol': 'tcp', 'FromPort': 8080, 'ToPort': 8080,
                        'IpRanges': [{'CidrIp': '0.0.0.0/0'}]}])
    client('ecs').update_service(cluster=m['compute']['cluster_name'], service=m['compute']['service_name'], desiredCount=1)
    client('kms').disable_key(KeyId=m['kms']['projection_arn'])
    client('rds').remove_tags_from_resource(ResourceName=m['database']['instance_arn'], TagKeys=['ClearLedgerDeployment'])
    client('iam').put_role_policy(RoleName=P+'-ecs_task', PolicyName='out-of-band',
        PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'*'}]}))
    client('lambda').delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
    client('sqs').delete_queue(QueueUrl=m['messaging']['queue_url'])
    subprocess.run([str(ROOT / 'deploy.sh')], check=True)
    m = json.loads((ROOT / 'manifest.json').read_text())
    assert before == (m['database']['instance_arn'], m['projections']['table_arn'], m['audit']['bucket_arn'])
    with database(m) as db:
        with db.cursor() as cur:
            cur.execute('SELECT count(*) FROM clearledger.events')
            assert cur.fetchone()[0] == count
            cur.execute('SELECT count(*) FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL')
            assert cur.fetchone()[0] == 0
            cur.execute("SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgrelid='clearledger.settlements'::regclass AND tgenabled<>'O'")
            assert cur.fetchone()[0] == 0
            cur.execute("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='settlements_domain'")
            assert 'trimmed' in cur.fetchone()[0]
    assert r.get('stray-key') is None
    for kind, v in versions(b):
        assert kind == 'Versions' and v['IsLatest'] and v['Key'].startswith('ledger-audit/batch-')
    assert 'out-of-band' not in client('iam').list_role_policies(RoleName=P+'-ecs_task')['PolicyNames']
    rules = ec2.describe_security_groups(GroupIds=[m['network']['security_group_ids']['ecs']])['SecurityGroups'][0]['IpPermissions']
    assert all(not r.get('IpRanges') and not r.get('Ipv6Ranges') for r in rules)
    assert client('kms').describe_key(KeyId=m['kms']['projection_arn'])['KeyMetadata']['KeyState'] == 'Enabled'
    print('PASS: deleted queue/mapping recreation, schema/IAM/network/KMS drift repair, preserved stores, bidirectional data convergence.')


if __name__ == '__main__':
    verify_recovery()
