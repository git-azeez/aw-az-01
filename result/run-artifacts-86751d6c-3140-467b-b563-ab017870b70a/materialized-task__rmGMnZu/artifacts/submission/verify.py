"""Live acceptance smoke test; creates one settlement using the published API."""
import json, uuid, time, urllib.request, urllib.parse, urllib.error
from datetime import datetime, timezone, timedelta
import operations as op
m = op.load()
def token(scope):
    c = m['auth']['clients'][scope]
    data = urllib.parse.urlencode(dict(grant_type='client_credentials', client_id=c['client_id'], client_secret=c['client_secret'], scope=c['scope'])).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(m['auth']['token_endpoint'], data=data)))['access_token']
tokens = {s: token(s) for s in ['read','write','admin']}
def request(path, method='GET', body=None, scope='write', key=None):
    headers={'X-Correlation-Id':'infrastructure-verification', 'Content-Type':'application/json'}
    if scope: headers['Authorization']='Bearer '+tokens[scope]
    if key: headers['Idempotency-Key']=key
    req=urllib.request.Request(m['service_url']+path, method=method, headers=headers, data=json.dumps(body).encode() if body else None)
    try: r=urllib.request.urlopen(req, timeout=20)
    except urllib.error.HTTPError as e: r=e
    return r.status,json.loads(r.read()),dict(r.headers)
sid=str(uuid.uuid4()); path='/v1/settlements/'+sid
create=dict(settlementId=sid,accountId='verify-account',reference='verify-clearing',debitParty='Bank-AA',creditParty='Bank-BB',expectedVersion=0)
key='verify-create-'+sid
assert request('/v1/settlements','POST',create,None,key)[0]==401
assert request('/v1/settlements','POST',create,'read',key)[0]==403
assert request('/v1/settlements','POST',create,'admin',key)[0]==403
assert request('/v1/settlements','POST',create,'write',key)[0]==201
assert request('/v1/settlements','POST',create,'write',key)[0]==200
now=datetime.now(timezone.utc); version=1
for status in ['VALIDATED','RESERVED','CLEARED','CLEARED','SETTLED','DISPUTED','DISPUTED','RECONCILED']:
    body=dict(entryId=str(uuid.uuid4()),status=status,clearingStage='verify-stage',memo=None if status=='RECONCILED' else 'verified-entry',occurredAt=(now+timedelta(seconds=version)).isoformat(),expectedVersion=version)
    code,result,_=request(path+'/entries','POST',body,'write','verify-entry-'+body['entryId'])
    assert code==202,(code,result)
    version+=1
body=dict(entryId=str(uuid.uuid4()),status='RECONCILED',clearingStage='terminal',occurredAt=(now+timedelta(seconds=version)).isoformat(),expectedVersion=version)
assert request(path+'/entries','POST',body,'write','verify-terminal-'+sid)[0]==400
for _ in range(30):
    code,projection,h=request(path,scope='read')
    if code==200 and projection['version']==version: break
    time.sleep(1)
assert code==200 and projection['version']==version,(code,projection)
assert request(path,scope='admin')[0]==403
assert request(path,scope='write')[0]==403
code,ledger,h=request(path+'/ledger',scope='read')
assert code==200 and [e['version'] for e in ledger['events']]==list(range(1,version+1))
assert request('/v1/admin/projections/'+sid+'/rebuild','POST',scope='admin')[0]==202
conn=op.db(m); conn.autocommit=True
for sql in [
    "UPDATE clearledger.events SET correlation_id='modified' WHERE settlement_id=%s",
    "DELETE FROM clearledger.events WHERE settlement_id=%s",
    "DELETE FROM clearledger.outbox WHERE settlement_id=%s",
    "UPDATE clearledger.settlements SET reference='modified' WHERE settlement_id=%s",
    "DELETE FROM clearledger.idempotency_keys WHERE scope='create:'||%s",
]:
    try: op.update(conn,sql,(sid,))
    except Exception as e: assert e.pgcode=='23514',(sql,e)
    else: raise AssertionError('invalid mutation accepted: '+sql)
conn.close()
op.reconcile()
assert request(path,scope='read')[1].get('lastMemo') is None
print('PASS OAuth scopes, idempotency, clearing transitions, terminal protection, projection/ledger, rebuild, append-only database, archive reconciliation')
