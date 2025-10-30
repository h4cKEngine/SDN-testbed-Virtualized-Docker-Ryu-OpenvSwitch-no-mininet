"""
Modulo di supporto (`ryu_helpers.py`) per l’applicazione Ryu `RyuFlows`.

Contiene classi helper strettamente associate a `RyuFlows` ma non derivate da essa,
organizzate per ambito funzionale:

  - **HelperBase**: classe base comune per gli helper; fornisce accesso facilitato
    a logger e configurazione REST dell’app principale.
  - **HelperREST**: funzioni di supporto per interazione REST con `ryu.app.rest_router`
    (operazioni GET/POST JSON, creazione idempotente di interfacce e rotte L3).
  - **HelperDatapath**: metodi per ottenere informazioni sui datapath (descrizione porte,
    MAC bridge locale, rilevamento porte chiave dei router).
  - **HelperFlow**: installazione di flussi OpenFlow preconfigurati per gestione ARP,
    traffico sul link di transito VXLAN e override specifici per il traffico inter-LAN.
  - **HelperPolicy**: funzioni di verifica e filtraggio IP↔IP per applicazione delle policy ACL.

Caratteristiche:
----------------
- Gli helper operano in modo idempotente, evitando di duplicare configurazioni già presenti.
- Le operazioni REST sono ritentate più volte con attese progressive in caso di errore.
- Le installazioni di flussi utilizzano cookie distintivi per consentire la rimozione selettiva.
- Il rilevamento porte router supporta convenzioni di naming (es. `router1-link`, `vxlan0`)
  e parametri LAN definiti nell’app `RyuFlows`.

Utilizzo:
---------
Gli oggetti helper vengono istanziati all’interno di `RyuFlows` e richiamati nei vari
event handler per:
    - interrogare lo stato della rete via REST,
    - rilevare la topologia e le porte chiave,
    - configurare interfacce e rotte su `rest_router`,
    - applicare flussi di instradamento e policy personalizzate.
"""


from ryu.lib import hub
import urllib.request, urllib.error, json
from ryu.lib.packet import ether_types
from ipaddress import ip_address


class HelperBase:
    """Base comune per helper: accoppiata stretta a RyuFlows, senza ereditarla."""
    def __init__(self, app):
        self.app = app  # istanza di RyuFlows

    # Scorciatoie: ora puoi usare self.logger invece di self.app.logger
    @property
    def logger(self):
        return self.app.logger

    @property
    def REST_BASE(self):
        return self.app.REST_BASE


class HelperREST(HelperBase):
    def __init__(self, app):
        super().__init__(app)

    def _dpid_hex(self, dpid):
        return f"{int(dpid):016x}"

    def _rest_get_json(self, url, default=None, timeout=2.0, tries=3, sleep=0.3):
        for i in range(tries):
            try:
                req = urllib.request.Request(url, method='GET')
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return json.loads(r.read().decode('utf-8'))
            except Exception as e:
                self.logger.debug("GET %s failed (%s) try %d/%d", url, e, i + 1, tries)
                hub.sleep(int(sleep))
        return default

    def _rest_post_json(self, url, payload, timeout=3.0, tries=3, sleep=0.4):
        data = json.dumps(payload).encode('utf-8')
        for i in range(tries):
            try:
                req = urllib.request.Request(url, data=data,
                                             headers={'Content-Type': 'application/json'},
                                             method='POST')
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    body = r.read().decode('utf-8')
                    self.logger.info("POST %s %s -> %s", url, payload, body)
                    return True
            except urllib.error.HTTPError as he:
                self.logger.warning("POST %s %s -> HTTP %s (idempotenza?)", url, payload, he.code)
                if he.code in (400, 409):
                    return True
            except Exception as e:
                self.logger.debug("POST %s failed (%s) try %d/%d", url, e, i + 1, tries)
                hub.sleep(int(sleep))
        return False

    def _ensure_interface(self, dpid, port_no, address):
        base = f"{self.REST_BASE}/router/{self._dpid_hex(dpid)}"
        current = self._rest_get_json(base, default=[])

        def collect_addrs_with_port(obj):
            pairs, addrs = set(), set()
            if isinstance(obj, list):
                for it in obj:
                    if isinstance(it, dict):
                        a = it.get('address')
                        p = it.get('port')
                        if a:
                            a = str(a).strip()
                            addrs.add(a)
                            if p is not None:
                                try:
                                    pairs.add((a, int(p)))
                                except Exception:
                                    pairs.add((a, p))
                    elif isinstance(it, str):
                        addrs.add(it.strip())
            elif isinstance(obj, dict):
                for k in ('addresses', 'interfaces', 'data', 'body'):
                    if k in obj:
                        sub_pairs, sub_addrs = collect_addrs_with_port(obj[k])
                        pairs |= sub_pairs
                        addrs |= sub_addrs
                for v in obj.values():
                    if isinstance(v, (list, dict)):
                        sub_pairs, sub_addrs = collect_addrs_with_port(v)
                        pairs |= sub_pairs
                        addrs |= sub_addrs
            return pairs, addrs

        have_pairs, have_addrs = collect_addrs_with_port(current)
        if (address, port_no) in have_pairs or address in have_addrs:
            self.logger.info("Interfaccia già presente su dpid=%s (addr=%s, port=%s)", dpid, address, port_no)
            return True

        payload = {"address": address, "port": int(port_no)}
        return self._rest_post_json(base, payload)

    def _ensure_route(self, dpid, destination, gateway):
        base = f"{self.REST_BASE}/router/{self._dpid_hex(dpid)}"
        current = self._rest_get_json(base, default=[])

        def _collect_routes(obj):
            routes = set()
            if isinstance(obj, list):
                for it in obj:
                    if isinstance(it, dict):
                        dst = it.get('destination') or it.get('dst') or it.get('network')
                        gw  = it.get('gateway')    or it.get('nexthop') or it.get('gw')
                        if dst and gw:
                            routes.add((str(dst).strip(), str(gw).strip()))
            elif isinstance(obj, dict):
                for k in ('route', 'routes', 'data', 'body'):
                    if k in obj:
                        routes |= _collect_routes(obj[k])
                for v in obj.values():
                    if isinstance(v, (list, dict)):
                        routes |= _collect_routes(v)
            return routes

        have = _collect_routes(current)
        if (destination, gateway) in have:
            self.logger.info("Route già presente su dpid=%s: %s via %s", dpid, destination, gateway)
            return True

        payload = {"destination": destination, "gateway": gateway}
        return self._rest_post_json(base, payload)


class HelperDatapath(HelperBase):
    def __init__(self, app):
        super().__init__(app)

    def _get_dp_by_id(self, dpid):
        return self.app.datapaths.get(dpid)

    def _get_portdesc(self, dpid):
        url = f"{self.REST_BASE}/stats/portdesc/{dpid}"
        data = self.app.helper_rest._rest_get_json(url, default={}) or {}
        return data.get(str(dpid), [])

    def _get_bridge_mac(self, dpid):
        # prima prova: porta chiamata "vxlan-br"
        for p in self._get_portdesc(dpid):
            if str(p.get('name', '')).lower() == 'vxlan-br':
                hw = p.get('hw_addr')
                if hw:
                    return hw
        # fallback: OFPP_LOCAL
        for p in self._get_portdesc(dpid):
            pn = p.get('port_no')
            if str(pn) in ('LOCAL', '4294967294'):
                hw = p.get('hw_addr')
                if hw:
                    return hw
        return None

    def _discover_router_ports(self, dpid):
        url = f"{self.REST_BASE}/stats/portdesc/{dpid}"
        data = self.app.helper_rest._rest_get_json(url, default={}) or {}
        entries = data.get(str(dpid), [])
        if not entries:
            return None

        lan_no = lan_mac = None
        lan_cidr = None
        vx_no = None

        for p in entries:
            name = str(p.get('name', ''))
            lname = name.lower()
            port_no = p.get('port_no')
            hw = p.get('hw_addr')

            if 'vxlan' in lname:
                vx_no = port_no

            if 'router' in lname and 'link' in lname:
                lan_no = port_no
                lan_mac = hw
                if '1' in lname:
                    lan_cidr = str(self.app.LAN1_CIDR)
                elif '2' in lname:
                    lan_cidr = str(self.app.LAN2_CIDR)

            if lname == 'router1-link' or lname == 'lan1':
                lan_no, lan_mac, lan_cidr = port_no, hw, str(self.app.LAN1_CIDR)
            if lname == 'router2-link' or lname == 'lan2':
                lan_no, lan_mac, lan_cidr = port_no, hw, str(self.app.LAN2_CIDR)

        if lan_no is None or vx_no is None or lan_cidr is None:
            return None

        return {'lan_no': lan_no, 'lan_mac': lan_mac, 'vx_no': vx_no, 'lan_cidr': lan_cidr}


class HelperFlow(HelperBase):
    def __init__(self, app):
        super().__init__(app)

    def _install_router_arp_capture(self, dp, gw_with_len, vx_with_len):
        p, ofp = dp.ofproto_parser, dp.ofproto

        def _ip(addr_with_len):
            return str(addr_with_len).split('/')[0]

        for ip in (_ip(gw_with_len), _ip(vx_with_len)):
            match = p.OFPMatch(eth_type=ether_types.ETH_TYPE_ARP, arp_tpa=ip)
            self.app.add_flow(
                dp, priority=550, match=match,
                actions=[p.OFPActionOutput(ofp.OFPP_CONTROLLER, ofp.OFPCML_NO_BUFFER)],
                cookie=self.app.COOKIE_BASE
            )

    def _install_transit_link_flows(self, dp):
        p, ofp = dp.ofproto_parser, dp.ofproto
        net = self.app.VX_CIDR
        naddr, nmask = str(net.network_address), str(net.netmask)

        # a) IP sul transit: L2/NORMAL
        match_vx_vx = p.OFPMatch(
            eth_type=ether_types.ETH_TYPE_IP,
            ipv4_src=(naddr, nmask),
            ipv4_dst=(naddr, nmask),
        )
        self.app.add_flow(dp, priority=36, match=match_vx_vx,
                          actions=[p.OFPActionOutput(ofp.OFPP_NORMAL)],
                          cookie=self.app.COOKIE_BASE)

        # b) ARP per il transit: al controller
        match_arp_vx = p.OFPMatch(eth_type=ether_types.ETH_TYPE_ARP,
                                  arp_tpa=(naddr, nmask))
        self.app.add_flow(dp, priority=250, match=match_arp_vx,
                          actions=[p.OFPActionOutput(ofp.OFPP_CONTROLLER, ofp.OFPCML_NO_BUFFER)],
                          cookie=self.app.COOKIE_BASE)

        # c) IP destinati al transit: al controller
        match_to_vx = p.OFPMatch(eth_type=ether_types.ETH_TYPE_IP,
                                 ipv4_dst=(naddr, nmask))
        self.app.add_flow(dp, priority=2, match=match_to_vx,
                          actions=[p.OFPActionOutput(ofp.OFPP_CONTROLLER, ofp.OFPCML_NO_BUFFER)],
                          cookie=self.app.COOKIE_BASE)

    def _install_interlan_overrides(self):
        """
        Per ciascun router: se il pacchetto è destinato alla *propria* LAN,
        consegnalo alla porta LAN (per far uscire lato LAN i frame decapsulati VXLAN).
        """
        for dpid in sorted(self.app.router_dpids):
            ports = self.app.router_ports.get(dpid)
            dp = self.app.helper_dp._get_dp_by_id(dpid)
            if not (ports and dp):
                continue

            p, ofp = dp.ofproto_parser, dp.ofproto
            lan_net = self.app.LAN1_CIDR if (ports['lan_cidr'] == str(self.app.LAN1_CIDR)) \
                     else self.app.LAN2_CIDR

            match_local_dst = p.OFPMatch(
                eth_type=ether_types.ETH_TYPE_IP,
                ipv4_dst=(str(lan_net.network_address), str(lan_net.netmask))
            )
            self.app.add_flow(dp, priority=40, match=match_local_dst,
                              actions=[p.OFPActionOutput(int(ports['lan_no']))],
                              cookie=self.app.COOKIE_BASE)

        self.logger.info("Override inter-LAN: ip→LAN installati (prio 40) su tutti i router.")


class HelperPolicy(HelperBase):
    def __init__(self, app):
        super().__init__(app)

    # Permette sia same-LAN sia cross-LAN
    def _both_in_lans(self, ipA, ipB):
        try:
            a = ip_address(ipA); b = ip_address(ipB)
        except Exception:
            return False
        in1_a = a in self.app.LAN1_CIDR; in2_a = a in self.app.LAN2_CIDR
        in1_b = b in self.app.LAN1_CIDR; in2_b = b in self.app.LAN2_CIDR
        # prima: (in1_a and in2_b) or (in2_a and in1_b)
        # ora: same-lan OPPURE cross-lan
        same = (in1_a and in1_b) or (in2_a and in2_b)
        cross = (in1_a and in2_b) or (in2_a and in1_b)
        return same or cross

