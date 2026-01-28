# Simulatore Multi-Node SDN con Ryu, Docker, Topologia VXLAN e UI Web

Questo progetto simula una **Software Defined Network (SDN)** utilizzando **container Docker** come host e switch **Open vSwitch (OVS)**, orchestrati da un **controller Ryu personalizzato**.
È inclusa un'**interfaccia web** per visualizzare la topologia e interagire tramite API REST.

---

> [Read this document in English](README.md) 🇺🇸

## 1. Panoramica

Il progetto fornisce un ambiente SDN distribuito con Ryu come piano di controllo e OVS come piano dati.
Router e switch vengono eseguiti all'interno di container Docker, interconnessi tramite tunnel VXLAN, consentendo simulazioni multi-nodo su macchine fisiche o virtuali.

---

## 2. Logica di Funzionamento

Il sistema costruisce un'**infrastruttura SDN distribuita** utilizzando **Open vSwitch** e un **controller Ryu personalizzato**.

Componenti principali:

* **Routing L3** gestito dal modulo di Ryu `ryu.app.rest_router`.
* **Classificazione automatica del datapath** (router vs switch di accesso).
* **Rilevamento porte router** per interfacce chiave (`routerX-link`, `vxlan0`).
* **Bootstrap idempotente** tramite chiamate REST a `rest_router` per configurare interfacce L3 e rotte statiche.
* **Applicazione policy IP<->IP**, dove solo le coppie definite in `allowed_pairs` possono comunicare.
* **Learning L2** abilitato solo su OVS (i router non gestiscono ARP/IP manualmente).

Il controller si occupa dell'automazione e dell'applicazione delle policy, delegando la logica di routing a `rest_router`.

---

## 3. Guida Rapida

### Requisiti

** IMPORTANTE **
!!! Installa Docker con privilegi di root !!!
   ```bash
   curl -fsSL https://get.docker.com -o get-docker.sh
   sudo sh ./get-docker.sh
   ```

- Docker Engine ≥ 20.x
- Docker Compose v2
- Python ≥ 3.8  (default 3.9)
- Framework Ryu (installato nel container del controller con l'app custom RyuFlows)

### Avvio della Simulazione
**Setup Docker Swarm:**
Prima di lanciare la topologia, devi inizializzare la rete di controllo e Docker Swarm sul nodo controller:

1. Avvia la rete di controllo e il controller:
   ```bash
   cd ryu_flows/
   sudo ./control-net.sh
   ```

2. Dopo l'avvio del controller, copia il **token di join Docker Swarm** mostrato nel terminale.
   Questo token sarà richiesto da tutti i nodi worker (es. Node A, Node B) per unirsi alla rete Swarm.

3. Su ogni nodo worker, unisciti allo Swarm copiando il token in topology-veth/topology.sh nella variabile CONTROLLER_SWARM_JOIN_TOKEN:
   ```bash
   CONTROLLER_SWARM_JOIN_TOKEN="<SWMTKN-1-TOKEN>"
   ```

Questo passaggio è richiesto per abilitare la comunicazione inter-nodo attraverso la rete overlay VXLAN.


#### Nodo A
```bash
cd topology-veth/
sudo ./topology.sh 1
```

#### Nodo B
```bash
cd topology-veth/
sudo ./topology.sh 2
```

Quando l'avvio è completo:
* Router e switch si registrano automaticamente al controller.
* Interfacce e rotte statiche vengono configurate.
* La policy predefinita abilita la comunicazione solo per coppie di IP predefinite.

Per pulire l'ambiente:
```bash
sudo ./cleanup_docker.sh
```

---

## 4. Utilizzo API REST

Il controller Ryu espone un'API REST per gestire le coppie IP consentite.

**Aggiungi una coppia:**
```bash
curl -X POST -H "Content-Type: application/json"      -d '{"src":"10.0.1.2","dst":"10.0.2.2"}'      http://<controller-ip>:8080/pair
```

**Rimuovi una coppia:**
```bash
curl -X DELETE -H "Content-Type: application/json"      -d '{"src":"10.0.1.2","dst":"10.0.2.2"}'      http://<controller-ip>:8080/pair
```

**Elenca tutte le coppie:**
```bash
curl http://<controller-ip>:8080/pairs | jq .
```

**Accedi alla Web UI:**
```
http://<controller-ip>:8080/ryuflows/index.html
```

---

## 5. Struttura del Progetto

```
multi-node/
│
├── ryu_flows/                     # Controller Ryu e API REST
│   ├── webpages/                  # Interfaccia Web (HTML/JS/CSS)
│   ├── control-net.sh             # Rete di controllo + avvio controller
│   ├── docker-compose.yml         # Definizione container controller
│   ├── ryu_api.py                 # API REST e server web statico
│   ├── ryu_flows.py               # Controller principale
│   ├── ryu_helpers.py             # Utility di supporto
│   └── ryu.Dockerfile             # Immagine controller Ryu
│
├── topology-veth/                 # Script topologia rete
│   ├── router/                    # Componenti router
│   │   ├── router_vxlan.sh
│   │   ├── router-ovs.sh
│   │   └── router.Dockerfile
│   ├── host.sh                    # Setup host
│   ├── ovs.sh                     # Setup OVS
│   ├── topology.sh                # Launcher topologia
│   ├── host.Dockerfile            # Immagine host
│   └── ovs.Dockerfile             # Immagine OVS
│
└── cleanup_docker.sh              # Pulizia Docker e rete
```

---

## Design Tabella dei Flow

Ogni switch (`s1`, `s2`, `s3`) carica le seguenti regole OpenFlow:

| Priorità | Match                                | Azione     | Scopo                                         |
| -------- | ------------------------------------ | ---------- | --------------------------------------------- |
| 65535    | `dl_type=0x88cc`                     | CONTROLLER | Pacchetti LLDP per scoperta topologia         |
| 120      | `ip,nw_dst=10.x.x.254`               | LOCAL      | Traffico verso lo switch stesso               |
| 110      | `arp,arp_tpa=10.x.x.254,arp_op=1/2`  | LOCAL      | Risposte ARP dallo switch                     |
| 100/90   | `arp`                                | CONTROLLER | Gestione ARP generica tramite controller      |
| 0        | any                                  | CONTROLLER | Packet-in predefinito per flussi dinamici     |

---

## Funzionalità del Controller

* Installazione dinamica delle rotte via REST.
* Export/import di topologia e flussi.
* Gestione ARP e table-miss.
* Gestione host e link via REST.
* Design modulare basato su Ryu.

---

## Stack Tecnico

* Docker Engine (≥ 20.x)
* Docker Compose (CLI v2)
* Ryu Controller (OpenFlow 1.3)
* Scripting Bash
* HTML, JavaScript, D3.js per Web UI

---

## Diagramma Panoramica Sistema

```
+--------------------+           +--------------------+
|      Nodo A        |           |      Nodo B        |
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

## Esempio di Workflow

1. Lancia il controller usando `control-net.sh`.
2. Esegui il deploy dei nodi della topologia con `topology.sh`.
3. Controlla container e reti usando `docker ps` e `docker network inspect`.
4. Verifica i flussi:
   ```bash
   ovs-ofctl -O OpenFlow13 dump-flows <bridge-name>
   ```
5. Aggiungi coppie di comunicazione usando REST.
6. Testa la connettività tra gli host consentiti.

---

## Pulizia

Per rimuovere tutti i container e le reti:
```bash
sudo ./cleanup_docker.sh
```

---

## Riferimenti

* [Ryu SDN Framework](https://ryu-sdn.org/resources.html)
* [Open vSwitch Documentation](https://www.openvswitch.org/)
* [Docker Networking](https://docs.docker.com/network/)
