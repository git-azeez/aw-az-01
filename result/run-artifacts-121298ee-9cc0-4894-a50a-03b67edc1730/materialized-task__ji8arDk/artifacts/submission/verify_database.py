"""Transactional invariant checks. All test rows are rolled back."""
import datetime as dt
import json
from pathlib import Path
import uuid
import psycopg2
from psycopg2.extras import Json

root = Path(__file__).resolve().parent
c = json.loads(Path('/workspace/config/config.json').read_text())
m = json.loads((root/'manifest.json').read_text())
d = m['database']
conn = psycopg2.connect(host=d['endpoint'], port=d['port'], dbname=d['db_name'],
                        user=d['username'], password=c['db_password'])
cur = conn.cursor()
sid, eid = str(uuid.uuid4()), str(uuid.uuid4())
when = dt.datetime.now(dt.timezone.utc)

def rejected(sql, args=()):
    cur.execute('SAVEPOINT invalid_operation')
    try:
        cur.execute(sql, args)
    except psycopg2.Error as e:
        assert e.pgcode in {'23514', '23503', '23502', '23505', 'P0001'}, e.pgcode
        cur.execute('ROLLBACK TO SAVEPOINT invalid_operation')
    else:
        raise AssertionError('Invalid operation accepted')

try:
    cur.execute('INSERT INTO clearledger.settlements(settlement_id,account_id,reference,debit_party,credit_party,current_status,current_stage,last_memo,version,created_at,updated_at) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,1,%s,%s)',
        (sid,'bank-test','test-reference','DebitBank','CreditBank','INITIATED','INITIATED@DebitBank','Settlement initiated',when,when))
    payload = {'schemaVersion':'1.0','eventId':eid,'eventType':'SettlementInitiated','aggregateType':'settlement',
        'aggregateId':sid,'aggregateVersion':1,'occurredAt':when.isoformat(),'correlationId':'db-test',
        'idempotencyKey':'db-test-create','data':{'kind':'settlementInitiated','accountId':'bank-test',
        'reference':'test-reference','debitParty':'DebitBank','creditParty':'CreditBank','status':'INITIATED',
        'clearingStage':'INITIATED@DebitBank','memo':'Settlement initiated'}}
    sql = 'INSERT INTO clearledger.events(event_id,settlement_id,aggregate_version,event_type,correlation_id,idempotency_key,occurred_at,payload) VALUES(%s,%s,1,%s,%s,%s,%s,%s)'
    bad = dict(payload, unexpected=True)
    rejected(sql, (eid,sid,'SettlementInitiated','db-test','db-test-create',when,Json(bad)))
    cur.execute(sql, (eid,sid,'SettlementInitiated','db-test','db-test-create',when,Json(payload)))
    cur.execute('INSERT INTO clearledger.outbox(event_id,settlement_id,aggregate_version,correlation_id,payload) VALUES(%s,%s,1,%s,%s)',
                (eid,sid,'db-test',Json(payload)))
    response = {'settlementId':sid,'eventId':eid,'version':1,'accepted':True,'idempotentReplay':False}
    cur.execute('INSERT INTO clearledger.idempotency_keys(scope,idempotency_key,request_hash,status_code,response_body) VALUES(%s,%s,%s,201,%s)',
                ('create:'+sid,'db-test-create','a'*64,Json(response)))
    for table in ['settlements','events','outbox']:
        rejected('DELETE FROM clearledger.'+table+' WHERE settlement_id=%s', (sid,))
    rejected('DELETE FROM clearledger.idempotency_keys WHERE scope=%s', ('create:'+sid,))
    rejected('UPDATE clearledger.events SET correlation_id=%s WHERE event_id=%s', ('changed-cid',eid))
    rejected('UPDATE clearledger.outbox SET published_at=clock_timestamp() WHERE event_id=%s', (eid,))
    rejected('UPDATE clearledger.idempotency_keys SET request_hash=%s WHERE scope=%s', ('b'*64,'create:'+sid))
    cur.execute('UPDATE clearledger.settlements SET version=2,entry_count=1,last_entry_id=%s,last_memo=NULL,current_status=%s,current_stage=%s,updated_at=%s WHERE settlement_id=%s',
                (str(uuid.uuid4()),'CLEARED','cleared-test',when+dt.timedelta(seconds=1),sid))
    cur.execute('SELECT last_memo FROM clearledger.settlements WHERE settlement_id=%s', (sid,))
    assert cur.fetchone()[0]=='Settlement initiated'
    update='UPDATE clearledger.settlements SET version=3,entry_count=2,last_entry_id=%s,current_status=%s,updated_at=%s WHERE settlement_id=%s'
    rejected(update,(str(uuid.uuid4()),'RESERVED',when+dt.timedelta(seconds=2),sid))
    cur.execute(update,(str(uuid.uuid4()),'DISPUTED',when+dt.timedelta(seconds=2),sid))
    rejected('UPDATE clearledger.settlements SET version=4,entry_count=3,last_entry_id=%s,current_status=%s,updated_at=%s WHERE settlement_id=%s',
             (str(uuid.uuid4()),'SETTLED',when+dt.timedelta(seconds=3),sid))
    cur.execute('UPDATE clearledger.settlements SET version=4,entry_count=3,last_entry_id=%s,current_status=%s,updated_at=%s WHERE settlement_id=%s',
             (str(uuid.uuid4()),'RECONCILED',when+dt.timedelta(seconds=3),sid))
    rejected('UPDATE clearledger.settlements SET version=5,entry_count=4,last_entry_id=%s,updated_at=%s WHERE settlement_id=%s',
             (str(uuid.uuid4()),when+dt.timedelta(seconds=4),sid))
    print('Database checks passed: closed event schema, append-only tables, delivery lifecycle, memo retention, rank/dispute/terminal transitions')
finally:
    conn.rollback()
    conn.close()
