#!/usr/bin/env python3
"""
Antiphase — BlueZ D-Bus + Sony Protocol Backend

Handles:
  1. BlueZ D-Bus communication (device discovery, connection state)
  2. RFCOMM Bluetooth socket for the Sony control protocol
  3. Sony binary protocol (V1, V2 and MDR COMMAND_1) encoding/decoding

The JSON-RPC surface lives in daemon.py; this module only provides the
building blocks (transport, protocols, BlueZ, controller, profiles).
"""

import os
import errno
import socket
import struct
import threading
import time
import select

# D-Bus (required for BlueZ communication)
import dbus


# ─── Sony Frame Codec ────────────────────────────────────────────────────────


class FrameCodec:
    """Sony MDR framed protocol — encoding/decoding."""

    START_MARKER = 0x3E
    END_MARKER = 0x3C
    ESCAPE_MARKER = 0x3D
    ESCAPED_60 = 0x2C  # 0x3C -> 0x3D 0x2C
    ESCAPED_61 = 0x2D  # 0x3D -> 0x3D 0x2D
    ESCAPED_62 = 0x2E  # 0x3E -> 0x3D 0x2E
    MAX_FRAME_SIZE = 2048
    MIN_BODY_SIZE = 7  # type(1) + seq(1) + len(4) + checksum(1)

    @staticmethod
    def escape(data: bytes) -> bytearray:
        result = bytearray()
        for b in data:
            if b == 0x3C:  # END_MARKER
                result.extend([0x3D, 0x2C])
            elif b == 0x3D:  # ESCAPE_MARKER
                result.extend([0x3D, 0x2D])
            elif b == 0x3E:  # START_MARKER
                result.extend([0x3D, 0x2E])
            else:
                result.append(b)
        return result

    @staticmethod
    def unescape(data: bytes) -> bytearray:
        result = bytearray()
        i = 0
        while i < len(data):
            if data[i] == 0x3D:  # ESCAPE_MARKER
                if i + 1 >= len(data):
                    raise ValueError("Incomplete escape sequence")
                i += 1
                if data[i] == 0x2C:
                    result.append(0x3C)
                elif data[i] == 0x2D:
                    result.append(0x3D)
                elif data[i] == 0x2E:
                    result.append(0x3E)
                else:
                    raise ValueError(f"Unexpected escaped byte: 0x{data[i]:02X}")
            else:
                result.append(data[i])
            i += 1
        return result

    @staticmethod
    def calculate_checksum(data: bytes) -> int:
        return sum(data) & 0xFF

    @staticmethod
    def encode(type_byte: int, sequence: int, payload: bytes) -> bytes:
        """Encode a Sony frame."""
        body = bytearray()
        body.append(type_byte & 0xFF)
        body.append(sequence & 0xFF)
        payload_len = len(payload)
        body.extend(
            [
                (payload_len >> 24) & 0xFF,
                (payload_len >> 16) & 0xFF,
                (payload_len >> 8) & 0xFF,
                payload_len & 0xFF,
            ]
        )
        body.extend(payload)
        body.append(FrameCodec.calculate_checksum(bytes(body)))

        escaped = FrameCodec.escape(bytes(body))
        if len(escaped) + 2 > FrameCodec.MAX_FRAME_SIZE:
            raise RuntimeError("Frame too large")

        return (
            bytes([FrameCodec.START_MARKER]) + escaped + bytes([FrameCodec.END_MARKER])
        )

    @staticmethod
    def decode(data: bytes) -> tuple:
        """Decode a Sony frame. Returns (type, sequence, payload)."""
        if len(data) < 2 or data[0] != 0x3E or data[-1] != 0x3C:
            raise ValueError("Invalid frame delimiters")

        body = data[1:-1]
        unescaped = FrameCodec.unescape(body)

        if len(unescaped) < FrameCodec.MIN_BODY_SIZE:
            raise ValueError("Frame too small")

        payload_len = (
            (unescaped[2] << 24)
            | (unescaped[3] << 16)
            | (unescaped[4] << 8)
            | unescaped[5]
        )

        if len(unescaped) < 6 + payload_len + 1:
            raise ValueError("Declared size exceeds received data")

        expected_checksum = unescaped[6 + payload_len]
        actual_checksum = FrameCodec.calculate_checksum(
            bytes(unescaped[: 6 + payload_len])
        )

        if expected_checksum != actual_checksum:
            raise ValueError(
                f"Invalid checksum: expected {expected_checksum}, got {actual_checksum}"
            )

        frame_type = unescaped[0]
        sequence = unescaped[1]
        payload = bytes(unescaped[6 : 6 + payload_len])

        return frame_type, sequence, payload


# ─── Sony Protocol Constants ──────────────────────────────────────────────────

# Service UUIDs for SDP lookup
SERVICE_UUID_V1 = bytes(
    [
        0x96,
        0xCC,
        0x20,
        0x3E,
        0x50,
        0x68,
        0x46,
        0xAD,
        0xB3,
        0x2D,
        0xE3,
        0x16,
        0xF5,
        0xE0,
        0x69,
        0xBA,
    ]
)
SERVICE_UUID_V2 = bytes(
    [
        0x95,
        0x6C,
        0x7B,
        0x26,
        0xD4,
        0x9A,
        0x4B,
        0xA8,
        0xB0,
        0x3F,
        0xB1,
        0x7D,
        0x39,
        0x3C,
        0xB6,
        0xE2,
    ]
)

# MDR COMMAND_1 protocol (WH-1000XM6 and newer firmware generations).
# Frame data types used by this variant.
MDR_DT_INIT = 0x00
MDR_DT_ACK = 0x01
MDR_DT_COMMAND_1 = 0x0C
# The MDR control channel on XM-series over-ears (service UUID V2).
MDR_CONTROL_CHANNEL = 9


# ─── Sony Device Profile Registry ─────────────────────────────────────────────

DEVICE_PROFILES = {
    "WH-1000XM3": {
        "protocol": "V1",
        "dualBattery": False,
        "eq": False,
        "dsee": False,
        "speakToChat": False,
        "adaptiveVolume": False,
        "autoPowerOff": False,
        "firmware": False,
        "codec": False,
    },
    "WH-1000XM4": {
        "protocol": "V1",
        "dualBattery": False,
        "eq": True,
        "dsee": False,
        "speakToChat": True,
        "adaptiveVolume": False,
        "autoPowerOff": False,
        "firmware": True,
        "codec": True,
    },
    "WH-1000XM5": {
        "protocol": "V2",
        "dualBattery": False,
        "eq": True,
        "dsee": True,
        "speakToChat": True,
        "adaptiveVolume": True,
        "autoPowerOff": True,
        "firmware": True,
        "codec": True,
    },
    "WH-1000XM6": {
        # COMMAND_1 MDR protocol, verified against a live unit.
        "protocol": "MDR",
        "dualBattery": False,
        "eq": True,
        "dsee": True,
        "speakToChat": False,
        "adaptiveVolume": False,
        "autoPowerOff": False,
        "firmware": False,
        "codec": True,
        "asc": True,
    },
    "WF-1000XM4": {
        "protocol": "V2",
        "dualBattery": True,
        "eq": True,
        "dsee": True,
        "speakToChat": True,
        "adaptiveVolume": False,
        "autoPowerOff": True,
        "firmware": True,
        "codec": True,
    },
    "WF-1000XM5": {
        "protocol": "V2",
        "dualBattery": True,
        "eq": True,
        "dsee": True,
        "speakToChat": True,
        "adaptiveVolume": True,
        "autoPowerOff": True,
        "firmware": True,
        "codec": True,
    },
    "WF-1000XM6": {
        "protocol": "V2",
        "dualBattery": True,
        "eq": True,
        "dsee": True,
        "speakToChat": True,
        "adaptiveVolume": True,
        "autoPowerOff": True,
        "firmware": True,
        "codec": True,
    },
    "WH-CH720N": {
        "protocol": "V2",
        "dualBattery": False,
        "eq": True,
        "dsee": True,
        "speakToChat": False,
        "adaptiveVolume": False,
        "autoPowerOff": True,
        "firmware": True,
        "codec": True,
    },
    "ULT WEAR": {
        "protocol": "V2",
        "dualBattery": False,
        "eq": True,
        "dsee": True,
        "speakToChat": False,
        "adaptiveVolume": False,
        "autoPowerOff": True,
        "firmware": True,
        "codec": True,
    },
    "LinkBuds S": {
        "protocol": "V2",
        "dualBattery": True,
        "eq": True,
        "dsee": True,
        "speakToChat": True,
        "adaptiveVolume": False,
        "autoPowerOff": True,
        "firmware": True,
        "codec": True,
    },
}


def identify_model(device_name: str) -> str:
    """Identify the Sony model from device name."""
    upper = device_name.upper()
    for model in DEVICE_PROFILES:
        if model.upper() in upper:
            return model
    return "Unknown"


def get_profile(model: str) -> dict:
    """Get device capabilities profile."""
    if model in DEVICE_PROFILES:
        return DEVICE_PROFILES[model]
    # Unknown model: the RFCOMM probe validates the channel with the MDR
    # INIT handshake, which COMMAND_1 (MDR/V2) devices answer; V1 devices
    # are answered by the controller's caps probe downgrade in connect().
    return {
        "protocol": "MDR",
        "dualBattery": False,
        "eq": False,
        "dsee": False,
        "speakToChat": False,
        "adaptiveVolume": False,
        "autoPowerOff": False,
        "firmware": False,
        "codec": False,
        "asc": False,
    }


# ─── RFCOMM Bluetooth Socket ─────────────────────────────────────────────────


class BluetoothError(Exception):
    pass


class SonyTransport:
    """RFCOMM Bluetooth transport for Sony protocol."""

    def __init__(self):
        self._sock = None
        self._seq = 0
        self._protocol = None
        self._rbuf = bytearray()
        self._mdr_ready = False
        self._address = None
        self._channel = None

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def connect(
        self,
        address: str,
        sdp_uuid: bytes,
        timeout: float = 5.0,
        full_scan: bool = True,
    ) -> str:
        """Connect to the Sony control service over RFCOMM.

        Channel discovery order:
        1. SDP lookup (works on BlueZ <= 5; on BlueZ 6 the classic SDP
           client API is deprecated and returns no records).
        2. Channel 9 — the MDR control channel on XM-series headphones.
        3. Brute-force scan of channels 1-30 (only when full_scan; the
           whole probe is bounded by an overall deadline so a stuck
           connect cannot hold the daemon's per-address lock for minutes).

        Each candidate is validated with the MDR INIT handshake (common
        to every Sony protocol version), so we never mistake a different
        RFCOMM service for the Sony control channel.
        """
        candidates = []
        if sdp_uuid:
            try:
                ch = self._sdp_find_channel(address, sdp_uuid)
                if ch:
                    candidates.append(ch)
            except Exception:
                pass
        candidates.append(MDR_CONTROL_CHANNEL)
        if full_scan:
            candidates += [c for c in range(1, 31) if c not in candidates]
        return self._connect_probe(address, candidates, timeout, deadline=25.0)

    def reconnect(self, timeout: float = 5.0) -> None:
        """Drop the socket and re-run the INIT handshake.

        When the headphones sleep or re-connect, the device's MDR service
        instance goes away but BlueZ keeps the old socket "connected" —
        every command then silently times out. Re-handshaking is the only
        way back; the last known channel is tried first.
        """
        if not self._address:
            raise BluetoothError("Cannot reconnect: transport was never connected")
        try:
            if self._sock:
                self._sock.close()
        except Exception:
            pass
        self._sock = None
        self._mdr_ready = False
        candidates = []
        if self._channel:
            candidates.append(self._channel)
        if 9 not in candidates:
            candidates.append(9)
        # No 1-30 brute force here: reconnect must stay fast; full discovery
        # only happens on the initial connect().
        try:
            self._connect_probe(self._address, candidates, timeout)
        except BluetoothError:
            # Right after a reconnect event the device's RFCOMM services
            # may not be registered yet — give them a moment.
            time.sleep(2)
            self._connect_probe(self._address, candidates, timeout)

    def _connect_probe(
        self, address: str, candidates: list, timeout: float, deadline: float = 25.0
    ) -> str:
        last_err = None
        end_by = time.monotonic() + deadline
        for channel in candidates:
            if time.monotonic() >= end_by:
                break
            sock = socket.socket(
                socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM
            )
            sock.settimeout(timeout)
            try:
                sock.connect((address, channel))
            except OSError as e:
                last_err = e
                try:
                    sock.close()
                except Exception:
                    pass
                continue

            self._sock = sock
            self._rbuf = bytearray()
            self._seq = 0
            self._mdr_ready = False
            try:
                self.mdr_init()
                self._address = address
                self._channel = channel
                return channel
            except Exception as e:
                last_err = e
                self.disconnect()

        raise BluetoothError(
            f"No Sony control service found for {address} ({last_err})"
        )

    # ── MDR (COMMAND_1) primitives ──────────────────────────────────────

    def _read_frame(self, deadline: float):
        """Read one Sony frame until the deadline. None when it expires."""
        while True:
            # Try to parse a complete frame out of the buffer first.
            while len(self._rbuf) >= 2:
                start = self._rbuf.find(bytes([FrameCodec.START_MARKER]))
                if start == -1:
                    self._rbuf.clear()
                    break
                if start > 0:
                    del self._rbuf[:start]
                end = self._rbuf.find(bytes([FrameCodec.END_MARKER]), 1)
                if end == -1:
                    break
                data = bytes(self._rbuf[: end + 1])
                del self._rbuf[: end + 1]
                try:
                    return FrameCodec.decode(data)
                except ValueError:
                    continue  # corrupt frame, skip to the next marker

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            try:
                ready, _, _ = select.select([self._sock], [], [], remaining)
            except (OSError, ValueError):
                return None
            if not ready:
                return None
            try:
                chunk = self._sock.recv(4096)
            except (socket.timeout, TimeoutError):
                continue
            except OSError:
                raise BluetoothError("Connection lost")
            if not chunk:
                raise BluetoothError("Connection closed by device")
            self._rbuf.extend(chunk)

    def _ack_mdr(self, frame_seq: int) -> None:
        # The headset retransmits unacknowledged frames forever, which
        # stalls the session. The ACK must carry the frame's seq XOR 1
        # (echoing the seq back is ignored by XM6 firmware).
        try:
            self._sock.sendall(FrameCodec.encode(MDR_DT_ACK, frame_seq ^ 1, b""))
        except OSError:
            pass

    def mdr_init(self, timeout: float = 1.5) -> bool:
        """MDR INIT_REQUEST handshake.

        The device ACKs with seq XOR 1; afterwards commands must start
        at seq=1 and toggle per command (frames with a wrong seq are
        silently dropped by the firmware).
        """
        if self._mdr_ready:
            return True
        if not self._sock:
            raise BluetoothError("Not connected")
        self._sock.sendall(FrameCodec.encode(MDR_DT_INIT, 0, bytes([0x00, 0x00])))
        self._seq = 1
        acked = False
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                frame = self._read_frame(deadline)
            except BluetoothError:
                break
            if frame is None:
                break
            ftype, fseq, _payload = frame
            if ftype == MDR_DT_ACK:
                acked = True
            else:
                self._ack_mdr(fseq)
        if not acked:
            raise BluetoothError("MDR INIT not acknowledged")
        self._mdr_ready = True
        return True

    def mdr_command(
        self,
        payload: bytes,
        expect_resp: int,
        expect_sub: int = -1,
        timeout: float = 2.5,
    ) -> bytes:
        """Send a COMMAND_1 frame and return the matching response payload.

        A "No response" / lost connection almost always means the session
        died (headphones slept or re-connected while our socket stayed
        open); recover with a fresh handshake and retry once before
        surfacing the error.
        """
        try:
            return self._mdr_attempt(payload, expect_resp, expect_sub, timeout)
        except (BluetoothError, OSError) as e:
            # Transport-level failure (reset/broken socket) vs a command
            # that merely timed out. Classify by errno where possible —
            # message text is locale- and layer-dependent.
            transport_lost = (
                isinstance(e, OSError)
                and e.errno
                in (
                    errno.EPIPE,
                    errno.ECONNRESET,
                    errno.ECONNABORTED,
                    errno.ENOTCONN,
                    errno.EBADF,
                    errno.ETIMEDOUT,
                    errno.EHOSTDOWN,
                    errno.EHOSTUNREACH,
                )
                or "Connection lost" in str(e)
                or "closed by device" in str(e)
            )
            no_response = "No response" in str(e)
            if not (transport_lost or no_response):
                raise
            # A command that merely timed out may mean the firmware does not
            # support it (it ACKs the frame and stays silent), not that the
            # session died. Probe with a cheap battery read before paying for
            # a full reconnect — otherwise every unsupported SET triggers a
            # multi-second reconnect storm.
            if no_response and not transport_lost and self._session_alive():
                raise
            self.reconnect()
            return self._mdr_attempt(payload, expect_resp, expect_sub, timeout)

    def _session_alive(self) -> bool:
        """Cheap liveness probe: battery GET on the current session."""
        try:
            self._mdr_attempt(bytes([0x22, 0x00]), 0x23, 0x00, timeout=1.5)
            return True
        except (BluetoothError, OSError):
            return False

    def mdr_write(self, payload: bytes, settle: float = 0.8) -> None:
        """Fire-and-forget COMMAND_1 write.

        EQ band writes are ACKed but never answered or notified, so we
        send the frame and drain/ACK whatever trickles in for a moment.
        """
        if not self._sock:
            raise BluetoothError("Not connected")
        self._sock.sendall(FrameCodec.encode(MDR_DT_COMMAND_1, self._seq, payload))
        self._seq ^= 1
        deadline = time.monotonic() + settle
        while time.monotonic() < deadline:
            frame = self._read_frame(deadline)
            if frame is None:
                continue
            ftype, fseq, _ = frame
            if ftype != MDR_DT_ACK:
                self._ack_mdr(fseq)

    def _mdr_attempt(
        self,
        payload: bytes,
        expect_resp: int,
        expect_sub: int = -1,
        timeout: float = 2.5,
    ) -> bytes:
        """One COMMAND_1 round-trip, no retry.

        A response matches when payload[0] == expect_resp (and payload[1]
        == expect_sub when given). The device ACKs the command and repeats
        the data response a few times; we return on the first match and
        ACK everything else so the session stays healthy.
        """
        if not self._sock:
            raise BluetoothError("Not connected")
        self._sock.sendall(FrameCodec.encode(MDR_DT_COMMAND_1, self._seq, payload))
        self._seq ^= 1

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = self._read_frame(deadline)
            if frame is None:
                continue
            ftype, fseq, rpayload = frame
            if ftype != MDR_DT_ACK:
                self._ack_mdr(fseq)
            if (
                ftype == MDR_DT_COMMAND_1
                and rpayload
                and (expect_resp is None or rpayload[0] == expect_resp)
                and (
                    expect_sub < 0 or (len(rpayload) > 1 and rpayload[1] == expect_sub)
                )
            ):
                # The device repeats the data response until ACKed; a
                # duplicate may still sit in the buffer when the next
                # command runs. Drain briefly so the next round-trip
                # cannot consume a stale frame.
                drain_until = time.monotonic() + 0.15
                while time.monotonic() < drain_until:
                    extra = self._read_frame(drain_until)
                    if extra is None:
                        break
                    if extra[0] != MDR_DT_ACK:
                        self._ack_mdr(extra[1])
                return rpayload
        raise BluetoothError(
            f"No response to command {payload.hex()} "
            f"(expected {expect_resp if expect_resp is None else f'{expect_resp:#04x}'})"
        )

    def _sdp_find_channel(self, address: str, uuid: bytes) -> int:
        """Find the RFCOMM channel for a 128-bit service UUID via SDP.

        Note: BlueZ 6 deprecated the classic SDP client API, so on modern
        BlueZ this typically yields no records. connect() treats 0 as a
        soft failure and falls back to probing known channels.
        """
        import ctypes
        import ctypes.util

        lib = ctypes.CDLL(ctypes.util.find_library("bluetooth"), use_errno=True)

        class SdpList(ctypes.Structure):
            pass

        SdpList._fields_ = [
            ("next", ctypes.POINTER(SdpList)),
            ("data", ctypes.c_void_p),
        ]

        class SdpVal(ctypes.Union):
            _fields_ = [("u64", ctypes.c_uint64), ("b", ctypes.c_ubyte * 16)]

        class SdpData(ctypes.Structure):
            _fields_ = [("dataType", ctypes.c_uint8), ("value", SdpVal)]

        lib.sdp_connect.restype = ctypes.c_void_p
        lib.sdp_connect.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
        lib.sdp_list_append.restype = ctypes.POINTER(SdpList)
        lib.sdp_list_append.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        lib.sdp_service_search_attr_req.restype = ctypes.c_int
        lib.sdp_service_search_attr_req.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(SdpList),
            ctypes.c_uint32,
            ctypes.POINTER(SdpList),
            ctypes.POINTER(ctypes.POINTER(SdpList)),
        ]
        lib.sdp_get_access_protos.restype = ctypes.c_int
        lib.sdp_get_access_protos.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.POINTER(SdpList)),
        ]
        lib.sdp_get_proto_port.restype = ctypes.c_int
        lib.sdp_get_proto_port.argtypes = [ctypes.POINTER(SdpList), ctypes.c_int]
        lib.sdp_list_free.restype = ctypes.c_int
        lib.sdp_list_free.argtypes = [ctypes.POINTER(SdpList), ctypes.c_void_p]
        lib.sdp_close.restype = ctypes.c_int
        lib.sdp_close.argtypes = [ctypes.c_void_p]

        def bdaddr(a: str) -> bytes:
            # bdaddr_t is little-endian (reversed octet order)
            return struct.pack("6B", *[int(x, 16) for x in reversed(a.split(":"))])

        session = lib.sdp_connect(b"\x00" * 6, bdaddr(address), 0x02)
        if not session:
            return 0
        try:
            ud = SdpData()
            ud.dataType = 0x25  # SDP_UUID128
            for i, byte in enumerate(uuid):
                ud.value.b[i] = byte
            search = lib.sdp_list_append(None, ctypes.byref(ud))

            ad = SdpData()
            ad.dataType = 0x24  # SDP_UINT32
            ad.value.u64 = 0x0000FFFF
            attrid = lib.sdp_list_append(None, ctypes.byref(ad))

            rsp = ctypes.POINTER(SdpList)()
            rc = lib.sdp_service_search_attr_req(
                session, search, 0x0002, attrid, ctypes.byref(rsp)
            )
            if rc != 0:
                return 0

            port = 0
            r = rsp
            while r:
                protos = ctypes.POINTER(SdpList)()
                if (
                    lib.sdp_get_access_protos(r.contents.data, ctypes.byref(protos))
                    == 0
                ):
                    p = lib.sdp_get_proto_port(protos, 3)  # RFCOMM_UUID = 0x0003
                    if p and not port:
                        port = p
                    lib.sdp_list_free(protos, None)
                r = r.contents.next

            lib.sdp_list_free(rsp, None)
            lib.sdp_list_free(search, None)
            lib.sdp_list_free(attrid, None)
            return port
        finally:
            lib.sdp_close(session)

    def send(self, type_byte: int, payload: bytes) -> None:
        """Send a Sony frame."""
        frame = FrameCodec.encode(type_byte, self._seq, payload)
        self._sock.sendall(frame)
        self._seq = (self._seq + 1) & 1  # Toggle sequence bit

    def send_and_await(
        self,
        type_byte: int,
        payload: bytes,
        expected_ret: int,
        expected_sub: int = -1,
        timeout: float = 2.5,
    ) -> bytes:
        """Send a frame and wait for response."""
        self.send(type_byte, payload)
        return self._read_response(expected_ret, expected_sub, timeout)

    def _read_response(
        self, expected_ret: int, expected_sub: int = -1, timeout: float = 2.5
    ) -> bytes:
        """Read and decode a Sony frame response."""
        deadline = time.monotonic() + timeout
        leftover = bytearray()

        while time.monotonic() < deadline:
            # Read available data
            ready, _, _ = select.select([self._sock], [], [], 0.1)
            if not ready:
                continue

            try:
                chunk = self._sock.recv(4096)
            except socket.timeout:
                continue
            except Exception as e:
                raise BluetoothError(f"Receive error: {e}")

            if not chunk:
                raise BluetoothError("Connection closed by device")

            leftover.extend(chunk)

            # Try to decode frames from leftover
            while len(leftover) >= 2:
                # Find START marker
                start = leftover.find(bytes([0x3E]))
                if start == -1:
                    leftover = bytearray()
                    break

                if start > 0:
                    leftover = leftover[start:]

                # Find END marker
                end = leftover.find(bytes([0x3C]), 1)
                if end == -1:
                    break  # Need more data

                frame_data = bytes(leftover[: end + 1])
                leftover = leftover[end + 1 :]

                try:
                    frame_type, seq, payload = FrameCodec.decode(frame_data)

                    # Handle ACK frames (type=1) — update sequence
                    if frame_type == 1:
                        self._seq = seq
                        continue

                    # Check if this is the expected response
                    if frame_type == expected_ret:
                        if expected_sub < 0 or (
                            len(payload) >= 2 and payload[1] == expected_sub
                        ):
                            return payload
                        # Sub-type mismatch, keep looking
                        continue

                    # Check if it's a DATA_MDR response (type=12) with the right command
                    if frame_type == 12:
                        if payload and payload[0] == expected_ret:
                            if expected_sub < 0 or (
                                len(payload) >= 2 and payload[1] == expected_sub
                            ):
                                return payload[1:]  # Strip the command byte
                            continue

                    # Send ACK for DATA_MDR frames we receive
                    if frame_type == 12:
                        ack_payload = bytes([0x01, (1 - seq) & 1])
                        ack_frame = FrameCodec.encode(1, seq, ack_payload)
                        self._sock.sendall(ack_frame)

                except ValueError:
                    continue  # Bad frame, skip

        raise BluetoothError(f"Timeout waiting for response 0x{expected_ret:02X}")

    def disconnect(self):
        """Close the RFCOMM connection."""
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
        self._seq = 0
        self._rbuf = bytearray()
        self._mdr_ready = False

    def __del__(self):
        # Interpreter shutdown can tear down module globals before this
        # runs; never let cleanup raise there.
        try:
            self.disconnect()
        except Exception:
            pass


# ─── Sony Protocol V1 ────────────────────────────────────────────────────────


class SonyProtocolV1:
    """Protocol V1 — WH-1000XM3, WH-1000XM4."""

    # Command constants
    NC_ASM_INQUIRED = 0x02
    EQ_INQUIRED = 0x01
    SPEAK_TO_CHAT_INQUIRED = 0x05

    def __init__(self, transport: SonyTransport):
        self._t = transport

    def init_device(self):
        """V1 init — best-effort poll of ambient state."""
        try:
            self._t.send_and_await(
                0x66, [self.NC_ASM_INQUIRED], 0x67, self.NC_ASM_INQUIRED, 1.5
            )
        except Exception:
            pass

    def get_battery(self) -> dict:
        """Get battery level."""
        # Single battery: GET 10 00 -> RET 11 00 <level> <charging>
        try:
            resp = self._t.send_and_await(0x10, [0x00], 0x11, 0x00)
            if len(resp) >= 4:
                return {
                    "main": resp[2],
                    "charging": resp[3] == 1,
                    "left": None,
                    "right": None,
                    "case": None,
                }
        except Exception:
            pass

        # Dual L/R battery: GET 10 01 -> RET 11 01 <Llvl> <Lchg> <Rlvl> <Rchg>
        try:
            resp = self._t.send_and_await(0x10, [0x01], 0x11, 0x01)
            if len(resp) >= 6:
                left = resp[2]
                right = resp[4]
                charging = resp[3] == 1 or resp[5] == 1
                if right == 0 and left > 0:
                    # Over-ear model: single reading in left slot
                    return {
                        "main": left,
                        "charging": charging,
                        "left": None,
                        "right": None,
                        "case": None,
                    }
                return {
                    "main": min(left, right),
                    "charging": charging,
                    "left": left,
                    "right": right,
                    "case": None,
                }
        except Exception:
            pass

        # Case battery: GET 10 02
        try:
            resp = self._t.send_and_await(0x10, [0x02], 0x11, 0x02)
            if len(resp) >= 4:
                return {
                    "main": 0,
                    "charging": False,
                    "left": None,
                    "right": None,
                    "case": resp[2],
                }
        except Exception:
            pass

        # Nothing answered: report unknown, not 0% (the UI hides the
        # percentage for negative levels instead of lying).
        return {
            "main": -1,
            "charging": False,
            "left": None,
            "right": None,
            "case": None,
        }

    def get_noise_control(self) -> dict:
        """GET 66 02 -> RET 67 02 <effect> <ncType> <dualSingle> <asmType> <asmId> <asmLevel>"""
        resp = self._t.send_and_await(
            0x66, [self.NC_ASM_INQUIRED], 0x67, self.NC_ASM_INQUIRED
        )
        if len(resp) < 8:
            raise ValueError("Malformed noise control response")

        on = resp[2] != 0
        ambient = resp[4] == 0  # 0=ambient, 2=ANC
        voice = resp[6] == 1
        level = resp[7]

        if not on:
            mode = 0  # Off
        elif ambient:
            mode = 2  # Ambient
        else:
            mode = 1  # ANC

        return {
            "mode": mode,
            "ambientLevel": level if mode == 2 else 0,
            "focusOnVoice": voice,
        }

    def set_noise_control(
        self, mode: int, ambient_level: int = 0, focus_on_voice: bool = False
    ):
        """SET 68 02 <effect> 01 <dualSingle> 01 <asmId> <asmLevel>"""
        off = mode == 0
        ambient = mode == 2
        level = ambient_level if ambient else 0
        level = max(1, min(20, level)) if ambient else 0

        payload = [
            0x68,
            self.NC_ASM_INQUIRED,
            0 if off else 0x11,  # effect
            0x01,  # level adjustment
            0 if (ambient or off) else 0x02,  # dual/single
            0x01,  # level adjustment
            1 if focus_on_voice else 0,
            level,
        ]
        self._t.send(0x68, payload)

    def get_equalizer(self) -> dict:
        """GET 56 01 -> RET 57 01 <preset> 06 <bass+10> <b1..b5 +10>"""
        resp = self._t.send_and_await(0x56, [self.EQ_INQUIRED], 0x57, self.EQ_INQUIRED)
        if len(resp) < 10:
            raise ValueError("Incomplete equalizer response")

        preset = resp[2]
        clear_bass = resp[4] - 10
        bands = [resp[5 + i] - 10 for i in range(5)]

        return {"preset": preset, "clearBass": clear_bass, "bands": bands}

    def set_equalizer_preset(self, preset: int):
        """SET 58 01 <preset> 00"""
        self._t.send(0x58, [self.EQ_INQUIRED, preset, 0x00])

    def set_equalizer_custom(self, clear_bass: int, bands: list, preset: int = None):
        """SET 58 01 A0 <1+n> <clearBass+10> <bands+10>"""
        clamped_bass = max(0, min(20, clear_bass + 10))
        clamped_bands = [max(0, min(20, b + 10)) for b in bands]
        target = preset if preset is not None else 0xA0
        payload = [
            self.EQ_INQUIRED,
            target,
            1 + len(bands),
            clamped_bass,
        ] + clamped_bands
        self._t.send(0x58, payload)

    def get_firmware(self) -> str:
        """GET 04 02 -> RET 05 02 <len> <ascii>"""
        resp = self._t.send_and_await(0x04, [0x02], 0x05)
        if len(resp) > 3:
            return resp[3:].decode("ascii", errors="replace")
        return ""

    def get_codec(self) -> str:
        """GET 18 00 -> RET 19 00 <codec>"""
        resp = self._t.send_and_await(0x18, [0x00], 0x19)
        if len(resp) >= 3:
            codec_map = {1: "SBC", 2: "AAC", 3: "LDAC", 4: "LG-AAC", 5: "LHDC"}
            return codec_map.get(resp[2], f"Unknown(0x{resp[2]:02X})")
        return ""

    def get_speak_to_chat(self) -> bool:
        """GET f6 05 -> RET f7 05 <kind> <onOff>"""
        resp = self._t.send_and_await(
            0xF6, [self.SPEAK_TO_CHAT_INQUIRED], 0xF7, self.SPEAK_TO_CHAT_INQUIRED
        )
        if len(resp) < 4:
            return False
        session_active = resp[2] == 0x02
        enabled = resp[3] != 0
        return session_active or enabled

    def set_speak_to_chat(self, enabled: bool):
        """Enable without timeout, then set on/off."""
        if enabled:
            self._t.send(0xFC, [self.SPEAK_TO_CHAT_INQUIRED, 0x00, 0x00, 0x01])
        self._t.send(
            0xF8, [self.SPEAK_TO_CHAT_INQUIRED, 0x01, 0x01 if enabled else 0x00]
        )


# ─── Sony Protocol V2 ────────────────────────────────────────────────────────


class SonyProtocolV2:
    """Protocol V2 — WH-1000XM5, WF-1000XM, WH-CH720N, etc."""

    def __init__(self, transport: SonyTransport, ten_band_eq: bool = False):
        self._t = transport
        self._ten_band = ten_band_eq

    def init_device(self):
        """V2 handshake: 00 00 -> RET 01"""
        try:
            self._t.send_and_await(0x00, [0x00, 0x00], 0x01)
        except Exception:
            pass

    def get_battery(self) -> dict:
        """V2 battery using opcode 0x22."""
        # Single: GET 22 00 -> RET 23 00 <level> <charging>
        try:
            resp = self._t.send_and_await(0x22, [0x00], 0x23, 0x00)
            if len(resp) >= 4:
                return {
                    "main": resp[2],
                    "charging": resp[3] == 1,
                    "left": None,
                    "right": None,
                    "case": None,
                }
        except Exception:
            pass

        # Dual L/R: GET 22 09 -> RET 23 09 <Llvl> <Lchg> <Rlvl> <Rchg>
        try:
            resp = self._t.send_and_await(0x22, [0x09], 0x23, 0x09)
            if len(resp) >= 6:
                left, right = resp[2], resp[4]
                charging = resp[3] == 1 or resp[5] == 1
                return {
                    "main": min(left, right),
                    "charging": charging,
                    "left": left,
                    "right": right,
                    "case": None,
                }
        except Exception:
            pass

        # Case: GET 22 0A -> RET 23 0A <level> <chg>
        try:
            resp = self._t.send_and_await(0x22, [0x0A], 0x23, 0x0A)
            if len(resp) >= 4:
                return {
                    "main": 0,
                    "charging": False,
                    "left": None,
                    "right": None,
                    "case": resp[2],
                }
        except Exception:
            pass

        # Nothing answered: report unknown, not 0% (the UI hides the
        # percentage for negative levels instead of lying).
        return {
            "main": -1,
            "charging": False,
            "left": None,
            "right": None,
            "case": None,
        }

    def get_noise_control(self) -> dict:
        """GET 66 17 -> RET 67 17 01 <effect> <settingType> <voice> <level>"""
        resp = self._t.send_and_await(0x66, [0x17], 0x67)
        if len(resp) < 7 or resp[1] != 0x17 or resp[2] != 1:
            raise ValueError("Malformed noise control response")

        on = resp[3] != 0
        ambient = resp[4] != 0
        voice = resp[5] != 0
        level = resp[6]

        if not on:
            mode = 0
        elif ambient:
            mode = 2
        else:
            mode = 1

        return {
            "mode": mode,
            "ambientLevel": level if mode == 2 else 0,
            "focusOnVoice": voice,
        }

    def set_noise_control(
        self, mode: int, ambient_level: int = 0, focus_on_voice: bool = False
    ):
        """SET 68 17 01 <effect> <type> <voice> <level>"""
        effect = 0 if mode == 0 else 1
        setting_type = 1 if mode == 2 else 0
        voice = 1 if focus_on_voice else 0
        level = max(1, ambient_level) if mode == 2 else 1

        self._t.send(0x68, [0x17, 0x01, effect, setting_type, voice, level])

    def get_equalizer(self) -> dict:
        """GET 56 04 (10-band) or 56 00 (5-band + Clear Bass)."""
        inquired = 0x04 if self._ten_band else 0x00
        resp = self._t.send_and_await(0x56, [inquired], 0x57)

        if len(resp) < 4 or resp[1] != inquired:
            raise ValueError("Incomplete equalizer response")

        preset = resp[2]
        count = resp[3]

        if len(resp) < 4 + count:
            raise ValueError("Truncated equalizer response")

        if self._ten_band:
            # 10-band: <preset> 0a <b1..b10> (raw 0-12)
            bands = [resp[4 + i] for i in range(count)]
            return {"preset": preset, "clearBass": 0, "bands": bands, "tenBand": True}
        else:
            # 5-band + Clear Bass: <preset> 06 <bass+10> <b1..b5 +10>
            clear_bass = resp[4] - 10
            bands = [resp[5 + i] - 10 for i in range(min(count - 1, 5))]
            return {
                "preset": preset,
                "clearBass": clear_bass,
                "bands": bands,
                "tenBand": False,
            }

    def set_equalizer_preset(self, preset: int):
        """SET 58 <inquired> <preset> 00"""
        inquired = 0x04 if self._ten_band else 0x00
        self._t.send(0x58, [inquired, preset, 0x00])

    def set_equalizer_custom(self, clear_bass: int, bands: list, preset: int = None):
        """SET custom."""
        inquired = 0x04 if self._ten_band else 0x00
        target = preset if preset is not None else 0xA0
        if self._ten_band:
            payload = [inquired, target, len(bands)] + [
                max(0, min(12, b)) for b in bands
            ]
        else:
            clamped_bass = max(0, min(20, clear_bass + 10))
            clamped_bands = [max(0, min(20, b + 10)) for b in bands]
            payload = [inquired, target, 1 + len(bands), clamped_bass] + clamped_bands
        self._t.send(0x58, payload)

    def get_dsee(self) -> bool:
        """GET e6 01 -> RET e7 01 <enabled>"""
        resp = self._t.send_and_await(0xE6, [0x01], 0xE7, 0x01)
        if len(resp) >= 3:
            return resp[2] != 0
        return False

    def set_dsee(self, enabled: bool):
        """SET e8 01 <enabled>"""
        self._t.send(0xE8, [0x01, 0x01 if enabled else 0x00])

    def get_firmware(self) -> str:
        """GET 04 02 -> RET 05 02 <ascii>"""
        resp = self._t.send_and_await(0x04, [0x02], 0x05)
        if len(resp) > 3:
            return resp[3:].decode("ascii", errors="replace")
        return ""

    def get_codec(self) -> str:
        """GET 12 02 -> RET 13 02 <codec>"""
        resp = self._t.send_and_await(0x12, [0x02], 0x13)
        if len(resp) >= 3:
            codec_map = {1: "SBC", 2: "AAC", 3: "LDAC", 4: "LG-AAC", 5: "LHDC"}
            return codec_map.get(resp[2], f"Unknown(0x{resp[2]:02X})")
        return ""

    def get_auto_power_off(self) -> int:
        """GET 26 05 -> RET 27 05 <c0> <c1>"""
        resp = self._t.send_and_await(0x26, [0x05], 0x27)
        if len(resp) >= 4:
            codes = [
                (0x11, 0x00),
                (0x00, 0x00),
                (0x01, 0x01),
                (0x02, 0x02),
                (0x03, 0x03),
                (0x10, 0x00),
            ]
            for i, (c0, c1) in enumerate(codes):
                if resp[2] == c0 and resp[3] == c1:
                    return i
        return 0

    def set_auto_power_off(self, index: int):
        """SET 28 05 <c0> <c1>"""
        if 0 <= index < 6:
            codes = [
                (0x11, 0x00),
                (0x00, 0x00),
                (0x01, 0x01),
                (0x02, 0x02),
                (0x03, 0x03),
                (0x10, 0x00),
            ]
            self._t.send(0x28, [0x05, codes[index][0], codes[index][1]])

    def get_speak_to_chat(self) -> bool:
        """GET f6 0c -> RET f7 0c <inverted_enabled>"""
        resp = self._t.send_and_await(0xF6, [0x0C], 0xF7, 0x0C)
        if len(resp) >= 3:
            return resp[2] == 0
        return False

    def set_speak_to_chat(self, enabled: bool):
        """SET f8 0c <inverted_enabled> 01"""
        self._t.send(0xF8, [0x0C, 0x00 if enabled else 0x01, 0x01])

    def get_adaptive_volume(self) -> bool:
        """GET f6 0a -> RET f7 0a <inverted_enabled>"""
        resp = self._t.send_and_await(0xF6, [0x0A], 0xF7, 0x0A)
        if len(resp) >= 3:
            return resp[2] == 0
        return False

    def set_adaptive_volume(self, enabled: bool):
        """SET f8 0a <inverted_enabled>"""
        self._t.send(0xF8, [0x0A, 0x00 if enabled else 0x01])


# ─── Sony MDR COMMAND_1 Protocol (WH-1000XM6) ────────────────────────────────


class SonyProtocolMDR:
    """Sony MDR COMMAND_1 protocol (WH-1000XM6 and newer firmware).

    Requests are COMMAND_1 (0x0C) frames with payload [opcode, sub, ...];
    responses echo opcode+1 and every device frame must be ACKed with
    seq XOR 1 (see SonyTransport._ack_mdr). Verified against a live
    WH-1000XM6:

      battery   GET 22 00 -> RET 23 00 <level> <charging>
      NCASM     GET 66 19 -> RET 67 19 <P> <B> <M> <V> <L> <A> 00
                SET 68 19 1 <B> <M> <V> <L> <A> 00 -> NTFY 69 19 ...
      info      GET 36 02 -> RET 37 02 <len-prefixed strings>
      caps      GET 06 02 -> RET 07 02 <count> <resp-op, kind>...
      equalizer GET 56 04 -> RET 57 04 <preset> 0a <10 bands>
                caps GET 50 04 -> RET 51 04 <bands> <steps> <count> <id 00>*
                SET 58 04 <preset> 00 -> NTFY 59 04 <preset> 0a <bands>
      dsee      GET E6 01 -> RET E7 01 <v>; SET E8 01 <v> -> NTFY E9 01 <v>
                (v: 00 on, 01 off — Sony's inverted booleans)
      codec     GET 12 02 -> RET 13 02 <c> (01 SBC, 02 AAC, 10 LDAC,
                20 aptX, 21 aptX HD, 30 LC3); GET 12 00 returns a JSON
                blob with model + firmware (sVer) + codec + link quality
      asc       caps GET 70 00 -> RET 71 00 <count> <scene id>*
                (08 Focus, 10 Office, 20 Aware); SET 78 00 <scene> ->
                NTFY 79 00 01; status GETs (72/76/7A) are not answered

    The XM6 firmware uses its own preset id table (00 off, 20 Vocal,
    30 Bass Boost, 31 Treble Boost, 32 Excited, 33 Mellow, A0-A2 custom
    1-3 — names inferred from the reported band shapes), not the classic
    10-17 ids; unknown ids are ACKed and silently ignored, which is what
    made earlier SET attempts look dead.
    """

    NCASM_SUB = 0x19  # XM6 wire sub (XM3/XM4 used 0x02)

    def __init__(self, transport: SonyTransport):
        self._t = transport

    def init_device(self):
        # The INIT handshake was already performed inside
        # SonyTransport.connect() to validate the channel; idempotent.
        self._t.mdr_init()

    def get_battery(self) -> dict:
        resp = self._t.mdr_command(bytes([0x22, 0x00]), 0x23, 0x00)
        if len(resp) < 4:
            raise ValueError("Incomplete battery response")
        return {
            "main": resp[2],
            "charging": resp[3] == 1,
            "left": None,
            "right": None,
            "case": None,
        }

    def _get_ncasm(self) -> bytes:
        resp = self._t.mdr_command(bytes([0x66, self.NCASM_SUB]), 0x67, self.NCASM_SUB)
        if len(resp) < 9:
            raise ValueError("Malformed NCASM response")
        return resp

    def get_noise_control(self) -> dict:
        resp = self._get_ncasm()
        enabled = resp[3] != 0
        ambient = resp[4] != 0
        if not enabled:
            mode = 0
        elif ambient:
            mode = 2
        else:
            mode = 1
        return {
            "mode": mode,
            "ambientLevel": resp[6],
            "focusOnVoice": resp[5] != 0,
            "autoAmbient": resp[7] != 0,
        }

    def set_noise_control(
        self, mode: int, ambient_level: int = 0, focus_on_voice: bool = False
    ):
        try:
            cur = self._get_ncasm()
            auto = cur[7]  # preserve Auto Ambient Sound
            level_cur = cur[6]
        except Exception:
            auto, level_cur = 0, 20
        enabled = 0 if mode == 0 else 1
        ambient = 1 if mode == 2 else 0
        level = ambient_level if (mode == 2 and 1 <= ambient_level <= 20) else level_cur
        payload = bytes(
            [
                0x68,
                self.NCASM_SUB,
                1,  # persist/commit (0 would be a slider-preview frame)
                enabled,
                ambient,
                1 if focus_on_voice else 0,
                level,
                auto,
                0,
            ]
        )
        # The device confirms a SET with a 0x69 notification frame.
        self._t.mdr_command(payload, 0x69, self.NCASM_SUB, timeout=3.0)

    def get_asc_scenes(self) -> list:
        """GET 70 00 -> RET 71 00 <count> <scene id>*.

        SENSE (Adaptive Sound Control) capability. On the XM6 this lists
        three scenes: 08 Focus, 10 Office, 20 Aware.
        """
        resp = self._t.mdr_command(bytes([0x70, 0x00]), 0x71, 0x00, timeout=3.0)
        if len(resp) < 3 or resp[1] != 0x00:
            raise ValueError("Incomplete adaptive sound control capability")
        count = resp[2]
        return [resp[3 + i] for i in range(min(count, len(resp) - 3))]

    def set_asc_scene(self, scene: int):
        """SET 78 00 <scene> -> NTFY 79 00 01.

        Mirrors the scene choice to the device. The XM6 exposes no
        readable SENSE status (GET 72/76/7A are silent) and the scene
        write alone does not change the noise-control state — the
        scene's NC combination is applied separately (see
        SonyDeviceController.set_asc_scene).
        """
        self._t.mdr_command(bytes([0x78, 0x00, scene]), 0x79, 0x00, timeout=3.0)

    def get_equalizer(self) -> dict:
        resp = self._t.mdr_command(bytes([0x56, 0x04]), 0x57)
        if len(resp) < 4 or resp[1] != 0x04:
            raise ValueError("Incomplete equalizer response")
        count = resp[3]
        bands = [resp[4 + i] for i in range(min(count, len(resp) - 4))]
        return {"preset": resp[2], "clearBass": 0, "bands": bands, "tenBand": True}

    def get_equalizer_presets(self) -> tuple:
        """GET 50 04 -> RET 51 04 <bands> <steps> <count> <id 00>*.

        Returns (preset_ids, level_steps).
        """
        resp = self._t.mdr_command(bytes([0x50, 0x04]), 0x51, 0x04, timeout=3.0)
        if len(resp) < 5 or resp[1] != 0x04:
            raise ValueError("Incomplete equalizer capability response")
        steps = resp[3]
        count = resp[4]
        ids = []
        i = 5
        for _ in range(count):
            if i >= len(resp):
                break
            ids.append(resp[i])
            i += 2  # <id> <namelen=00>
        return ids, steps

    def set_equalizer_preset(self, preset: int):
        """SET 58 04 <preset> 00 -> NTFY 59 04 <preset> 0a <bands>.

        Returns the resulting band curve so the UI can pick up the
        preset's stored bands without a second round-trip.
        """
        resp = self._t.mdr_command(
            bytes([0x58, 0x04, preset, 0x00]), 0x59, 0x04, timeout=3.0
        )
        bands = []
        if len(resp) > 4 and resp[3] == 0x0A:
            bands = [b for b in resp[4:14]]
        return {"preset": preset, "bands": bands}

    def set_equalizer_custom(self, clear_bass: int, bands: list, preset: int = None):
        """SET 58 04 <preset> 0a <10 bands> — ACKed, never notified.

        Band values are raw 0..steps-1 (center 6 on the XM6's 13 steps).
        """
        if preset is None:
            raise ValueError("Custom band writes need the target preset id")
        if len(bands) != 10:
            raise ValueError("Expected 10 band values")
        self._t.mdr_write(
            bytes([0x58, 0x04, preset, 0x0A] + [int(b) & 0xFF for b in bands])
        )

    def get_device_info(self) -> dict:
        """Length-prefixed strings: hwId, mdrId, modelId, '', serial, ..."""
        resp = self._t.mdr_command(bytes([0x36, 0x02]), 0x37, 0x02, timeout=3.0)
        strings = []
        i = 2
        while i < len(resp):
            ln = resp[i]
            if i + 1 + ln > len(resp):
                break
            strings.append(
                resp[i + 1 : i + 1 + ln].decode("ascii", "replace") if ln else ""
            )
            i += 1 + ln
        return {
            "hwId": strings[0] if strings else None,
            "mdrId": strings[1] if len(strings) > 1 else None,
            "modelId": strings[2] if len(strings) > 2 else None,
            "serial": next((s for s in strings[3:] if len(s) >= 8), None),
        }

    def get_capabilities(self) -> list:
        """Manifest of (response_opcode, parameter_kind) pairs."""
        resp = self._t.mdr_command(bytes([0x06, 0x02]), 0x07, 0x02, timeout=3.0)
        body = resp[3:]
        return [(body[i], body[i + 1]) for i in range(0, len(body) - 1, 2)]

    def get_firmware(self) -> str:
        raise ValueError("Firmware version is not exposed on this firmware")

    def get_codec(self) -> str:
        """GET 12 02 -> RET 13 02 <codec> (01 SBC, 02 AAC, 10 LDAC, ...)."""
        resp = self._t.mdr_command(bytes([0x12, 0x02]), 0x13, 0x02)
        if len(resp) < 3:
            raise ValueError("Incomplete codec response")
        return {
            0x01: "SBC",
            0x02: "AAC",
            0x10: "LDAC",
            0x20: "aptX",
            0x21: "aptX HD",
            0x30: "LC3",
        }.get(resp[2], "")

    def get_dsee(self) -> bool:
        """GET E6 01 -> RET E7 01 <v> (00 on, 01 off — inverted bool)."""
        resp = self._t.mdr_command(bytes([0xE6, 0x01]), 0xE7, 0x01)
        return len(resp) > 2 and resp[2] == 0x00

    def set_dsee(self, enabled: bool):
        """SET E8 01 <v> -> NTFY E9 01 <v> (00 on, 01 off)."""
        self._t.mdr_command(
            bytes([0xE8, 0x01, 0x00 if enabled else 0x01]), 0xE9, 0x01, timeout=3.0
        )


# Every IEEE OUI registered to a Sony entity (standards-oui.ieee.org,
# fetched Nov 2026: Sony Corporation, Sony Interactive Entertainment,
# Home Entertainment & Sound Products, Visual / Video & Sound Products,
# Imaging Products & Solutions). No Sony *mobile* registrations exist,
# so Xperia phones do not match.
SONY_OUIS = frozenset(
    {
        "00:00:95",
        "00:01:4A",
        "00:04:1F",
        "00:0A:D9",
        "00:0E:07",
        "00:0F:DE",
        "00:12:EE",
        "00:13:15",
        "00:13:A9",
        "00:15:C1",
        "00:16:20",
        "00:16:B8",
        "00:18:13",
        "00:19:63",
        "00:19:C5",
        "00:1A:75",
        "00:1A:80",
        "00:1B:59",
        "00:1C:A4",
        "00:1D:0D",
        "00:1D:28",
        "00:1D:BA",
        "00:1E:45",
        "00:1E:DC",
        "00:1F:A7",
        "00:1F:E4",
        "00:21:9E",
        "00:22:98",
        "00:22:A6",
        "00:23:45",
        "00:23:F1",
        "00:24:8D",
        "00:24:BE",
        "00:24:EF",
        "00:25:E7",
        "00:D9:D1",
        "00:E4:21",
        "00:EB:2D",
        "04:5D:4B",
        "04:F7:78",
        "08:00:46",
        "0C:70:43",
        "0C:FE:45",
        "10:4F:A8",
        "14:3F:A6",
        "18:00:2D",
        "1C:7B:21",
        "20:54:76",
        "24:21:AB",
        "28:0D:FC",
        "28:3F:69",
        "28:40:DD",
        "2C:97:ED",
        "2C:9E:00",
        "2C:CC:44",
        "30:17:C8",
        "30:39:26",
        "30:75:12",
        "30:A8:DB",
        "30:F9:ED",
        "38:18:4C",
        "38:78:62",
        "3C:01:EF",
        "3C:07:71",
        "3C:38:F4",
        "40:2B:A1",
        "40:40:A7",
        "40:B8:37",
        "44:74:6C",
        "44:D4:E0",
        "4C:21:D0",
        "50:12:5C",
        "50:B0:3B",
        "54:26:3D",
        "54:42:49",
        "54:53:ED",
        "54:E6:FD",
        "58:17:0C",
        "58:18:62",
        "58:48:22",
        "5C:84:3C",
        "5C:96:66",
        "5C:B5:24",
        "68:28:6C",
        "68:76:4F",
        "6C:0E:0D",
        "6C:23:B9",
        "6C:B2:27",
        "70:26:05",
        "70:66:2A",
        "70:9E:29",
        "78:84:3C",
        "78:C8:81",
        "80:99:E7",
        "84:00:D2",
        "84:8E:DF",
        "84:C7:EA",
        "84:E6:57",
        "88:C9:E8",
        "8C:64:22",
        "90:47:48",
        "90:C1:15",
        "94:CE:2C",
        "94:DB:56",
        "98:FA:2E",
        "9C:37:CB",
        "9C:5C:F9",
        "A0:E4:53",
        "A8:E3:EE",
        "AC:80:0A",
        "AC:9B:0A",
        "B4:0A:D8",
        "B4:1F:4D",
        "B4:52:7D",
        "B4:52:7E",
        "B8:F9:34",
        "BC:33:29",
        "BC:60:A7",
        "BC:6E:64",
        "C0:15:1B",
        "C4:3A:BE",
        "C8:4A:A0",
        "C8:63:F1",
        "CC:98:8B",
        "D0:51:62",
        "D4:38:9C",
        "D4:F7:D5",
        "D8:D4:3C",
        "E0:63:E5",
        "E8:6E:3A",
        "EC:74:8C",
        "F0:BF:97",
        "F4:64:12",
        "F8:46:1C",
        "F8:4E:17",
        "F8:D0:AC",
        "FC:0F:E6",
        "FC:CA:40",
        "FC:F1:52",
    }
)


def is_sony_headphone(name: str, address: str) -> bool:
    """Check if a Bluetooth device is a Sony headphone/earbud.

    Two signals: the model-name patterns of Sony's headphone lines, or
    a MAC whose OUI is owned by a Sony entity.
    """
    upper = (name or "").upper()
    for pattern in ("WH-", "WF-", "WI-", "MDR-", "LINKBUDS", "ULT WEAR", "INZONE"):
        if pattern in upper:
            return True
    if address:
        oui = address.upper().replace("-", ":")[:8]
        if oui in SONY_OUIS:
            return True
    return False


# Sony's Adaptive Sound Control scenes with their stock definitions.
# The device only stores the selection; the audible effect is each
# scene's noise-control combination, which the user can edit in the UI
# (persisted by the daemon).
ASC_SCENE_DEFAULTS = [
    {"id": 0x08, "name": "Focus", "mode": 1, "ambientLevel": 0, "focusOnVoice": False},
    {
        "id": 0x10,
        "name": "Office",
        "mode": 2,
        "ambientLevel": 10,
        "focusOnVoice": False,
    },
    {"id": 0x20, "name": "Aware", "mode": 2, "ambientLevel": 20, "focusOnVoice": False},
]


# ─── BlueZ Manager ───────────────────────────────────────────────────────────


class BlueZManager:
    """Manages BlueZ D-Bus communication for device discovery and connection."""

    def __init__(self):
        self._bus = None
        self._bus_lock = threading.Lock()
        self._adapter_path = None

    def _get_bus(self):
        # One shared connection guarded by _bus_lock: dbus-python's default
        # connection is thread-local, and the daemon's threaded servers
        # would otherwise open a fresh system-bus connection per request.
        # All BlueZ calls here are short, so serializing them is cheap.
        # Callers must hold _bus_lock for the whole D-Bus exchange.
        if self._bus is None:
            try:
                self._bus = dbus.SystemBus()
            except Exception as e:
                raise BluetoothError(f"Failed to connect to system bus: {e}")
        return self._bus

    def list_adapters(self) -> list:
        """List Bluetooth adapters."""
        with self._bus_lock:
            bus = self._get_bus()
            obj = bus.get_object("org.bluez", "/")
            manager = dbus.Interface(obj, "org.freedesktop.DBus.ObjectManager")
            objects = manager.GetManagedObjects()

        adapters = []
        for path, interfaces in objects.items():
            if "org.bluez.Adapter1" in interfaces:
                adapter = interfaces["org.bluez.Adapter1"]
                adapters.append(
                    {
                        "path": path,
                        "name": adapter.get("Name", ""),
                        "address": adapter.get("Address", ""),
                        "powered": adapter.get("Powered", False),
                    }
                )
        return adapters

    def list_devices(self) -> list:
        """List all paired Bluetooth devices belonging to Sony headphones."""
        with self._bus_lock:
            bus = self._get_bus()
            obj = bus.get_object("org.bluez", "/")
            manager = dbus.Interface(obj, "org.freedesktop.DBus.ObjectManager")
            objects = manager.GetManagedObjects()

        devices = []
        for path, interfaces in objects.items():
            if "org.bluez.Device1" not in interfaces:
                continue

            dev = interfaces["org.bluez.Device1"]
            paired = dev.get("Paired", False)
            connected = dev.get("Connected", False)
            name = dev.get("Name", "Unknown")
            address = dev.get("Address", "")

            # Filter for Sony devices
            if not is_sony_headphone(name, address):
                continue

            devices.append(
                {
                    "path": path,
                    "name": name,
                    "address": address,
                    "paired": paired,
                    "connected": connected,
                }
            )

        return devices

    def connect_device(self, device_path: str) -> bool:
        """Ask BlueZ to connect a device."""
        with self._bus_lock:
            bus = self._get_bus()
            obj = bus.get_object("org.bluez", device_path)
            dev = dbus.Interface(obj, "org.bluez.Device1")
            try:
                dev.Connect()
                return True
            except Exception as e:
                raise BluetoothError(f"Failed to connect device: {e}")

    def disconnect_device(self, device_path: str) -> bool:
        """Ask BlueZ to disconnect a device."""
        with self._bus_lock:
            bus = self._get_bus()
            obj = bus.get_object("org.bluez", device_path)
            dev = dbus.Interface(obj, "org.bluez.Device1")
            try:
                dev.Disconnect()
                return True
            except Exception as e:
                raise BluetoothError(f"Failed to disconnect device: {e}")

    def get_device_property(self, device_path: str, property: str) -> any:
        """Get a property from a device."""
        with self._bus_lock:
            bus = self._get_bus()
            obj = bus.get_object("org.bluez", device_path)
            props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
            return props.Get("org.bluez.Device1", property)


# ─── Sony Device Controller ──────────────────────────────────────────────────


class SonyDeviceController:
    """High-level controller for a Sony headphone."""

    def __init__(self, address: str, device_name: str):
        self._address = address
        self._device_name = device_name
        self._model = identify_model(device_name)
        self._profile = get_profile(self._model)
        self._transport = SonyTransport()
        self._protocol = None
        self._connected = False

    @property
    def address(self):
        return self._address

    @property
    def device_name(self):
        return self._device_name

    @property
    def model(self):
        return self._model

    @property
    def profile(self):
        return self._profile

    @property
    def connected(self):
        return self._connected

    def connect(self):
        """Connect to the device and initialize the protocol."""
        try:
            # Connect RFCOMM. Unknown models skip the 1-30 channel
            # brute-force scan: keep the daemon's per-address lock hold
            # short for devices whose service layout we cannot predict.
            uuid = (
                SERVICE_UUID_V1
                if self._profile["protocol"] == "V1"
                else SERVICE_UUID_V2
            )
            self._transport.connect(
                self._address, uuid, full_scan=self._model in DEVICE_PROFILES
            )

            # Unknown models default to MDR, but V1 devices answer the
            # INIT handshake too. Distinguish with the table-1
            # supported-functions query (MDR/V2 only answer 06 00 -> 07).
            if self._model == "Unknown":
                proto = "MDR"
                try:
                    self._transport._mdr_attempt(
                        bytes([0x06, 0x00]), 0x07, -1, timeout=2.0
                    )
                except Exception:
                    proto = "V1"
                self._profile = dict(self._profile)
                self._profile["protocol"] = proto

            # Initialize protocol
            if self._profile["protocol"] == "V1":
                self._protocol = SonyProtocolV1(self._transport)
            elif self._profile["protocol"] == "MDR":
                self._protocol = SonyProtocolMDR(self._transport)
            else:
                self._protocol = SonyProtocolV2(self._transport)

            self._protocol.init_device()
            self._connected = True

            # Advertise the preset ids the firmware accepts (MDR models use
            # a model-specific id table; the UI builds its combo from this).
            if self._profile.get("eq") and hasattr(
                self._protocol, "get_equalizer_presets"
            ):
                try:
                    ids, steps = self._protocol.get_equalizer_presets()
                    if ids:
                        self._profile = dict(self._profile)
                        self._profile["eqPresets"] = ids
                        self._profile["eqSteps"] = steps
                except Exception:
                    pass

            # Adaptive Sound Control scene ids (Focus/Office/Aware).
            if hasattr(self._protocol, "get_asc_scenes"):
                try:
                    scenes = self._protocol.get_asc_scenes()
                    if scenes:
                        self._profile = dict(self._profile)
                        self._profile["ascScenes"] = scenes
                except Exception:
                    pass
        except Exception as e:
            self.disconnect()
            raise BluetoothError(f"Sony connection failed: {e}")

    def disconnect(self):
        """Disconnect from the device."""
        if self._transport:
            self._transport.disconnect()
        self._connected = False

    # ── Public API ──────────────────────────────────────────────────────────

    def refresh_battery(self) -> dict:
        if not self._connected:
            return {"error": "Not connected"}
        return self._protocol.get_battery()

    def refresh_noise_control(self) -> dict:
        if not self._connected:
            return {"error": "Not connected"}
        return self._protocol.get_noise_control()

    def poll_state(self) -> dict:
        """Cheap snapshot for the daemon's change monitor.

        Reads only the fields the headphones can change on their own
        (battery, noise control, codec, DSEE). A field whose read fails
        is omitted rather than failing the whole snapshot; an entirely
        empty result means the session is dead and raises.
        """
        if not self._connected:
            raise BluetoothError("Not connected")
        state = {}
        try:
            b = self._protocol.get_battery()
            state["battery"] = b.get("main", -1)
            state["charging"] = bool(b.get("charging", False))
        except Exception:
            pass
        try:
            n = self._protocol.get_noise_control()
            state["mode"] = n.get("mode", 0)
            state["ambientLevel"] = n.get("ambientLevel", 10)
            state["focusOnVoice"] = bool(n.get("focusOnVoice", False))
        except Exception:
            pass
        if self._profile.get("codec"):
            try:
                state["codec"] = self._protocol.get_codec() or ""
            except Exception:
                pass
        if self._profile.get("dsee"):
            try:
                state["dsee"] = bool(self._protocol.get_dsee())
            except Exception:
                pass
        if not state:
            raise BluetoothError("State poll failed")
        return state

    def set_noise_mode(
        self, mode: int, ambient_level: int = 0, focus_on_voice: bool = False
    ):
        if not self._connected:
            return {"error": "Not connected"}
        self._protocol.set_noise_control(mode, ambient_level, focus_on_voice)
        return {"success": True}

    # Sony's Adaptive Sound Control scenes are app-side presets: the
    # device only stores the selection (SENSE family, write-only on the
    # XM6) while the audible change is the scene's NC combination.
    ASC_SCENE_PRESETS = {
        s["id"]: {"mode": s["mode"], "ambientLevel": s["ambientLevel"]}
        for s in ASC_SCENE_DEFAULTS
    }

    def set_asc_scene(
        self,
        scene: int,
        mode: int = None,
        ambient_level: int = 0,
        focus_on_voice: bool = False,
    ):
        if not self._connected:
            return {"error": "Not connected"}
        if mode is None:  # fall back to the stock definition
            preset = self.ASC_SCENE_PRESETS.get(scene)
            if preset is None:
                return {"error": f"Unknown ASC scene {scene:#04x}"}
            mode, ambient_level = preset["mode"], preset["ambientLevel"]
        self._protocol.set_noise_control(mode, ambient_level, focus_on_voice)
        # Mirror the selection to the device; only the three stock ids
        # exist in the SENSE family, custom scenes skip the mirror.
        if scene in self.ASC_SCENE_PRESETS:
            try:
                self._protocol.set_asc_scene(scene)
            except Exception:
                pass
        return {
            "success": True,
            "scene": scene,
            "mode": mode,
            "ambientLevel": ambient_level,
        }

    def refresh_equalizer(self) -> dict:
        if not self._connected:
            return {"error": "Not connected"}
        return self._protocol.get_equalizer()

    def set_equalizer_preset(self, preset: int):
        if not self._connected:
            return {"error": "Not connected"}
        result = self._protocol.set_equalizer_preset(preset) or {}
        result["success"] = True
        return result

    def set_equalizer_custom(self, clear_bass: int, bands: list, preset: int = None):
        if not self._connected:
            return {"error": "Not connected"}
        if preset is not None:
            self._protocol.set_equalizer_custom(clear_bass, bands, preset=preset)
        else:
            self._protocol.set_equalizer_custom(clear_bass, bands)
        return {"success": True}

    def refresh_info(self) -> dict:
        """Get firmware version and codec."""
        result = {}
        if self._profile.get("firmware"):
            try:
                result["firmware"] = self._protocol.get_firmware()
            except Exception:
                result["firmware"] = None
        if self._profile.get("codec"):
            try:
                result["codec"] = self._protocol.get_codec()
            except Exception:
                result["codec"] = None
        return result

    def set_dsee(self, enabled: bool):
        if not self._connected:
            return {"error": "Not connected"}
        self._protocol.set_dsee(enabled)
        return {"success": True}

    def get_dsee(self) -> bool:
        if not self._connected:
            return False
        try:
            return self._protocol.get_dsee()
        except Exception:
            return False

    def set_speak_to_chat(self, enabled: bool):
        if not self._connected:
            return {"error": "Not connected"}
        self._protocol.set_speak_to_chat(enabled)
        return {"success": True}

    def get_speak_to_chat(self) -> bool:
        if not self._connected:
            return False
        try:
            return self._protocol.get_speak_to_chat()
        except Exception:
            return False

    def set_adaptive_volume(self, enabled: bool):
        if not self._connected:
            return {"error": "Not connected"}
        self._protocol.set_adaptive_volume(enabled)
        return {"success": True}

    def get_adaptive_volume(self) -> bool:
        if not self._connected:
            return False
        try:
            return self._protocol.get_adaptive_volume()
        except Exception:
            return False

    def set_auto_power_off(self, index: int):
        if not self._connected:
            return {"error": "Not connected"}
        self._protocol.set_auto_power_off(index)
        return {"success": True}

    def get_auto_power_off(self) -> int:
        if not self._connected:
            return 0
        try:
            return self._protocol.get_auto_power_off()
        except Exception:
            return 0

    def power_off(self):
        """Power off the device."""
        if not self._connected:
            return {"error": "Not connected"}
        if self._profile["protocol"] != "MDR":
            # The V1/V2 power-off frame is unverified (the old code sent
            # 0x22 as a frame *type*, a guaranteed no-op); an unconfirmed
            # command risks corrupting the session, so decline.
            return {"error": "Power off is not supported on this model"}
        # MDR: POWER SET_STATUS 24 03 01 (verified on the WH-1000XM5,
        # same COMMAND_1 family). The link drops immediately, so nothing
        # answers; if the XM6 ignores it we still drop the session and
        # the device stays on — same visible outcome as before.
        try:
            self._transport.mdr_write(bytes([0x24, 0x03, 0x01]), settle=0.3)
        except Exception:
            pass
        self.disconnect()
        return {"success": True}
