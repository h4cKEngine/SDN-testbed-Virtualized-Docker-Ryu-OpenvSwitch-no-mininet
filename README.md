# SDN Multi-Node Simulator with Ryu, Docker, VXLAN Topology and Web UI

This project simulates a **Software Defined Network (SDN)** using **Docker containers** as hosts and **Open vSwitch (OVS)** switches, orchestrated by a **custom Ryu controller**.  
A **web interface** is included for visualizing the topology and interacting via REST APIs.

---

## 1. Overview

The project provides a distributed SDN environment with Ryu as the control plane and OVS as the data plane.  
Routers and switches run inside Docker containers, interconnected via VXLAN tunnels, allowing multi-node simulations over physical or virtual machines.

---

## 2. Operating Logic

The system builds a **distributed SDN infrastructure** using **Open vSwitch** and a **custom Ryu controller**.

Main components:

* **L3 routing** handled by Ryu’s module `ryu.app.rest_router`.
* **Automatic datapath classification** (router vs access switch).
* **Router port detection** for key interfaces (`routerX-link`, `vxlan0`).
* **Idempotent bootstrap** through REST calls to `rest_router` for configuring L3 interfaces and static routes.
* **IP↔IP policy enforcement**, where only pairs defined in `allowed_pairs` can communicate.
* **L2 learning** enabled only on OVS (routers don’t handle ARP/IP manually).

The controller focuses on automation and policy enforcement, delegating routing logic to `rest_router`.

---

## 3. Quick Start

### Requirements

** IMPORTANT **
!!! Install Docker with root privileges !!!
   ```bash
   curl -fsSL https://get.docker.com -o get-docker.sh
   sudo sh ./get-docker.sh
   ```

- Docker Engine ≥ 20.x  
- Docker Compose v2  
- Python ≥ 3.8  (default 3.9)
- Ryu Framework (installed within controller container with RyuFlows custom app)

### Launching the Simulation
**Docker Swarm Setup:**  
Before launching the topology, you must initialize the control network and Docker Swarm on the controller node:

1. Start the control network and controller:
   ```bash
   cd ryu_flows/
   sudo ./control-net.sh
   ```

2. After the controller starts, copy the **Docker Swarm join token** displayed in the terminal.  
   This token will be required by all worker nodes (e.g., Node A, Node B) to join the Swarm network.

3. On each worker node, join the Swarm copying the token into topology-veth/topology.sh in CONTROLLER_SWARM_JOIN_TOKEN:
   ```bash
   CONTROLLER_SWARM_JOIN_TOKEN="<SWMTKN-1-TOKEN>"
   ```

This step is required to enable inter-node communication through the VXLAN overlay network.


#### Node A
```bash
cd topology-veth/
sudo ./topology.sh 1
```

#### Node B
```bash
cd topology-veth/
sudo ./topology.sh 2
```

When the startup completes:
* Routers and switches register automatically to the controller.
* Interfaces and static routes are configured.
* Default policy enables communication only for predefined IP pairs.

To clean up the environment:
```bash
sudo ./cleanup_docker.sh
```

---

## 4. REST API Usage

The Ryu controller exposes a REST API for managing allowed IP pairs.

**Add a pair:**
```bash
curl -X POST -H "Content-Type: application/json"      -d '{"src":"10.0.1.2","dst":"10.0.2.2"}'      http://<controller-ip>:8080/pair
```

**Remove a pair:**
```bash
curl -X DELETE -H "Content-Type: application/json"      -d '{"src":"10.0.1.2","dst":"10.0.2.2"}'      http://<controller-ip>:8080/pair
```

**List all pairs:**
```bash
curl http://<controller-ip>:8080/pairs | jq .
```

**Access the Web UI:**
```
http://<controller-ip>:8080/ryuflows/index.html
```

---

## 5. Project Structure

```
multi-node/
│
├── ryu_flows/                     # Ryu controller and REST APIs
│   ├── webpages/                  # Web interface (HTML/JS/CSS)
│   ├── control-net.sh             # Control network + controller startup
│   ├── docker-compose.yml         # Controller container definition
│   ├── ryu_api.py                 # REST API and static web server
│   ├── ryu_flows.py               # Main controller
│   ├── ryu_helpers.py             # Helper utilities
│   └── ryu.Dockerfile             # Ryu controller image
│
├── topology-veth/                 # Network topology scripts
│   ├── router/                    # Router components
│   │   ├── router_vxlan.sh
│   │   ├── router-ovs.sh
│   │   └── router.Dockerfile
│   ├── host.sh                    # Host setup
│   ├── ovs.sh                     # OVS setup
│   ├── topology.sh                # Topology launcher
│   ├── host.Dockerfile            # Host image
│   └── ovs.Dockerfile             # OVS image
│
└── cleanup_docker.sh              # Docker and network cleanup
```

---

## ⚙️ Flow Table Design

Each switch (`s1`, `s2`, `s3`) loads the following OpenFlow rules:

| Priority | Match                                | Action     | Purpose                                       |
| -------- | ------------------------------------ | ---------- | --------------------------------------------- |
| 65535    | `dl_type=0x88cc`                     | CONTROLLER | LLDP packets for topology discovery           |
| 120      | `ip,nw_dst=10.x.x.254`               | LOCAL      | Traffic to switch itself                      |
| 110      | `arp,arp_tpa=10.x.x.254,arp_op=1/2`  | LOCAL      | ARP replies from switch                       |
| 100/90   | `arp`                                | CONTROLLER | Generic ARP handling via controller           |
| 0        | any                                  | CONTROLLER | Default packet-in for dynamic flows           |

---

## 🔧 Controller Features

* Dynamic route installation via REST.  
* Topology and flow export/import.  
* ARP and table-miss management.  
* Host and link management via REST.  
* Modular Ryu-based design.

---

## 🧠 Technical Stack

* Docker Engine (≥ 20.x)
* Docker Compose (CLI v2)
* Ryu Controller (OpenFlow 1.3)
* Bash scripting
* HTML, JavaScript, D3.js Web UI

---

## 🖥️ System Overview Diagram

```
+--------------------+           +--------------------+
|      Node A        |           |      Node B        |
|  +-------------+   |           |  +-------------+   |
|  |  Router 1   |   |<==VXLAN==>|  |  Router 2   |   |
|  +------+------+   |           |  +------+------+   |
|         |          |           |         |          |
|   +-----+----+     |           |   +-----+----+     |
|   | Switches |     |           |   | Switches |     |
|   +-----+----+     |           |   +-----+----+     |
|         |          |           |         |          |
|     +---+---+      |           |     +---+---+      |
|     | Hosts |      |           |     | Hosts |      |
+--------------------+           +--------------------+

         ↕
   Docker Swarm Overlay
         ↕
   Ryu Controller + Web UI
```

---

## 🧩 Example Workflow

1. Launch the controller using `control-net.sh`.
2. Deploy topology nodes with `topology.sh`.
3. Check containers and networks using `docker ps` and `docker network inspect`.
4. Verify flows:
   ```bash
   ovs-ofctl -O OpenFlow13 dump-flows <bridge-name>
   ```
5. Add communication pairs using REST.
6. Test connectivity between allowed hosts.

---

## 📦 Cleanup

To remove all containers and networks:
```bash
sudo ./cleanup_docker.sh
```

---

## 📚 References

* [Ryu SDN Framework](https://ryu-sdn.org/resources.html)
* [Open vSwitch Documentation](https://www.openvswitch.org/)
* [Docker Networking](https://docs.docker.com/network/)
