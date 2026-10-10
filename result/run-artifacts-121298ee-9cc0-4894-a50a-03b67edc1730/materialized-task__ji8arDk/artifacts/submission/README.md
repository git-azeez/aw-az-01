# ClearLedger infrastructure

```sh
/workspace/submission/deploy.sh
/workspace/submission/destroy.sh
```

Inputs are loaded from `/workspace/config/config.json` on every invocation.
Terraform resources and policies are in `infra/`; local state is
`infra/terraform.tfstate`. `manifest.json` is generated and schema-validated.
The scripts use the installed Terraform, Python AWS/PostgreSQL/Redis clients,
`jq`, and `flock`.

Deployment performs two declarative apply passes, atomic PostgreSQL schema
repair, worker invocation, readiness polling, and bidirectional reconciliation.
During reconciliation, consumers and schedules are temporarily suspended and
PostgreSQL writes are fenced while reads remain available. Committed events
drive exact projection replay, canonical audit coverage/version cleanup, and
API-backed cache warming with a 90-second TTL. Consumers and schedules are
restored even if reconciliation fails; a subsequent deployment repairs an
interrupted run. Durable resource replacement is rejected before apply.

Teardown stops producers, removes versioned objects and scoped out-of-band
resources, and empties Terraform state. Baseline `cl-base-*` resources are
excluded from cleanup. KMS uses the required AWS ten-day deletion window;
a subsequent deployment can re-adopt and enable its canonical scheduled keys.

`verify_recovery.py` is an opt-in destructive drift drill for a deployment
containing a test settlement. It verifies queue/mapping recreation, schema,
IAM/security/KMS repair, projection/cache/archive convergence, and preservation
of durable identities and committed events. Application images are unchanged.
