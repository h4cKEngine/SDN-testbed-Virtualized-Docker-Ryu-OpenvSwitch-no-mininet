"""
REST and web interface module for the Ryu `RyuFlows` application.

Contains WSGI controllers (`ControllerBase`) that expose APIs for:
  - dynamic management of allowed IP pairs (ACL),
  - host registration and lookup,
  - router configuration lookup,
  - serving static support web content.

Main components:
-----------------------
- **RyuApi**
    - Allowed pairs management:
        * POST `/pair` -> adds an allowed IP<->IP pair (idempotent).
        * DELETE `/pair` -> removes an IP<->IP pair (idempotent).
        * GET `/pairs` -> returns list of allowed pairs and, if available,
          the corresponding installed OpenFlow rules.
    - Host management:
        * POST `/register_host` -> registers a host with IP, port, and hostname.
        * GET `/hostmap` -> returns the registered host mapping.
- **RyuWebInterface**
    - Serving static files (HTML, CSS, JS, images) via the `/ryuflows/{filename}` route.
- **RouterApi**
    - Router configuration:
        * POST `/cfg/router/{dpid}` -> sets configuration for a router identified by DPID.
        * GET `/cfg/router/{dpid}` -> returns configuration of the specified router.
        * GET `/cfg/routers` -> lists configurations of all managed routers.

Features:
----------------
- REST endpoints operate idempotently where possible.
- IP pair management uses the `allowed_pairs` attribute of the `RyuFlows` instance.
- ACL rule reprogramming is done by invoking `update_allowed_pairs()` or,
  if missing, `program_policy_rules()` of the controller.
- Host registration and router configuration are stored in the internal state
  of `RyuFlows`.
- Static files are served from the `webpages/` subdirectory relative to the module.

Usage:
---------
These controllers are registered by the `RyuFlows` app's WSGI context if present,
enabling runtime policy management and configuration lookup via HTTP commands.
"""


from ryu.app.wsgi import ControllerBase, route
from webob import Response
import os, json

# Key to access the Ryu controller instance from the WSGI web context
ALLOWED_PAIR_KEY = 'allowed_pair_api'
# String to access the directory relative to the web interface
STATIC_DIR = os.path.join(os.path.dirname(__file__), 'webpages')

class RyuApi(ControllerBase):
    def __init__(self, req, link, data, **config):
        super(RyuApi, self).__init__(req, link, data, **config)
        self.controller = data[ALLOWED_PAIR_KEY] # Link to RyuFlows controller

    # API to add an allowed IP pair to communication
    @route('add_pair', '/pair', methods=['POST'])
    def add_allowed_pair(self, req, **kwargs):
        """
        POST /pair
        Body: {"src":"10.0.X.X","dst":"10.0.Y.Y"}
        - Idempotent: if pair already exists, returns 200.
        - Updates rules by calling update_allowed_pairs() (or fallback program_policy_rules()).
        """
        try:
            data = req.json if req.body else {}
            src_ip = str(data.get('src', '')).strip()
            dst_ip = str(data.get('dst', '')).strip()
            if not src_ip or not dst_ip:
                return Response(status=400, body='Missing src or dst IP')

            pair = (src_ip, dst_ip)

            # Build new set (idempotent)
            new_set = set(getattr(self.controller, 'allowed_pairs', set()))
            if pair in new_set:
                # Already present: no reprogramming needed
                return Response(status=200, body='Pair already exists\n')

            new_set.add(pair)

            # Prefer controller API that normalizes and reprograms
            if hasattr(self.controller, 'update_allowed_pairs'):
                self.controller.update_allowed_pairs(new_set)
            else:
                # Fallback: update and reprogram
                self.controller.allowed_pairs = new_set
                if hasattr(self.controller, 'program_policy_rules'):
                    self.controller.program_policy_rules()

            self.controller.logger.info(f'Added allowed pair: {src_ip} -> {dst_ip}')
            return Response(status=200, body='Pair added\n')

        except Exception as e:
            return Response(status=500, body=str(e))

    # Route to remove a pair via DELETE
    @route('ryu_routes', '/pair', methods=['DELETE'])
    def remove_allowed_pair(self, req, **kwargs):
        """
        DELETE /pair
        Body: {"src":"10.0.X.X","dst":"10.0.Y.Y"}
        - Idempotent: if pair does not exist, returns 404.
        - Updates rules by calling update_allowed_pairs() (or fallback program_policy_rules()).
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

            # Prefer controller API that normalizes and reprograms
            if hasattr(self.controller, 'update_allowed_pairs'):
                self.controller.update_allowed_pairs(current)
            else:
                # Fallback: update and reprogram
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

    # API to get dynamic host mapping (IP, port) -> hostname
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
        -> Returns the list of allowed pairs.
          If controller exposes 'pair_to_flows', matches installed are also added.
        """
        controller = self.controller  # type: ignore

        pairs_out = []
        flow_map = getattr(controller, 'pair_to_flows', None)  # may not exist
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
    # Private method to return a file with the correct content
    def _serve_file(self, path, content_type):
        full_path = os.path.join(STATIC_DIR, path.lstrip('/'))
        if not os.path.isfile(full_path):
            return Response(status=404, body='File not found')
        with open(full_path, 'rb') as f:
            return Response(content_type=content_type, body=f.read())

    # Route to serve HTML files via the /ryuflows/{filename} path
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
        # set self.controller just like in RyuApi
        self.controller = data[ALLOWED_PAIR_KEY]

    @route('cfg_router', '/cfg/router/{dpid}', methods=['POST'])
    def set_router(self, req, **kwargs):
        dpid = kwargs['dpid']
        body = req.json or {}
        # save in controller.router_cfg
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
        # controller.router_cfg is a dict { dpid_str: {…config…}, … }
        entries = [
            {'dpid': dpid, 'config': cfg}
            for dpid, cfg in self.controller.router_cfg.items()
        ]
        body = json.dumps(entries, indent=2)
        # option A: specify charset
        return Response(
            content_type='application/json',
            charset='utf-8',
            body=body
        )
