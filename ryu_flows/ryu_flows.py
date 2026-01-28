"""
Minimal Ryu Controller that delegates optimal L3 routing to the official `ryu.app.rest_router` app.
The module (`ryu_flows.py`) is located within the `ryu_flows/` package along with:

  - `ryu_helpers.py` -> helper functions and classes (REST, datapath, flow, policy)
  - `ryu_api.py`      -> potential custom REST APIs for allowed_pairs and diagnostics

Main Features:
------------------------
  - Classification of datapaths as router (with VXLAN interface) or access OVS
  - Port detection for routers (`routerX-link` LAN port and `vxlan0`)
  - Idempotent bootstrap via REST to `rest_router` (L3 interfaces and static routes)
  - Application of an IP<->IP `allowed_pairs` policy on top of rules set by `rest_router`
  - Implementation of L2 learning only on OVS (no L3 logic in packet-in)

Operational Notes:
------------------
- Start with:
    ryu-manager ryu_flows/ryu_flows.py
  or, if `__init__.py` exports the `RyuFlows` class:
    ryu-manager ryu_flows

- Intended to work in conjunction with `ryu.app.rest_router`

Verification (examples):
------------------
# Interfaces configured by rest_router
curl -s http://localhost:8080/router/<dpid_hex_16_digits> | jq .

# Static routes
curl -s http://localhost:8080/router/<dpid_hex_16_digits>/route | jq .

Flow Verification (expected priorities):
------------------------------------
# On routers (bridge vxlan-br) and on OVS:
ovs-ofctl -O OpenFlow13 dump-flows vxlan-br

Important Information:
------------------------
- ALLOW rules are implemented with OUTPUT:CONTROLLER
- L3 routing is managed entirely by `rest_router`
- No tables or pipelines are modified outside of standard ones
"""


from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import (
    CONFIG_DISPATCHER,
    MAIN_DISPATCHER,
    DEAD_DISPATCHER,
    set_ev_cls
)
from ryu.ofproto import ofproto_v1_3
from ryu.lib.packet import packet, arp, ethernet, ether_types, ipv4
from ryu.app.wsgi import WSGIApplication
from ryu.topology import switches
from ryu.topology.event import EventSwitchEnter
from ryu.lib import hub
from ipaddress import ip_network

try:
    from .ryu_helpers import HelperREST, HelperDatapath, HelperFlow, HelperPolicy
    from .ryu_api import RyuApi, ALLOWED_PAIR_KEY, RyuWebInterface, RouterApi
    _HAVE_RYU_API = True
except Exception:
    ALLOWED_PAIR_KEY = 'allowed_pairs_owner'
    _HAVE_RYU_API = False

ENABLE_DEFAULT_DROP = False
ENABLE_INTERLAN_OVERRIDE = False

class RyuFlows(app_manager.RyuApp):
    """
    Minimal Controller:
      - Classifies datapath (router vs OVS)
      - Bootstraps router via rest_router (interfaces + routes)
      - Policy allowed_pairs (allowlist IP<->IP) atop `rest_router` routing
      - L2 learning only on OVS
    """
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]
    _CONTEXTS = {
        'wsgi': WSGIApplication,
        'switches': switches.Switches
    }

    ROUTE_EP_CANDIDATES = ('/router/{dpid}/route',
                           '/router/{dpid}/static_route',
                           '/router/{dpid}/routes')

    # LAN and transit (constraints/assumptions)
    LAN1_CIDR = ip_network('10.0.1.0/24')
    LAN2_CIDR = ip_network('10.0.2.0/24')
    LAN1_GW = '10.0.1.254/24'
    LAN2_GW = '10.0.2.254/24'

    # Transit inter-router su /24
    VX_CIDR  = ip_network('10.30.30.0/24')
    VX_R1    = '10.30.30.11/24'
    VX_R2    = '10.30.30.12/24'
    VX_R1_IP = '10.30.30.11'
    VX_R2_IP = '10.30.30.12'
    COOKIE_BASE = 0x2

    REST_BASE = "http://localhost:8080"

    # Policy: priorities
    PRIO_ALLOW = 15
    PRIO_DROP = 20
    PRIO_ARP = 10
    PRIO_MISS = 0

    # Cookie to identify (and delete) custom policies
    COOKIE_POLICY = 0x0A110ED  # arbitrary hex 'ALLOWED'

    def __init__(self, *args, **kwargs):
        super(RyuFlows, self).__init__(*args, **kwargs)
        self.helper_rest = HelperREST(self)
        self.helper_dp = HelperDatapath(self)
        self.helper_flows = HelperFlow(self)
        self.helper_policy = HelperPolicy(self)
        
        self.mac_to_port = {}           # L2 learning per OVS
        self.allowed_pairs = set()      # {(ipA, ipB), ...}
        self.router_cfg = {}
        self.host_info = {}
        self.router_names = {}          # dpid(int) -> "router1"/"router2"
        self.router_dpids = set()
        self.all_dpids = set()

        # Router ports state: dpid -> {'lan_no','lan_mac','vx_no','lan_cidr'}
        self.router_ports = {}
        self._bootstrapped = set()

        # Local Datapath registry (fix: no send_request_to_manager)
        # populated by EventOFPStateChange
        self.datapaths = {}  # dpid -> datapath

        # Local WSGI / REST
        wsgi = kwargs.get('wsgi')
        if wsgi:
            if _HAVE_RYU_API:
                wsgi.register(RyuApi, {ALLOWED_PAIR_KEY: self})
                wsgi.register(RouterApi, {ALLOWED_PAIR_KEY: self})
                wsgi.register(RyuWebInterface)
            else:
                self.logger.warning(".ryu_api module not available; custom REST disabled.")

        self.logger.info("RyuFlows initialized: routing via rest_router, policy IP<->IP in OF.")

    # =========================
    # Datapath & Topology Events
    # =========================
    @set_ev_cls(ofp_event.EventOFPStateChange, [MAIN_DISPATCHER, DEAD_DISPATCHER])
    def _state_change_handler(self, ev):
        """Registers/unregisters active datapaths (without send_request_to_manager)."""
        dp = ev.datapath
        if ev.state == MAIN_DISPATCHER:
            if dp.id not in self.datapaths:
                self.datapaths[dp.id] = dp
                self.logger.debug("Datapath registered: dpid=%s", dp.id)
        elif ev.state == DEAD_DISPATCHER:
            if dp.id in self.datapaths:
                del self.datapaths[dp.id]
                self.logger.debug("Datapath removed: dpid=%s", dp.id)

    @set_ev_cls(EventSwitchEnter)
    def _on_switch_enter(self, ev):
        """
        Handles the event when a switch enters the topology.
        Classifies the switch as OVS or Router and starts bootstrapping if necessary.
        """
        dpid = ev.switch.dp.id
        self.all_dpids.add(dpid)
        self.logger.info("Switch joined: dpid=%s", dpid)

        self.get_router_dpids()
        ovs = self.all_dpids - self.router_dpids

        self.logger.info("   OVS switches:   %s", sorted(ovs))
        self.logger.info("   Router DPIDs:   %s", sorted(self.router_dpids))
        self.logger.info("   Names:          %s", self.router_names)

    def get_router_dpids(self):
        """
        Queries the topology to identify which switches are Routers (based on port names).
        Updates internal data structures.
        """
        topo_url = f"{self.REST_BASE}/v1.0/topology/switches"
        sws = self.helper_rest._rest_get_json(topo_url, default=[]) or []
        all_dpids, router_dpids = set(), set()

        for sw in sws:
            try:
                dpid_int = int(sw['dpid'], 16)
            except Exception:
                continue
            all_dpids.add(dpid_int)

            stat_port = self.helper_rest._rest_get_json(f"{self.REST_BASE}/stats/portdesc/{dpid_int}", default={}) or {}
            ports = stat_port.get(str(dpid_int), [])
            names = [str(p.get('name', '')).lower() for p in ports]

            # VXLAN ONLY -> router (no router*-link)
            has_vx = any('vxlan' in n for n in names)  # match anche vxlan_sys_4789
            if has_vx:
                router_dpids.add(dpid_int)

        self.all_dpids.update(all_dpids)
        self.router_dpids = router_dpids
        for r in sorted(self.router_dpids):
            if r not in self._bootstrapped:
                self._bootstrapped.add(r)
                hub.spawn(self.bootstrap_router, r)

        self.router_names = {dpid: f"router{idx+1}" for idx, dpid in enumerate(sorted(self.router_dpids))}
        return self.router_dpids


    # =========================
    # Switch Features (setup base)
    # =========================
    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER) # type: ignore
    def switch_features_handler(self, ev):
        """
        Handles the SwitchFeatures event.
        Installs base flows (Table-miss, ARP flood) and configures routers/OVS.
        """
        dp = ev.msg.datapath
        ofp = dp.ofproto
        p = dp.ofproto_parser

        # Refresh classification (idempotent)
        try:
            self.get_router_dpids()
        except Exception:
            pass

        dpid = dp.id
        is_router = dpid in self.router_dpids

        # Table-miss
        if is_router:
            # router: deliver to L2
            self.add_flow(dp, self.PRIO_MISS, p.OFPMatch(),
                        [p.OFPActionOutput(ofp.OFPP_NORMAL)])
        else:
            # OVS: first packet to controller (simple learning in packet-in handler)
            self.add_flow(dp, self.PRIO_MISS, p.OFPMatch(),
                        [p.OFPActionOutput(ofp.OFPP_CONTROLLER, ofp.OFPCML_NO_BUFFER)])

        # ARP flood
        match_arp = p.OFPMatch(eth_type=ether_types.ETH_TYPE_ARP)
        self.add_flow(dp, self.PRIO_ARP, match_arp, [p.OFPActionOutput(ofp.OFPP_FLOOD)])

        if is_router:
            # (optional but recommended) clean old "transit" flows before putting them back
            try:
                self.del_flows_by_cookie(dp, cookie=self.COOKIE_BASE)
            except Exception:
                pass
            self.helper_flows._install_transit_link_flows(dp)
            self.logger.info("Base setup router dpid=%s (ARP flood + miss + transit).", dpid)
        else:
            # Apply/replace ACL policies on OVS (ALLOW > DROP)
            self.program_policy_rules(dpids=[dpid])
            self.logger.info("Base setup OVS dpid=%s (ARP flood + miss + policy).", dpid)


    # ==============
    # Flow utilities
    # ==============
    def add_flow(self, datapath, priority, match, actions, table_id=0,
                 buffer_id=None, cookie=0, idle_timeout=0, hard_timeout=0):
        """
        Adds a flow entry to the switch.
        """
        ofp = datapath.ofproto
        parser = datapath.ofproto_parser

        # If actions is None, force explicit drop without APPLY_ACTIONS
        instructions = []
        if actions is not None:
            instructions = [parser.OFPInstructionActions(ofp.OFPIT_APPLY_ACTIONS, actions)]

        kwargs = dict(datapath=datapath, table_id=table_id,
                      priority=priority, match=match, instructions=instructions,
                      cookie=cookie, idle_timeout=idle_timeout, hard_timeout=hard_timeout)
        if buffer_id is not None:
            kwargs['buffer_id'] = buffer_id
        mod = parser.OFPFlowMod(**kwargs)
        datapath.send_msg(mod)

    def del_flows_by_cookie(self, datapath, cookie, cookie_mask=0xffffffffffffffff, table_id=ofproto_v1_3.OFPTT_ALL):
        """Deletes rules with a specific cookie (idempotent)."""
        ofp = datapath.ofproto
        parser = datapath.ofproto_parser
        mod = parser.OFPFlowMod(datapath=datapath, table_id=table_id,
                                command=ofp.OFPFC_DELETE,
                                out_port=ofp.OFPP_ANY, out_group=ofp.OFPG_ANY,
                                cookie=cookie, cookie_mask=cookie_mask)
        datapath.send_msg(mod)

    # =======================
    # Packet-In: only L2 on OVS
    # =======================
    @set_ev_cls(ofp_event.EventOFPPacketIn, MAIN_DISPATCHER) # type: ignore
    def _packet_in_handler(self, ev):
        """
        Handles incoming packets to the controller (Packet-In).
        Implments L2 learning on OVS. Routers are ignored (handled by rest_router).
        """
        msg = ev.msg
        dp = msg.datapath
        dpid = dp.id
        ofp = dp.ofproto
        p = dp.ofproto_parser
        in_port = msg.match.get('in_port')
        if in_port is None:
            return  # no in_port, cannot forward

        pkt = packet.Packet(msg.data)
        eth = pkt.get_protocols(ethernet.ethernet)[0]
        if eth.ethertype == ether_types.ETH_TYPE_LLDP: # type: ignore
            return

        # Router: no custom L3 logic, leave to rest_router
        if dpid in self.router_dpids:
            return

        # OVS: minimal L2 learning
        dpid_str = str(dpid)
        self.mac_to_port.setdefault(dpid_str, {})
        self.mac_to_port[dpid_str][eth.src] = in_port # type: ignore

        out_port = self.mac_to_port[dpid_str].get(eth.dst, ofp.OFPP_FLOOD) # type: ignore
        actions = [p.OFPActionOutput(out_port)]

        # Install L2 flow (idempotent in time)
        if out_port != ofp.OFPP_FLOOD:
            match = p.OFPMatch(in_port=in_port, eth_src=eth.src, eth_dst=eth.dst) # type: ignore
            self.add_flow(dp, 1, match, actions)

        # Correct PacketOut: if using data -> OFP_NO_BUFFER, otherwise reuse buffer_id
        if msg.buffer_id != ofp.OFP_NO_BUFFER:
            out = p.OFPPacketOut(
                datapath=dp,
                buffer_id=msg.buffer_id,
                in_port=in_port,
                actions=actions,
                data=None
            )
        else:
            out = p.OFPPacketOut(
                datapath=dp,
                buffer_id=ofp.OFP_NO_BUFFER,
                in_port=in_port,
                actions=actions,
                data=msg.data
            )
        dp.send_msg(out)


    # =========================
    # Bootstrap Router (REST)
    # =========================
    def bootstrap_router(self, dpid, max_tries=10, sleep_s=1.0):
        """
        Bootstraps a Router:
        - Discovers router ports (LAN and vxlan0)
        - Configures L3 interfaces and static route via rest_router (idempotent)
        - (Re)programs policy flows for this router
        """
        self.logger.info("Router bootstrap started: dpid=%s", dpid)

        # 1) Port discovery
        ports = None
        for i in range(max_tries):
            ports = self.helper_dp._discover_router_ports(dpid)
            if ports:
                break
            self.logger.info("Router ports not ready (attempt %d/%d). Retry...", i + 1, max_tries)
            hub.sleep(int(sleep_s))

        if not ports:
            self.logger.error("Unable to discover ports for router dpid=%s. Abort bootstrap.", dpid)
            return

        self.router_ports[dpid] = ports
        self.logger.info("Router ports for dpid=%s: %s", dpid, ports)

        # 2) L3 Config via REST (idempotent)
        is_r1 = (ports['lan_cidr'] == str(self.LAN1_CIDR))
        lan_addr = self.LAN1_GW if is_r1 else self.LAN2_GW
        vx_addr = self.VX_R1 if is_r1 else self.VX_R2
        dest_cidr = str(self.LAN2_CIDR if is_r1 else self.LAN1_CIDR)
        gw_next = self.VX_R2_IP if is_r1 else self.VX_R1_IP

        self.logger.info("Config dpid=%s: LAN=%s, VX=%s, route %s via %s",
                         dpid, lan_addr, vx_addr, dest_cidr, gw_next)

        # Interfaces
        self.helper_rest._ensure_interface(dpid, ports['lan_no'], lan_addr)
        self.helper_rest._ensure_interface(dpid, ports['vx_no'], vx_addr)
        # Static route
        self.helper_rest._ensure_route(dpid, destination=dest_cidr, gateway=gw_next)

        # 3) Policy for this router
        dp = self.helper_dp._get_dp_by_id(dpid)
        if dp:
            self.helper_flows._install_transit_link_flows(dp)
            self.helper_flows._install_router_arp_capture(dp, lan_addr, vx_addr)
            self.program_policy_rules(dpids=[dpid])
            if ENABLE_INTERLAN_OVERRIDE:
                try:
                    self.helper_flows._install_interlan_overrides()
                except Exception as e:
                    self.logger.warning("Interlan overrides not installed: %s", e)
        else:
            self.logger.warning("Datapath not available for dpid=%s; will retry at next event.", dpid)

    # ======================================
    # Policy: allowed_pairs + default cross-DROP
    # ======================================
    def program_policy_rules(self, dpids=None):
        """
        Applies policy rules (Allowed Pairs) to specified switches or all.
        Configures specific ALLOW and default cross-LAN DROP on OVS.
        """
        targets = dpids or list(self.router_dpids | (self.all_dpids - self.router_dpids))
        if not targets:
            self.logger.info("No targets for policy.")
            return

        # Normalize pairs (directional)
        pairs = []
        for pair in getattr(self, 'allowed_pairs', set()):
            if not pair or len(pair) != 2:
                continue
            a, b = str(pair[0]).strip(), str(pair[1]).strip()
            # accept only cross-LAN
            if self.helper_policy._both_in_lans(a, b):
                pairs.append((a, b))

        for dpid in sorted(targets):
            dp = self.helper_dp._get_dp_by_id(dpid)
            if not dp:
                continue
            p, ofp = dp.ofproto_parser, dp.ofproto

            # Clean old policies on this DP
            self.del_flows_by_cookie(dp, cookie=self.COOKIE_POLICY)

            if dpid in self.router_dpids:
                # Router: no ALLOW/DROP (leave to rest_router)
                self.logger.info("Router policy dpid=%s: no ACL (handled by rest_router).", dpid)
                continue

            # Access OVS: specific ALLOW + default cross-LAN DROP
            # ALLOW for each pair (high prio, pass to L2 NORMAL)
            for (src_ip, dst_ip) in pairs:
                match = p.OFPMatch(
                    eth_type=ether_types.ETH_TYPE_IP,
                    ipv4_src=src_ip,
                    ipv4_dst=dst_ip
                )
                self.add_flow(
                    dp, priority=80, match=match,
                    actions=[p.OFPActionOutput(ofp.OFPP_NORMAL)],
                    cookie=self.COOKIE_POLICY
                )

            # DROP cross-LAN (prio below ALLOW, above learning)
            match12 = p.OFPMatch(
                eth_type=ether_types.ETH_TYPE_IP,
                ipv4_src=(str(self.LAN1_CIDR.network_address), str(self.LAN1_CIDR.netmask)),
                ipv4_dst=(str(self.LAN2_CIDR.network_address), str(self.LAN2_CIDR.netmask))
            )
            self.add_flow(dp, priority=70, match=match12, actions=[], cookie=self.COOKIE_POLICY)

            match21 = p.OFPMatch(
                eth_type=ether_types.ETH_TYPE_IP,
                ipv4_src=(str(self.LAN2_CIDR.network_address), str(self.LAN2_CIDR.netmask)),
                ipv4_dst=(str(self.LAN1_CIDR.network_address), str(self.LAN1_CIDR.netmask))
            )
            self.add_flow(dp, priority=70, match=match21, actions=[], cookie=self.COOKIE_POLICY)

            self.logger.info("Policy OVS dpid=%s: %d ALLOW + DROP cross-LAN.", dpid, len(pairs))

    # ===========
    # Hook REST custom (se presente .ryu_api)
    # ===========
    def update_allowed_pairs(self, new_pairs):
        """
        Updates the allowed_pairs set and reprograms policies on all routers.
        new_pairs: iterable of tuple/list (src_ip, dst_ip)
        """
        normalized = set()
        for pair in new_pairs or []:
            if not pair or len(pair) != 2:
                continue
            a, b = str(pair[0]).strip(), str(pair[1]).strip()
            normalized.add((a, b))
        self.allowed_pairs = normalized
        self.logger.info("allowed_pairs updated: %s", sorted(self.allowed_pairs))
        self.program_policy_rules()
