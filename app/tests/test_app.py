import json
import threading
import time
import unittest
import urllib.request
from http.server import HTTPServer

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from app import AppHandler

TEST_PORT = 18080


def start_test_server():
    server = HTTPServer(("127.0.0.1", TEST_PORT), AppHandler)
    thread = threading.Thread(target=server.serve_forever)
    thread.daemon = True
    thread.start()
    time.sleep(0.2)
    return server


class TestApp(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.server = start_test_server()
        cls.base = f"http://127.0.0.1:{TEST_PORT}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def get(self, path):
        with urllib.request.urlopen(f"{self.base}{path}") as r:
            return r.status, json.loads(r.read())

    def test_root_returns_200(self):
        status, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn("message", body)

    def test_health_returns_healthy(self):
        status, body = self.get("/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "healthy")
        self.assertIn("timestamp", body)
        self.assertIn("version", body)

    def test_info_returns_platform(self):
        status, body = self.get("/info")
        self.assertEqual(status, 200)
        self.assertIn("python", body)
        self.assertIn("hostname", body)

    def test_unknown_route_returns_404(self):
        try:
            urllib.request.urlopen(f"{self.base}/unknown")
        except urllib.error.HTTPError as e:
            self.assertEqual(e.code, 404)


if __name__ == "__main__":
    unittest.main()
