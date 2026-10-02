# Tuning guide (PID + feedforward)

Everything below is changed live from **Remote role → Tune** (+10 % / −10 % / ×1.5 / ÷1.5, or tap a value to type it). It works immediately. Press **Save to drone** (disarmed) to keep it after power-off.

## How the controller is built (ESP32, 1 kHz)

```
stick / follow setpoint (angle)
   │
   ├─► angle error × angle_p ───────────────┐
   └─► d(angle setpoint)/dt × angle_ff ──────┤──► rate setpoint (deg/s)
                                             │
rate setpoint ─► P·error + I·∫error − D·d(gyro)/dt + FF·d(rate setpoint)/dt ─► mixer ─► ESCs
```

- **P** (rate): the main stiffness.
- **I**: removes slow drift (centre of gravity off-centre, wind).
- **D**: damps overshoot. It acts on the gyro, so stick moves don't "kick" it.
- **FF** (rate): pushes immediately when the setpoint changes. Gives sharper response without raising P.
- **angle_p**: how hard it returns to level. **angle_ff**: passes the stick's motion straight to the rate loop.

## Starting values

The defaults were checked in simulation for a 450 frame with A2212/1045 on 3S. [Guessing] Your real frame will differ.

| | roll | pitch | yaw |
|---|---|---|---|
| rate P | 0.0007 | 0.0007 | 0.0025 |
| rate I | 0.0020 | 0.0020 | 0.0030 |
| rate D | 0.000012 | 0.000012 | – |
| rate FF | 0.000015 | 0.000015 | 0 |
| angle P | 5.0 | 5.0 | heading_p 3.0 |
| angle_ff | 0.8 | | |

## Procedure (tethered, dummy weight, low hover)

Change **one thing at a time** in 10 % steps. Do roll and pitch together if the frame is symmetric.

1. **Set I and FF to zero** for both roll and pitch, keeping a note of the values. Set `angle_ff` to 0.
2. **Rate P:**
   - Raise it until you see fast small oscillation (buzzing, 5–20 Hz wobble), then back off 30 %.
   - Sluggish, slow wobbling: P is too low.
3. **Rate D:**
   - Raise it to stop the overshoot when you give a sharp stick tap and let go.
   - Too much D shows as hot motors, a rough sound and high-pitched jitter. If D gets noisy, lower `dterm_lpf_hz` (40 → 30).
4. **Rate I:**
   - Restore it.
   - If it slowly drifts to one side and leans: raise I.
   - If it shows slow (~1 Hz) wallowing after moves: lower I.
5. **Rate FF:**
   - Restore it, then raise it until stick response feels immediate. Too much FF overshoots on stick moves only, not in hover.
6. **angle_p:**
   - Higher = snaps back to level harder.
   - Slow 1–2 Hz rocking in hover = too high.
   - Slow, floaty return = too low.
7. **angle_ff:** restore 0.8. Raise it toward 1.0 for crisper stick response; lower it if moves overshoot.
8. **Yaw:**
   - Raise `rate_yaw_p` if the heading wanders.
   - Raise `rate_yaw_i` if it slowly rotates on its own.
   - Yaw has little authority on a quad, so don't expect it to be snappy.
9. **Save to drone.**

## Symptom table

| Symptom | Most likely fix |
|---|---|
| Fast buzzing/wobble everywhere | rate P down, or rate D down |
| Overshoots and bounces back after a quick stick move | rate D up, or rate FF down |
| Feels slow/mushy, lags the stick | rate FF up, then rate P up |
| Leans and slowly drifts one way | Level cal, then rate I up; check centre of gravity |
| Slow wobble while hovering (1–2 Hz) | angle_p down, or rate I down |
| Wobbles only when descending (prop wash) | rate D up a little |
| Flips immediately at take-off | **stop**: motor order/direction or IMU orientation is wrong (TESTING.md step 8) |
| Motors hot after a short hover | D too high, or D filter too high → lower `dterm_lpf_hz` |
| Twitches when the phone/laptop link hiccups | normal stick steps; lower `ff_lpf_hz` (15 → 10) |

## Other parameters
| Name | Meaning |
|---|---|
| `hover_thr` | Learned automatically (shown in telemetry). Used by failsafe hover, landing and follow take-off. |
| `motor_idle` | Spin while armed. Raise it if a motor stalls or stutters at low throttle. |
| `liftoff_thr` | Above this throttle the I-terms and air-mode mixing turn on. |
| `land_speed_mps`, `land_vz_gain` | Descent speed in automatic landings, and how hard it holds it. |
| `land_impact_g` | Touchdown detection. If it disarms in the air: raise it. If it bounces on the ground: lower it. |
| `failsafe_hover_s`, `link_timeout_s` | Failsafe timing (defaults 1.0 s and 0.5 s). |
| `batt_warn_v`, `batt_land_v` | 10.5 V warning and 9.9 V auto-land (3S, sustained 3 s). |
| `follow_timeout_s` | Follow-mode safety timer (default 45 s). |
| `max_angle_manual` / `max_angle_follow` | Tilt limits (25° / 15°). |
| `gyro_lpf_hz` | Extra gyro filter (0 = off). Try 100–150 if motor noise is high. |

## Follow-mode (phone outer loop) gains
These live in `ios/PinkDrone/Follow/FollowConfig.swift`. Change them and rebuild.

| Gain | Effect |
|---|---|
| `heightKp/Ki/Kd` | Height hold. If it bobs up and down, lower Kp or raise Kd. If it sags as the battery drains, raise Ki. |
| `distanceKp/Kd` | How hard it closes the distance. If it surges back and forth, lower Kp or raise Kd. |
| `lateralKp/Kd` | Same, sideways. |
| `targetHeight`, `targetDistance` | 2.0 m / 4.0 m |
