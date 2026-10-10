#!/usr/bin/env python3
"""Tiny forwarding HTTP proxy used only while Terraform runs.

The AWS provider talks to S3 Control through the virtual host
``<account-id>.<endpoint-host>``. That name does not resolve inside this
workspace, so the provider is pointed at a synthetic S3 Control host and
``HTTP_PROXY`` is set to this process, which relays every request it receives to
the real control-plane endpoint while preserving the Host header.
"""
import http.client
import socketserver
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

TARGET = urllib.parse.urlparse(sys.argv[2])
HOP = {"proxy-connection", "connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            out = b""
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    return out
                out += self.rfile.read(size)
                self.rfile.readline()
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _relay(self):
        body = self._read_body()
        path = self.path
        if path.startswith("http://") or path.startswith("https://"):
            u = urllib.parse.urlparse(path)
            path = u.path + ("?" + u.query if u.query else "")
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        if body:
            headers["Content-Length"] = str(len(body))
        conn = http.client.HTTPConnection(TARGET.hostname, TARGET.port or 80, timeout=120)
        try:
            conn.request(self.command, path, body=body or None, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in HOP or k.lower() == "content-length":
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
        except Exception as exc:  # noqa: BLE001
            msg = str(exc).encode()
            self.send_response(502)
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
        finally:
            conn.close()

    do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = do_PATCH = _relay


class Server(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    port = int(sys.argv[1])
    Server(("127.0.0.1", port), Handler).serve_forever()
