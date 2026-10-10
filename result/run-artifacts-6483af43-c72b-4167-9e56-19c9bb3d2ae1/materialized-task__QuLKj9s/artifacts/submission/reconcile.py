"""Repair derived stores while holding a bounded PostgreSQL write barrier.

The application stays available for reads. Writes wait at the database and
resume after commit; there is no window in which a stale snapshot can erase
events committed by live traffic. Workload schedules are paused by the caller.
"""
import hashlib
import json
import re

from boto3.dynamodb.types import TypeDeserializer, TypeSerializer
import psycopg2.extras
import redis


def canonical_json(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(',', ':'), sort_keys=True)


def timestamp(dt):
    return dt.isoformat().replace('+00:00', 'Z')


def projection(s):
    p = {'settlementId': str(s['settlement_id']), 'accountId': s['account_id'],
         'reference': s['reference'], 'debitParty': s['debit_party'], 'creditParty': s['credit_party'],
         'status': s['current_status'], 'clearingStage': s['current_stage'],
         'version': s['version'], 'entryCount': s['entry_count'],
         'updatedAt': timestamp(s['updated_at'])}
    if s['last_entry_id'] is not None:
        p['lastEntryId'] = str(s['last_entry_id'])
    if s['last_memo'] is not None:
        p['lastMemo'] = s['last_memo']
    return p


def expected_items(settlements, events):
    result = {}
    for s in settlements:
        sid = str(s['settlement_id'])
        pk = 'SETTLEMENT#' + sid
        item = {'PK': pk, 'SK': 'STATE', 'GSI1PK': 'ACCOUNT#' + s['account_id'], 'GSI1SK': pk,
                'settlement_id': sid, 'account_id': s['account_id'], 'reference': s['reference'],
                'debit_party': s['debit_party'], 'credit_party': s['credit_party'],
                'status': s['current_status'], 'clearing_stage': s['current_stage'],
                'version': s['version'], 'entry_count': s['entry_count'], 'updated_at': timestamp(s['updated_at'])}
        if s['last_entry_id'] is not None:
            item['last_entry_id'] = str(s['last_entry_id'])
        if s['last_memo'] is not None:
            item['last_memo'] = s['last_memo']
        result[(pk, 'STATE')] = item
    for e in events:
        p = e['payload']
        d = p['data']
        pk = 'SETTLEMENT#' + str(e['settlement_id'])
        sk = f"EVENT#{e['aggregate_version']:08d}"
        item = {'PK': pk, 'SK': sk, 'settlement_id': str(e['settlement_id']),
                'event_id': str(e['event_id']), 'version': e['aggregate_version'],
                'event_type': e['event_type'], 'status': d['status'], 'clearing_stage': d['clearingStage'],
                'occurred_at': p['occurredAt'], 'correlation_id': e['correlation_id'], 'envelope': canonical_json(p)}
        for src, dest in [('entryId', 'entry_id'), ('memo', 'memo')]:
            if d.get(src) is not None:
                item[dest] = d[src]
        result[(pk, sk)] = item
    return result


def reconcile_dynamodb(m, expected, client):
    c = client('dynamodb')
    table = m['projections']['table_name']
    serializer = TypeSerializer()
    deserializer = TypeDeserializer()
    current = {}
    args = {'TableName': table, 'ConsistentRead': True}
    while True:
        page = c.scan(**args)
        for raw in page['Items']:
            item = {k: deserializer.deserialize(v) for k, v in raw.items()}
            current[(item['PK'], item['SK'])] = item
        if not page.get('LastEvaluatedKey'):
            break
        args['ExclusiveStartKey'] = page['LastEvaluatedKey']
    for pk, sk in current.keys() - expected.keys():
        c.delete_item(TableName=table, Key={'PK': {'S': pk}, 'SK': {'S': sk}})
    for key, item in expected.items():
        if item != current.get(key):
            c.put_item(TableName=table, Item={k: serializer.serialize(v) for k, v in item.items()})


def all_versions(c, bucket):
    for page in c.get_paginator('list_object_versions').paginate(Bucket=bucket):
        yield from [(x, False) for x in page.get('Versions', [])]
        yield from [(x, True) for x in page.get('DeleteMarkers', [])]


def reconcile_archive(cur, m, rows, client):
    c = client('s3')
    bucket = m['audit']['bucket_name']
    source = {r['seq']: r['payload'] for r in rows}
    covered = set()
    versions = list(all_versions(c, bucket))
    latest = sorted([(v, marker) for v, marker in versions if v['IsLatest']], key=lambda pair: pair[0]['Key'])
    keep = set()
    pattern = re.compile(r'^ledger-audit/batch-(\d{8,})-(\d{8,})-([0-9a-f]{16})\.ndjson$')
    for v, marker in latest:
        key = v['Key']
        match = pattern.fullmatch(key)
        valid = False
        if match and not marker:
            lo, hi = int(match[1]), int(match[2])
            if lo <= hi and hi - lo < 1000000 and not any(i in covered for i in range(lo, hi+1)):
                raw = c.get_object(Bucket=bucket, Key=key, VersionId=v['VersionId'])['Body'].read()
                try:
                    events = [json.loads(line) for line in raw.splitlines()]
                    valid = (hashlib.sha256(raw).hexdigest()[:16] == match[3]
                             and raw.endswith(b'\n') and len(events) == hi-lo+1
                             and all(source.get(i) == events[i-lo] for i in range(lo, hi+1)))
                except (ValueError, UnicodeError):
                    valid = False
                if valid:
                    covered.update(range(lo, hi+1))
                    keep.add((key, v['VersionId']))
    # Delete by version ID: do not create fresh delete markers during repair.
    for v, marker in versions:
        if marker or (v['Key'], v['VersionId']) not in keep:
            c.delete_object(Bucket=bucket, Key=v['Key'], VersionId=v['VersionId'])
    missing = sorted(source.keys() - covered)
    batches = []
    for seq in missing:
        if not batches or len(batches[-1]) >= 100 or seq != batches[-1][-1] + 1:
            batches.append([])
        batches[-1].append(seq)
    for batch in batches:
        raw = (''.join(canonical_json(source[i]) + '\n' for i in batch)).encode()
        digest = hashlib.sha256(raw).hexdigest()[:16]
        key = f'ledger-audit/batch-{batch[0]:08d}-{batch[-1]:08d}-{digest}.ndjson'
        c.put_object(Bucket=bucket, Key=key, Body=raw, ContentType='application/x-ndjson',
                     ServerSideEncryption='aws:kms', SSEKMSKeyId=m['kms']['audit_arn'])
    cur.execute('UPDATE clearledger.outbox SET archived_at=clock_timestamp() WHERE archived_at IS NULL')
    final = list(all_versions(c, bucket))
    assert all(v['IsLatest'] and not marker for v, marker in final), 'S3 version convergence failed'
    assert len(final) == len(keep) + len(batches), 'S3 batch convergence failed'


def converge(conn, m, client, drain):
    psycopg2.extras.register_uuid(conn_or_curs=conn)
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SET LOCAL lock_timeout='45s'; SET LOCAL statement_timeout='150s'; SET LOCAL TIME ZONE 'UTC'")
        cur.execute('SELECT pg_advisory_xact_lock(734927101)')
        cur.execute('LOCK TABLE clearledger.settlements,clearledger.events,clearledger.outbox,clearledger.idempotency_keys IN SHARE ROW EXCLUSIVE MODE')
        cur.execute('SELECT * FROM clearledger.settlements ORDER BY settlement_id')
        settlements = cur.fetchall()
        cur.execute('SELECT * FROM clearledger.events ORDER BY seq')
        events = cur.fetchall()
        cur.execute('SELECT * FROM clearledger.outbox ORDER BY seq')
        rows = cur.fetchall()
        sqs = client('sqs')
        for row in rows:
            if row['published_at'] is None:
                sqs.send_message(QueueUrl=m['messaging']['queue_url'], MessageBody=canonical_json(row['payload']))
                cur.execute('UPDATE clearledger.outbox SET published_at=clock_timestamp(),attempts=attempts+1,last_error=NULL WHERE seq=%s', (row['seq'],))
        expected = expected_items(settlements, events)
        reconcile_dynamodb(m, expected, client)
        drain(m)
        # Projector replay may have filled nullable fields; enforce exact item shape.
        reconcile_dynamodb(m, expected, client)
        reconcile_archive(cur, m, rows, client)
        cache = redis.Redis(host=m['cache']['endpoint'], port=m['cache']['port'], socket_timeout=5)
        desired = {'clearledger:settlement:' + str(s['settlement_id']): canonical_json(projection(s)) for s in settlements}
        for key in cache.scan_iter(count=500):
            if key.decode() not in desired:
                cache.delete(key)
        with cache.pipeline(transaction=True) as pipeline:
            for key, value in desired.items():
                pipeline.set(key, value, ex=90)
            pipeline.execute()
        for key, value in desired.items():
            assert cache.get(key).decode() == value and 0 < cache.ttl(key) <= 90, 'Cache convergence failed'
        print(f"Reconciled {len(settlements)} settlements and {len(events)} committed events.", flush=True)
