# ElastiCache for Valkey (`services/elasticache-valkey.md`)

- Provision an ElastiCache subnet group (`aws_elasticache_subnet_group`) spanning the private subnets.
- Provision a Valkey cluster (`aws_elasticache_cluster`) with:
  - `engine = "valkey"`
  - `engine_version = "8.0"` (or `8.*`)
  - `node_type = "cache.t4g.micro"`
  - `num_cache_nodes = 1`
  - `port = 6379`
  - `security_group_ids` containing the `valkey` security group
- Pass `redis://<endpoint>:<port>` as `VALKEY_URL` to both the API service and the Projector Lambda, and set `CACHE_TTL_SECONDS = "90"` on the API container.
