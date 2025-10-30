FROM ubuntu:24.04
LABEL ovs="Open vSwitch image for SDN - Ubuntu 24.04"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && apt-get upgrade -y && \
    apt-get install -y \
    openvswitch-switch iproute2 iptables iputils-ping arping bash netcat-openbsd telnet net-tools util-linux traceroute tcpdump jq curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

RUN echo "net.ipv4.ip_forward=0" >> /etc/sysctl.conf && \
    echo "net.ipv6.ip_forward=0" >> /etc/sysctl.conf

SHELL ["/bin/bash", "-c"]
COPY ovs.sh /
RUN chmod 755 /ovs.sh

ENTRYPOINT ["/ovs.sh"]
