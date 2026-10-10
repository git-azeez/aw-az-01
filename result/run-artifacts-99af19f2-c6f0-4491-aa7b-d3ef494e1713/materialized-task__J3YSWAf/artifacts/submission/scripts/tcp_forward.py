#!/usr/bin/env python3
"""Tiny TCP forwarder: 127.0.0.1:<listen_port> -> <host>:<port>.

The AWS provider's S3 Control client prepends the account id to the endpoint
host name (000000000000.<host>), which cannot be resolved for the single-label
control-plane host.  `*.localhost` always resolves to loopback, so Terraform
points its s3control endpoint at this forwarder instead.
"""
import socket
import sys
import threading


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()


def handle(client, host, port):
    try:
        upstream = socket.create_connection((host, port), timeout=10)
        upstream.settimeout(None)
    except OSError:
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


def main():
    listen_port, host, port = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", listen_port))
    srv.listen(128)
    print(srv.getsockname()[1], flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, host, port), daemon=True).start()


if __name__ == "__main__":
    main()
