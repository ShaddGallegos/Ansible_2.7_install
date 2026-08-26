#!/usr/bin/python3
import argparse
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST_PATTERN = re.compile(r"^[A-Za-z0-9.:[\]-]+$")


def normalized_host(value: str, fallback: str) -> str:
    host = value.strip()
    if not host or not HOST_PATTERN.fullmatch(host):
        return fallback
    if host.startswith("["):
        closing_bracket = host.find("]")
        return host[: closing_bracket + 1] if closing_bracket > 0 else fallback
    if host.count(":") == 1:
        hostname, port = host.rsplit(":", 1)
        if port.isdigit():
            return hostname
    return host


class RedirectHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AAP-HTTP-Redirect"
    sys_version = ""
    fallback_host = "localhost"
    https_port = 443

    def redirect(self) -> None:
        host = normalized_host(self.headers.get("Host", ""), self.fallback_host)
        port = "" if self.https_port == 443 else f":{self.https_port}"
        path = self.path.replace("\r", "").replace("\n", "")
        self.send_response(308)
        self.send_header("Location", f"https://{host}{port}{path}")
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    do_GET = redirect
    do_HEAD = redirect
    do_POST = redirect
    do_PUT = redirect
    do_PATCH = redirect
    do_DELETE = redirect
    do_OPTIONS = redirect

    def log_message(self, format_string: str, *args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=80)
    parser.add_argument("--https-port", type=int, default=443)
    parser.add_argument("--fallback-host", default="localhost")
    args = parser.parse_args()

    RedirectHandler.fallback_host = args.fallback_host
    RedirectHandler.https_port = args.https_port
    ThreadingHTTPServer(("0.0.0.0", args.port), RedirectHandler).serve_forever()


if __name__ == "__main__":
    main()
