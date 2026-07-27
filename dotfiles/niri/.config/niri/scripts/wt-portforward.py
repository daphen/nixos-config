#!/usr/bin/env python3
"""Dual-stack TCP forwarder: listen on LISTEN, forward to 127.0.0.1:TARGET.

Binds v4 and v6 separately because some callers resolve localhost to ::1 and
others to 127.0.0.1; a v4-only listener silently fails for half of them.
"""

import socket
import sys
import threading

LISTEN, TARGET = int(sys.argv[1]), int(sys.argv[2])


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(family, addr):
    srv = socket.socket(family, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    srv.bind((addr, LISTEN))
    srv.listen(16)
    print(f"forwarding {addr}:{LISTEN} -> 127.0.0.1:{TARGET}", flush=True)
    while True:
        client, _ = srv.accept()
        try:
            upstream = socket.create_connection(("127.0.0.1", TARGET))
        except OSError:
            client.close()
            continue
        threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


threading.Thread(target=serve, args=(socket.AF_INET, "127.0.0.1"), daemon=True).start()
serve(socket.AF_INET6, "::1")
