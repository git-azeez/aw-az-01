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
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/application/target \
    cargo build --release --workspace --bins && \
    mkdir -p /out && \
    cp target/release/clearledger-api \
       target/release/clearledger-projector \
       target/release/clearledger-outbox-relay \
       target/release/clearledger-audit-archiver \
       /out/

FROM --platform=linux/amd64 hashicorp/terraform:1.9.8@sha256:18f9986038bbaf02cf49db9c09261c778161c51dcc7fb7e355ae8938459428cd AS terraform-cli

FROM --platform=linux/amd64 mirror.gcr.io/library/python:3.12.11-slim-bookworm@sha256:54fd2da9fc88eed6ef2ef3fa6fdeeb8fd9fad2bd3ce8fb3ac0db32a85f10c0f9 AS main
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AWS_DEFAULT_REGION=us-east-1 \
    AWS_REGION=us-east-1 \
    AWS_ACCESS_KEY_ID=test \
    AWS_SECRET_ACCESS_KEY=test \
    AWS_ENDPOINT_URL=http://aws:4566 \
    TF_IN_AUTOMATION=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      iproute2 \
      jq \
      less \
      netcat-openbsd \
      openssl \
      postgresql-client \
      procps \
      ripgrep \
      tar \
      unzip \
      vim-tiny \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY --from=terraform-cli /bin/terraform /usr/local/bin/terraform

RUN curl -fsSL https://github.com/opentofu/opentofu/releases/download/v1.8.4/tofu_1.8.4_linux_amd64.zip \
      -o /tmp/tofu.zip && \
    unzip -q /tmp/tofu.zip tofu -d /usr/local/bin && \
    chmod +x /usr/local/bin/tofu && \
    rm -f /tmp/tofu.zip

RUN pip install --no-cache-dir \
      awscli==1.38.1 \
      boto3==1.37.1 \
      httpx==0.28.1 \
      jsonschema==4.23.0 \
      psycopg[binary]==3.2.6 \
      pytest==8.3.5 \
      pyyaml==6.0.2 \
      redis==5.2.1

RUN terraform -version && tofu version && aws --version && psql --version

RUN mkdir -p /opt/Terraform/cache/registry.terraform.io/hashicorp/aws/6.51.0/linux_amd64 && \
    curl -fsSL https://releases.hashicorp.com/terraform-provider-aws/6.51.0/terraform-provider-aws_6.51.0_linux_amd64.zip \
      -o /tmp/provider.zip && \
    unzip -q /tmp/provider.zip -d /opt/Terraform/cache/registry.terraform.io/hashicorp/aws/6.51.0/linux_amd64 && \
    chmod -R a+rX /opt/Terraform/cache && \
    rm -f /tmp/provider.zip

RUN cat <<'EOF' >/etc/terraform.tfrc
provider_installation {
  filesystem_mirror {
    path    = "/opt/Terraform/cache"
    include = ["registry.terraform.io/hashicorp/*"]
  }
  direct {
    exclude = ["registry.terraform.io/hashicorp/*"]
  }
}
disable_checkpoint = true
EOF

ENV TF_CLI_CONFIG_FILE=/etc/terraform.tfrc

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

RUN mv /usr/bin/curl /usr/bin/curl.real && \
    cat <<'EOF' >/usr/bin/curl && chmod +x /usr/bin/curl
#!/usr/bin/env bash
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}localhost,127.0.0.1,::1,aws,runtime,.amazonaws.com,.elb.amazonaws.com,.local"
export no_proxy="${no_proxy:+${no_proxy},}localhost,127.0.0.1,::1,aws,runtime,.amazonaws.com,.elb.amazonaws.com,.local"
if ! nc -z -w 1 172.20.0.1 18080 >/dev/null 2>&1; then
  unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
fi
if [[ ! -f "${CURL_CA_BUNDLE:-/etc/daytona-netleash-ca.crt}" ]] || [[ ! -s "${CURL_CA_BUNDLE:-/etc/daytona-netleash-ca.crt}" ]]; then
  export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
fi
exec /usr/bin/curl.real "$@"
EOF

RUN useradd -m -u 1000 -s /bin/bash agent && \
    useradd -m -u 1001 -s /bin/bash verifier

COPY --from=rust-builder /out /opt/clearledger/bin
COPY runtime/manifest.schema.json runtime/events.schema.json /opt/clearledger/schemas/
COPY runtime/runtime.sh /opt/clearledger/runtime.sh
COPY test.sh /tests/test.sh
COPY suite /tests/suite
RUN chmod +x /opt/clearledger/runtime.sh /opt/clearledger/bin/* /tests/test.sh && \
    chown -R verifier:verifier /tests

RUN mkdir -p /workspace/contracts/schemas /workspace/config /workspace/submission/infra /workspace/evidence /logs/verifier && \
    cp -R /opt/clearledger/schemas/. /workspace/contracts/schemas/ && \
    chown -R verifier:verifier /workspace /logs/verifier

WORKDIR /workspace
USER verifier
