"""Tests for PushBroker push event manager."""
import json
import socket
import threading
import unittest

from insightkit.ipc.push_broker import PushBroker


class TestPushBroker(unittest.TestCase):
    def test_register_and_emit(self):
        """emit sends NDJSON event to all registered clients."""
        broker = PushBroker()
        server_sock, client_sock = socket.socketpair()
        try:
            broker.register(server_sock)
            broker.emit("test.event", {"key": "value"})
            raw = client_sock.recv(4096)
            msg = json.loads(raw.decode("utf-8").strip())
            self.assertEqual(msg["event"], "test.event")
            self.assertEqual(msg["data"]["key"], "value")
        finally:
            broker.unregister(server_sock)
            server_sock.close()
            client_sock.close()

    def test_unregister_removes_client(self):
        """After unregister, emit does not send to that client."""
        broker = PushBroker()
        server_sock, client_sock = socket.socketpair()
        try:
            broker.register(server_sock)
            broker.unregister(server_sock)
            broker.emit("test.event", {"key": "value"})
            client_sock.settimeout(0.1)
            with self.assertRaises(socket.timeout):
                client_sock.recv(4096)
        finally:
            server_sock.close()
            client_sock.close()

    def test_emit_broken_client_auto_removes(self):
        """If a client's socket is broken, emit silently removes it."""
        broker = PushBroker()
        server_sock, client_sock = socket.socketpair()
        client_sock.close()  # Break the receiving end
        broker.register(server_sock)
        broker.emit("test.event", {"key": "value"})  # Should not raise
        self.assertEqual(broker.client_count, 0)
        server_sock.close()

    def test_emit_multiple_clients(self):
        """emit broadcasts to all registered clients."""
        broker = PushBroker()
        pairs = [socket.socketpair() for _ in range(3)]
        try:
            for s, _ in pairs:
                broker.register(s)
            broker.emit("broadcast", {"n": 42})
            for _, c in pairs:
                raw = c.recv(4096)
                msg = json.loads(raw.decode("utf-8").strip())
                self.assertEqual(msg["event"], "broadcast")
                self.assertEqual(msg["data"]["n"], 42)
        finally:
            for s, c in pairs:
                broker.unregister(s)
                s.close()
                c.close()
