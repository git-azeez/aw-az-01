"""Exercise relational invariants in a rolled-back transaction."""
import sys, json, uuid, datetime
from pathlib import Path
sys.path.insert(0,'/workspace/submission')
import lifecycle as l
import psycopg2
from psycopg2.extras import Json
m=json.loads(Path('/workspace/submission/manifest.json').read_text())
conn=l.database(m)
cur=conn.cursor()
sid=str(uuid.uuid4());eid=str(uuid.uuid4());now=datetime.datetime.now(datetime.timezone.utc)
def rejected(sql,args=()):
 cur.execute('SAVEPOINT negative_probe')
 try:
  cur.execute(sql,args)
 except psycopg2.Error as e:
  assert e.pgcode in ('23514','23503','23502','23505','P0001'),e.pgcode
  cur.execute('ROLLBACK TO SAVEPOINT negative_probe')
 else:
  cur.execute('ROLLBACK TO SAVEPOINT negative_probe')
  raise AssertionError('invalid mutation was accepted')
cur.execute("SELECT count(*) FROM pg_indexes WHERE schemaname='clearledger' AND indexname LIKE 'idx_clearledger_%'")
assert cur.fetchone()[0]==6
cur.execute("SELECT count(DISTINCT tgrelid) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O' AND tgrelid IN ('clearledger.settlements'::regclass,'clearledger.events'::regclass,'clearledger.outbox'::regclass,'clearledger.idempotency_keys'::regclass)")
assert cur.fetchone()[0]==4
cur.execute("INSERT INTO clearledger.settlements(settlement_id,account_id,reference,debit_party,credit_party,current_status,current_stage,last_memo,version,created_at,updated_at) VALUES (%s,'acct-probe','probe','Bank-A','Bank-B','INITIATED','INITIATED@Bank-A','Settlement initiated',1,%s,%s)",(sid,now,now))
p={'schemaVersion':'1.0','eventId':eid,'eventType':'SettlementInitiated','aggregateType':'settlement','aggregateId':sid,'aggregateVersion':1,'occurredAt':now.isoformat(),'correlationId':'schema-probe','idempotencyKey':'schema-probe-key','data':{'kind':'settlementInitiated','accountId':'acct-probe','reference':'probe','debitParty':'Bank-A','creditParty':'Bank-B','status':'INITIATED','clearingStage':'INITIATED@Bank-A','memo':'Settlement initiated'}}
insert="INSERT INTO clearledger.events(event_id,settlement_id,aggregate_version,event_type,correlation_id,idempotency_key,occurred_at,payload) VALUES (%s,%s,1,'SettlementInitiated','schema-probe','schema-probe-key',%s,%s)"
bad=json.loads(json.dumps(p));bad['unexpected']=True
rejected(insert,(eid,sid,now,Json(bad)))
bad=json.loads(json.dumps(p));del bad['data']['memo']
rejected(insert,(eid,sid,now,Json(bad)))
bad=json.loads(json.dumps(p));bad['data']['accountId']='other-account'
rejected(insert,(eid,sid,now,Json(bad)))
bad=json.loads(json.dumps(p));bad['eventId']=eid.replace('-','')
rejected(insert,(eid,sid,now,Json(bad)))
cur.execute(insert,(eid,sid,now,Json(p)))
rejected('UPDATE clearledger.events SET payload=payload WHERE event_id=%s',(eid,))
rejected('DELETE FROM clearledger.events WHERE event_id=%s',(eid,))
cur.execute('INSERT INTO clearledger.outbox(event_id,settlement_id,aggregate_version,correlation_id,payload) VALUES (%s,%s,1,%s,%s)',(eid,sid,'schema-probe',Json(p)))
rejected('UPDATE clearledger.outbox SET published_at=now() WHERE event_id=%s',(eid,))
rejected('UPDATE clearledger.outbox SET archived_at=now() WHERE event_id=%s',(eid,))
cur.execute('UPDATE clearledger.outbox SET published_at=now(),attempts=1 WHERE event_id=%s',(eid,))
rejected('UPDATE clearledger.outbox SET attempts=2 WHERE event_id=%s',(eid,))
rejected('DELETE FROM clearledger.outbox WHERE event_id=%s',(eid,))
response={'settlementId':sid,'eventId':eid,'version':1,'accepted':True,'idempotentReplay':False}
cur.execute('INSERT INTO clearledger.idempotency_keys(scope,idempotency_key,request_hash,status_code,response_body) VALUES (%s,%s,%s,201,%s)',('create:'+sid,'schema-probe-key','a'*64,Json(response)))
rejected('UPDATE clearledger.idempotency_keys SET status_code=201')
rejected('DELETE FROM clearledger.idempotency_keys')
rejected('DELETE FROM clearledger.settlements WHERE settlement_id=%s',(sid,))
rejected('UPDATE clearledger.settlements SET reference=reference WHERE settlement_id=%s',(sid,))
conn.rollback();conn.close()
print('Schema verification passed: six indexes, enabled triggers on all four tables, 14 rejected invalid mutations; no test rows committed')
