import sys,json
sys.path.insert(0,'/workspace/submission')
import lifecycle as l
import redis,requests
m=l.manifest();p=l.PREFIX
conn=l.db()
assert l.count(conn,'published_at IS NULL OR archived_at IS NULL')==0
assert l.archive_valid(conn,m)
vs=l.versions(m['audit']['bucket_name'])
assert all(not v['marker'] and v['IsLatest'] for v in vs)
assert sum(len(l.client('s3').get_object(Bucket=m['audit']['bucket_name'],Key=v['Key'])['Body'].read().splitlines()) for v in vs)==l.count(conn,'true')
for k in l.ROLE_KEYS:
    role=p+'-'+k
    assert l.client('iam').list_role_policies(RoleName=role)['PolicyNames']==[role+'-canonical']
    assert not l.client('iam').list_attached_role_policies(RoleName=role)['AttachedPolicies']
assert not l.client('iam').list_policies(Scope='Local')['Policies']
for role in ('rds','valkey'):
    assert not l.client('ec2').describe_security_groups(GroupIds=[m['network']['security_group_ids'][role]])['SecurityGroups'][0]['IpPermissionsEgress']
rows=l.sql(conn,'SELECT * FROM clearledger.settlements')
conn.close()
c=redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'],decode_responses=True)
assert set(c.keys('*'))=={'clearledger:settlement:'+str(s['settlement_id']) for s in rows}
client=m['auth']['clients']['read']
token=requests.post(m['auth']['token_endpoint'],auth=(client['client_id'],client['client_secret']),data={'grant_type':'client_credentials','scope':client['scope']}).json()['access_token']
for s in rows:
    r=requests.get(m['service_url']+'/v1/settlements/'+str(s['settlement_id']),headers={'Authorization':'Bearer '+token})
    assert r.status_code==200
    assert r.headers['X-ClearLedger-Source']=='cache',r.headers
    assert r.json()['version']==s['version']
print('Recovery validated: outbox, canonical archive, current-only versions, IAM guardrails, SG egress, projection/cache reads')
