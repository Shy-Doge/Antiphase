#!/usr/bin/env python3
"""
Antiphase — Daemon Backend

Runs as a persistent daemon exposing a newline-delimited JSON-RPC 2.0 API on:
  - a Unix domain socket, owner-only (for CLI/debug tools)
  - an HTTP endpoint on 127.0.0.1 (POST /rpc) — used by the QML frontend,
    because the QtNetwork QML module is unusable on this system and XHR is
    the only network primitive available to QML. The HTTP endpoint validates
    the Host/Origin headers so browser pages and DNS-rebinding attacks
    cannot drive it, and verifies through /proc that the connecting process
    runs as the same user (loopback is per-machine, not per-user).

Usage: python3 daemon.py [--socket PATH] [--http-port PORT] [--allow-raw]
  Default socket path: ~/.cache/antiphase/daemon.sock
  Default HTTP port: 48322 (loopback only)
  --allow-raw: enable the raw_command debug method (off by default)
"""

import sys
import os
import json
import glob
import socket
import signal
import tempfile
import threading
import time
import errno
import http.server
from pathlib import Path


# ─── Peer identity (loopback is per-machine, not per-user) ──────────────────
# The HTTP endpoint cannot authenticate with a token because the QML client
# has no way to read a file (XHR only speaks http:// in Qt). Instead the
# daemon proves the connecting process runs as the *same user*: find the
# client-side socket's inode in /proc/net/tcp{,6}, then show that inode is
# open in some process we can inspect (Linux restricts /proc/<pid>/fd to
# the owner, so readability is itself the credential).


def _peer_socket_inode(peer_port: int, our_port: int):
    """Inode of the socket at *peer_port* connected to *our_port*."""
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path) as f:
                next(f, None)
                for line in f:
                    fields = line.split()
                    if len(fields) < 10:
                        continue
                    local, remote = fields[1], fields[2]
                    if (
                        local.rsplit(":", 1)[-1] == f"{peer_port:04X}"
                        and remote.rsplit(":", 1)[-1] == f"{our_port:04X}"
                    ):
                        return fields[9]
        except OSError:
            continue
    return None


def _peer_is_same_user(conn, our_port: int) -> bool:
    """True only when the peer socket demonstrably belongs to our uid."""
    try:
        peer_port = conn.getpeername()[1]
    except OSError:
        return False
    inode = _peer_socket_inode(peer_port, our_port)
    if inode is None:
        return False
    target = f"socket:[{inode}]"
    my_uid = os.getuid()
    for fd_dir in glob.glob("/proc/[0-9]*/fd"):
        try:
            if os.stat(fd_dir[: -len("/fd")]).st_uid != my_uid:
                continue
            for fd in os.scandir(fd_dir):
                try:
                    if os.readlink(fd.path) == target:
                        return True
                except OSError:
                    pass
        except OSError:
            continue  # another user's fd directory: unreadable, not ours
    return False


# ─── HTTP/JSON-RPC endpoint ────────────────────────────────────────────────
# The QML frontend cannot use sockets (the QtNetwork QML module is unusable on
# this system), so it talks to the daemon over plain HTTP using XMLHttpRequest.


class _RpcHTTPHandler(http.server.BaseHTTPRequestHandler):
    """Tiny JSON-RPC-over-HTTP handler (POST /rpc only, loopback)."""

    # Keep-alive lets the UI's 2.5 s poll reuse one connection, so the
    # per-connection peer-uid scan runs rarely.
    protocol_version = "HTTP/1.1"

    rpc_handler = None  # set by SocketManager.start_http()
    our_port = 0  # set by SocketManager.start_http()

    def _host_allowed(self) -> bool:
        """Reject cross-origin and DNS-rebinding requests.

        A page on an attacker domain that resolves to 127.0.1 can POST to
        loopback (simple request, no preflight for text/plain); validating
        Host and Origin closes both the CSRF side effect and rebinding
        reads. The QML XHR client sends no Origin and a 127.0.0.1 Host.
        """
        from urllib.parse import urlparse

        host = (self.headers.get("Host") or "").strip().lower()
        if host not in ("127.0.0.1", "localhost", "[::1]", "::1"):
            # strip :port
            host = host.rsplit(":", 1)[0]
        if host not in ("127.0.0.1", "localhost", "[::1]", "::1"):
            return False
        origin = (self.headers.get("Origin") or "").strip().lower()
        if origin:
            try:
                oh = urlparse(origin).hostname or ""
            except Exception:
                return False
            if oh not in ("127.0.0.1", "localhost", "::1"):
                return False
        referer = (self.headers.get("Referer") or "").strip().lower()
        if referer:
            try:
                rh = urlparse(referer).hostname or ""
            except Exception:
                return False
            if rh not in ("127.0.0.1", "localhost", "::1"):
                return False
        return True

    def _send_json(self, status: int, response: dict) -> None:
        payload = json.dumps(response).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path != "/rpc":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self._host_allowed():
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not _peer_is_same_user(self.connection, self.our_port):
            # Loopback is shared by every local user; only our own
            # processes may drive the device over HTTP.
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        request = None
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length < 0 or length > 1 << 20:
                # A huge Content-Length would let a local process OOM us.
                self.send_response(413)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = self.rfile.read(length)
            request = json.loads(body.decode())
            response = self.rpc_handler(request)
            self._send_json(200, response)
        except Exception as e:  # noqa: BLE001 - report back to the client
            request_id = request.get("id") if isinstance(request, dict) else None
            resp = {
                "jsonrpc": "2.0",
                "error": {"code": -32000, "message": str(e)},
                "id": request_id,
            }
            try:
                self._send_json(500, resp)
            except OSError:
                pass  # client vanished mid-write

    def log_message(self, fmt, *args):
        pass  # keep the daemon quiet


# ─── Daemon socket management ───────────────────────────────────────────────


class SocketManager:
    """Manages the IPC endpoints (owner-only Unix socket + loopback HTTP)."""

    def __init__(self, socket_path=None, http_host="127.0.0.1", http_port=48322):
        self.socket_path = socket_path or os.path.expanduser(
            "~/.cache/antiphase/daemon.sock"
        )
        self.http_host = http_host
        self.http_port = http_port
        self._unix_server = None
        self._http_server = None
        self._bound = False  # True only once *this* instance owns the file
        self._clients = {}
        self._client_counter = 0
        self._lock = threading.Lock()
        self._shutdown = threading.Event()

    def start(self):
        """Start listening on the Unix socket."""
        # Create directory if needed
        os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)

        # A live daemon's socket must not be unlinked (that would kill the
        # running instance's endpoint); only a *stale* socket is removed.
        if os.path.exists(self.socket_path):
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.settimeout(1.0)
            live = False
            try:
                probe.connect(self.socket_path)
                live = True
            except OSError:
                pass  # connect refused / timed out -> stale
            finally:
                probe.close()
            if live:
                raise OSError(f"{self.socket_path} is in use by a running daemon")
            try:
                os.unlink(self.socket_path)
            except OSError:
                pass

        # Create Unix domain socket. The file must never be world-writable,
        # even momentarily: bind under a restrictive umask instead of
        # chmod'ing after the fact.
        old_umask = os.umask(0o077)
        try:
            self._unix_server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._unix_server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._unix_server.bind(self.socket_path)
            self._bound = True
        finally:
            os.umask(old_umask)
        self._unix_server.listen(5)
        self._unix_server.settimeout(1.0)  # Check for shutdown periodically

        print(f"Daemon listening on {self.socket_path}", file=sys.stderr)

    def start_http(self, request_handler):
        """Start the loopback HTTP endpoint used by the QML frontend."""
        _RpcHTTPHandler.rpc_handler = request_handler
        _RpcHTTPHandler.our_port = self.http_port
        self._http_server = http.server.ThreadingHTTPServer(
            (self.http_host, self.http_port), _RpcHTTPHandler
        )
        thread = threading.Thread(target=self._http_server.serve_forever, daemon=True)
        thread.start()
        print(
            f"Daemon HTTP listening on http://{self.http_host}:{self.http_port}/rpc",
            file=sys.stderr,
        )

    def accept_clients(self, request_handler):
        """Accept client connections on the Unix socket (main thread)."""
        self._accept_loop(self._unix_server, request_handler)

    def stop(self):
        self._shutdown.set()

    def _accept_loop(self, server, request_handler):
        """Accept loop for a single listening socket."""
        while not self._shutdown.is_set():
            try:
                client_socket, _ = server.accept()
                with self._lock:
                    self._client_counter += 1
                    client_id = self._client_counter
                    self._clients[client_id] = client_socket
                client_socket.settimeout(5.0)

                # Handle client in a separate thread
                t = threading.Thread(
                    target=self._handle_client,
                    args=(client_id, client_socket, request_handler),
                    daemon=True,
                )
                t.start()

            except socket.timeout:
                continue
            except OSError as e:
                if e.errno == errno.EINTR:
                    continue
                if self._shutdown.is_set():
                    break
                raise

    def _handle_client(self, client_id, sock, handler):
        """Handle a single client connection."""
        try:
            buffer = b""
            while True:
                try:
                    data = sock.recv(4096)
                except (socket.timeout, OSError):
                    break

                if not data:
                    break

                # The accept-time timeout only guards connections that
                # never send a first request; an interactive client
                # (socat) may idle between commands as long as it likes.
                sock.settimeout(None)

                buffer += data

                # Process complete lines
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    line = line.decode("utf-8", errors="replace").strip()
                    if not line:
                        continue

                    try:
                        request = json.loads(line)
                        response = handler(request)
                        response_json = json.dumps(response) + "\n"
                        sock.sendall(response_json.encode())
                    except json.JSONDecodeError as e:
                        resp = {
                            "jsonrpc": "2.0",
                            "error": {"code": -32700, "message": str(e)},
                            "id": None,
                        }
                        sock.sendall((json.dumps(resp) + "\n").encode())
                    except Exception as e:
                        resp = {
                            "jsonrpc": "2.0",
                            "error": {"code": -32000, "message": str(e)},
                            "id": request.get("id")
                            if isinstance(request, dict)
                            else None,
                        }
                        try:
                            sock.sendall((json.dumps(resp) + "\n").encode())
                        except OSError:
                            pass
        finally:
            with self._lock:
                self._clients.pop(client_id, None)
            try:
                sock.close()
            except OSError:
                pass

    def shutdown(self):
        """Stop the servers and close all connections."""
        self._shutdown.set()
        if self._http_server:
            try:
                self._http_server.shutdown()
                self._http_server.server_close()
            except OSError:
                pass
        if self._unix_server:
            try:
                self._unix_server.close()
            except OSError:
                pass
        with self._lock:
            for sock in self._clients.values():
                try:
                    sock.close()
                except OSError:
                    pass
            self._clients.clear()

        # Clean up socket file — only if this instance actually bound it
        # (a rejected second instance must not delete the live daemon's).
        try:
            if self._bound and os.path.exists(self.socket_path):
                os.unlink(self.socket_path)
        except OSError:
            pass


# Import from the main backend module
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from backend import (
    BlueZManager,
    SonyDeviceController,
    BluetoothError,
    ASC_SCENE_DEFAULTS,
)


# ─── Scene configuration store ───────────────────────────────────────────────
# The ASC scenes are app-side presets (the device only stores the selection),
# so their editable definitions live here, persisted across restarts.

SCENES_FILE = Path(os.path.expanduser("~/.local/share/antiphase/scenes.json"))


def normalize_scene(raw: dict) -> dict:
    mode = int(raw.get("mode", 0))
    mode = max(0, min(2, mode))
    level = int(raw.get("ambientLevel", 10))
    if mode == 2:
        level = max(1, min(20, level))
    else:
        level = 0  # irrelevant for Off / Noise cancelling
    return {
        "id": int(raw.get("id", 0)),
        "name": str(raw.get("name", ""))[:24],
        "mode": mode,
        "ambientLevel": level,
        "focusOnVoice": bool(raw.get("focusOnVoice", False)),
    }


def normalize_scenes(raw: list) -> list:
    """Normalize a scene list; drop malformed entries and duplicate ids."""
    scenes, seen = [], set()
    for item in raw:
        if not isinstance(item, dict):
            continue
        try:
            scene = normalize_scene(item)
        except (TypeError, ValueError):
            continue
        if scene["id"] in seen:
            continue
        seen.add(scene["id"])
        scenes.append(scene)
    return scenes


def load_scene_config() -> list:
    scenes = []
    try:
        with open(SCENES_FILE) as f:
            raw = json.load(f).get("scenes", [])
        if isinstance(raw, list):
            scenes = normalize_scenes(raw)
    except Exception:
        pass
    if not scenes:
        scenes = [normalize_scene(s) for s in ASC_SCENE_DEFAULTS]
    return scenes


def save_scene_config(scenes: list) -> None:
    SCENES_FILE.parent.mkdir(parents=True, exist_ok=True)
    # Unique temp file in the target directory (same filesystem, so the
    # replace is atomic) plus fsync so a crash cannot truncate the store.
    fd, tmp_path = tempfile.mkstemp(dir=str(SCENES_FILE.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"scenes": scenes}, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, SCENES_FILE)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ─── JSON-RPC handler for daemon ────────────────────────────────────────────


class DaemonRPCHandler:
    """JSON-RPC handler for the daemon."""

    # Methods that can drive the device with arbitrary bytes; disabled
    # unless the daemon was started with --allow-raw.
    DEBUG_METHODS = frozenset({"raw_command"})

    def __init__(self, allow_raw: bool = False):
        self._allow_raw = allow_raw
        self._bluez = BlueZManager()
        self._controllers = {}  # address -> SonyDeviceController
        self._dev_locks = {}  # address -> threading.Lock
        self._locks_guard = threading.Lock()
        self._scenes_lock = threading.Lock()
        self._scenes = load_scene_config()
        # address -> last monitor snapshot (see _monitor_loop).
        self._state = {}
        self._monitor_stop = threading.Event()
        threading.Thread(
            target=self._monitor_loop, name="state-monitor", daemon=True
        ).start()

    def _lock_for(self, address: str) -> threading.Lock:
        with self._locks_guard:
            return self._dev_locks.setdefault(address, threading.Lock())

    def stop(self):
        """Stop the background state monitor (called on daemon exit)."""
        self._monitor_stop.set()

    def handle_request(self, request):
        """Process a JSON-RPC request."""
        request_id = None
        try:
            if not isinstance(request, dict):
                return self._error(None, -32600, "Invalid Request: not an object")
            method = str(request.get("method", ""))
            params = request.get("params", {})
            request_id = request.get("id", None)

            handler = getattr(self, f"handle_{method}", None)
            if (
                handler is None
                or not callable(handler)
                or handler == self.handle_request
            ):
                return self._error(request_id, -32601, f"Method not found: {method}")
            if not self._allow_raw and method in self.DEBUG_METHODS:
                # raw_command is a development aid; hidden unless the
                # operator explicitly enabled it at startup.
                return self._error(request_id, -32601, f"Method not found: {method}")

            # All control methods share one RFCOMM socket per device and
            # the HTTP server is threaded — serialize per address so
            # command/response pairs never interleave on the wire.
            address = params.get("address") if isinstance(params, dict) else None
            if address:
                with self._lock_for(address):
                    result = handler(params)
            else:
                result = handler(params)
            return self._response(request_id, result)

        except Exception as e:
            return self._error(request_id, -32000, str(e))

    def _response(self, request_id, result):
        return {"jsonrpc": "2.0", "result": result, "id": request_id}

    def _error(self, request_id, code, message):
        return {
            "jsonrpc": "2.0",
            "error": {"code": code, "message": message},
            "id": request_id,
        }

    # ── Device state monitor ──────────────────────────────────────────────
    # The headphones change state on their own (NC button, power, codec
    # renegotiation, battery drain) and the control session only surfaces
    # that when asked. A background monitor snapshots the cheap fields
    # every few seconds; the UI polls the cache via get_state and applies
    # the diff, so the tray follows the hardware within seconds.

    POLL_INTERVAL = 3.0
    POLL_FAIL_LIMIT = 5  # consecutive failures before the session is dropped

    def _monitor_loop(self):
        fails = {}
        while not self._monitor_stop.wait(self.POLL_INTERVAL):
            try:
                self._monitor_cycle(fails)
            except Exception as e:  # noqa: BLE001 - never kill live sync
                print(f"State monitor cycle error: {e}", file=sys.stderr)

    def _monitor_cycle(self, fails):
        # A powered-off or out-of-range headset stops answering at
        # the Bluetooth level; gate on that so a dead link is
        # dropped promptly instead of burning reconnect attempts.
        try:
            bt = {
                d["address"] for d in self._bluez.list_devices() if d.get("connected")
            }
        except Exception:
            bt = None  # BlueZ unreadable this cycle; do not gate on it
        for address, ctrl in list(self._controllers.items()):
            if bt is not None and address not in bt:
                print(
                    f"Bluetooth link for {address} is gone; dropping the Sony session",
                    file=sys.stderr,
                )
                if self._drop_session(address):
                    fails.pop(address, None)
                continue
            lock = self._lock_for(address)
            # Never queue behind a UI command — skip this cycle.
            if not lock.acquire(blocking=False):
                continue
            state, err, prev = None, None, None
            try:
                if ctrl.connected:
                    state = ctrl.poll_state()
                if state is not None:
                    # Publish under the lock: a UI write that starts after
                    # this point must land on top of this snapshot, never
                    # be clobbered by it.
                    prev = self._state.get(address)
                    self._state[address] = state
            except Exception as e:
                err = e
            finally:
                lock.release()
            if err is not None:
                fails[address] = fails.get(address, 0) + 1
                print(
                    f"State poll failed for {address} "
                    f"({fails[address]}/{self.POLL_FAIL_LIMIT}): {err}",
                    file=sys.stderr,
                )
                if fails[address] >= self.POLL_FAIL_LIMIT:
                    if self._drop_session(address):
                        fails.pop(address, None)
                continue
            fails.pop(address, None)
            if state is None:
                continue  # session closed; the UI drives the teardown
            if prev:
                delta = {
                    k: (prev.get(k), v) for k, v in state.items() if prev.get(k) != v
                }
                if delta:
                    print(
                        f"Device state changed on {address}: {delta}",
                        file=sys.stderr,
                    )
        # Prune per-address locks of devices that are gone (bounded growth).
        with self._locks_guard:
            for address in list(self._dev_locks):
                if (
                    address not in self._controllers
                    and not self._dev_locks[address].locked()
                ):
                    del self._dev_locks[address]

    def _drop_session(self, address, lock_held=False):
        """Close and forget the Sony session for *address*.

        Returns True when the session was removed. Callers from the
        monitor must not hold the device lock (it is acquired here);
        request handlers already hold it and pass lock_held=True.
        """
        lock = self._lock_for(address)
        acquired = True
        if not lock_held:
            # Never yank the socket out from under a mid-command thread;
            # defer the drop to the next cycle if the device is busy.
            acquired = lock.acquire(timeout=5.0)
            if not acquired:
                print(
                    f"Deferring session drop for {address}: device busy",
                    file=sys.stderr,
                )
                return False
        try:
            ctrl = self._controllers.pop(address, None)
            self._state.pop(address, None)
            if ctrl:
                try:
                    ctrl.disconnect()
                except Exception:
                    pass
        finally:
            if not lock_held and acquired:
                lock.release()
        return True

    def _cache_state(self, address, **fields):
        """Record a write's outcome so get_state never serves a value
        the user has just visibly changed (the monitor converges within
        one poll cycle anyway)."""
        self._state.setdefault(address, {}).update(fields)

    # ── Methods (same as stdin/stdout backend) ────────────────────────────

    def handle_list_adapters(self, params):
        return self._bluez.list_adapters()

    def handle_list_devices(self, params):
        return self._bluez.list_devices()

    def handle_connect_device(self, params):
        address = params.get("address")
        device_path = params.get("device_path")
        device_name = params.get("device_name", "")

        if not address:
            raise BluetoothError("Missing address")

        # Connect via BlueZ only if not already connected. Calling Connect()
        # on an already-connected device can hang until the D-Bus reply times
        # out (~25s), which would block this handler and freeze the UI.
        if device_path:
            try:
                already = bool(
                    self._bluez.get_device_property(device_path, "Connected")
                )
            except Exception:
                already = False
            if not already:
                self._bluez.connect_device(device_path)

        # Get or create controller. An existing live session is reused as-is:
        # tearing it down to reconnect would close the MDR channel window and
        # force an audible ACL reconnect blip for no benefit.
        if address in self._controllers:
            ctrl = self._controllers[address]
            if ctrl.connected:
                return {"success": True, "model": ctrl.model, "profile": ctrl.profile}
            del self._controllers[address]

        ctrl = SonyDeviceController(address, device_name)
        try:
            ctrl.connect()
        except BluetoothError:
            # The headset only registers its MDR control channel around
            # connection events; if the channel refused us, bounce the
            # ACL link so the services re-register, then retry once.
            if not device_path:
                raise
            try:
                self._bluez.disconnect_device(device_path)
                time.sleep(2)
                self._bluez.connect_device(device_path)
                time.sleep(1)
            except Exception:
                pass
            ctrl.connect()
        self._controllers[address] = ctrl

        return {"success": True, "model": ctrl.model, "profile": ctrl.profile}

    def handle_disconnect_device(self, params):
        address = params.get("address")
        # handle_request already holds this address's device lock.
        self._drop_session(address, lock_held=True)
        return {"success": True}

    def handle_get_state(self, params):
        """Cached snapshot maintained by the monitor thread.

        Served without touching the device; the UI polls this cheaply
        and applies the diff, which is how on-device changes (NC button,
        power loss) reach the tray.
        """
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        state = self._state.get(address)
        if state is None:
            # First request before the monitor's next cycle: read now
            # (handle_request already holds this device's lock).
            state = ctrl.poll_state()
            self._state[address] = state
        result = {"state": True}
        result.update(state)
        return result

    def handle_refresh_battery(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.refresh_battery()

    def handle_refresh_noise(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.refresh_noise_control()

    def handle_set_noise_mode(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        # Validate before touching the device: a malformed level must
        # not turn a completed SET into a spurious error afterwards.
        try:
            mode = int(params.get("mode", 0))
            level = int(params.get("ambientLevel", 0))
        except (TypeError, ValueError) as e:
            return {"error": f"Invalid noise mode params: {e}"}
        focus = bool(params.get("focusOnVoice", False))
        result = ctrl.set_noise_mode(mode, level, focus)
        if isinstance(result, dict) and result.get("success"):
            fields = {"mode": mode, "focusOnVoice": focus}
            # The firmware keeps the stored level for Off / NC modes,
            # so only a valid ambient level for mode 2 may be cached.
            if mode == 2 and 1 <= level <= 20:
                fields["ambientLevel"] = level
            self._cache_state(address, **fields)
        return result

    def handle_get_scenes(self, params):
        with self._scenes_lock:
            scenes = [dict(s) for s in self._scenes]
        return {"scenes": scenes, "defaults": ASC_SCENE_DEFAULTS}

    def handle_set_scenes(self, params):
        raw = params.get("scenes", [])
        if not isinstance(raw, list) or not raw:
            return {"error": "Expected a non-empty list of scenes"}
        scenes = normalize_scenes(raw)
        if not scenes:
            return {"error": "No valid scenes in config"}
        # Persist first: only swap the in-memory copy once the file has
        # survived the atomic replace, so a failed write cannot leave
        # memory and disk disagreeing.
        try:
            save_scene_config(scenes)
        except OSError as e:
            return {"error": f"Could not persist scenes: {e}"}
        with self._scenes_lock:
            self._scenes = scenes
        return {"success": True}

    def handle_set_asc_scene(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        scene = params.get("scene", 0)
        with self._scenes_lock:
            cfg = next((s for s in self._scenes if s.get("id") == scene), None)
        if cfg is None:
            return {"error": f"Unknown ASC scene {scene}"}
        result = ctrl.set_asc_scene(
            scene,
            mode=cfg.get("mode"),
            ambient_level=cfg.get("ambientLevel", 10),
            focus_on_voice=cfg.get("focusOnVoice", False),
        )
        if isinstance(result, dict) and result.get("success"):
            # The scene's audible effect is its NC combination; cache it
            # exactly as the scene was applied.
            self._cache_state(
                address,
                mode=cfg.get("mode", 0),
                ambientLevel=cfg.get("ambientLevel", 10),
                focusOnVoice=bool(cfg.get("focusOnVoice", False)),
            )
        return result

    def handle_refresh_equalizer(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.refresh_equalizer()

    def handle_set_equalizer_preset(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.set_equalizer_preset(params.get("preset", 0))

    def handle_set_equalizer_custom(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.set_equalizer_custom(
            params.get("clearBass", 0),
            params.get("bands", []),
            preset=params.get("preset"),
        )

    def handle_refresh_info(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.refresh_info()

    def handle_set_dsee(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        result = ctrl.set_dsee(params.get("enabled", False))
        if isinstance(result, dict) and result.get("success"):
            self._cache_state(address, dsee=bool(params.get("enabled", False)))
        return result

    def handle_get_dsee(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return False
        return ctrl.get_dsee()

    def handle_set_speak_to_chat(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.set_speak_to_chat(params.get("enabled", False))

    def handle_get_speak_to_chat(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return False
        return ctrl.get_speak_to_chat()

    def handle_set_adaptive_volume(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.set_adaptive_volume(params.get("enabled", False))

    def handle_get_adaptive_volume(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return False
        return ctrl.get_adaptive_volume()

    def handle_set_auto_power_off(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.set_auto_power_off(params.get("index", 0))

    def handle_get_auto_power_off(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return 0
        return ctrl.get_auto_power_off()

    def handle_get_capabilities(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        return ctrl.get_capabilities()

    def handle_power_off(self, params):
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        result = ctrl.power_off()
        if result.get("success"):
            # Only drop the session when the command actually went out;
            # on unsupported models power_off declines and the working
            # controller must survive.
            self._controllers.pop(address, None)
            self._state.pop(address, None)
        return result

    def handle_raw_command(self, params):
        """Debug: send a raw MDR COMMAND_1 payload (hex) and reply hex.

        Development aid for protocol reverse-engineering; only reachable
        when the daemon runs with --allow-raw.
        """
        address = params.get("address")
        ctrl = self._controllers.get(address)
        if not ctrl or not ctrl.connected:
            return {"error": "Not connected"}
        transport = getattr(ctrl._protocol, "_t", None)
        if transport is None or not hasattr(transport, "mdr_command"):
            return {"error": "Not an MDR transport"}
        try:
            payload = bytes.fromhex(str(params.get("payload", "")))
            expect = int(str(params["expect"]), 0) if params.get("expect") else None
            expect_sub = (
                int(str(params.get("expect_sub", "0")), 0)
                if params.get("expect_sub") is not None
                else -1
            )
            timeout = float(params.get("timeout", 3.0))
        except (TypeError, ValueError) as e:
            return {"error": f"Invalid raw_command params: {e}"}
        resp = transport.mdr_command(payload, expect, expect_sub, timeout=timeout)
        return {"response": resp.hex()}


# ─── Main ───────────────────────────────────────────────────────────────────


def main():
    socket_path = None
    http_port = 48322
    allow_raw = False
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--socket":
            if i + 1 >= len(args):
                print("Missing value for --socket", file=sys.stderr)
                return 2
            socket_path = args[i + 1]
            i += 2
        elif arg == "--http-port":
            if i + 1 >= len(args):
                print("Missing value for --http-port", file=sys.stderr)
                return 2
            try:
                http_port = int(args[i + 1])
            except ValueError:
                print(f"Invalid port: {args[i + 1]}", file=sys.stderr)
                return 2
            i += 2
        elif arg == "--allow-raw":
            allow_raw = True
            i += 1
        else:
            print(f"Ignoring unknown argument: {arg}", file=sys.stderr)
            i += 1

    handler = DaemonRPCHandler(allow_raw=allow_raw)
    sock_manager = SocketManager(socket_path, http_port=http_port)

    def signal_handler(sig, frame):
        # Never sys.exit() from a signal handler: it can fire while a
        # lock is held. Flip the shutdown flag and let the main loop
        # unwind through its finally block instead.
        print("Shutting down...", file=sys.stderr)
        sock_manager.stop()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        sock_manager.start()
        sock_manager.start_http(handler.handle_request)
        sock_manager.accept_clients(handler.handle_request)
    except OSError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    finally:
        sock_manager.shutdown()
        handler.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
