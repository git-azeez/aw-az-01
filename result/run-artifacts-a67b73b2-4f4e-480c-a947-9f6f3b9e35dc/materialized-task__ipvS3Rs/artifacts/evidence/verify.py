import sys, uuid, time, datetime
sys.path.insert(0, '/workspace/submission')
import lifecycle as l
import requests
m=l.manifest()
def token(scope):
    c=m['auth']['clients'][scope]
    r=requests.post(m['auth']['token_endpoint'], auth=(c['client_id'],c['client_secret']), data={'grant_type':'client_credentials','scope':c['scope']},timeout=5)
    r.raise_for_status()
    return r.json()['access_token']
tokens={k:token(k) for k in ('read','write','admin')}
sid=str(uuid.uuid4())
headers={'Authorization':'Bearer '+tokens['write'],'Idempotency-Key':'verify-create-'+sid,'X-Correlation-Id':'verify-'+sid}
payload=dict(settlementId=sid,accountId='account-recovery-test',reference='verification',debitParty='Bank Alpha',creditParty='Bank Beta',expectedVersion=0)
r=requests.post(m['service_url']+'/v1/settlements',headers=headers,json=payload,timeout=10)
assert r.status_code==201,(r.status_code,r.text)
print('Create settlement: 201')
r=requests.post(m['service_url']+'/v1/settlements',headers=headers,json=payload,timeout=10)
assert r.status_code==200,(r.status_code,r.text)
assert r.json()['idempotentReplay']
print('Idempotency replay: 200')
for v,status in enumerate(['VALIDATED','CLEARED','CLEARED','DISPUTED','RECONCILED'],start=1):
    p=dict(entryId=str(uuid.uuid4()),status=status,clearingStage='verification-stage',memo='entry-'+str(v),occurredAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),expectedVersion=v)
    headers['Idempotency-Key']='verify-entry-'+str(uuid.uuid4())
    r=requests.post(m['service_url']+'/v1/settlements/'+sid+'/entries',headers=headers,json=p,timeout=10)
    assert r.status_code==202,(status,r.status_code,r.text)
print('Lifecycle advances / same-status / dispute resolution accepted')
p['expectedVersion']=6
p['entryId']=str(uuid.uuid4())
headers['Idempotency-Key']='verify-terminal-'+str(uuid.uuid4())
r=requests.post(m['service_url']+'/v1/settlements/'+sid+'/entries',headers=headers,json=p,timeout=10)
assert r.status_code==400,(r.status_code,r.text)
print('Terminal transition rejected: 400')
read={'Authorization':'Bearer '+tokens['read']}
for _ in range(40):
    r=requests.get(m['service_url']+'/v1/settlements/'+sid,headers=read,timeout=5)
    if r.status_code==200 and r.json()['version']==6: break
    time.sleep(.5)
assert r.status_code==200 and r.json()['version']==6,(r.status_code,r.text)
print('SQS projector converged to version 6')
r=requests.get(m['service_url']+'/v1/settlements/'+sid+'/ledger',headers=read,timeout=5)
assert r.status_code==200 and len(r.json()['events'])==6,(r.status_code,r.text)
for scope in ('write','admin'):
    r=requests.get(m['service_url']+'/v1/settlements/'+sid,headers={'Authorization':'Bearer '+tokens[scope]},timeout=5)
    assert r.status_code==403
assert requests.get(m['service_url']+'/v1/settlements/'+sid,timeout=5).status_code==401
print('Non-hierarchical OAuth2 scopes verified')
conn=l.db(); conn.autocommit=True
for statement in ['UPDATE clearledger.events SET correlation_id=correlation_id','DELETE FROM clearledger.events','UPDATE clearledger.idempotency_keys SET request_hash=request_hash','DELETE FROM clearledger.outbox']:
    try: l.sql(conn,statement)
    except Exception as e: assert e.pgcode=='23514',e
    else: raise AssertionError('append-only guard failed')
conn.close()
print('Database append-only triggers verified')
print('SETTLEMENT_ID='+sid)
