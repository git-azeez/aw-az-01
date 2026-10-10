"""Live end-to-end smoke check; intentionally commits a verification settlement."""
import json
import uuid
import time
import urllib.request
import urllib.error
import base64
import datetime
import operations as o

m = o.manifest()


def token(scope):
    c = m['auth']['clients'][scope]
    r = urllib.request.Request(m['auth']['token_endpoint'],
        data=f"grant_type=client_credentials&scope={c['scope']}".encode(), headers={
        'Authorization': 'Basic ' + base64.b64encode(f"{c['client_id']}:{c['client_secret']}".encode()).decode(),
        'Content-Type': 'application/x-www-form-urlencoded'})
    return json.load(urllib.request.urlopen(r))['access_token']


tokens = {s: token(s) for s in ['read', 'write', 'admin']}


def request(path, scope='read', body=None, idem=None):
    h = {'Authorization': 'Bearer ' + tokens[scope], 'X-Correlation-Id': 'verify-recovery-2026'}
    if body is not None:
        h['Content-Type'] = 'application/json'
        h['Idempotency-Key'] = idem or str(uuid.uuid4())
    r = urllib.request.Request(m['service_url'] + path, headers=h,
        data=json.dumps(body).encode() if body is not None else None)
    try:
        res = urllib.request.urlopen(r, timeout=20)
    except urllib.error.HTTPError as e:
        res = e
    return res.status, dict(res.headers), json.load(res)


sid = str(uuid.uuid4())
idem = str(uuid.uuid4())
body = {'settlementId': sid, 'accountId': 'verify-account', 'reference': 'verify-reference',
    'debitParty': 'BANK-A', 'creditParty': 'BANK-B', 'expectedVersion': 0}
status, _, out = request('/v1/settlements', 'write', body, idem)
assert status == 201, (status, out)
assert request('/v1/settlements', 'write', body, idem)[0] == 200
assert request('/v1/settlements/' + sid, 'write')[0] == 403
for status_name in ['CLEARED', 'CLEARED', 'RECONCILED']:
    with o.db(m) as conn:
        s = conn.execute('SELECT version FROM clearledger.settlements WHERE settlement_id=%s', (sid,)).fetchone()
    b = {'entryId': str(uuid.uuid4()), 'status': status_name, 'clearingStage': 'CLEARING@BANK-B',
        'memo': 'Operational verification', 'occurredAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'expectedVersion': s['version']}
    status, _, out = request('/v1/settlements/' + sid + '/entries', 'write', b)
    assert status == 202, (status, out)
bad = dict(b, entryId=str(uuid.uuid4()), expectedVersion=4,
    occurredAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
assert request('/v1/settlements/' + sid + '/entries', 'write', bad)[0] == 400
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    status, h, p = request('/v1/settlements/' + sid)
    if status == 200 and p['version'] == 4:
        break
    time.sleep(.5)
else:
    raise AssertionError('Projection did not catch up')
ledger = request('/v1/settlements/' + sid + '/ledger')[2]
assert [e['version'] for e in ledger['events']] == [1, 2, 3, 4]
o.invoke(m['workers']['outbox_relay']['function_name'], {})
o.invoke(m['workers']['audit_archiver']['function_name'], {})
print('Verified OAuth scope isolation, idempotency, clearing transitions, ordered projection, relay, and archiver.')
print('Verification settlement: ' + sid)
