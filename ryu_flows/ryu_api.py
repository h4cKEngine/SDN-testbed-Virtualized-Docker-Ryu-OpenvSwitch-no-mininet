"""
Modulo di interfaccia REST e web per l’applicazione Ryu `RyuFlows`.

Contiene controller WSGI (`ControllerBase`) che espongono API per:
  - gestione dinamica di coppie IP consentite (ACL),
  - registrazione e consultazione mappatura host,
  - consultazione configurazioni router,
  - erogazione di contenuti web statici di supporto.

Componenti principali:
-----------------------
- **RyuApi**
    - Gestione coppie consentite:
        * POST `/pair` → aggiunge una coppia IP↔IP consentita (idempotente).
        * DELETE `/pair` → rimuove una coppia IP↔IP (idempotente).
        * GET `/pairs` → restituisce elenco delle coppie consentite e, se disponibile,
          le corrispondenti regole OpenFlow installate.
    - Gestione host:
        * POST `/register_host` → registra un host con IP, porta e hostname.
        * GET `/hostmap` → restituisce la mappatura host registrati.
- **RyuWebInterface**
    - Erogazione file statici (HTML, CSS, JS, immagini) tramite rotta `/ryuflows/{filename}`.
- **RouterApi**
    - Configurazione router:
        * POST `/cfg/router/{dpid}` → imposta configurazione per un router identificato da DPID.
        * GET `/cfg/router/{dpid}` → restituisce configurazione del router specificato.
        * GET `/cfg/routers` → elenca configurazioni di tutti i router gestiti.

Caratteristiche:
----------------
- Gli endpoint REST operano in modalità idempotente quando possibile.
- La gestione delle coppie IP utilizza l’attributo `allowed_pairs` dell’istanza `RyuFlows`.
- La riprogrammazione delle regole ACL è effettuata invocando `update_allowed_pairs()` o,
  in assenza, `program_policy_rules()` del controller.
- La registrazione host e la configurazione router vengono memorizzate nello stato interno
  di `RyuFlows`.
- I file statici sono serviti dalla sottodirectory `webpages/` relativa al modulo.

Utilizzo:
---------
Questi controller vengono registrati dal contesto WSGI dell’app `RyuFlows` se presente,
permettendo la gestione runtime delle policy e la consultazione della configurazione
tramite comandi HTTP.
"""


from ryu.app.wsgi import ControllerBase, route
from webob import Response
import os, json

# Chiave per accedere all'istanza del controller Ryu dal contesto web WSGI
ALLOWED_PAIR_KEY = 'allowed_pair_api'
# Stringa per accedere alla directory relativa all'intefaccia web
STATIC_DIR = os.path.join(os.path.dirname(__file__), 'webpages')

class RyuApi(ControllerBase):
    def __init__(self, req, link, data, **config):
        super(RyuApi, self).__init__(req, link, data, **config)
        self.controller = data[ALLOWED_PAIR_KEY] # Collegamento al controller RyuFlows

    # API per aggiungere una coppia IP consentita alla comunicazione
    @route('add_pair', '/pair', methods=['POST'])
    def add_allowed_pair(self, req, **kwargs):
        """
        POST /pair
        Body: {"src":"10.0.X.X","dst":"10.0.Y.Y"}
        - Idempotente: se la coppia esiste già, risponde 200.
        - Aggiorna le regole chiamando update_allowed_pairs() (o, fallback, program_policy_rules()).
        """
        try:
            data = req.json if req.body else {}
            src_ip = str(data.get('src', '')).strip()
            dst_ip = str(data.get('dst', '')).strip()
            if not src_ip or not dst_ip:
                return Response(status=400, body='Missing src or dst IP')

            pair = (src_ip, dst_ip)

            # Costruiamo nuovo set (idempotente)
            new_set = set(getattr(self.controller, 'allowed_pairs', set()))
            if pair in new_set:
                # Già presente: nessuna riprogrammazione necessaria
                return Response(status=200, body='Pair already exists\n')

            new_set.add(pair)

            # Preferisci l'API del controller che normalizza e riprogramma
            if hasattr(self.controller, 'update_allowed_pairs'):
                self.controller.update_allowed_pairs(new_set)
            else:
                # Fallback: aggiorna e riprogramma
                self.controller.allowed_pairs = new_set
                if hasattr(self.controller, 'program_policy_rules'):
                    self.controller.program_policy_rules()

            self.controller.logger.info(f'Added allowed pair: {src_ip} -> {dst_ip}')
            return Response(status=200, body='Pair added\n')

        except Exception as e:
            return Response(status=500, body=str(e))

    # Rotta per rimuovere una coppia via DELETE
    @route('ryu_routes', '/pair', methods=['DELETE'])
    def remove_allowed_pair(self, req, **kwargs):
        """
        DELETE /pair
        Body: {"src":"10.0.X.X","dst":"10.0.Y.Y"}
        - Idempotente: se la coppia non esiste risponde 404.
        - Aggiorna le regole chiamando update_allowed_pairs() (o, fallback, program_policy_rules()).
        """
        try:
            data = req.json if req.body else {}
            src_ip = str(data.get('src', '')).strip()
            dst_ip = str(data.get('dst', '')).strip()
            if not src_ip or not dst_ip:
                return Response(status=400, body="Invalid request payload")

            pair = (src_ip, dst_ip)
            current = set(getattr(self.controller, 'allowed_pairs', set()))
            if pair not in current:
                return Response(status=404, body="Pair not found")

            current.discard(pair)

            # Preferisci l'API del controller che normalizza e riprogramma
            if hasattr(self.controller, 'update_allowed_pairs'):
                self.controller.update_allowed_pairs(current)
            else:
                # Fallback: aggiorna e riprogramma
                self.controller.allowed_pairs = current
                if hasattr(self.controller, 'program_policy_rules'):
                    self.controller.program_policy_rules()

            self.controller.logger.info(f'Removed allowed pair: {src_ip} -> {dst_ip}')
            return Response(status=200, body=f"Pair removed: {src_ip} -> {dst_ip}\n")

        except Exception as e:
            return Response(status=500, body=str(e))

    @route('register_host', '/register_host', methods=['POST'])
    def register_host(self, req, **kwargs):
        try:
            data = req.json
            ip = data.get('ip')
            port = data.get('port')
            hostname = data.get('hostname')
            dpid = str(data.get('dpid', '')).strip()
            if ip and port and hostname:
                self.controller.host_info[ip] = {
                    "hostname": hostname,
                    "port": port,
                    "dpid": dpid or None
                }
                return Response(status=200, body='Host registered\n')
            return Response(status=400, body='Missing fields')
        except Exception as e:
            return Response(status=500, body=str(e))

    # API per ottenere la mappatura dinamica degli host (IP, porta) → nome host
    @route('hostmap', '/hostmap', methods=['GET'])
    def list_host_mapping(self, req, **kwargs):
        entries = []
        for key, data in self.controller.host_info.items():
            if isinstance(key, tuple) and isinstance(data, dict):
                ip, port = key
                entries.append({
                    "ip": ip,
                    "port": port,
                    "hostname": data.get("hostname"),
                    "dpid": data.get("dpid")
                })
            elif isinstance(key, str) and isinstance(data, dict):
                entries.append({
                    "ip": key,
                    "port": data.get("port"),
                    "hostname": data.get("hostname"),
                    "dpid": data.get("dpid")
                })
        return Response(content_type='application/json', text=json.dumps(entries, indent=2))

    @route('list_pairs', '/pairs', methods=['GET'])
    def list_allowed_pairs(self, req, **kwargs):
        """
        GET /pairs
        → Ritorna l'elenco delle coppie consentite.
          Se il controller espone 'pair_to_flows', aggiunge anche i match installati.
        """
        controller = self.controller  # type: ignore

        pairs_out = []
        flow_map = getattr(controller, 'pair_to_flows', None)  # può non esistere
        for src, dst in sorted(getattr(controller, 'allowed_pairs', set())):
            entry = {'src': src, 'dst': dst}
            if isinstance(flow_map, dict):
                flows = flow_map.get((src, dst), [])
                entry['flows'] = [
                    {
                        'dpid': getattr(dp, 'id', None),
                        'match': repr(match)
                    }
                    for dp, match in flows
                ]
            pairs_out.append(entry)

        body = json.dumps({'pairs': pairs_out}, indent=2)
        return Response(
            body=body,
            content_type='application/json',
            charset='utf-8'
        )

class RyuWebInterface(ControllerBase):
    # Metodo privato che restituisce un file con il giusto contenuto
    def _serve_file(self, path, content_type):
        full_path = os.path.join(STATIC_DIR, path.lstrip('/'))
        if not os.path.isfile(full_path):
            return Response(status=404, body='File not found')
        with open(full_path, 'rb') as f:
            return Response(content_type=content_type, body=f.read())

    # Rotta per servire file HTML tramite il path /ryuflows/{filename}
    @route('ryu_routes', '/ryuflows/{filename:.*}', methods=['GET'])
    def serve_file(self, req, filename, **kwargs):
        ext = os.path.splitext(filename)[1].lower()
        content_types = {
            '.html': 'text/html',
            '.css': 'text/css',
            '.js': 'application/javascript',
            '.ico': 'image/x-icon',
            '.png': 'image/png',
        }
        content_type = content_types.get(ext, 'application/octet-stream')
        return self._serve_file(filename, content_type)
    
class RouterApi(ControllerBase):
    def __init__(self, req, link, data, **config):
        super(RouterApi, self).__init__(req, link, data, **config)
        # qui imposti self.controller proprio come in RyuApi
        self.controller = data[ALLOWED_PAIR_KEY]

    @route('cfg_router', '/cfg/router/{dpid}', methods=['POST'])
    def set_router(self, req, **kwargs):
        dpid = kwargs['dpid']
        body = req.json or {}
        # salva in controller.router_cfg
        self.controller.router_cfg.setdefault(dpid, {}).update(body)
        return Response(status=200, body='OK\n')

    @route('cfg_router', '/cfg/router/{dpid}', methods=['GET'])
    def get_router(self, req, **kwargs):
        dpid = kwargs['dpid']
        cfg = self.controller.router_cfg.get(dpid, {})
        body = json.dumps(cfg, indent=2)
        return Response(
            body=body,
            content_type='application/json',
            charset='utf-8'
        )

    @route('cfg_routers', '/cfg/routers', methods=['GET'])
    def list_routers(self, req, **kwargs):
        # controller.router_cfg è un dict { dpid_str: {…config…}, … }
        entries = [
            {'dpid': dpid, 'config': cfg}
            for dpid, cfg in self.controller.router_cfg.items()
        ]
        body = json.dumps(entries, indent=2)
        # opzione A: specifico il charset
        return Response(
            content_type='application/json',
            charset='utf-8',
            body=body
        )
