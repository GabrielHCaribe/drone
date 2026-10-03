#!/usr/bin/env python3
"""
DroneBoyfriendTracker ground station (Windows / macOS / Linux, Python 3.8+, standard library only)

    python ground_station.py

Opens a pink page in your browser with:
  * KILL (button, Space or K)  - motors off immediately, latched until "Clear kill"
  * LAND, DISARM, START FOLLOW (two-step confirm), video on/off
  * telemetry, link quality and control-loop timing
  * live video from the drone iPhone (when enabled)

Safety design
-------------
The ESP32 refuses to arm unless this program is sending heartbeats, and it lands
the drone if they stop for 0.5 s. The heartbeat is only sent while the BROWSER
PAGE is alive (a timer in a Web Worker pings this program every 100 ms). If the
page is closed or the browser freezes, the drone lands. A forgotten background
copy of this script can therefore never pretend that a kill switch is present.
"""

import http.server
import json
import os
import socket
import socketserver
import struct
import sys
import threading
import time
import webbrowser

# --------------------------------------------------------------------------- config
DRONE_ADDR = (os.environ.get("DRONEBOYFRIENDTRACKER_IP", "192.168.4.1"), 4210)
LOCAL_CTRL_PORT = 4212   # replies (telemetry, acks) come back to this port
VIDEO_PORT = 4211        # JPEG frames from the drone iPhone
HTTP_PORT = 8765         # browser UI: http://127.0.0.1:8765
HEARTBEAT_HZ = 50
BROWSER_TIMEOUT_S = 0.4  # no browser ping for this long -> stop heartbeats -> drone lands

WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

# --------------------------------------------------------------------------- protocol
# Must match firmware/DroneFC/protocol.h and docs/PROTOCOL.md
MAGIC = 0x4450
VERSION = 1
SRC_LAPTOP = 1
FLAG_KILL = 0x01

PKT_HEARTBEAT = 0x01
PKT_COMMAND = 0x10
PKT_TELEMETRY = 0x80
PKT_CMD_ACK = 0x81
PKT_PARAM_INFO = 0x82

CMD = {
    "arm": 1, "disarm": 2, "land": 3, "start_follow": 4, "cancel_follow": 5,
    "cal_gyro": 6, "cal_level": 7, "param_save": 8, "param_reset": 9,
    "esc_cal_high": 10, "esc_cal_low": 11, "esc_cal_exit": 12,
    "video_on": 13, "video_off": 14, "kill": 15,
}
CMD_NAMES = {v: k for k, v in CMD.items()}

HEADER = struct.Struct("<HBBBBH")
TELEM = struct.Struct("<4B3h3H4H3H3B3B3H2Hh4sI")
ACK = struct.Struct("<BBH")
VIDEO_HDR = struct.Struct("<HHBB4HBB")
VIDEO_MAGIC = 0x5650

assert HEADER.size == 8 and TELEM.size == 56 and VIDEO_HDR.size == 16


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


# --------------------------------------------------------------------------- state
class Station:
    def __init__(self):
        self.lock = threading.Lock()
        self.seq = 0
        self.kill_latched = False
        self.browser_last = 0.0
        self.telem = None
        self.telem_time = 0.0
        self.acks = []  # recent acks for the UI
        self.pending = {}  # seq -> (cmd, arg, first_sent, tries)

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", LOCAL_CTRL_PORT))
        self.sock.settimeout(0.2)

        self.video_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.video_sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        self.video_sock.bind(("0.0.0.0", VIDEO_PORT))
        self.video_sock.settimeout(0.5)

        self.frame_cond = threading.Condition()
        self.frame_jpeg = None
        self.frame_id = -1
        self.frame_time = 0.0
        self.frame_box = None
        self.frame_tracking = False
        self.video_fps = 0.0
        self._video_count = 0
        self._video_window = time.time()

    # ---- sending
    def _packet(self, ptype: int, payload: bytes = b"") -> bytes:
        with self.lock:
            self.seq = (self.seq + 1) & 0xFFFF
            seq = self.seq
            flags = FLAG_KILL if self.kill_latched else 0
        body = HEADER.pack(MAGIC, VERSION, ptype, SRC_LAPTOP, flags, seq) + payload
        return body + struct.pack("<H", crc16(body)), seq

    def send(self, ptype: int, payload: bytes = b"") -> int:
        pkt, seq = self._packet(ptype, payload)
        try:
            self.sock.sendto(pkt, DRONE_ADDR)
        except OSError:
            pass  # not connected to the drone WiFi yet
        return seq

    def command(self, name: str, arg: int = 0):
        cmd = CMD[name]
        seq = self.send(PKT_COMMAND, struct.pack("<BB", cmd, arg))
        with self.lock:
            self.pending[seq] = (cmd, arg, time.time(), 1)

    def kill(self):
        with self.lock:
            self.kill_latched = True
        for _ in range(3):  # belt and braces; every heartbeat also carries the kill flag
            self.command("kill")

    def clear_kill(self):
        with self.lock:
            self.kill_latched = False
        self.command("disarm")

    def browser_alive(self) -> bool:
        return time.time() - self.browser_last < BROWSER_TIMEOUT_S

    # ---- threads
    def heartbeat_loop(self):
        period = 1.0 / HEARTBEAT_HZ
        nxt = time.perf_counter()
        while True:
            nxt += period
            # While killed we keep sending (with the kill flag) no matter what.
            if self.browser_alive() or self.kill_latched:
                self.send(PKT_HEARTBEAT)
            self._retry_commands()
            delay = nxt - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            else:
                nxt = time.perf_counter()

    def _retry_commands(self):
        now = time.time()
        resend = []
        with self.lock:
            for seq, (cmd, arg, t0, tries) in list(self.pending.items()):
                if now - t0 > 0.06 * tries:
                    del self.pending[seq]
                    if tries < 3:
                        resend.append((cmd, arg, t0, tries + 1))
        for cmd, arg, t0, tries in resend:
            seq = self.send(PKT_COMMAND, struct.pack("<BB", cmd, arg))
            with self.lock:
                self.pending[seq] = (cmd, arg, t0, tries)

    def receive_loop(self):
        while True:
            try:
                data, _ = self.sock.recvfrom(512)
            except socket.timeout:
                continue
            except OSError:
                time.sleep(0.2)
                continue
            if len(data) < 10:
                continue
            if crc16(data[:-2]) != struct.unpack_from("<H", data, len(data) - 2)[0]:
                continue
            magic, ver, ptype, src, flags, seq = HEADER.unpack_from(data, 0)
            if magic != MAGIC or ver != VERSION:
                continue
            payload = data[HEADER.size:-2]
            if ptype == PKT_TELEMETRY and len(payload) == TELEM.size:
                self._on_telemetry(payload)
            elif ptype == PKT_CMD_ACK and len(payload) == ACK.size:
                cmd, result, aseq = ACK.unpack(payload)
                with self.lock:
                    self.pending = {s: p for s, p in self.pending.items() if p[0] != cmd}
                    self.acks.append({"t": time.time(), "cmd": CMD_NAMES.get(cmd, str(cmd)), "result": result})
                    self.acks = self.acks[-8:]

    def _on_telemetry(self, payload: bytes):
        v = TELEM.unpack(payload)
        t = {
            "state": v[0], "sflags": v[1], "arm_block_manual": v[2] & 0x0F, "arm_block_follow": v[2] >> 4,
            "last_event": v[3],
            "roll": v[4] / 100.0, "pitch": v[5] / 100.0, "yaw": v[6] / 100.0,
            "vbat": v[7] / 1000.0, "throttle": v[8] / 10.0, "hover": v[9] / 10.0,
            "motors": [m / 10.0 for m in v[10:14]],
            "loop_hz": v[14], "loop_max_us": v[15], "loop_jitter_us": v[16],
            "link_rate": list(v[17:20]), "link_loss": list(v[20:23]), "link_age": list(v[23:26]),
            "follow_left": v[26] / 10.0, "countdown": v[27] / 10.0, "height": v[28] / 100.0,
            "laptop_ip": ".".join(str(b) for b in v[29]), "uptime": v[30] / 1000.0,
        }
        with self.lock:
            self.telem = t
            self.telem_time = time.time()

    def video_loop(self):
        partial = {}
        while True:
            try:
                data, _ = self.video_sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                time.sleep(0.2)
                continue
            if len(data) <= VIDEO_HDR.size:
                continue
            magic, fid, idx, count, bx, by, bw, bh, vflags, _ = VIDEO_HDR.unpack_from(data, 0)
            if magic != VIDEO_MAGIC or count == 0 or idx >= count:
                continue
            if fid != self.frame_id and ((fid - self.frame_id) & 0xFFFF) > 0x8000 and self.frame_id >= 0:
                continue  # older than what we already showed
            entry = partial.setdefault(fid, [None] * count)
            if len(entry) != count:
                continue
            entry[idx] = data[VIDEO_HDR.size:]
            if all(c is not None for c in entry):
                jpeg = b"".join(entry)
                partial = {k: e for k, e in partial.items() if ((k - fid) & 0xFFFF) < 0x8000 and k != fid}
                with self.frame_cond:
                    self.frame_jpeg = jpeg
                    self.frame_id = fid
                    self.frame_time = time.time()
                    self.frame_box = [bx / 10000.0, by / 10000.0, bw / 10000.0, bh / 10000.0] if bw else None
                    self.frame_tracking = bool(vflags & 1)
                    self.frame_cond.notify_all()
                self._video_count += 1
            if len(partial) > 6:  # drop stale incomplete frames
                for k in sorted(partial)[:-3]:
                    partial.pop(k, None)
            now = time.time()
            if now - self._video_window >= 1.0:
                self.video_fps = self._video_count / (now - self._video_window)
                self._video_count = 0
                self._video_window = now

    def state_json(self) -> dict:
        with self.lock:
            age = time.time() - self.telem_time if self.telem_time else None
            return {
                "telem": self.telem,
                "telem_age": age,
                "kill_latched": self.kill_latched,
                "browser_alive": self.browser_alive(),
                "acks": self.acks,
                "video": {
                    "fps": round(self.video_fps, 1),
                    "age": (time.time() - self.frame_time) if self.frame_time else None,
                    "box": self.frame_box,
                    "tracking": self.frame_tracking,
                },
            }


STATION = None


# --------------------------------------------------------------------------- HTTP
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # keep the console quiet

    def _send(self, code, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(os.path.join(WEB_DIR, "index.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/state":
            self._send(200, json.dumps(STATION.state_json()).encode())
        elif self.path.startswith("/video.mjpg"):
            self._stream_video()
        else:
            self._send(404, b"{}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        if self.path == "/hb":
            STATION.browser_last = time.time()
            self._send(200, b"{}")
            return
        if self.path == "/cmd":
            try:
                req = json.loads(raw or b"{}")
            except ValueError:
                self._send(400, b"{}")
                return
            name = req.get("cmd", "")
            if name == "kill":
                STATION.kill()
            elif name == "clear_kill":
                STATION.clear_kill()
            elif name in CMD and name not in ("arm", "esc_cal_high", "esc_cal_low"):
                STATION.command(name, int(req.get("arg", 0)))
            else:
                self._send(400, b'{"error":"unknown command"}')
                return
            self._send(200, b"{}")
            return
        self._send(404, b"{}")

    def _stream_video(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        last = None
        try:
            while True:
                with STATION.frame_cond:
                    STATION.frame_cond.wait_for(lambda: STATION.frame_id != last, timeout=1.0)
                    if STATION.frame_jpeg is None or STATION.frame_id == last:
                        continue
                    jpeg, last = STATION.frame_jpeg, STATION.frame_id
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(jpeg))
                self.wfile.write(jpeg)
                self.wfile.write(b"\r\n")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    global STATION
    try:
        STATION = Station()
    except OSError as e:
        print(f"Could not open UDP ports {LOCAL_CTRL_PORT}/{VIDEO_PORT}: {e}")
        print("Is another copy of the ground station already running?")
        sys.exit(1)

    for target in (STATION.heartbeat_loop, STATION.receive_loop, STATION.video_loop):
        threading.Thread(target=target, daemon=True).start()

    server = Server(("127.0.0.1", HTTP_PORT), Handler)
    url = f"http://127.0.0.1:{HTTP_PORT}/"
    print("DroneBoyfriendTracker ground station")
    print(f"  UI:     {url}")
    print(f"  Drone:  {DRONE_ADDR[0]}:{DRONE_ADDR[1]}  (join the 'DroneBoyfriendTracker' WiFi first)")
    print("  KILL:   Space or K in the browser page.  Ctrl+C here to quit.")
    print("  Keep the page open: closing it stops the heartbeat and the drone lands.")
    if "--no-browser" not in sys.argv:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
