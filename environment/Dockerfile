# syntax=docker/dockerfile:1.7

FROM --platform=linux/amd64 mirror.gcr.io/library/rust:1.88.0-bookworm@sha256:af306cfa71d987911a781c37b59d7d67d934f49684058f96cf72079c3626bfe0 AS rust-builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang \
      cmake \
      make \
      perl \
      pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/application
COPY application/Cargo.toml application/Cargo.lock ./
COPY application/crates ./crates
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/application/target,sharing=locked \
    cargo build --release --workspace --bins && \
    mkdir -p /out && \
    cp target/release/clearledger-api \
       target/release/clearledger-projector \
       target/release/clearledger-outbox-relay \
       target/release/clearledger-audit-archiver \
       /out/

FROM --platform=linux/amd64 mirror.gcr.io/library/node:24-bookworm-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d AS main
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    AWS_DEFAULT_REGION=us-east-1 \
    AWS_REGION=us-east-1 \
    AWS_ACCESS_KEY_ID=test \
    AWS_SECRET_ACCESS_KEY=test \
    AWS_ENDPOINT_URL=http://aws:4566 \
    AWS_EC2_METADATA_DISABLED=true \
    TF_IN_AUTOMATION=1 \
    TF_CLI_CONFIG_FILE=/etc/terraform.tfrc

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      fd-find \
      git \
      iproute2 \
      jq \
      less \
      netcat-openbsd \
      openssl \
      patch \
      postgresql-client \
      procps \
      psmisc \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      tar \
      unzip \
      vim-tiny \
      wget \
      xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/curl /usr/bin/curl.real

RUN npm install -g opencode-ai@1.17.8

RUN curl -fsSL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip \
      -o /tmp/terraform.zip && \
    unzip -q /tmp/terraform.zip terraform -d /usr/local/bin && \
    chmod +x /usr/local/bin/terraform && \
    rm -f /tmp/terraform.zip

RUN curl -fsSL https://github.com/opentofu/opentofu/releases/download/v1.8.4/tofu_1.8.4_linux_amd64.zip \
      -o /tmp/tofu.zip && \
    unzip -q /tmp/tofu.zip tofu -d /usr/local/bin && \
    chmod +x /usr/local/bin/tofu && \
    rm -f /tmp/tofu.zip

RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir \
      awscli==1.38.1 \
      boto3==1.37.1 \
      httpx==0.28.1 \
      jsonschema==4.23.0 \
      "psycopg[binary]==3.2.6" \
      pytest==8.3.5 \
      pyyaml==6.0.2 \
      redis==5.2.1 \
      "litellm<1.92" \
      mini-swe-agent

RUN terraform -version && tofu version && aws --version && psql --version

RUN mkdir -p /opt/Terraform/cache/registry.terraform.io/hashicorp/aws/6.51.0/linux_amd64 && \
    curl -fsSL https://releases.hashicorp.com/terraform-provider-aws/6.51.0/terraform-provider-aws_6.51.0_linux_amd64.zip \
      -o /tmp/provider.zip && \
    unzip -q /tmp/provider.zip -d /opt/Terraform/cache/registry.terraform.io/hashicorp/aws/6.51.0/linux_amd64 && \
    ln -sfn /opt/Terraform/cache/registry.terraform.io /opt/Terraform/cache/registry.opentofu.org && \
    chmod -R a+rX /opt/Terraform/cache && \
    rm -f /tmp/provider.zip

RUN cat <<'EOF' >/etc/terraform.tfrc
provider_installation {
  filesystem_mirror {
    path    = "/opt/Terraform/cache"
    include = ["registry.terraform.io/hashicorp/*", "registry.opentofu.org/hashicorp/*"]
  }
  direct {
    exclude = ["registry.terraform.io/hashicorp/*", "registry.opentofu.org/hashicorp/*"]
  }
}
disable_checkpoint = true
EOF

RUN mv /usr/local/bin/terraform /usr/local/bin/terraform.real && \
    cat <<'EOF' >/usr/local/bin/terraform && chmod +x /usr/local/bin/terraform
#!/usr/bin/env bash
unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
exec /usr/local/bin/terraform.real "$@"
EOF

RUN mv /usr/local/bin/tofu /usr/local/bin/tofu.real && \
    cat <<'EOF' >/usr/local/bin/tofu && chmod +x /usr/local/bin/tofu
#!/usr/bin/env bash
unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
exec /usr/local/bin/tofu.real "$@"
EOF

RUN cat <<'EOF' >/opt/venv/bin/curl && chmod +x /opt/venv/bin/curl
#!/usr/bin/env bash
[[ "$*" == *"nvm-sh/nvm"* ]] && { echo "true"; exit 0; }
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
export no_proxy="${no_proxy:+${no_proxy},}localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal"
nc -z -w 1 172.20.0.1 18080 >/dev/null 2>&1 || unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
[[ -n "${CURL_CA_BUNDLE:-}" && -f "${CURL_CA_BUNDLE:-}" && -s "${CURL_CA_BUNDLE:-}" ]] || export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
exec /usr/bin/curl "$@"
EOF

RUN mv /opt/venv/bin/mini-swe-agent /opt/venv/bin/mini-swe-agent.real && \
    cat <<'EOF' >/opt/venv/bin/mini-swe-agent && chmod +x /opt/venv/bin/mini-swe-agent
#!/usr/bin/env bash
nc -z -w 1 172.20.0.1 18080 >/dev/null 2>&1 || unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
[[ -n "${SSL_CERT_FILE:-}" && -f "${SSL_CERT_FILE:-}" && -s "${SSL_CERT_FILE:-}" ]] || { export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt; unset NODE_EXTRA_CA_CERTS; }
cleanup_children() {
  pkill -9 -f "mini-swe-agent.real|terraform-provider|terraform.real|tofu.real" >/dev/null 2>&1 || true
  exec >/dev/null 2>&1
}
trap cleanup_children EXIT
timeout -k 15 1800 /opt/venv/bin/mini-swe-agent.real "$@"
exit 0
EOF

RUN cat <<'EOF' >/opt/venv/bin/uv && chmod +x /opt/venv/bin/uv
#!/usr/bin/env bash
mkdir -p "${HOME:-/home/agent}/.local/bin"
ln -sf /opt/venv/bin/mini-swe-agent "${HOME:-/home/agent}/.local/bin/mini-swe-agent"
exit 0
EOF

RUN cat <<'EOF' >/opt/venv/bin/npm && chmod +x /opt/venv/bin/npm
#!/usr/bin/env bash
[[ "$*" == *" -g "* && -x /usr/local/bin/opencode ]] && exit 0
nc -z -w 1 172.20.0.1 18080 >/dev/null 2>&1 || unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
exec /usr/local/bin/npm "$@"
EOF

RUN cat <<'EOF' >/opt/venv/bin/apt-get && chmod +x /opt/venv/bin/apt-get
#!/usr/bin/env bash
[[ "$(id -u)" != "0" || "$*" == *"curl"* ]] && exit 0
exec /usr/bin/apt-get "$@"
EOF

RUN cat <<'EOF' >/opt/venv/bin/opencode && chmod +x /opt/venv/bin/opencode
#!/usr/bin/env bash
nc -z -w 1 172.20.0.1 18080 >/dev/null 2>&1 || unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
[[ -n "${SSL_CERT_FILE:-}" && -f "${SSL_CERT_FILE:-}" && -s "${SSL_CERT_FILE:-}" ]] || { export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt; unset NODE_EXTRA_CA_CERTS; }
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" || "${1:-}" == "version" ]]; then
  exec /usr/local/bin/opencode "$@"
fi
export AWS_EC2_METADATA_DISABLED=true
cleanup_children() {
  pkill -9 -f "opencode-linux|/usr/local/bin/opencode|terraform-provider|terraform.real|tofu.real" >/dev/null 2>&1 || true
  exec >/dev/null 2>&1
}
trap cleanup_children EXIT
DEADLINE=$(( $(date +%s) + 1800 ))
MODEL_ARG="openrouter/z-ai/glm-5.2"
for arg in "$@"; do
  case "$arg" in
    --model=*) MODEL_ARG="${arg#--model=}" ;;
  esac
done
run_with_idle_watchdog() {
  local rem=$(( DEADLINE - $(date +%s) ))
  if (( rem <= 15 )); then
    return 0
  fi
  timeout -k 10 "$rem" /usr/local/bin/opencode "$@" &
  local pid=$!
  local last_size=-1
  local idle_secs=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    if (( $(date +%s) >= DEADLINE )); then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -f "opencode-linux|/usr/local/bin/opencode" >/dev/null 2>&1 || true
      return 124
    fi
    local cur_size=0
    if [[ -f /logs/agent/opencode.txt ]]; then
      cur_size=$(stat -c%s /logs/agent/opencode.txt 2>/dev/null || echo 0)
    fi
    if [[ "$cur_size" == "$last_size" ]]; then
      idle_secs=$(( idle_secs + 5 ))
    else
      last_size="$cur_size"
      idle_secs=0
    fi
    if (( idle_secs >= 240 )); then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -f "opencode-linux|/usr/local/bin/opencode" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
      return 125
    fi
  done
  wait "$pid" 2>/dev/null || return $?
  return 0
}
run_with_idle_watchdog "$@"
rc=$?
for attempt in 1 2; do
  if (( rc == 125 && $(date +%s) + 60 < DEADLINE )); then
    run_with_idle_watchdog --model="$MODEL_ARG" run --format=json --continue \
      "The previous stream stalled. Check current workspace/submission state and finish any remaining verification steps."
    rc=$?
  else
    break
  fi
done
exit 0
EOF

RUN userdel -r node 2>/dev/null || true && \
    useradd -m -u 1000 -s /bin/bash agent && \
    useradd -m -u 1001 -s /bin/bash verifier && \
    mkdir -p /home/agent/.nvm /root/.nvm && \
    printf '%s\n' 'nvm() { return 0; }' 'export -f nvm' >/home/agent/.nvm/nvm.sh && \
    printf '%s\n' 'nvm() { return 0; }' 'export -f nvm' >/root/.nvm/nvm.sh && \
    chmod +x /home/agent/.nvm/nvm.sh /root/.nvm/nvm.sh && \
    chown -R agent:agent /home/agent

COPY --from=rust-builder /out /opt/clearledger/bin
COPY workspace/contracts /opt/clearledger/contracts
COPY runtime.sh /opt/clearledger/runtime.sh
RUN chmod +x /opt/clearledger/runtime.sh /opt/clearledger/bin/* && \
    mkdir -p /workspace/contracts /workspace/config /workspace/submission/infra /workspace/evidence /logs/agent /logs/verifier && \
    cp -R /opt/clearledger/contracts/. /workspace/contracts/ && \
    chown -R root:root /opt/clearledger && \
    chmod -R 0700 /opt/clearledger && \
    chown -R agent:agent /workspace /logs/agent && \
    chown -R verifier:verifier /logs/verifier

WORKDIR /workspace
USER agent
