# Laptop ground station (Windows): kill switch, land, follow start, video

## Setup (once)
1. Install **Python 3** from python.org. Tick **"Add python.exe to PATH"** in the installer.
   - Nothing else to install: the program only uses Python's standard library.
2. Get the repo (Code → Download ZIP) and unzip it.

## Every session
1. Power the drone. Join the **PinkDrone** WiFi on the laptop (same password as `secrets.h`).
   - Windows will say "No internet". That's expected.
   - The laptop has no internet over WiFi while connected.
2. Open a terminal in the repo folder and run:
   ```
   py laptop\ground_station.py
   ```
3. The first time, Windows Firewall asks about Python. Allow it on **Private networks**, otherwise no telemetry or video arrives.
   - If you clicked it away: **Windows Security → Firewall → Allow an app through firewall → python.exe → tick Private**.
4. A pink page opens at `http://127.0.0.1:8765`. Check:
   - "drone connected"
   - "kill switch active"
   - the state reads DISARMED and the control loop reads ~1000 Hz

## Controls
| Control | What it does |
|---|---|
| **KILL** button, **Space** or **K** | Motors off immediately. Latched: every packet keeps the kill flag until you press **Clear kill**. |
| **LAND** | Controlled descent and disarm. |
| **DISARM** | Motors off (not latched). |
| **START FOLLOW** | Click twice (confirm). The drone phone counts down 3 s, then takes off. |
| **Video** | Turns the drone phone's camera stream on or off. |

## Important behaviour
- **The drone can't arm unless this page is open.** If the page closes, the browser freezes or the laptop sleeps, the heartbeat stops and the drone **lands** after 0.5 s.
  - A Web Worker keeps the heartbeat going even when the tab is in the background.
  - Still, keep the page in its own window and keep it visible.
- Before flying, set Windows power options to **never sleep** while plugged in. In Device Manager → your WiFi adapter → Advanced/Power, set power saving to **Maximum Performance** to avoid latency spikes.
- The table at the bottom shows packet loss and timing for each device. If loss stays above about 1 % while sitting next to the drone, there's interference: try another `WIFI_CHANNEL` in `config.h` (1, 6 or 11).
