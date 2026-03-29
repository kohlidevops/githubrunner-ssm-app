import json
import os
import logging
import platform
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger(__name__)

APP_ENV  = os.getenv("APP_ENV", "dev")
APP_PORT = int(os.getenv("PORT", 8080))
APP_NAME = os.getenv("APP_NAME", "my-app")
VERSION  = os.getenv("APP_VERSION", "1.0.0")


class AppHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        routes = {
            "/":        self.handle_root,
            "/health":  self.handle_health,
            "/info":    self.handle_info,
        }
        handler = routes.get(self.path, self.handle_not_found)
        handler()

    def handle_root(self):
        self._json(200, {
            "message": f"Hello from {APP_NAME}!",
            "env":     APP_ENV,
            "version": VERSION,
        })

    def handle_health(self):
        self._json(200, {
            "status":    "healthy",
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "env":       APP_ENV,
            "version":   VERSION,
        })

    def handle_info(self):
        self._json(200, {
            "app":      APP_NAME,
            "version":  VERSION,
            "env":      APP_ENV,
            "python":   platform.python_version(),
            "hostname": platform.node(),
            "os":       platform.system(),
        })

    def handle_not_found(self):
        self._json(404, {"error": "Not found", "path": self.path})

    def _json(self, status, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        logger.info(f"{self.client_address[0]} - {format % args}")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", APP_PORT), AppHandler)
    logger.info(f"Starting {APP_NAME} v{VERSION} on port {APP_PORT} [{APP_ENV}]")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Server stopped")
        server.server_close()
