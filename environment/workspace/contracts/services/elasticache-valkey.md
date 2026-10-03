# ElastiCache for Valkey (`services/elasticache-valkey.md`)

- Provision an ElastiCache subnet group (`aws_elasticache_subnet_group`) spanning the private subnets.
- Provision a Valkey cache using `aws_elasticache_replication_group` (as `CreateReplicationGroup` is used for Redis/Valkey engines) with:
  - `replication_group_id` prefixed with `<resource_prefix>`
  - `engine = "redis"` (or `"valkey"`)
  - `node_type = "cache.t4g.micro"`
  - `num_cache_clusters = 1`
  - `port = 6379`
  - `subnet_group_name` referencing the ElastiCache subnet group
  - `security_group_ids` containing the `valkey` security group
- Pass `redis://<endpoint>:<port>` as `VALKEY_URL` to both the API service and the Projector Lambda, and set `CACHE_TTL_SECONDS = "90"` on the API container.
