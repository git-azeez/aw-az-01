import sys,json,uuid,time,urllib.request,urllib.parse,urllib.error
sys.path.insert(0,'/workspace/submission')
import ops
m=ops.manifest()
def http(path,token=None,data=None,headers=None):
    h=headers or {}
    if token: h['Authorization']='Bearer '+token
    if data is not None: h['Content-Type']='application/json'
    req=urllib.request.Request(m['service_url']+path,data=json.dumps(data).encode() if data is not None else None,headers=h)
    try:r=urllib.request.urlopen(req,timeout=15)
    except urllib.error.HTTPError as e:r=e
    return r.status,json.loads(r.read()),dict(r.headers)
tokens={}
for scope,c in m['auth']['clients'].items():
    data=urllib.parse.urlencode({'grant_type':'client_credentials','client_id':c['client_id'],'client_secret':c['client_secret'],'scope':c['scope']}).encode()
    req=urllib.request.Request(m['auth']['token_endpoint'],data=data,headers={'Content-Type':'application/x-www-form-urlencoded'})
    tokens[scope]=json.load(urllib.request.urlopen(req))['access_token']
sid=str(uuid.uuid4())
payload={'settlementId':sid,'accountId':'bank-test-001','reference':'operational-smoke','debitParty':'Bank A','creditParty':'Bank B','expectedVersion':0}
h={'Idempotency-Key':'smoke-create-'+sid,'X-Correlation-Id':'smoke-'+sid}
assert http('/v1/settlements',tokens['admin'],payload,h.copy())[0]==403
r=http('/v1/settlements',tokens['write'],payload,h.copy());print('create',r[0],r[1]);assert r[0]==201
r=http('/v1/settlements',tokens['write'],payload,h.copy());assert r[0]==200 and r[1]['idempotentReplay']
time.sleep(3)
r=http('/v1/settlements/'+sid,tokens['read']);print('read',r[0],r[1]);assert r[0]==200
entry={'entryId':str(uuid.uuid4()),'status':'CLEARED','clearingStage':'INTERBANK','memo':'Clearing smoke','occurredAt':'2026-10-09T23:59:00Z','expectedVersion':1}
r=http('/v1/settlements/'+sid+'/entries',tokens['write'],entry,{'Idempotency-Key':'smoke-entry-'+sid,'X-Correlation-Id':'smoke-entry-'+sid});print('entry',r[0],r[1]);assert r[0]==202
entry.update(entryId=str(uuid.uuid4()),status='RESERVED',expectedVersion=2)
r=http('/v1/settlements/'+sid+'/entries',tokens['write'],entry,{'Idempotency-Key':'smoke-invalid-'+sid});print('regression rejected',r[0]);assert r[0]==400
time.sleep(3)
r=http('/v1/settlements/'+sid+'/ledger',tokens['read']);print('ledger',r[0],r[1]);assert len(r[1]['events'])==2
ops.invoke(m,'outbox_relay');ops.invoke(m,'audit_archiver')
print('DynamoDB:',json.dumps(ops.client('dynamodb').scan(TableName=m['projections']['table_name'])['Items'],indent=2))
print('Archive:',[(x['Key'],x['IsLatest']) for x in ops.versions(m['audit']['bucket_name'])])
print('Smoke tests passed')
