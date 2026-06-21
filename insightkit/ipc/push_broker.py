"""Push event broker for persistent IPC connections."""

from __future__ import annotations

import json
import logging
import socket
import threading
from typing import Any

logger = logging.getLogger(__name__)


class PushBroker:
    """Manages persistent client connections and broadcasts push events."""

    def __init__(self) -> None:
        self._clients: dict[int, socket.socket] = {}
        self._lock = threading.Lock()

    @property
    def client_count(self) -> int:
        with self._lock:
            return len(self._clients)

    def register(self, conn: socket.socket) -> None:
        with self._lock:
            self._clients[conn.fileno()] = conn

    def register_ready(self, conn: socket.socket, ready_payload: bytes) -> None:
        """Register a client and send its ready response before queued pushes."""
        with self._lock:
            fd = conn.fileno()
            self._clients[fd] = conn
            try:
                conn.sendall(ready_payload)
            except (BrokenPipeError, ConnectionResetError, OSError):
                self._clients.pop(fd, None)
                raise

    def unregister(self, conn: socket.socket) -> None:
        with self._lock:
            self._clients.pop(conn.fileno(), None)

    def emit(self, event: str, data: dict[str, Any]) -> None:
        message = json.dumps(
            {"event": event, "data": data},
            ensure_ascii=False,
            separators=(",", ":"),
        ) + "\n"
        payload = message.encode("utf-8")
        dead: list[int] = []
        with self._lock:
            for fd, conn in self._clients.items():
                try:
                    conn.sendall(payload)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    dead.append(fd)
            for fd in dead:
                self._clients.pop(fd, None)
                logger.debug("push_broker: removed dead client fd=%d", fd)
