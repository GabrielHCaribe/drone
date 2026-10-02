# UDP protocol

- **Transport:** UDP to `192.168.4.1:4210`. The ESP32 replies to the address and port each packet came from.
- **No broadcast or multicast:** so no multicast entitlement is needed on iOS.
- **Byte order:** little-endian.
- **Sources of truth:** `firmware/DroneFC/protocol.h`, `ios/PinkDrone/Link/Protocol.swift` and `laptop/ground_station.py`.

```
[Header 8][payload N][CRC16 2]
Header: magic u16 = 0x4450 ('P','D') | version u8 = 1 | type u8 | source u8 | flags u8 | seq u16
CRC   : CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over header + payload
flags : bit0 KILL - sender's kill switch is latched; the ESP32 stops the motors on ANY packet with it set
source: 0 ESP32, 1 laptop, 2 phone (Remote role), 3 phone (Drone role)
seq   : per sender; the ESP32 drops duplicates/out-of-order packets and counts gaps as loss
```

## Rates
| Sender | Packet | Rate |
|---|---|---|
| Laptop | HEARTBEAT | 50 Hz (only while the browser page is alive) |
| Phone, Remote role | RC | 50 Hz |
| Phone, Drone role | FOLLOW | 50 Hz (phone outer loops run at 30–100 Hz) |
| ESP32 | TELEMETRY | 20 Hz to every client heard from in the last 3 s |
| any | COMMAND | on demand, resent up to 3× (60 ms apart) until acknowledged |

## Client → ESP32
| Type | Name | Payload |
|---|---|---|
| 0x01 | HEARTBEAT | – |
| 0x02 | RC | `i16 roll, i16 pitch, i16 yaw` (−1000..1000; pitch + = stick forward), `u16 throttle` (0..1000) |
| 0x03 | FOLLOW | `i16 roll_cdeg, i16 pitch_cdeg` (+ = nose up), `i16 yaw_rate_ddps` (0 = hold heading), `u16 throttle` 0..1000, `i16 height_cm, i16 vz_cms, u8 phase, u8 flags` (ready, tracking, height_valid, active) |
| 0x04 | MOTOR_TEST | `u16 motor[4]` 0..1000 (capped at 150) |
| 0x10 | COMMAND | `u8 cmd, u8 arg` |
| 0x11 | PARAM_GET | – (reply: one PARAM_INFO per parameter) |
| 0x12 | PARAM_SET | `u8 id, f32 value` (reply: PARAM_INFO) |

Commands:
1. ARM (Remote phone only)
2. DISARM (also clears a kill)
3. LAND (arg = reason: 1 command, 7 target lost)
4. START_FOLLOW (laptop or Drone phone)
5. CANCEL_FOLLOW
6. CAL_GYRO
7. CAL_LEVEL
8. PARAM_SAVE (disarmed only)
9. PARAM_RESET
10. ESC_CAL_HIGH
11. ESC_CAL_LOW
12. ESC_CAL_EXIT
13. VIDEO_ON
14. VIDEO_OFF
15. KILL

## ESP32 → client
| Type | Name | Payload |
|---|---|---|
| 0x80 | TELEMETRY | 56 bytes, see `TelemetryPayload` |
| 0x81 | CMD_ACK | `u8 cmd, u8 result, u16 seq` |
| 0x82 | PARAM_INFO | `u8 id, u8 count, f32 value, f32 min, f32 max, char name[24]` |

TELEMETRY fields:
- `state`
- `flags`: armed, kill, imu_ok, gyro_cal, batt_warn, batt_present, video_on, params_dirty
- `arm_block`: low nibble = manual-arm check, high nibble = follow-start check
- `last_event`
- roll / pitch / yaw (centi-degrees)
- battery mV
- collective and hover throttle
- 4 motor outputs
- loop Hz, worst execution µs, worst jitter µs
- per client (laptop, remote, drone): packets/s, loss %, age in ms
- follow time left, countdown
- drone phone height (cm)
- laptop IPv4 (so the drone phone can stream video straight to it)
- uptime

## Video (drone phone → laptop, UDP port 4211)
- Header: `u16 0x5650, u16 frame_id, u8 chunk, u8 chunks, u16 box x,y,w,h (×10000, top-left origin), u8 flags (bit0 tracking), u8 0`.
- Then up to 1200 bytes of a JPEG frame.
- Frames are 640×480 at 10 fps, sent only while the laptop has video switched on.
- Video goes phone → ESP32 access point → laptop, using a lower-priority WiFi queue (video) than control packets (voice). [Guessing] how much that protects control traffic on the ESP32 access point; the bench test in TESTING.md step 9 measures it.
