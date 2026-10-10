"""Optional live-traffic redeployment verification; creates immutable test settlements."""
import concurrent.futures
import subprocess
import threading
import time
import uuid

import requests

from ops import ROOT, manifest, db

m = manifest()
v = m['auth']['clients']['write']
r = requests.post(m['auth']['token_endpoint'], auth=(v['client_id'], v['client_secret']),
                  data={'grant_type': 'client_credentials', 'scope': v['scope']}, timeout=10)
r.raise_for_status()
token = r.json()['access_token']
stop = threading.Event()
written = []
errors = []


def traffic():
    while not stop.is_set():
        sid = str(uuid.uuid4())
        body = {'settlementId': sid, 'accountId': 'LIVE001', 'reference': 'LIFECYCLE',
                'debitParty': 'BANKA', 'creditParty': 'BANKB', 'expectedVersion': 0}
        try:
            response = requests.post(m['service_url'] + '/v1/settlements', json=body,
                                     headers={'Authorization': 'Bearer ' + token,
                                              'Idempotency-Key': 'live-' + sid,
                                              'X-Correlation-Id': 'live-deployment'}, timeout=40)
            if response.status_code != 201:
                errors.append((response.status_code, response.text))
            else:
                written.append(sid)
        except Exception as error:
            errors.append(str(error))
        time.sleep(0.25)


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    futures = [pool.submit(traffic) for _ in range(2)]
    time.sleep(1)
    try:
        subprocess.run([str(ROOT / 'deploy.sh')], check=True, timeout=720)
    finally:
        stop.set()
        for future in futures:
            future.result()
assert not errors, errors
conn = db()
with conn.cursor() as cur:
    cur.execute('SELECT settlement_id::text FROM clearledger.settlements WHERE settlement_id = ANY(%s::uuid[])', (written,))
    assert {row[0] for row in cur.fetchall()} == set(written)
conn.close()
subprocess.run([str(ROOT / 'deploy.sh')], check=True, timeout=720)
print(f'Live redeployment passed: {len(written)} writes, zero failed requests, zero lost commits.')
