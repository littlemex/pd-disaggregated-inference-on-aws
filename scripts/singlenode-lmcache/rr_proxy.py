#!/usr/bin/env python3
"""Round-robin TCP proxy with true byte-level streaming.

Usage:
    python3 rr_proxy.py --listen 0.0.0.0:8100 \
        --backend http://127.0.0.1:18001 \
        --backend http://127.0.0.1:18002

- TCP レベルのプロキシ。HTTP を一切解釈せずバイトをそのまま双方向転送。
- round-robin: 新規接続ごとに次のバックエンドに振る。
- aiohttp / httpx などの streaming に対し TTFT を正しく計測可能。
"""
from __future__ import annotations

import argparse
import itertools
import logging
import select
import socket
import sys
import threading
from urllib.parse import urlparse

LOG = logging.getLogger("rr_proxy")
BUF = 65536


class _State:
    def __init__(self, backends: list[tuple[str, int]]) -> None:
        self.backends = backends
        self._iter = itertools.cycle(backends)
        self._lock = threading.Lock()

    def pick(self) -> tuple[str, int]:
        with self._lock:
            return next(self._iter)


_state: _State | None = None


def _pipe(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            r, _, _ = select.select([src], [], [], 60)
            if not r:
                break
            data = src.recv(BUF)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass


def _handle(client: socket.socket, backend_host: str, backend_port: int) -> None:
    try:
        backend = socket.create_connection((backend_host, backend_port), timeout=10)
    except OSError as e:
        LOG.warning("cannot connect to %s:%d: %s", backend_host, backend_port, e)
        client.close()
        return

    t = threading.Thread(target=_pipe, args=(backend, client), daemon=True)
    t.start()
    _pipe(client, backend)
    t.join(timeout=300)

    for s in (client, backend):
        try:
            s.close()
        except OSError:
            pass


def _serve(listen_host: str, listen_port: int) -> None:
    assert _state is not None
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((listen_host, listen_port))
    srv.listen(256)
    LOG.info("proxy listening on %s:%d, backends=%s",
             listen_host, listen_port,
             ["%s:%d" % b for b in _state.backends])

    while True:
        client, addr = srv.accept()
        host, port = _state.pick()
        LOG.debug("conn from %s → %s:%d", addr, host, port)
        threading.Thread(target=_handle, args=(client, host, port), daemon=True).start()


def main() -> int:
    global _state
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True, help="host:port e.g. 0.0.0.0:8100")
    parser.add_argument("--backend", action="append", required=True,
                        help="backend URL, repeatable")
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args()

    logging.basicConfig(level=args.log_level.upper(), format="[%(asctime)s] %(message)s")

    listen_host, port_s = args.listen.rsplit(":", 1)
    listen_port = int(port_s)

    backends: list[tuple[str, int]] = []
    for b in args.backend:
        p = urlparse(b)
        if not (p.scheme and p.hostname and p.port):
            LOG.error("invalid backend URL: %s", b)
            return 2
        backends.append((p.hostname, p.port))

    _state = _State(backends)
    try:
        _serve(listen_host, listen_port)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
