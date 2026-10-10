"""Live integration check; writes one persistent, clearly labelled settlement."""
import datetime
import json
import time
import uuid

import requests

from ops import ROOT, database, invoke, client, canonical


def verify():
    m = json.loads((ROOT / 'manifest.json').read_text())
    tokens = {}
    for scope, c in m['auth']['clients'].items():
        r = requests.post(m['auth']['token_endpoint'], data={
            'grant_type': 'client_credentials', 'client_id': c['client_id'],
            'client_secret': c['client_secret'], 'scope': c['scope']}, timeout=10)
        r.raise_for_status()
        tokens[scope] = r.json()['access_token']
    sid = str(uuid.uuid4())
    base = m['service_url'] + '/v1/settlements'
    headers = {'Authorization': 'Bearer ' + tokens['write'], 'Idempotency-Key': 'verify-' + sid,
               'X-Correlation-Id': 'verify-' + sid}
    payload = {'settlementId': sid, 'accountId': 'verification', 'reference': 'lifecycle-verification',
               'debitParty': 'BANK-A', 'creditParty': 'BANK-B', 'expectedVersion': 0}
    r = requests.post(base, json=payload, headers=headers, timeout=15)
    assert r.status_code == 201, (r.status_code, r.text)
    replay = requests.post(base, json=payload, headers=headers, timeout=15)
    assert replay.status_code == 200 and replay.json()['idempotentReplay']
    for version, status, memo in [(1, 'CLEARED', 'Memo retained'), (2, 'CLEARED', None)]:
        headers['Idempotency-Key'] = 'verify-' + str(uuid.uuid4())
        r = requests.post(base + '/' + sid + '/entries', headers=headers, json={
            'entryId': str(uuid.uuid4()), 'status': status, 'clearingStage': 'CLEARING@BANK-A',
            'memo': memo, 'occurredAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'expectedVersion': version}, timeout=15)
        assert r.status_code == 202, (r.status_code, r.text)
        time.sleep(.01)
    headers['Idempotency-Key'] = 'verify-' + str(uuid.uuid4())
    r = requests.post(base + '/' + sid + '/entries', headers=headers, json={
        'entryId': str(uuid.uuid4()), 'status': 'RESERVED', 'clearingStage': 'INVALID-REGRESSION',
        'occurredAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'expectedVersion': 3}, timeout=15)
    assert r.status_code == 400, (r.status_code, r.text)
    assert requests.get(base + '/' + sid, headers=headers, timeout=5).status_code == 403
    assert requests.get(base + '/' + sid, timeout=5).status_code == 401
    for _ in range(40):
        r = requests.get(base + '/' + sid, headers={'Authorization': 'Bearer ' + tokens['read']}, timeout=5)
        if r.status_code == 200 and r.json()['version'] == 3:
            break
        time.sleep(.5)
    assert r.status_code == 200 and r.json()['lastMemo'] == 'Memo retained', (r.status_code, r.text)
    with database(m) as db:
        with db.cursor() as cur:
            cur.execute('SELECT payload FROM clearledger.events WHERE settlement_id=%s ORDER BY aggregate_version', (sid,))
            payloads = [r[0] for r in cur.fetchall()]
            cur.execute('SELECT last_memo,version FROM clearledger.settlements WHERE settlement_id=%s', (sid,))
            assert cur.fetchone() == ('Memo retained', 3)
    invoke(m, 'outbox_relay', {})
    invoke(m, 'audit_archiver', {})
    s3 = client('s3'); bucket = m['audit']['bucket_name']
    for obj in s3.list_objects_v2(Bucket=bucket).get('Contents', []):
        raw = s3.get_object(Bucket=bucket, Key=obj['Key'])['Body'].read().decode()
        for line in raw.splitlines():
            p = json.loads(line)
            assert line == canonical(p), 'Canonical serialization differs: ' + line
    print('PASS: create, idempotency, append, omitted memo, regression rejection, OAuth scope isolation, projection, relay, archive.')
    print('Verification settlement: ' + sid)


if __name__ == '__main__':
    verify()
