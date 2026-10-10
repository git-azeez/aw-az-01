import sys, json
from pathlib import Path
sys.path.insert(0,'/workspace/submission')
import lifecycle as l
m=json.loads(Path('/workspace/submission/manifest.json').read_text())
if sys.argv[1]=='seed':
 tags=[{'Key':'ClearLedgerDeployment','Value':l.PREFIX}]
 iam=l.client('iam');role=l.PREFIX+'-ecs_task'
 iam.create_instance_profile(InstanceProfileName=l.PREFIX+'-operational-profile',Tags=tags)
 iam.add_role_to_instance_profile(InstanceProfileName=l.PREFIX+'-operational-profile',RoleName=role)
 document=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'sqs:GetQueueUrl','Resource':m['messaging']['queue_arn']}]})
 policy=iam.create_policy(PolicyName=l.PREFIX+'-operational-policy',PolicyDocument=document,Tags=tags)['Policy']['Arn']
 iam.create_policy_version(PolicyArn=policy,PolicyDocument=document,SetAsDefault=True)
 iam.attach_role_policy(RoleName=role,PolicyArn=policy)
 l.client('s3').create_multipart_upload(Bucket=m['audit']['bucket_name'],Key='operational/incomplete')
 l.client('cognito-idp').create_user_pool_domain(Domain=l.PREFIX+'-operations',UserPoolId=m['auth']['user_pool_id'])
 ec2=l.client('ec2')
 ec2.create_security_group(GroupName=l.PREFIX+'-operations',Description='Teardown verification',VpcId=m['network']['vpc_id'],TagSpecifications=[{'ResourceType':'security-group','Tags':tags}])
 ec2.create_route_table(VpcId=m['network']['vpc_id'],TagSpecifications=[{'ResourceType':'route-table','Tags':tags}])
 print('Operational teardown dependencies seeded')
else:
 state=l.state_resources();assert not any(r.get('mode')=='managed' and r.get('instances') for r in state)
 checks=[('ecs','list_clusters','clusterArns'),('ecs','list_task_definitions','taskDefinitionArns'),('rds','describe_db_instances','DBInstances'),('dynamodb','list_tables','TableNames'),('s3','list_buckets','Buckets'),('sqs','list_queues','QueueUrls'),('lambda','list_functions','Functions'),('scheduler','list_schedules','Schedules'),('cognito-idp','list_user_pools','UserPools'),('iam','list_roles','Roles'),('iam','list_instance_profiles','InstanceProfiles'),('iam','list_policies','Policies'),('elbv2','describe_load_balancers','LoadBalancers'),('elbv2','describe_target_groups','TargetGroups'),('elasticache','describe_replication_groups','ReplicationGroups'),('logs','describe_log_groups','logGroups')]
 for svc,op,key in checks:
  args={'MaxResults':60} if svc=='cognito-idp' else {'Scope':'Local'} if op=='list_policies' else {}
  rows=list(l.pages(svc,op,key,**args));assert all(l.PREFIX not in json.dumps(x,default=str) for x in rows),(svc,rows)
 for status in ['ACTIVE','INACTIVE']:
  assert all(l.PREFIX not in x for x in l.pages('ecs','list_task_definitions','taskDefinitionArns',status=status))
 for key in l.pages('kms','list_keys','Keys'):
  d=l.client('kms').describe_key(KeyId=key['KeyId'])['KeyMetadata']
  if d.get('Description','').startswith(l.PREFIX):assert d['KeyState']=='PendingDeletion'
 assert all(l.PREFIX not in x['AliasName'] for x in l.pages('kms','list_aliases','Aliases'))
 vpcs=list(l.pages('ec2','describe_vpcs','Vpcs'));assert len(vpcs)==1 and vpcs[0]['IsDefault']
 print('Teardown verified: empty managed state, no deployment resources, default VPC preserved, KMS deletion scheduled')
