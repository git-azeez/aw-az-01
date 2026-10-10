"""End-to-end smoke check against the deployed, unmodified containers."""
import datetime as dt
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from operations import manifest, client, connection, invoke

m = manifest()
def token(scope):
    c = m['auth']['clients'][scope]
    data = urllib.parse.urlencode(dict(grant_type='client_credentials', client_id=c['client_id'], client_secret=c['client_secret'], scope=c['scope'])).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(m['auth']['token_endpoint'], data=data)))['access_token']

tokens = {s: token(s) for s in ('read', 'write', 'admin')}
def request(path, scope='read', body=None, key=None):
    headers = {'Authorization': 'Bearer '+tokens[scope], 'X-Correlation-Id': 'smoke-clearledger', 'Content-Type': 'application/json'}
    if key: headers['Idempotency-Key'] = key
    req = urllib.request.Request(m['service_url']+path, data=json.dumps(body).encode() if body else None, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as r: return r.status, json.load(r), dict(r.headers)
    except urllib.error.HTTPError as e: return e.code, json.load(e), dict(e.headers)

sid = str(uuid.uuid4())
body = dict(settlementId=sid, accountId='smoke-account', reference='smoke-reference', debitParty='BANK-A', creditParty='BANK-B', expectedVersion=0)
key = 'create-'+sid
code, value, headers = request('/v1/settlements', 'write', body, key)
assert code == 201, (code, value)
assert request('/v1/settlements', 'write', body, key)[0] == 200
assert request('/v1/settlements/'+sid, 'write')[0] == 403
assert request('/v1/settlements', 'read', body, 'forbidden-'+sid)[0] == 403
for v, status in enumerate(('VALIDATED', 'CLEARED', 'CLEARED', 'SETTLED', 'RECONCILED'), 1):
    entry = dict(entryId=str(uuid.uuid4()), status=status, clearingStage=status+'@BANK-B', memo='Smoke check', occurredAt=dt.datetime.now(dt.timezone.utc).isoformat(), expectedVersion=v)
    code, value, _ = request('/v1/settlements/'+sid+'/entries', 'write', entry, f'entry-{sid}-{v}')
    assert code == 202, (code, value)
    if status == 'CLEARED':
        bad = dict(entry, entryId=str(uuid.uuid4()), status='RESERVED', expectedVersion=v+1, occurredAt=dt.datetime.now(dt.timezone.utc).isoformat())
        assert request('/v1/settlements/'+sid+'/entries', 'write', bad, f'invalid-{sid}-{v}')[0] == 400
terminal = dict(entry, entryId=str(uuid.uuid4()), expectedVersion=6, occurredAt=dt.datetime.now(dt.timezone.utc).isoformat())
assert request('/v1/settlements/'+sid+'/entries', 'write', terminal, 'terminal-'+sid)[0] == 400
for _ in range(40):
    code, value, headers = request('/v1/settlements/'+sid)
    if code == 200 and value['version'] == 6: break
    time.sleep(1)
assert code == 200 and value['version'] == 6, (code, value)
code, ledger, _ = request('/v1/settlements/'+sid+'/ledger')
assert code == 200 and len(ledger['events']) == 6
assert request('/v1/settlements/'+sid)[2].get('x-clearledger-source') == 'cache'
invoke(m['workers']['outbox_relay']['function_name'], {})
invoke(m['workers']['audit_archiver']['function_name'], {})
with connection(m) as db, db.cursor() as cur:
    cur.execute('SELECT count(*) FROM clearledger.outbox WHERE settlement_id=%s AND archived_at IS NOT NULL', (sid,))
    assert cur.fetchone()[0] == 6
print('PASS: OAuth scope isolation, idempotency, lifecycle constraints, SQS projection, ledger, cache, relay and archiver')
print('Verified settlement:', sid)
