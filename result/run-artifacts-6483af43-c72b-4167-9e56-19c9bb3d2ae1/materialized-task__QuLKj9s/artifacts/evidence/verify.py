import sys, json, uuid, time, base64, urllib.request, urllib.error
from pathlib import Path
sys.path.insert(0,'/workspace/submission')
import lifecycle as l
import redis
m=json.loads(Path('/workspace/submission/manifest.json').read_text())
def token(scope):
 c=m['auth']['clients'][scope]
 basic=base64.b64encode((c['client_id']+':'+c['client_secret']).encode()).decode()
 req=urllib.request.Request(m['auth']['token_endpoint'],data=('grant_type=client_credentials&scope='+c['scope']).encode(),headers={'Authorization':'Basic '+basic,'Content-Type':'application/x-www-form-urlencoded'})
 return json.load(urllib.request.urlopen(req))['access_token']
tokens={s:token(s) for s in ['read','write','admin']}
def request(path,scope,body=None,key=None):
 headers={'Authorization':'Bearer '+tokens[scope],'X-Correlation-Id':'infra-verification'}
 if key:headers['Idempotency-Key']=key
 if body:headers['Content-Type']='application/json'
 req=urllib.request.Request(m['service_url']+path,data=json.dumps(body).encode() if body else None,headers=headers)
 try:r=urllib.request.urlopen(req)
 except urllib.error.HTTPError as e:r=e
 return r.status,json.loads(r.read()),{k.lower():v for k,v in r.headers.items()}
mode=sys.argv[1]
if mode=='traffic':
 sid=str(uuid.uuid4()); path='/v1/settlements/'+sid
 body={'settlementId':sid,'accountId':'acct-infra-check','reference':'infra-check','debitParty':'Bank-A','creditParty':'Bank-B','expectedVersion':0}
 result=request('/v1/settlements','write',body,'infra-create-'+sid)
 print('create',result[0],result[1]); assert result[0]==201
 assert request('/v1/settlements','write',body,'infra-create-'+sid)[0]==200
 assert request(path,'write')[0]==403
 assert request('/v1/settlements','read',body,'infra-forbidden-'+sid)[0]==403
 time.sleep(3)
 result=request(path,'read');print('projection',result);assert result[0]==200
 for version,status in enumerate(['VALIDATED','CLEARED','CLEARED','DISPUTED','RECONCILED'],start=1):
  body={'entryId':str(uuid.uuid4()),'status':status,'clearingStage':status+'@Bank-B','memo':'Verified entry','occurredAt':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(time.time()+version)),'expectedVersion':version}
  result=request(path+'/entries','write',body,'infra-entry-'+str(uuid.uuid4()))
  print('entry',version,status,result[0],result[1]);assert result[0]==202
 time.sleep(3)
 result=request(path+'/ledger','read');print('ledger',result[0],len(result[1].get('events',[])));assert result[0]==200 and len(result[1]['events'])==6
 body['expectedVersion']=6;body['entryId']=str(uuid.uuid4());body['occurredAt']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime(time.time()+20))
 assert request(path+'/entries','write',body,'infra-terminal-'+str(uuid.uuid4()))[0]==400
 Path('/workspace/evidence/settlement.json').write_text(json.dumps({'id':sid}))
 print('traffic checks passed')
elif mode=='drift':
 sid=json.loads(Path('/workspace/evidence/settlement.json').read_text())['id']
 ddb=l.client('dynamodb');table=m['projections']['table_name']
 ddb.update_item(TableName=table,Key={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'STATE'}},UpdateExpression='SET #v=:v, #s=:s',ExpressionAttributeNames={'#v':'version','#s':'status'},ExpressionAttributeValues={':v':{'N':'999'},':s':{'S':'POISONED'}})
 ddb.put_item(TableName=table,Item={'PK':{'S':'ORPHAN'},'SK':{'S':'STRAY'}})
 ddb.delete_item(TableName=table,Key={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'EVENT#00000002'}})
 r=redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port']);r.set('stray-key','poison');r.set('clearledger:settlement:'+sid,'{}')
 s3=l.client('s3');bucket=m['audit']['bucket_name']
 s3.put_object(Bucket=bucket,Key='orphan.txt',Body=b'poison')
 s3.put_object(Bucket=bucket,Key='orphan.txt',Body=b'poison-v2')
 s3.delete_object(Bucket=bucket,Key='orphan.txt')
 s3.put_public_access_block(Bucket=bucket,PublicAccessBlockConfiguration={k:False for k in ['BlockPublicAcls','IgnorePublicAcls','BlockPublicPolicy','RestrictPublicBuckets']})
 l.client('kms').schedule_key_deletion(KeyId=m['kms']['audit_arn'],PendingWindowInDays=10)
 l.client('kms').disable_key(KeyId=m['kms']['messaging_arn'])
 l.client('kms').disable_key_rotation(KeyId=m['kms']['projection_arn'])
 l.client('rds').remove_tags_from_resource(ResourceName=m['database']['instance_arn'],TagKeys=['ClearLedgerDeployment'])
 l.client('ecs').update_cluster_settings(cluster=m['compute']['cluster_name'],settings=[{'name':'containerInsights','value':'disabled'}])
 l.client('elbv2').modify_target_group(TargetGroupArn=m['ingress']['target_group_arn'],HealthCheckPath='/bad',HealthCheckIntervalSeconds=30)
 l.client('dynamodb').update_continuous_backups(TableName=table,PointInTimeRecoverySpecification={'PointInTimeRecoveryEnabled':False})
 l.client('sqs').set_queue_attributes(QueueUrl=m['messaging']['queue_url'],Attributes={'VisibilityTimeout':'50'})
 l.client('iam').put_role_policy(RoleName=l.PREFIX+'-ecs_task',PolicyName=l.PREFIX+'-bad',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}))
 ec2=l.client('ec2');ec2.authorize_security_group_ingress(GroupId=m['network']['security_group_ids']['ecs'],IpPermissions=[{'IpProtocol':'tcp','FromPort':8080,'ToPort':8080,'IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
 with l.database(m) as conn:
  with conn.cursor() as cur:cur.execute('DROP INDEX clearledger.idx_clearledger_outbox_unpublished; ALTER TABLE clearledger.events DISABLE TRIGGER guard_event')
 print('control and data-plane drift injected')
elif mode=='check':
 sid=json.loads(Path('/workspace/evidence/settlement.json').read_text())['id']
 result=request('/v1/settlements/'+sid,'read');print('read after reconciliation',result)
 assert result[0]==200 and result[1]['version']==6 and result[1]['status']=='RECONCILED' and result[2]['x-clearledger-source']=='cache'
 result=request('/v1/settlements/'+sid+'/ledger','read'); assert len(result[1]['events'])==6
 assert l.client('kms').describe_key(KeyId=m['kms']['audit_arn'])['KeyMetadata']['KeyState']=='Enabled'
 assert l.client('kms').describe_key(KeyId=m['kms']['messaging_arn'])['KeyMetadata']['KeyState']=='Enabled'
 assert l.client('kms').get_key_rotation_status(KeyId=m['kms']['projection_arn'])['KeyRotationEnabled']
 assert l.client('dynamodb').describe_continuous_backups(TableName=m['projections']['table_name'])['ContinuousBackupsDescription']['PointInTimeRecoveryDescription']['PointInTimeRecoveryStatus']=='ENABLED'
 with l.database(m) as conn:
  with conn.cursor() as cur:
   cur.execute('SELECT count(*), count(published_at), count(archived_at) FROM clearledger.outbox');counts=cur.fetchone();print('outbox',counts);assert counts==(6,6,6)
   cur.execute("SELECT count(*) FROM pg_trigger WHERE tgrelid='clearledger.events'::regclass AND NOT tgisinternal AND tgenabled='O'");assert cur.fetchone()[0]>=1
 versions=l.client('s3').list_object_versions(Bucket=m['audit']['bucket_name']);assert not versions.get('DeleteMarkers') and all(v['IsLatest'] for v in versions.get('Versions',[]))
 print('recovery checks passed')
