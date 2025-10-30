FROM python:3.9-slim
LABEL ovs="Ryu image for SDN - python3.9"

# 1. Dipendenze di sistema
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        iproute2 iptables iputils-ping arping git bash netcat-openbsd telnet \
        net-tools traceroute tcpdump jq curl python3-pip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Utente non-root per eseguire Ryu
RUN groupadd -r useryu && \
    useradd  -r -g useryu -m -d /home/useryu -s /bin/bash useryu

# 3. Switcha a useryu e aggiorna il PATH
USER useryu
WORKDIR /home/useryu
ENV PATH="/home/useryu/.local/bin:$PATH"

# 4. Installa ryu nell'ambiente utente (~/.local)
RUN pip3 install --upgrade pip && \
    pip install setuptools==58.0.4 && \
    git clone https://github.com/faucetsdn/ryu.git && \
    cd ryu && pip install . && \
    pip cache purge

# 5. Copia l'app custom dentro a Ryu
COPY --chown=useryu:useryu .  /home/useryu/.local/lib/python3.9/site-packages/ryu/app/ryu_flows

# 6. Esponne le porte e avvia Ryu
EXPOSE 6633 6640 6653 8080

ENTRYPOINT [ "ryu-manager", "--observe-links", "--ofp-tcp-listen-port", "6653", \
    "ryu.app.ofctl_rest", "ryu.app.rest_topology", "ryu.app.rest_router", "ryu.app.ryu_flows.ryu_flows" ]