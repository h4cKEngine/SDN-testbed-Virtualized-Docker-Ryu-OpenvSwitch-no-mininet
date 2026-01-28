FROM ubuntu:24.04
LABEL ovs="host - Ubuntu 24.04"

# 1. Install networking utilities (curl, ping, iproute2, tcpdump, etc.)
RUN apt-get update -y && apt-get upgrade -y && \
    apt-get install -y \
        iproute2 iptables iputils-ping arping bash netcat-openbsd util-linux telnet net-tools traceroute tcpdump jq curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Setup startup script
SHELL ["/bin/bash", "-c"]
COPY host.sh /host.sh
RUN chmod 755 /host.sh

ENTRYPOINT ["/host.sh"]
