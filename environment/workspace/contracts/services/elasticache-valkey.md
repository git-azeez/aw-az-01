# ElastiCache for Valkey (`services/elasticache-valkey.md`)

- Provision an ElastiCache subnet group (`aws_elasticache_subnet_group`) spanning the private subnets.
- Provision a Valkey 8 cache using `aws_elasticache_replication_group` (or `aws_elasticache_cluster`) with:
  - `replication_group_id` (or `cluster_id`) prefixed with `<resource_prefix>`
  - `engine = "valkey"` and `engine_version = "8.0"` (`engine = "redis"` is also accepted for provider compatibility)
  - `node_type = "cache.t4g.micro"`
  - `num_cache_clusters = 1` (or `num_cache_nodes = 1`)
  - `port = 6379`
  - `subnet_group_name` referencing the ElastiCache subnet group
  - `security_group_ids` containing the `valkey` security group
  - In-transit and at-rest encryption (`transit_encryption_enabled`, `at_rest_encryption_enabled`) are not required; cache connections use plain `redis://<endpoint>:<port>` inside the private VPC.
- Pass `redis://<endpoint>:<port>` as `VALKEY_URL` to both the API service and the Projector Lambda, and set `CACHE_TTL_SECONDS = "90"` on the API container.
