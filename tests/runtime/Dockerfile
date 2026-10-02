# syntax=docker/dockerfile:1.7

FROM rust:1.86-bookworm@sha256:300ec56abce8cc9448ddea2172747d048ed902a3090e6b57babb2bf19f754081 AS rust-builder
WORKDIR /src/application
COPY application/Cargo.toml application/Cargo.lock ./
COPY application/crates ./crates
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/application/target \
    cargo build --release --locked --bins && \
    mkdir -p /out && \
    cp target/release/clearledger-api \
       target/release/clearledger-projector \
       target/release/clearledger-outbox-relay \
       target/release/clearledger-audit-archiver \
       /out/

FROM hashicorp/terraform:1.9.8@sha256:18f9986038bbaf02cf49db9c09261c778161c51dcc7fb7e355ae8938459428cd AS terraform-cli

FROM python:3.12-slim-bookworm@sha256:54c85f3c47607a77f32adec749d3c81d1348bf25833671f512b26a9b6d778cb3 AS main
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
      skopeo \
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

RUN useradd -m -u 1000 -s /bin/bash agent && \
    useradd -m -u 1001 -s /bin/bash verifier

COPY --from=rust-builder /out /opt/clearledger/bin
COPY runtime/manifest.schema.json runtime/events.schema.json /opt/clearledger/schemas/
COPY runtime/runtime.sh /opt/clearledger/runtime.sh
RUN chmod +x /opt/clearledger/runtime.sh /opt/clearledger/bin/*

RUN mkdir -p /workspace/contracts/schemas /workspace/config /workspace/submission/infra /workspace/evidence /logs/verifier && \
    cp -R /opt/clearledger/schemas/. /workspace/contracts/schemas/ && \
    chown -R agent:agent /workspace && \
    chown -R verifier:verifier /logs/verifier

WORKDIR /workspace
USER verifier
