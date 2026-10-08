#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://aws:4566}"
ROLE="${ROLE:-agent}"

wait_for_aws() {
  for _ in $(seq 1 90); do
    if aws --endpoint-url "${AWS_ENDPOINT_URL}" sts get-caller-identity >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "AWS control plane did not become ready at ${AWS_ENDPOINT_URL}" >&2
  return 1
}

GLOBAL_AWS_IP=""

register_host_dns() {
  local aws_ip helper_image cid containers_json
  if [[ ! -S /var/run/docker.sock ]]; then
    return 0
  fi
  containers_json="$(curl.real --unix-socket /var/run/docker.sock -fsS "http://localhost/containers/json" 2>/dev/null || echo "[]")"
  aws_ip="$(printf '%s' "${containers_json}" | jq -r '
    map(select((.Names // [] | any(test("aws"))) or (.Image // "" | test("floci"))))
    | .[0].NetworkSettings.Networks // {}
    | (to_entries | .[0].value.IPAddress) // empty
  ' 2>/dev/null || true)"
  if [[ -z "${aws_ip}" ]]; then
    aws_ip="$(getent hosts aws | awk 'NR==1 {print $1}' || true)"
  fi
  if [[ -z "${aws_ip}" ]]; then
    return 0
  fi
  GLOBAL_AWS_IP="${aws_ip}"
  helper_image="$(curl.real --unix-socket /var/run/docker.sock -fsS "http://localhost/containers/$(hostname)/json" 2>/dev/null | jq -r '.Image // empty' || true)"
  if [[ -z "${helper_image}" ]]; then
    helper_image="$(printf '%s' "${containers_json}" | jq -r '.[0].ImageID // empty' 2>/dev/null || true)"
  fi
  if [[ -z "${helper_image}" ]]; then
    return 0
  fi
  cid="$(curl.real --unix-socket /var/run/docker.sock -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "{\"Image\":\"${helper_image}\",\"Entrypoint\":[\"/bin/sh\",\"-c\",\"for f in /host/etc/hosts /host/var/lib/docker/containers/*/hosts; do if [ -f \\\"\\\$f\\\" ]; then grep -vE '[[:space:]]aws([[:space:]]|\\\$)' \\\"\\\$f\\\" > \\\"\\\${f}.tmp\\\" || true; printf '%s\\\\taws\\\\n' '${aws_ip}' >> \\\"\\\${f}.tmp\\\"; cat \\\"\\\${f}.tmp\\\" > \\\"\\\$f\\\"; rm -f \\\"\\\${f}.tmp\\\"; fi; done\"],\"HostConfig\":{\"Binds\":[\"/etc:/host/etc\",\"/var/lib/docker/containers:/host/var/lib/docker/containers\"]}}" \
    "http://localhost/containers/create" 2>/dev/null | jq -r '.Id // empty' || true)"
  if [[ -n "${cid}" ]]; then
    curl.real --unix-socket /var/run/docker.sock -fsS -X POST "http://localhost/containers/${cid}/start" >/dev/null 2>&1 || true
    curl.real --unix-socket /var/run/docker.sock -fsS -X POST "http://localhost/containers/${cid}/wait" >/dev/null 2>&1 || true
    curl.real --unix-socket /var/run/docker.sock -fsS -X DELETE "http://localhost/containers/${cid}?force=true" >/dev/null 2>&1 || true
  fi
}

build_runtime_image() {
  local name="$1"
  local bin_path="$2"
  local entrypoint="$3"
  local workdir
  workdir="$(mktemp -d)"

  mkdir -p "${workdir}/rootfs/usr/local/bin" \
           "${workdir}/rootfs/var/runtime" \
           "${workdir}/rootfs/app" \
           "${workdir}/rootfs/etc/ssl/certs" \
           "${workdir}/rootfs/tmp" \
           "${workdir}/rootfs/lib" \
           "${workdir}/rootfs/lib64" \
           "${workdir}/rootfs/usr/lib"
  chmod 1777 "${workdir}/rootfs/tmp"

  cp "${bin_path}" "${workdir}/rootfs${entrypoint}"
  chmod 0755 "${workdir}/rootfs${entrypoint}"
  cp /etc/ssl/certs/ca-certificates.crt "${workdir}/rootfs/etc/ssl/certs/ca-certificates.crt"
  [[ -f /etc/nsswitch.conf ]] && cp /etc/nsswitch.conf "${workdir}/rootfs/etc/nsswitch.conf"
  touch "${workdir}/rootfs/etc/hosts" "${workdir}/rootfs/etc/resolv.conf" "${workdir}/rootfs/etc/hostname"
  if [[ -n "${GLOBAL_AWS_IP}" ]]; then
    printf "127.0.0.1\tlocalhost\n%s\taws\n" "${GLOBAL_AWS_IP}" >"${workdir}/rootfs/etc/hosts"
  fi

  while read -r lib; do
    [[ -z "${lib}" ]] && continue
    mkdir -p "${workdir}/rootfs$(dirname "${lib}")"
    cp -L "${lib}" "${workdir}/rootfs${lib}"
  done < <(ldd "${bin_path}" | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}' | sort -u)

  for extra_lib in /lib/x86_64-linux-gnu/libnss_*.so* /lib/x86_64-linux-gnu/libresolv*.so* /usr/lib/x86_64-linux-gnu/libnss_*.so* /usr/lib/x86_64-linux-gnu/libresolv*.so*; do
    [[ -e "${extra_lib}" ]] || continue
    mkdir -p "${workdir}/rootfs$(dirname "${extra_lib}")"
    cp -L "${extra_lib}" "${workdir}/rootfs${extra_lib}"
  done

  tar -C "${workdir}/rootfs" -cf "${workdir}/layer.tar" .
  local diff_id
  diff_id="sha256:$(sha256sum "${workdir}/layer.tar" | awk '{print $1}')"

  local daemon_arch image_arch
  daemon_arch="$(curl.real --unix-socket /var/run/docker.sock -fsS "http://localhost/info" | jq -r '.Architecture // "x86_64"' || echo "x86_64")"
  case "${daemon_arch}" in
    aarch64|arm64)
      image_arch="arm64"
      ;;
    *)
      image_arch="amd64"
      ;;
  esac

  cat >"${workdir}/config.json" <<JSON
{
  "architecture": "${image_arch}",
  "os": "linux",
  "config": {
    "Entrypoint": ["${entrypoint}"],
    "ExposedPorts": {
      "8080/tcp": {}
    },
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
      "AWS_EC2_METADATA_DISABLED=true",
      "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}",
      "AWS_REGION=${AWS_REGION}",
      "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}",
      "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}",
      "AWS_ENDPOINT_URL=${AWS_ENDPOINT_URL}",
      "CLEARLEDGER_AWS_IP=${GLOBAL_AWS_IP}",
      "NO_PROXY=localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal",
      "no_proxy=localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
    ],
    "WorkingDir": "/"
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": ["${diff_id}"]
  },
  "history": [
    {
      "created": "2026-01-01T00:00:00Z",
      "created_by": "clearledger-runtime"
    }
  ]
}
JSON

  local config_hash
  config_hash="$(sha256sum "${workdir}/config.json" | awk '{print $1}')"
  mv "${workdir}/config.json" "${workdir}/${config_hash}.json"

  cat >"${workdir}/manifest.json" <<JSON
[
  {
    "Config": "${config_hash}.json",
    "RepoTags": ["${name}"],
    "Layers": ["layer.tar"]
  }
]
JSON

  tar -C "${workdir}" -cf "${workdir}/image.tar" "${config_hash}.json" layer.tar manifest.json
  curl.real --unix-socket /var/run/docker.sock -fsS -X POST \
    -H "Content-Type: application/x-tar" \
    --data-binary @"${workdir}/image.tar" \
    "http://localhost/images/load" >/dev/null

  rm -rf "${workdir}"
  echo "sha256:${config_hash}"
}

seed_baseline() {
  local prefix="$1"
  local base_prefix="cl-base-${prefix#cl-}"

  local bucket="${base_prefix}-keep"
  aws --endpoint-url "${AWS_ENDPOINT_URL}" s3api create-bucket --bucket "${bucket}" >/dev/null 2>&1 || true

  local queue_url
  queue_url="$(aws --endpoint-url "${AWS_ENDPOINT_URL}" sqs create-queue \
    --queue-name "${base_prefix}-keep-queue" \
    --attributes VisibilityTimeout=30 \
    --query 'QueueUrl' --output text)"

  local table_arn
  table_arn="$(aws --endpoint-url "${AWS_ENDPOINT_URL}" dynamodb create-table \
    --table-name "${base_prefix}-keep-table" \
    --attribute-definitions AttributeName=PK,AttributeType=S \
    --key-schema AttributeName=PK,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --query 'TableDescription.TableArn' --output text 2>/dev/null || \
    aws --endpoint-url "${AWS_ENDPOINT_URL}" dynamodb describe-table \
      --table-name "${base_prefix}-keep-table" \
      --query 'Table.TableArn' --output text)"

  local log_group="/clearledger/${base_prefix}/keep"
  aws --endpoint-url "${AWS_ENDPOINT_URL}" logs create-log-group --log-group-name "${log_group}" >/dev/null 2>&1 || true

  local role_arn
  role_arn="$(aws --endpoint-url "${AWS_ENDPOINT_URL}" iam create-role \
    --role-name "${base_prefix}-keep-role" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --query 'Role.Arn' --output text 2>/dev/null || \
    aws --endpoint-url "${AWS_ENDPOINT_URL}" iam get-role \
      --role-name "${base_prefix}-keep-role" \
      --query 'Role.Arn' --output text)"

  local key_arn
  key_arn="$(aws --endpoint-url "${AWS_ENDPOINT_URL}" kms create-key \
    --description "Baseline key ${base_prefix}" \
    --tags TagKey=ClearLedgerBaseline,TagValue=true \
    --query 'KeyMetadata.Arn' --output text)"

  local vpc_id
  vpc_id="$(aws --endpoint-url "${AWS_ENDPOINT_URL}" ec2 create-vpc \
    --cidr-block 10.250.0.0/24 \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${base_prefix}-keep-vpc},{Key=ClearLedgerBaseline,Value=true}]" \
    --query 'Vpc.VpcId' --output text)"

  cat >/tmp/baseline.json <<JSON
{
  "base_prefix": "${base_prefix}",
  "s3_bucket": "${bucket}",
  "sqs_queue_url": "${queue_url}",
  "dynamodb_table_name": "${base_prefix}-keep-table",
  "dynamodb_table_arn": "${table_arn}",
  "log_group_name": "${log_group}",
  "iam_role_name": "${base_prefix}-keep-role",
  "iam_role_arn": "${role_arn}",
  "kms_key_arn": "${key_arn}",
  "vpc_id": "${vpc_id}"
}
JSON
}

wait_for_aws
register_host_dns

tag_prefix="clearledger"
api_image="${tag_prefix}/api:1.0.0"
projector_image="${tag_prefix}/projector:1.0.0"
relay_image="${tag_prefix}/relay:1.0.0"
archiver_image="${tag_prefix}/archiver:1.0.0"

api_id="$(build_runtime_image "${api_image}" /opt/clearledger/bin/clearledger-api /usr/local/bin/clearledger-api)"
projector_id="$(build_runtime_image "${projector_image}" /opt/clearledger/bin/clearledger-projector /var/runtime/bootstrap)"
relay_id="$(build_runtime_image "${relay_image}" /opt/clearledger/bin/clearledger-outbox-relay /var/runtime/bootstrap)"
archiver_id="$(build_runtime_image "${archiver_image}" /opt/clearledger/bin/clearledger-audit-archiver /var/runtime/bootstrap)"

mkdir -p /workspace/contracts/schemas /workspace/config /workspace/submission/infra /workspace/evidence /logs/verifier
if [[ -d /opt/clearledger/contracts ]]; then
  rm -rf /workspace/contracts/*
  cp -R /opt/clearledger/contracts/. /workspace/contracts/
elif [[ -d /opt/clearledger/schemas ]]; then
  mkdir -p /workspace/contracts/schemas
  cp -R /opt/clearledger/schemas/. /workspace/contracts/schemas/
fi

prefix="cl-$(openssl rand -hex 3)"
password="Cl$(openssl rand -hex 5)!"

cat >/workspace/config/config.json <<JSON
{
  "resource_prefix": "${prefix}",
  "region": "${AWS_DEFAULT_REGION}",
  "aws_endpoint_url": "${AWS_ENDPOINT_URL}",
  "db_name": "clearledger",
  "db_username": "clearledger",
  "db_password": "${password}",
  "api_image": "${api_image}",
  "projector_image": "${projector_image}",
  "relay_image": "${relay_image}",
  "archiver_image": "${archiver_image}",
  "api_image_id": "${api_id}",
  "projector_image_id": "${projector_id}",
  "relay_image_id": "${relay_id}",
  "archiver_image_id": "${archiver_id}"
}
JSON

if [[ "${ROLE}" == "verifier" ]]; then
  seed_baseline "${prefix}"
  cp /tmp/baseline.json /workspace/config/.baseline.json
  chmod 0644 /workspace/config/.baseline.json
  chown -R 1001:1001 /workspace/contracts /workspace/config /workspace/submission /workspace/evidence /logs/verifier || true
else
  chown -R 1000:1000 /workspace/contracts /workspace/config /workspace/submission /workspace/evidence
  chown -R 1001:1001 /logs/verifier || true
fi
