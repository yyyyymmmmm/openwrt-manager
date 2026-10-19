"""CI-only HTTP fixture. Not an app resource; never connects to a real router."""

import copy
import json
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs


SESSIONS = {}
LOCK = threading.RLock()
COMMAND = "/usr/libexec/package-manager-call list-installed"
PACKAGES = [
    {"name": "luci-app-ci-extension", "version": "1.0-ci", "description": "CI integration fixture", "depends": ["ci-extension"], "contents": []},
    {"name": "ci-extension", "version": "1.0-ci", "depends": [], "contents": ["etc/config/ci_extension", "etc/init.d/ci_extension"]},
]
MENU = {"children": {"admin": {"children": {"services": {
    "title": "Services", "children": {"ci_extension": {
        "title": "CI Extension", "depends": {"acl": ["luci-app-ci-extension"], "uci": {"ci_extension": True}}
    }}
}}}}}


def new_state(readonly):
    return {"readonly": readonly, "configs": {
        "system": {"main": {".type": "system", ".index": 0, ".anonymous": False, "hostname": "ci-router"}},
        "ci_extension": {"main": {".type": "service", ".index": 0, ".anonymous": False, "enabled": "1", "servers": ["one", "two"]}},
    }, "staged": {}, "before": None, "deadline": None, "running": True, "enabled": True}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self.send_json({"test_only": True})
        if self.path == "/cgi-bin/luci/admin/menu":
            token = self.headers.get("Cookie", "").removeprefix("sysauth_http=")
            return self.send_json(MENU if token in SESSIONS else {}, 200 if token in SESSIONS else 403)
        self.send_json({}, 404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path == "/cgi-bin/cgi-exec":
            form = parse_qs(body.decode())
            if form.get("sessionid", [""])[0] not in SESSIONS:
                return self.send_json({}, 403)
            if form.get("command", [""])[0] != COMMAND:
                return self.send_json({}, 400)
            return self.send_json(PACKAGES)
        if self.path != "/ubus":
            return self.send_json({}, 404)
        try:
            request = json.loads(body)
            token, obj, method, args = request["params"]
            with LOCK:
                code, result = self.rpc(token, obj, method, args)
            self.send_json({"jsonrpc": "2.0", "id": request["id"], "result": [code, result]})
        except (KeyError, ValueError, TypeError):
            self.send_json({}, 400)

    def rpc(self, token, obj, method, args):
        if (obj, method) == ("session", "login"):
            if args.get("username") not in ("root", "readonly") or args.get("password") != "ci-only-password":
                return 6, {}
            token = secrets.token_hex(16)
            SESSIONS[token] = new_state(args["username"] == "readonly")
            return 0, {"ubus_rpc_session": token, "expires": 3600}
        if token not in SESSIONS:
            return 6, {}
        state = SESSIONS[token]
        if state["deadline"] and time.monotonic() >= state["deadline"]:
            state["configs"] = state["before"]
            state["before"] = state["deadline"] = None
        if obj == "session":
            if method == "access":
                return 0, {"access": not state["readonly"] or args.get("function") == "read"}
            if method == "destroy":
                del SESSIONS[token]
                return 0, {}
        if (obj, method) == ("system", "board"):
            return 0, {"hostname": state["configs"]["system"]["main"]["hostname"], "model": "CI integration server", "kernel": "6.6-ci", "release": {"distribution": "OpenWrt", "version": "CI", "target": "x86/64"}}
        if (obj, method) == ("system", "info"):
            return 0, {"uptime": 3600, "memory": {"total": 1073741824, "available": 536870912}, "load": [6553, 3276, 1638], "root": {"total": 1000000, "used": 250000}}
        if (obj, method) == ("network.interface", "dump"):
            return 0, {"interface": [{"interface": "lan", "up": True, "proto": "static", "l3_device": "br-lan", "ipv4-address": [{"address": "192.0.2.1", "mask": 24}]}]}
        if (obj, method) == ("luci-rpc", "getDHCPLeases"):
            return 0, {"dhcp_leases": [{"hostname": "CI Phone", "ipaddr": "192.0.2.10", "macaddr": "02:00:00:00:00:01", "expires": 1800}], "dhcp6_leases": []}
        if (obj, method) == ("network.wireless", "status"):
            return 6, {}
        if (obj, method) == ("service", "list"):
            return 0, {"ci_extension": {"instances": {"main": {"running": state["running"]}}}}
        if (obj, method) == ("file", "list") and args.get("path") == "/etc/config":
            return 0, {"entries": [{"name": name, "type": "file"} for name in state["configs"]]}
        if (obj, method) == ("luci", "getInitList"):
            return 0, {"ci_extension": {"enabled": state["enabled"]}}
        if (obj, method) == ("luci", "setInitAction"):
            if state["readonly"]:
                return 6, {}
            if args.get("name") != "ci_extension":
                return 4, {}
            action = args.get("action")
            if action in ("start", "restart", "stop"):
                state["running"] = action != "stop"
            elif action in ("enable", "disable"):
                state["enabled"] = action == "enable"
            else:
                return 2, {}
            return 0, {"result": True}
        if (obj, method) == ("log", "read"):
            return 0, {"log": [{"msg": "CI fixture log", "metadata": {"test_only": True}}]}
        if obj == "luci" and method in ("getProcessList", "getMountPoints"):
            return 0, {"result": [{"name": "CI fixture", "active": True, "nested": {"value": "preserved"}}]}
        if obj == "uci":
            if method == "get":
                config = args.get("config")
                if config not in state["configs"]:
                    return 4, {}
                return 0, {"values": state["staged"].get(config, state["configs"][config])}
            if method == "changes":
                return 0, {"changes": {name: [["set"]] for name in state["staged"]}}
            if state["readonly"]:
                return 6, {}
            if method in ("set", "delete", "add"):
                config = args["config"]
                draft = state["staged"].setdefault(config, copy.deepcopy(state["configs"][config]))
                section = args.get("section")
                if method == "set":
                    draft[section].update(args["values"])
                elif method == "delete":
                    if "option" in args:
                        del draft[section][args["option"]]
                    else:
                        del draft[section]
                else:
                    name = args.get("name", "cfg" + secrets.token_hex(3))
                    draft[name] = {".type": args["type"], ".index": len(draft), ".anonymous": "name" not in args, **args.get("values", {})}
                    return 0, {"section": name}
                return 0, {}
            if method == "revert":
                state["staged"].pop(args["config"], None)
                return 0, {}
            if method == "apply":
                if args != {"rollback": True, "timeout": 90}:
                    return 2, {}
                state["before"] = copy.deepcopy(state["configs"])
                state["configs"].update(state["staged"])
                state["staged"] = {}
                state["deadline"] = time.monotonic() + 90
                return 0, {}
            if method in ("confirm", "rollback"):
                if state["before"] is None:
                    return 5, {}
                if method == "rollback":
                    state["configs"] = state["before"]
                state["before"] = state["deadline"] = None
                return 0, {}
        return 4, {}


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18795), Handler).serve_forever()
