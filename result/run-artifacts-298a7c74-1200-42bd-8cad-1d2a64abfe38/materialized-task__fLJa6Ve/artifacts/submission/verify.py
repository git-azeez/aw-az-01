"""Optional live smoke test; creates an immutable test settlement."""
import json
import time
import uuid
from pathlib import Path

import boto3
import requests

m = json.loads(Path('/workspace/submission/manifest.json').read_text())
c = json.loads(Path('/workspace/config/config.json').read_text())
base = m['service_url']
tokens = {}
for role, v in m['auth']['clients'].items():
    r = requests.post(m['auth']['token_endpoint'], auth=(v['client_id'], v['client_secret']),
                      data={'grant_type': 'client_credentials', 'scope': v['scope']}, timeout=10)
    r.raise_for_status()
    tokens[role] = r.json()['access_token']
sid = str(uuid.uuid4())
headers = {'Authorization': 'Bearer ' + tokens['write'], 'Idempotency-Key': 'smoke-create-' + sid,
           'X-Correlation-Id': 'smoke-correlation'}
body = {'settlementId': sid, 'accountId': 'ACCT001', 'reference': 'SMOKE001', 'debitParty': 'BANKA',
        'creditParty': 'BANKB', 'expectedVersion': 0}
r = requests.post(base + '/v1/settlements', headers=headers, json=body, timeout=10)
assert r.status_code == 201, r.text
time.sleep(2)
for version, extra in [(1, {'memo': 'Retain this memo'}), (2, {})]:
    headers['Idempotency-Key'] = 'smoke-entry-' + str(uuid.uuid4())
    body = {'entryId': str(uuid.uuid4()), 'status': 'CLEARED', 'clearingStage': 'CLEARING',
            'occurredAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'expectedVersion': version, **extra}
    r = requests.post(base + f'/v1/settlements/{sid}/entries', headers=headers, json=body, timeout=10)
    assert r.status_code == 202, r.text
    time.sleep(2)
r = requests.get(base + f'/v1/settlements/{sid}', headers={'Authorization': 'Bearer ' + tokens['read']}, timeout=10)
assert r.status_code == 200, r.text
assert r.json()['lastMemo'] == 'Retain this memo'
for role in ['read', 'admin']:
    denied_body = {'settlementId': str(uuid.uuid4()), 'accountId': 'ACCT001', 'reference': 'SMOKE001',
                   'debitParty': 'BANKA', 'creditParty': 'BANKB', 'expectedVersion': 0}
    r = requests.post(base + '/v1/settlements', headers={**headers, 'Authorization': 'Bearer ' + tokens[role]},
                      json=denied_body, timeout=10)
    assert r.status_code == 403, (r.status_code, r.text)
session = boto3.Session(aws_access_key_id='test', aws_secret_access_key='test', region_name=c['region'])
d = session.client('dynamodb', endpoint_url=c['aws_endpoint_url'])
items = d.scan(TableName=m['projections']['table_name'])['Items']
print('DynamoDB field types:', [(i['SK'], {k: list(v)[0] for k, v in i.items()}) for i in items])
lam = session.client('lambda', endpoint_url=c['aws_endpoint_url'])
for worker in ['outbox_relay', 'audit_archiver']:
    result = lam.invoke(FunctionName=m['workers'][worker]['function_name'], Payload=b'{}')
    assert not result.get('FunctionError'), result['Payload'].read()
    result['Payload'].read()
s3 = session.client('s3', endpoint_url=c['aws_endpoint_url'])
for obj in s3.list_objects_v2(Bucket=m['audit']['bucket_name']).get('Contents', []):
    raw = s3.get_object(Bucket=m['audit']['bucket_name'], Key=obj['Key'])['Body'].read().decode()
    print('Archive example:', raw.splitlines()[0])
print('Live smoke test passed:', sid)
