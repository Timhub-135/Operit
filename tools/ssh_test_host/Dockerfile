# SSH test host for the Operit terminal's remote target.
#
# Base image is the requested plain ubuntu:latest; everything else is installed here so
# a test container is reproducible instead of hand-configured. APT is pointed at the
# Aliyun mirror because the default archive host is slow or unreachable from CN networks.
FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    sed -i 's|http://archive.ubuntu.com/ubuntu/|https://mirrors.aliyun.com/ubuntu/|g; s|http://security.ubuntu.com/ubuntu/|https://mirrors.aliyun.com/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        openssh-server \
        openssh-client \
        tmux \
        python3 \
        curl \
        rsync \
        procps \
        less \
        ncurses-term \
        ca-certificates \
        netcat-openbsd \
        sshpass \
        pandoc; \
    rm -rf /var/lib/apt/lists/*

# Test account used by the terminal tests. The password is intentionally obvious: this
# image only ever listens on a developer machine's published port.
ARG TEST_USER=operit
ARG TEST_PASSWORD=operit-test
RUN set -eux; \
    useradd -m -s /bin/bash "${TEST_USER}"; \
    echo "${TEST_USER}:${TEST_PASSWORD}" | chpasswd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 22 is the in-container sshd port; tests publish it as 2222 and reach it from the
# Android emulator through 10.0.2.2:2222.
#
# Package notes: ca-certificates is not part of the minimal ubuntu image, and without it
# every HTTPS request fails with `curl: (77) error setting certificate file` — which reads
# like a network outage during a verification run. netcat-openbsd and sshpass drive the
# tunnel checks; pandoc converts fetched papers to markdown on the target host.
EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
