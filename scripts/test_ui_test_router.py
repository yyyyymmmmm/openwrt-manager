"""Verify the CI server through the same HTTP protocol used by the iOS app."""

import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.request import Request, urlopen

from ui_test_router import Handler


class RouterHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/ubus"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join(timeout=5)

    def rpc(self, token, obj, method, args=None):
        payload = {"jsonrpc": "2.0", "id": 1, "method": "call", "params": [token, obj, method, args or {}]}
        with urlopen(Request(self.url, json.dumps(payload).encode(), {"Content-Type": "application/json"}), timeout=5) as response:
            return json.load(response)["result"]

    def login(self, username="root"):
        code, result = self.rpc("0" * 32, "session", "login", {"username": username, "password": "ci-only-password"})
        self.assertEqual(code, 0)
        return result["ubus_rpc_session"]

    def test_four_fixed_queries_and_unknown_command_rejection(self):
        token = self.login()
        for family in ("-4", "-6"):
            for table in ("route", "neigh"):
                code, result = self.rpc(token, "file", "exec", {"command": "/sbin/ip", "params": [family, table, "show"]})
                self.assertEqual((code, result["code"]), (0, 0))
                self.assertTrue(result["stdout"])
        for args in ({"command": "/bin/sh", "params": ["-c", "true"]}, {"command": "/sbin/ip", "params": ["link", "set", "br-lan", "down"]}):
            self.assertEqual(self.rpc(token, "file", "exec", args)[0], 6)

    def test_denied_command_error_and_expired_session_remain_distinct(self):
        args = {"command": "/sbin/ip", "params": ["-4", "route", "show"]}
        self.assertEqual(self.rpc(self.login("route-denied"), "file", "exec", args)[0], 6)
        code, result = self.rpc(self.login("route-failure"), "file", "exec", args)
        self.assertEqual((code, result["code"]), (0, 1))
        self.assertIn("unavailable", result["stderr"])
        token = self.login()
        self.rpc(token, "session", "destroy")
        self.assertEqual(self.rpc(token, "file", "exec", args)[0], 6)

    def test_sessions_isolate_changes_and_rollback_restores_values(self):
        first, second = self.login(), self.login()
        args = {"config": "ci_extension", "section": "main", "values": {"servers": ["three", "four"]}}
        self.assertEqual(self.rpc(first, "uci", "set", args)[0], 0)
        self.assertEqual(self.rpc(first, "uci", "apply", {"rollback": True, "timeout": 90})[0], 0)
        def servers(token):
            return self.rpc(token, "uci", "get", {"config": "ci_extension"})[1]["values"]["main"]["servers"]
        self.assertEqual(servers(first), ["three", "four"])
        self.assertEqual(servers(second), ["one", "two"])
        self.assertEqual(self.rpc(first, "uci", "rollback")[0], 0)
        self.assertEqual(servers(first), ["one", "two"])

    def test_readonly_cannot_stage_or_control_service(self):
        token = self.login("readonly")
        for obj, method, args in [
            ("uci", "set", {"config": "system", "section": "main", "values": {"hostname": "changed"}}),
            ("luci", "setInitAction", {"name": "ci_extension", "action": "stop"}),
        ]:
            self.assertEqual(self.rpc(token, obj, method, args)[0], 6)


if __name__ == "__main__":
    unittest.main()
