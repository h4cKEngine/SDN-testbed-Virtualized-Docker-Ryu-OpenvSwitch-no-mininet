FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install OVS and networking tools
RUN apt-get update -y && apt-get upgrade -y && \
    apt-get install -y \
    openvswitch-switch iproute2 iptables iputils-ping arping bash netcat-openbsd telnet net-tools util-linux traceroute tcpdump jq curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create working directory and copy setup script
RUN mkdir -p /opt/router
COPY router-ovs.sh /opt/router/router-ovs.sh
RUN chmod +x /opt/router/router-ovs.sh

CMD ["/opt/router/router-ovs.sh"]
