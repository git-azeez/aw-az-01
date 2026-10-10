# ElastiCache for Valkey (`services/elasticache-valkey.md`)

- Provision an ElastiCache subnet group (`aws_elasticache_subnet_group`) spanning the private subnets.
- Provision a Valkey 8 cache using `aws_elasticache_replication_group` with:
  - `replication_group_id` prefixed with `<resource_prefix>`
  - `engine = "valkey"` and `engine_version = "8.0"` (`engine = "redis"` is also accepted for provider compatibility)
  - `node_type = "cache.t4g.micro"`
  - `num_cache_clusters = 1`
  - `port = 6379`
  - `subnet_group_name` referencing the ElastiCache subnet group
  - `security_group_ids` containing the `valkey` security group
  - Explicitly set `transit_encryption_enabled = false` and `at_rest_encryption_enabled = false` on `aws_elasticache_replication_group`; cache connections use plain `redis://<endpoint>:<port>` inside the private VPC.
- Pass `redis://<endpoint>:<port>` as `VALKEY_URL` to both the API service and the Projector Lambda, and set `CACHE_TTL_SECONDS = "90"` on the API container.
- During `deploy.sh` data-plane convergence, reconcile the Valkey instance against `clearledger.settlements` (and the converged DynamoDB `STATE` projection) so that Valkey contains **only** `clearledger:settlement:<settlement_id>` keys for settlements present in `clearledger.settlements` (purging any orphan settlement keys as well as any stray keys outside the `clearledger:settlement:<settlement_id>` namespace), and every settlement in `clearledger.settlements` is actively populated in Valkey at `clearledger:settlement:<settlement_id>` with a valid TTL in `(0, 90]` and a canonical `SettlementProjection` JSON payload matching the DynamoDB `STATE` projection (so `GET /v1/settlements/{id}` immediately after `deploy.sh` hits cache and returns `X-ClearLedger-Source: cache` with the exact same payload as a DynamoDB projection read).

