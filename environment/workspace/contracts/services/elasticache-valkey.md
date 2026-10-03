# ElastiCache for Valkey (`services/elasticache-valkey.md`)

- Provision an ElastiCache subnet group (`aws_elasticache_subnet_group`) spanning the private subnets.
- Provision a Valkey cache cluster (`aws_elasticache_cluster`) with:
  - `engine = "redis"` (Terraform `aws_elasticache_cluster` uses `"redis"` for the Valkey/Redis engine)
  - `node_type = "cache.t4g.micro"`
  - `num_cache_nodes = 1`
  - `port = 6379`
  - `security_group_ids` containing the `valkey` security group
- Pass `redis://<endpoint>:<port>` as `VALKEY_URL` to both the API service and the Projector Lambda, and set `CACHE_TTL_SECONDS = "90"` on the API container.
