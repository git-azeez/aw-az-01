"""Verify lifecycle write-lock repair under concurrent API traffic."""
import concurrent.futures
import subprocess
import threading
import uuid

import requests
from operations import ROOT, manifest, connect, client, canonical_items


def main():
    m = manifest()
    c = m['auth']['clients']['write']
    r = requests.post(m['auth']['token_endpoint'], auth=(c['client_id'], c['client_secret']),
                      data={'grant_type': 'client_credentials', 'scope': c['scope']}, timeout=10)
    r.raise_for_status()
    token = r.json()['access_token']
    stop = threading.Event()
    committed = []
    errors = []

    def writer():
        while not stop.is_set():
            sid = str(uuid.uuid4())
            try:
                r = requests.post(m['service_url']+'/v1/settlements', timeout=45,
                                  headers={'Authorization': 'Bearer '+token, 'Idempotency-Key': 'traffic-'+sid,
                                           'X-Correlation-Id': 'live-traffic-verification'},
                                  json={'settlementId': sid, 'accountId': 'traffic-account', 'reference': 'live-traffic',
                                        'debitParty': 'bank-a', 'creditParty': 'bank-b', 'expectedVersion': 0})
                if r.status_code == 201:
                    committed.append(sid)
                else:
                    errors.append((r.status_code,r.text))
            except requests.RequestException as exc:
                errors.append(str(exc))
            stop.wait(.2)

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        workers = [pool.submit(writer) for _ in range(2)]
        try:
            subprocess.run([str(ROOT/'deploy.sh')], check=True, timeout=720)
        finally:
            stop.set()
            for worker in workers:
                worker.result()
    assert committed and not errors, errors
    # Quiesce the test writers and establish a final canonical checkpoint.
    subprocess.run([str(ROOT/'deploy.sh')], check=True, timeout=720)
    with connect() as db:
        settlements = db.execute('SELECT * FROM clearledger.settlements').fetchall()
        events = db.execute('SELECT * FROM clearledger.events').fetchall()
        assert set(committed).issubset({str(s['settlement_id']) for s in settlements})
        assert db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL').fetchone()['n']==0
    from boto3.dynamodb.types import TypeDeserializer
    from operations import pages
    deser = TypeDeserializer()
    items = list(pages(client('dynamodb'),'scan','Items', TableName=m['projections']['table_name'],ConsistentRead=True))
    actual = {(i['PK']['S'],i['SK']['S']):{k:deser.deserialize(v) for k,v in i.items()} for i in items}
    assert actual==canonical_items(settlements,events)
    print(f'PASS: {len(committed)} concurrent writes survived deployment, followed by complete authoritative convergence.')


if __name__=='__main__':
    main()
