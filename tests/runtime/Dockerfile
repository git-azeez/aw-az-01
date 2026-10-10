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
    NO_PROXY=localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal \
    no_proxy=localhost,127.0.0.1,::1,aws,floci,runtime,.amazonaws.com,.elb.amazonaws.com,.local,.internal \
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

RUN python3 -m venv --system-site-packages /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir \
      awscli==1.38.1 \
      boto3==1.37.1 \
      httpx==0.28.1 \
      jsonschema==4.23.0 \
      "psycopg[binary]==3.2.6" \
      psycopg2-binary==2.9.10 \
      pytest==8.3.5 \
      pyyaml==6.0.2 \
      redis==5.2.1 \
      requests==2.32.3 && \
    ln -sf /opt/venv/bin/aws /usr/local/bin/aws && \
    sed -i 's|PATH="/usr/local/bin:|PATH="/opt/venv/bin:/usr/local/bin:|g; s|PATH="/usr/local/sbin:|PATH="/opt/venv/bin:/usr/local/sbin:|g' /etc/profile && \
    printf '%s\n' \
      'export PATH="/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"' \
      'export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"' \
      'export AWS_REGION="${AWS_REGION:-us-east-1}"' \
      'export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"' \
      'export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"' \
      'export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://aws:4566}"' \
      'export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"' \
      'export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-1}"' \
      'export TF_CLI_CONFIG_FILE="${TF_CLI_CONFIG_FILE:-/etc/terraform.tfrc}"' \
      >/etc/profile.d/00-venv.sh && \
    chmod +x /etc/profile.d/00-venv.sh && \
    printf '\n. /etc/profile.d/00-venv.sh\n' >>/etc/bash.bashrc && \
    printf '\n. /etc/profile.d/00-venv.sh\n' >>/root/.bashrc && \
    printf '\n. /etc/profile.d/00-venv.sh\n' >>/root/.profile

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

RUN userdel -r node 2>/dev/null || true && \
    useradd -m -u 1000 -s /bin/bash agent && \
    useradd -o -u 0 -g 0 -M -d /root -s /bin/bash verifier

COPY --from=rust-builder /out /opt/clearledger/bin
COPY runtime/manifest.schema.json runtime/events.schema.json /opt/clearledger/contracts/schemas/
COPY runtime/manifest.schema.json runtime/events.schema.json /opt/clearledger/schemas/
COPY runtime/runtime.sh /opt/clearledger/runtime.sh
COPY test.sh /tests/test.sh
COPY suite /tests/suite
RUN chmod +x /opt/clearledger/runtime.sh /opt/clearledger/bin/* /tests/test.sh && \
    mkdir -p /workspace/contracts/schemas /workspace/config /workspace/submission/infra /workspace/evidence /logs/verifier && \
    cp -R /opt/clearledger/contracts/. /workspace/contracts/ && \
    chown -R root:root /opt/clearledger && \
    chmod -R 0700 /opt/clearledger && \
    chmod -R 777 /workspace /logs/verifier

WORKDIR /workspace
USER verifier
