/**
 * fetchTopology()
 * 1) Fetch parallelo: /links, /hosts, /hostmap, /cfg/routers, /switches.
 * 2) Indici porte:
 *    - portIndexByName[nameLower] -> { dpid, port_no }
 *    - portIndexByKey["dpid:port"] -> nameLower
 * 3) Router:
 *    - routerDpids = DPID da /cfg/routers
 *    - + ogni switch che ha almeno una porta con name che inizia per "vxlan"
 * 4) Naming nodi:
 *    - Switch: label guessSwitchLabelFromPorts(ports) (es. porta "s3-to-s4" => "s3").
 *      if (dpid ∈ routerDpids) skip inferenza.
 *    - Router: nome stabile r1, r2, … usando window._routerNameMap (persistente tra refresh).
 * 5) Regole “infra” e host fantasma:
 *    - INFRA_RE: porta è “infra” se name combacia con: "*-to-*", "router*-link", "vxlan*", "vxlan_sys_*",
 *      "dp*", "patch-*", "local".
 *    - isInfraPort(dpid, port):
 *        if (dpid ∈ routerDpids) return true;              // tutte le porte dei router sono infra
 *        else return INFRA_RE.test(nomePorta) (solo se name esiste).
 *    - isGhostHost(h):
 *        if (h.port.dpid ∈ routerDpids) return true;       // mai disegnare host sui router
 *        if (isInfraPort(...) && !haIP) return true;        // infra senza IP => fantasma
 *        else return false.
 * 6) Merge host:
 *    - Parto da /hosts, filtro con isGhostHost(); tengo set seenIPs.
 *    - /hostmap: per ogni entry
 *         - se IP già in seenIPs => skip
 *         - se mancano dpid/port: risolvo via resolvePortForHost(hostname) usando portIndexByName
 *         - if (dpid ∈ routerDpids) => skip
 *         - if (isInfraPort(dpid, port) && IP assente) => skip
 *         - altrimenti aggiungo (mac="host:<hostname|ip>", ipv4=[ip?]).
 * 7) Link:
 *    - Aggiungo link fisici da /links (src.dpid:src.port_no → dst.dpid:dst.port_no).
 *    - Aggiungo link “solo UI” tra router consecutivi (ordinati) con:
 *        { kind:'router_vxlan', src_port:'VXLAN', dst_port:'VXLAN' }.
 * 8) Nodi:
 *    - host dai dati uniti; switch+router da dpid visti nei link/host.
 * 9) Espongo per le tabelle:
 *    window._macToHostName, window._dpidToSwitchName, window._routerDpids.
 * 10) drawTopology(nodes, links, mappe).
 *
 * drawTopology()
 * - D3 forces + zoom/drag.
 * - Link (un solo layer) con stile condizionale:
 *     if (kind==='router_vxlan') stroke #6aa, width 3, dash "6,4", opacity 0.9, raise();
 *     else stroke #aaa, width 2.
 * - Icone: host.png / router.png / switch.png.
 * - Label: host -> _macToHostName[id]; switch/router -> _dpidToSwitchName[id].
 *
 * fetchSwitches()
 * - Tabella “Switch Ports”: Name(label), Switch(DPID), Port No, MAC, NameLink (nome porta).
 *
 * fetchHosts()
 * - Tabella “Hosts” filtrata: salta le righe con host.port.dpid ∈ _routerDpids.
 *
 * refreshTopology()
 * - Esegue fetchTopology(), poi fetchSwitches() e fetchHosts().
*/

async function fetchTopology() {
  try {
    const [linksRes, hostsRes, hostMapRes, routersRes, switchesRes] = await Promise.all([
      fetch('/v1.0/topology/links'),
      fetch('/v1.0/topology/hosts'),
      fetch('/hostmap'),
      fetch('/cfg/routers'),
      fetch('/v1.0/topology/switches')
    ]);

    const linksData = await linksRes.json();
    const hostsApi  = await hostsRes.json();      // può includere porte "infra"
    const hostMap   = await hostMapRes.json();    // [{ip,port,hostname,dpid?}]
    const routers   = await routersRes.json();    // [{dpid,...}] o []
    const switches  = await switchesRes.json();   // [{dpid,ports:[...]}]

    // ---- Indici porte
    const portIndexByName = new Map();            // nameLower -> {dpid, port_no}
    const portIndexByKey  = new Map();            // "dpid:port_no" -> nameLower
    switches.forEach(sw => {
      const dpidStr = String(sw.dpid);
      (sw.ports || []).forEach(p => {
        const name = String(p.name || '').toLowerCase();
        if (name) portIndexByName.set(name, { dpid: dpidStr, port_no: p.port_no });
        portIndexByKey.set(`${dpidStr}:${p.port_no}`, name);
      });
    });

    function resolvePortForHost(hostname) {
      if (!hostname) return null;
      const key = String(hostname).toLowerCase();
      const candidates = [key, `peer_${key}`, `peer-${key}`, `${key}_peer`, `${key}-peer`];
      for (const k of candidates) if (portIndexByName.has(k)) return portIndexByName.get(k);
      for (const [n, info] of portIndexByName.entries()) if (n.includes(key)) return info;
      return null;
    }

    // ---- Router DPIDs
    const routerDpids = new Set((routers || []).map(r => String(r.dpid)));
    switches.forEach(sw => {
      const hasVx = (sw.ports || []).some(p => String(p.name || '').toLowerCase().startsWith('vxlan'));
      if (hasVx) routerDpids.add(String(sw.dpid));
    });

    const nodesMap = {};
    const links = [];
    const macToHostName = {};
    const dpidToSwitchName = {};
    const ipToHostname = {};
    let switchCounter = 1;

    // ---- Filtra host su porte "infra"
    const INFRA_RE =/(^|[^a-z0-9])((\w+[-_]to[-_]\w+)|(router\d*[-_]link)|(vxlan\S*)|(vxlan_sys_\d+)|(\bdp\d+)|(\bpatch-\S+)|(\blocal\b))($|[^a-z0-9])/i;

    function getPortName(dpid, port_no) {
      return (portIndexByKey.get(`${String(dpid)}:${port_no}`) || '').toLowerCase();
    }

    // Porta “infra” solo se il nome la identifica chiaramente.
    // Porte senza nome NON sono infra (molte host-side non hanno name).
    function isInfraPort(dpid, port_no) {
      if (routerDpids.has(String(dpid))) return true;
      const name = getPortName(dpid, port_no);
      if (!name) return false;
      return INFRA_RE.test(name);
    }

    // Considero “host fantasma” solo se collegato a porta infra E non ha IP valido.
    function isGhostHost(h) {
      const dpid = h.port?.dpid, port_no = h.port?.port_no;
      // qualsiasi porta di un router → host non valido per la tua UI
      if (dpid != null && routerDpids.has(String(dpid))) return true;

      const hasIP = Boolean((h.ipv4 && h.ipv4[0]) || (h.ipv6 && h.ipv6[0]));
      return (dpid != null && port_no != null) && isInfraPort(dpid, port_no) && !hasIP;
    }

    // ---- IP -> hostname (etichette host)
    (hostMap || []).forEach(e => { if (e && e.ip) ipToHostname[e.ip] = e.hostname || e.ip; });

    // ---- Ricava etichette switch dai nomi di porta
    function guessSwitchLabelFromPorts(ports) {
      for (const p of (ports || [])) {
        const n = String(p.name || '').toLowerCase();
        let m = n.match(/^(?:s|ovs)(\d+)[-_]to[-_]/);
        if (m) return `s${m[1]}`;
        m = n.match(/^([a-z0-9]+)[-_]to[-_]/);
        if (m) {
          const pref = m[1];
          const m2 = pref.match(/^ovs(\d+)$/); if (m2) return `s${m2[1]}`;
          const m3 = pref.match(/^s(\d+)$/);   if (m3) return `s${m3[1]}`;
          return pref;
        }
      }
      return null;
    }
    switches.forEach(sw => {
      const dpid = String(sw.dpid);
      if (routerDpids.has(dpid)) return;
      const label = guessSwitchLabelFromPorts(sw.ports);
      if (label) dpidToSwitchName[dpid] = label;
    });

    const prevRouterNameMap = window._routerNameMap || {};
    let nextIdx = Object.keys(prevRouterNameMap).length + 1;

    Array.from(routerDpids).sort().forEach(dpid => {
      if (!prevRouterNameMap[dpid]) {
        prevRouterNameMap[dpid] = `r${nextIdx++}`;
      }
      // forza il nome del router (sovrascrive eventuale "sN")
      dpidToSwitchName[dpid] = prevRouterNameMap[dpid];
    });
    window._routerNameMap = prevRouterNameMap;

    // ---- Link switch-switch
    linksData.forEach(link => {
      const src = String(link.src.dpid);
      const dst = String(link.dst.dpid);
      if (!dpidToSwitchName[src]) dpidToSwitchName[src] = `s${switchCounter++}`;
      if (!dpidToSwitchName[dst]) dpidToSwitchName[dst] = `s${switchCounter++}`;
      links.push({ source: src, target: dst, src_port: link.src.port_no, dst_port: link.dst.port_no });
    });

    // === UI-ONLY: aggiungi tratto grafico tra router (VXLAN overlay) ===
    (function addRouterUiLinks() {
      const routersArr = Array.from(routerDpids).map(String).sort(); // ordina per stabilità
      if (routersArr.length < 2) return;

      // collega in "catena" r1—r2, r2—r3, ... (se vuoi solo r1—r2, fai un solo push)
      for (let i = 1; i < routersArr.length; i++) {
        const a = routersArr[i - 1], b = routersArr[i];
        const exists = links.some(l => {
          const src = typeof l.source === 'object' ? l.source.id : String(l.source);
          const dst = typeof l.target === 'object' ? l.target.id : String(l.target);
          return (src === a && dst === b) || (src === b && dst === a);
        });
        if (!exists) {
          links.push({
            source: a,
            target: b,
            src_port: 'VXLAN',
            dst_port: 'VXLAN',
            kind: 'router_vxlan'
          });
        }
      }
    })();

    // ============== UNIONE HOST con filtro INFRA ==============
    const hostsData = [];
    const seenIPs = new Set();

    // a) /hosts (filtrato)
    (hostsApi || []).forEach(h => {
      const ip = (h.ipv4 && h.ipv4[0]) || (h.ipv6 && h.ipv6[0]) || '';
      if (isGhostHost(h)) return; // scarta fantasma
      hostsData.push(h);
      if (ip) seenIPs.add(ip);
    });

    // b) /hostmap (aggiungi mancanti; deduci dpid/port; filtra INFRA)
    // b) /hostmap (aggiungi mancanti; deduci dpid/port; filtra INFRA)
    (hostMap || []).forEach(h => {
      if (!h) return;
      const ip = h.ip || '';
      if (ip && seenIPs.has(ip)) return;

      let dpid = h.dpid ? String(h.dpid) : null;
      let port_no = h.port;
      if (!dpid) {
        const resolved = resolvePortForHost(h.hostname);
        if (resolved) { dpid = resolved.dpid; if (!port_no) port_no = resolved.port_no; }
      }
      if (!dpid || !port_no) return;

      if (routerDpids.has(String(dpid))) return;       // ⬅️ evita host su porte dei router
      if (isInfraPort(dpid, port_no) && !ip) return;

      hostsData.push({
        mac: `host:${(h.hostname && h.hostname.trim()) || ip}`,
        ipv4: ip ? [ip] : [],
        port: { dpid, port_no }
      });
      if (ip) seenIPs.add(ip);
    });

    // ---- nodi host + link
    hostsData.forEach(host => {
      const hostId = host.mac;
      const ip = (host.ipv4 && host.ipv4[0]) || (host.ipv6 && host.ipv6[0]) || '';
      const hostname = ipToHostname[ip] || hostId;
      macToHostName[hostId] = hostname;

      nodesMap[hostId] = { id: hostId, type: 'host' };
      if (host.port && host.port.dpid != null) {
        links.push({ source: hostId, target: String(host.port.dpid), src_port: host.port.port_no, dst_port: 'N/A' });
      }
    });

    // ---- nodi switch/router
    const allDpids = new Set(Object.keys(dpidToSwitchName));
    hostsData.forEach(h => { if (h.port && h.port.dpid != null) allDpids.add(String(h.port.dpid)); });
    allDpids.forEach(dpid => {
      nodesMap[dpid] = { id: dpid, type: routerDpids.has(dpid) ? 'router' : 'switch' };
    });

    // ---- esponi mappe + disegna
    window._macToHostName = macToHostName;
    window._dpidToSwitchName = dpidToSwitchName;
    window._routerDpids = routerDpids;

    const nodes = Object.values(nodesMap);
    drawTopology(nodes, links, macToHostName, dpidToSwitchName);
  } catch (error) {
    console.error('Error fetching topology:', error);
  }
}

function drawTopology(nodes, links, macToHostName, dpidToSwitchName) {
  const svg = d3.select("#topology");
  svg.selectAll("*").remove(); // Clear previous drawings

  const width = +svg.attr("width");
  const height = +svg.attr("height");

  const container = svg.append("g");

  const simulation = d3.forceSimulation(nodes)
    .force("link", d3.forceLink(links).id(d => d.id).distance(120))
    .force("charge", d3.forceManyBody().strength(-300))
    .force("center", d3.forceCenter(width / 2, height / 2));

  const zoom = d3.zoom().on("zoom", (event) => {
    container.attr("transform", event.transform);
  });
  svg.call(zoom);

  // Draw links
  const link = container.append("g")
  .attr("stroke-linecap", "round")
  .selectAll("line")
  .data(links)
  .join("line")
  .attr("stroke", d => d.kind === 'router_vxlan' ? "#6aa" : "#aaa")
  .attr("stroke-width", d => d.kind === 'router_vxlan' ? 3 : 2)
  .attr("stroke-dasharray", d => d.kind === 'router_vxlan' ? "6,4" : null)
  .attr("stroke-opacity", d => d.kind === 'router_vxlan' ? 0.9 : 1);

  link.filter(d => d.kind === 'router_vxlan').raise();

  // Add tooltips to links
  link.append("title").text(d => `Src Port: ${d.src_port}, Dst Port: ${d.dst_port}`);

  // Draw nodes
  const node = container.append("g")
    .selectAll("image")
    .data(nodes)
    .join("image")
    .attr("href", d => {
      if (d.type === 'host') return 'images/host.png';
      if (d.type === 'router') return 'images/router.png';
      return 'images/switch.png';
    })
    .attr("width", 40)
    .attr("height", 40)
    .attr("x", -20)
    .attr("y", -20)
    .call(drag(simulation))
    .on("click", (event, d) => alert(`Node ID: ${d.id}, Type: ${d.type}`));

  node.append("title").text(d => d.id);

  // Add labels
  const label = container.append("g")
    .selectAll("text")
    .data(nodes)
    .join("text")
    .attr("text-anchor", "middle")
    .attr("dy", -25)
    .text(d => {
      if (d.type === 'host') {
        return macToHostName[d.id] || d.id;
      } else if (d.type === 'switch' || d.type === 'router') { // <— aggiungi router qui
        return dpidToSwitchName[d.id] || d.id;
      }
    });

  // Tick updates
  simulation.on("tick", () => {
    container.selectAll("line")
      .attr("x1", d => d.source.x)
      .attr("y1", d => d.source.y)
      .attr("x2", d => d.target.x)
      .attr("y2", d => d.target.y);

    node
      .attr("x", d => d.x - 20)
      .attr("y", d => d.y - 20);

    label
      .attr("x", d => d.x)
      .attr("y", d => d.y - 25);
  });

  function drag(simulation) {
    function dragstarted(event, d) {
      if (!event.active) simulation.alphaTarget(0.3).restart();
      d.fx = d.x;
      d.fy = d.y;
    }

    function dragged(event, d) {
      d.fx = event.x;
      d.fy = event.y;
    }

    function dragended(event, d) {
      if (!event.active) simulation.alphaTarget(0);
      d.fx = null;
      d.fy = null;
    }

    return d3.drag()
      .on("start", dragstarted)
      .on("drag", dragged)
      .on("end", dragended);
  }
}

async function fetchSwitches() {
  try {
    const container = document.getElementById("switchTableContainer");
    if (!container) return; // pagina senza la tabella Switches

    const res = await fetch('/v1.0/topology/switches');
    const switches = await res.json();

    if (!switches || switches.length === 0) {
      container.innerHTML = "<p>No switches found.</p>";
      return;
    }

    const dpidToSwitchName = window._dpidToSwitchName || {};
    let html = "<table border='1'><tr><th>Name</th><th>Switch</th><th>Port No</th><th>MAC</th><th>NameLink</th></tr>";
    switches.forEach(sw => {
      const swName = dpidToSwitchName[sw.dpid] || sw.dpid;
      (sw.ports || []).forEach(port => {
        html += `<tr>
          <td>${swName}</td>
          <td>${sw.dpid}</td>
          <td>${port.port_no}</td>
          <td>${port.hw_addr}</td>
          <td>${port.name}</td>
        </tr>`;
      });
    });
    container.innerHTML = html + "</table>";
  } catch (error) {
    console.error('Error fetching switches:', error);
  }
}

async function fetchHosts() {
  try {
    const container = document.getElementById("hostTableContainer");
    if (!container) return; // pagina senza la tabella Hosts

    const res = await fetch('/v1.0/topology/hosts');
    const hosts = await res.json();
    const macToHostName = window._macToHostName || {};
    const dpidToSwitchName = window._dpidToSwitchName || {};
    const routerDpids = window._routerDpids || new Set();

    if (!hosts || hosts.length === 0) {
      container.innerHTML = "<p>No hosts found.</p>";
      return;
    }

    let html = "<table border='1'><tr><th>Host</th><th>Hostname</th><th>IPv4</th><th>Switch</th><th>Port</th></tr>";
    let rows = 0;
    hosts.forEach(host => {
      if (host.port && routerDpids.has(String(host.port.dpid))) return; // salta host su router
      rows++;
      const hostname = macToHostName[host.mac] || host.mac;
      html += `<tr>
        <td>${host.mac}</td>
        <td>${hostname}</td>
        <td>${host.ipv4.join(', ')}</td>
        <td>${dpidToSwitchName[host.port.dpid] || host.port.dpid}</td>
        <td>${host.port.name ? `${host.port.name} (${host.port.port_no})` : host.port.port_no}</td>
      </tr>`;
    });
    container.innerHTML = rows ? html + "</table>" : "<p>No hosts (after filtering).</p>";
  } catch (error) {
    console.error('Error fetching hosts:', error);
  }
}

function refreshTopology() {
  const hasSvg = !!document.getElementById("topology"); // la pagina ha il canvas?
  const p = hasSvg ? fetchTopology() : Promise.resolve();

  p.then(() => {
    if (document.getElementById("switchTableContainer")) fetchSwitches();
    if (document.getElementById("hostTableContainer"))   fetchHosts();
  });
}

// Initialize Topology GUI
refreshTopology()