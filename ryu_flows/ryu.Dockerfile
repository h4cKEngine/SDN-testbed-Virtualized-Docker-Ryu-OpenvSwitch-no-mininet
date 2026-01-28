FROM python:3.9-slim
LABEL ovs="Ryu image for SDN - python3.9"

# 1. System dependencies
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        iproute2 iptables iputils-ping arping git bash netcat-openbsd telnet \
        net-tools traceroute tcpdump jq curl python3-pip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Non-root user to run Ryu
RUN groupadd -r useryu && \
    useradd  -r -g useryu -m -d /home/useryu -s /bin/bash useryu

# 3. Switch to useryu and update PATH
USER useryu
WORKDIR /home/useryu
ENV PATH="/home/useryu/.local/bin:$PATH"

# 4. Install ryu in user environment (~/.local)
RUN pip3 install --upgrade pip && \
    pip install setuptools==58.0.4 && \
    git clone https://github.com/faucetsdn/ryu.git && \
    cd ryu && pip install . && \
    pip cache purge

# 5. Copy custom app inside Ryu
COPY --chown=useryu:useryu .  /home/useryu/.local/lib/python3.9/site-packages/ryu/app/ryu_flows

# 6. Expose ports and start Ryu
EXPOSE 6633 6640 6653 8080

ENTRYPOINT [ "ryu-manager", "--observe-links", "--ofp-tcp-listen-port", "6653", \
    "ryu.app.ofctl_rest", "ryu.app.rest_topology", "ryu.app.rest_router", "ryu.app.ryu_flows.ryu_flows" ]