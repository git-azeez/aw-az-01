import sys,json
from pathlib import Path
sys.path.insert(0,'/workspace/submission')
import lifecycle as l
inventory={}
for service,operation,key,field in [
 ('iam','list_roles','Roles','RoleName'),('iam','list_policies','Policies','PolicyName'),
 ('s3','list_buckets','Buckets','Name'),('sqs','list_queues','QueueUrls',None),
 ('dynamodb','list_tables','TableNames',None),('lambda','list_functions','Functions','FunctionName'),
 ('scheduler','list_schedules','Schedules','Name'),('logs','describe_log_groups','logGroups','logGroupName'),
 ('rds','describe_db_instances','DBInstances','DBInstanceIdentifier'),('rds','describe_db_subnet_groups','DBSubnetGroups','DBSubnetGroupName'),
 ('elasticache','describe_cache_clusters','CacheClusters','CacheClusterId'),('elasticache','describe_replication_groups','ReplicationGroups','ReplicationGroupId'),
 ('elasticache','describe_cache_subnet_groups','CacheSubnetGroups','CacheSubnetGroupName'),
 ('elbv2','describe_load_balancers','LoadBalancers','LoadBalancerName'),('elbv2','describe_target_groups','TargetGroups','TargetGroupName'),
 ('ecs','list_clusters','clusterArns',None),('cognito-idp','list_user_pools','UserPools','Name')]:
    kwargs={'Scope':'Local'} if operation=='list_policies' else {'MaxResults':60} if operation=='list_user_pools' else {}
    rows=l.pages(service,operation,key,**kwargs)
    names=[r[field] if field else r for r in rows]
    if len(sys.argv)>1 and sys.argv[1]=='baseline':
        names=[n for n in names if not l.scoped(n)]
    inventory[service+'/'+operation]=sorted(names)
ec2=l.client('ec2')
vpcs=ec2.describe_vpcs()['Vpcs']
owned={v['VpcId'] for v in vpcs if l.scoped('',v.get('Tags',[]))}
for op,key,field in [('describe_vpcs','Vpcs','VpcId'),('describe_subnets','Subnets','SubnetId'),('describe_route_tables','RouteTables','RouteTableId'),('describe_security_groups','SecurityGroups','GroupId'),('describe_internet_gateways','InternetGateways','InternetGatewayId')]:
    rows=getattr(ec2,op)()[key]
    if len(sys.argv)>1 and sys.argv[1]=='baseline':
        rows=[r for r in rows if r.get('VpcId') not in owned and not l.scoped('',r.get('Tags',[]))]
    inventory['ec2/'+op]=sorted(r[field] for r in rows)
keys=[]
for k in l.pages('kms','list_keys','Keys'):
    meta=l.client('kms').describe_key(KeyId=k['KeyId'])['KeyMetadata']
    if meta['KeyState']=='PendingDeletion':continue
    if len(sys.argv)>1 and sys.argv[1]=='baseline' and l.scoped(meta.get('Description','')):continue
    keys.append(k['KeyId'])
inventory['kms/keys']=sorted(keys)
path=Path('/workspace/evidence/baseline.json')
if len(sys.argv)>1 and sys.argv[1]=='baseline':
    path.write_text(json.dumps(inventory,indent=2))
    print('Baseline inventory recorded')
else:
    assert inventory==json.loads(path.read_text()),json.dumps(inventory,indent=2)
    print('Post-teardown inventory matches baseline')
