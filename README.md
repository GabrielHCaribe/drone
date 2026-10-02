# PinkDrone ♥

A follow-me quadcopter built from:
- an **ESP32** running the flight controller
- an **iPhone 13** mounted on the drone, which does the computer vision
- a **Windows laptop** acting as the kill switch

## Hardware
- ESP32-WROOM-32 (38-pin DevKitC)
- MPU6500 IMU (SPI)
- 4 × A2212 1000 kV motors with 1045 props, 4 × generic 30 A ESCs (standard PWM)
- 3S battery
- 450 mm X frame

## Repository layout
```
firmware/DroneFC/   ESP32 flight controller (Arduino IDE sketch, no extra libraries)
ios/                iPhone app (SwiftUI). Built in the cloud by GitHub Actions -> TestFlight
laptop/             Ground station: python ground_station.py (kill switch, land, follow, video)
docs/               Wiring, uploading, iOS build, protocol, testing order, tuning
.github/workflows/  CI: firmware compile, iOS compile + TestFlight upload
```

## How the pieces fit

```
             WiFi access point "PinkDrone" (hosted by the ESP32, 192.168.4.1, UDP 4210)
   ┌────────────────────────────┬───────────────────────────────┬──────────────────────────┐
   │ Laptop (ground station)    │ iPhone - Remote role          │ iPhone - Drone role      │
   │ heartbeat 50 Hz            │ (in your hand)                │ (mounted on the drone)   │
   │ KILL / LAND / START FOLLOW │ pink sticks 50 Hz, ARM, tune, │ camera + Vision + height │
   │ telemetry, video           │ motor test                    │ filter -> follow setpoints│
   └─────────────┬──────────────┴───────────────┬───────────────┴────────────┬─────────────┘
                 └───────────────────────── ESP32 ───────────────────────────┘
       core 0: WiFi + UDP + telemetry + battery      core 1: 1 kHz control loop (nothing else)
```

**Where the loops run, and why**

| Loop | Runs on | Rate | Why |
|---|---|---|---|
| Gyro rate PID + feedforward → mixer → ESCs | ESP32 core 1 | 1 kHz (IMU interrupt) | Needs sub-millisecond, jitter-free timing. WiFi lives on the other core. |
| Angle loop + angle feedforward, attitude filter | ESP32 core 1 | 1 kHz | Same |
| Arming, failsafe, landing, 45 s follow timer, low battery, crash, kill | ESP32 | 1 kHz | Must work even if every phone and laptop disappears |
| Person tracking, distance & height estimation, follow outer loops | iPhone (Drone role) | 30–100 Hz | Only the phone has the camera and barometer. These loops are slow (1–2 Hz bandwidth), so WiFi delay doesn't matter. |

**Authority**
- The **laptop must be connected** to arm. If it disappears (page closed, laptop asleep), the drone **lands**.
- **Manual flight** comes from the phone in **Remote** role. **Follow** setpoints come from the phone in **Drone** role and are only accepted in Follow mode.
- **Kill** from any device is always obeyed, stays latched until Disarm, and works inside any packet type.
- **Lost link** (0.5 s without packets): hover level for 1 s, then descend and disarm. If the drone is still on the ground, it just disarms.

## Getting started
1. Wire it: [docs/WIRING.md](docs/WIRING.md)
2. Flash the ESP32: [docs/ESP32_UPLOAD.md](docs/ESP32_UPLOAD.md)
3. Get the app on the iPhone without a Mac: [docs/IOS_BUILD.md](docs/IOS_BUILD.md)
4. Run the laptop kill switch: [docs/LAPTOP.md](docs/LAPTOP.md)
5. Test in order, props off first: [docs/TESTING.md](docs/TESTING.md)
6. Tune: [docs/TUNING.md](docs/TUNING.md)

Protocol reference: [docs/PROTOCOL.md](docs/PROTOCOL.md)

## Safety
- Props off for everything up to the tethered hover.
- Fly in open spaces, low, and away from people.
- The laptop page is your kill switch: Space or K.
- Every automatic mode lands by itself: follow timer, lost target, lost link, low battery.
