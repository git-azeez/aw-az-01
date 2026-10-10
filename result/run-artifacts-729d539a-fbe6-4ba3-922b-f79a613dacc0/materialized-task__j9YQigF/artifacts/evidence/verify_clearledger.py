import json, pathlib, time, uuid, urllib.request, urllib.error
import boto3

m = json.loads(pathlib.Path('/workspace/submission/manifest.json').read_text())
tokens = {}
for scope in ['read', 'write', 'admin']:
    c = m['auth']['clients'][scope]
    form = urllib.parse.urlencode({'grant_type': 'client_credentials', 'client_id': c['client_id'], 'client_secret': c['client_secret'], 'scope': c['scope']}).encode()
    with urllib.request.urlopen(urllib.request.Request(m['auth']['token_endpoint'], data=form)) as response:
        tokens[scope] = json.load(response)['access_token']

def request(path, scope, body=None, key=None):
    headers = {'Authorization': 'Bearer ' + tokens[scope], 'X-Correlation-Id': 'verify-clearledger', 'Content-Type': 'application/json'}
    if key: headers['Idempotency-Key'] = key
    req = urllib.request.Request(m['service_url'] + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e), dict(e.headers)

sid = str(uuid.uuid4())
body = {'settlementId': sid, 'accountId': 'account-verify', 'reference': 'verify-clearing', 'debitParty': 'Bank-A', 'creditParty': 'Bank-B', 'expectedVersion': 0}
status, result, _ = request('/v1/settlements', 'write', body, 'verify-create-' + sid)
assert status == 201, (status, result)
assert request('/v1/settlements', 'write', body, 'verify-create-' + sid)[0] == 200
version = 1
for status in ['VALIDATED', 'CLEARED', 'CLEARED', 'DISPUTED', 'DISPUTED', 'RECONCILED']:
    entry = {'entryId': str(uuid.uuid4()), 'status': status, 'clearingStage': 'verification', 'memo': 'operational verification', 'occurredAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time()+1)), 'expectedVersion': version}
    code, result, _ = request('/v1/settlements/' + sid + '/entries', 'write', entry, 'verify-entry-' + entry['entryId'])
    assert code == 202, (code, result)
    version += 1
entry['entryId'] = str(uuid.uuid4()); entry['expectedVersion'] = version
assert request('/v1/settlements/' + sid + '/entries', 'write', entry, 'verify-terminal-' + sid)[0] == 400
assert request('/v1/settlements/' + sid, 'admin')[0] == 403
assert request('/v1/settlements/' + sid, 'write')[0] == 403
for _ in range(40):
    code, result, headers = request('/v1/settlements/' + sid, 'read')
    if code == 200 and result['version'] == version:
        break
    time.sleep(1)
else:
    raise AssertionError('projection did not converge')
code, result, _ = request('/v1/settlements/' + sid + '/ledger', 'read')
assert code == 200 and [x['version'] for x in result['events']] == list(range(1, version+1)), result
pathlib.Path('/workspace/evidence/verified_settlement.json').write_text(json.dumps({'settlement_id': sid, 'version': version}))
print('Verified client credentials, isolated scopes, accepted writes, idempotent replay, lifecycle transitions, terminal rejection, projection and ordered ledger (%d events).' % version)
