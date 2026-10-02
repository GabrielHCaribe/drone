# Testing order

Work through these in order and don't skip ahead. **Props stay OFF until step 9.** Each step lists what "pass" looks like.

Your kill switches:
- the laptop: KILL button, **Space** or **K**
- the phone: the big red KILL button

Kill is latched; reset it with **Disarm** / **Clear kill**.

---

## 1. Power-up and IMU detection (USB only, no flight battery)
- Upload as described in ESP32_UPLOAD.md and open the Serial Monitor at 115200.
- **Pass:** `WHO_AM_I = 0x70 -> OK`, and the LED goes from fast blink (gyro calibration) to a short flash every second.

## 2. Laptop link and loop timing
- Join PinkDrone WiFi, run `py laptop\ground_station.py`.
- **Pass:**
  - "drone connected" and "kill switch active"
  - state DISARMED
  - loop **1000 Hz**
  - worst execution under ~300 µs
  - jitter under ~100 µs

## 3. Phone link (Remote role)
- Install via TestFlight, open the app, choose **Remote**, accept the WiFi prompt.
- **Pass:** the top bar shows Drone (green), Kill switch (green) and the state.

## 4. IMU direction check (very important)
Hold the drone and watch the horizon on the phone and the numbers on the laptop.

| Move the drone | Expected |
|---|---|
| Right side down | **roll positive**, horizon tilts like a real one |
| Nose up | **pitch positive** |
| Turn nose to the right (from above, clockwise) | **yaw increases** |

- If any sign is wrong, fix `IMU_ROTATION_DEG` / `IMU_UPSIDE_DOWN` and re-upload.
- Then put the drone on a flat surface and press **Tune → Level cal**, then **Save to drone**.

## 5. Battery reading
- Connect the flight battery. Before plugging it in, unplug USB; never power from both at once.
- Compare the laptop's voltage with a multimeter and fix `batt_scale` (WIRING.md).

## 6. ESC calibration (props OFF)
1. Flight battery unplugged.
2. Step-down 5 V wire unplugged from the ESP32. Power the ESP32 from USB.
3. Phone in Remote role → **Motors** → tick "props removed" → **Max signal** → confirm.
4. Plug in the flight battery and wait for the ESC beeps.
5. Press **Min signal** and wait for the confirmation beeps.
6. Press **Finish**, unplug the battery and reconnect the step-down.

**Pass:** the ESCs beep their "calibrated" tune (it varies by ESC).

## 7. Motor test (props OFF)
- **Motors** screen → each slider at ~8 %.
- **Pass:**
  - The right motor spins at each position in the diagram (M1 rear-right, M2 front-right, M3 rear-left, M4 front-left).
  - Directions: M1 and M4 **clockwise**, M2 and M3 **counter-clockwise**. Hold a paper strip near the motor bell, or look at a piece of tape on it.
- Wrong direction → swap any two of that motor's three wires.
- Wrong position → swap signal wires.
- At the same slider value, all four should start and run smoothly.
- If they stutter at 400 Hz, set `ESC_PWM_HZ` to 250 or 50.

## 8. Arming, kill and failsafe checks (props OFF)

**Refusals.** Each of these must be refused, and the phone shows why:
- Arm with the laptop page closed → "Laptop kill switch not connected"
- Arm while tilted more than 10° → "Drone is not level"
- Arm with the throttle stick up → "Throttle not at the bottom"

**Stabilisation direction (the classic first-flight crash cause).**
1. Arm, raise throttle to ~20 % (below lift-off, so the I-terms stay off), and watch the motor % on the laptop while tilting the drone by hand:
   - Right side down → **M1 and M2 (right side) go UP**
   - Nose down → **M2 and M4 (front) go UP**
   - Twist the nose to the right → **M1 and M4 (CW) go UP**
2. If any of these is backwards, **stop**: it would flip on take-off. Recheck step 4 and the motor positions.

**Kill paths.** Arm, throttle ~20 %, and confirm each of these stops the motors immediately:
- laptop KILL
- Space key
- phone KILL
- closing the laptop page (failsafe → disarm, because it's not airborne)
- switching the phone's WiFi off

## 9. Video bench test (props OFF, drone phone in Drone role)
1. Leave everything running for 1 minute with video **off**. Note loss % and jitter on the laptop.
2. Switch video **on** for 1 minute and compare.
- **Pass:** loss stays under ~1 % and loop jitter doesn't change. If video makes it noticeably worse, leave it off. Control always comes first.

## 10. Tethered hover with the dummy weight (PROPS ON from here)
- Mount ~175 g where the phone goes.
- Tie the drone to something heavy (a toolbox, or a bucket of water) with 3–4 strings at the arms, with ~30–50 cm of slack. That lets it lift but stops it flying away.
- Phone in Remote role in your hand, laptop page open, stand 3 m or more away, and wear glasses.

Steps:
1. Arm and raise throttle slowly until it gets light, then just lifts against the tethers.
2. Watch for wobbling and tune with TUNING.md.
3. After a few hovers, `hover_thr` on the Tune screen will have learned your hover throttle. It's saved automatically on landing.
4. **Failsafe test while hovering low (tethered):**
   - close the laptop page → it should level, hover ~1 s, descend and disarm
   - repeat with the phone's WiFi off

## 11. Manual flight
Open area, no people, low (1–2 m), short flights. Land with the throttle, or press **Land**.

## 12. Follow-mode hand-held checks (props OFF)
Mount the phone and switch it to the **Drone** role. Keep the drone disarmed and walk around in front of it.

1. **Lock-on:** you get a pink box. Others get dashed lilac boxes.
2. **Distance:** stand exactly **3 m** away and use **More → Calibrate distance**. Then step to 5 m. **Pass:** it reads about 5 m.
3. **Sideways direction:** step to the **drone's right** (your left when you face it).
   - **Pass:** it reads "X° to drone's right".
   - If it says left, set `invertLateral = true` in `FollowConfig.swift` and rebuild.
4. **Height:** have someone hold the drone ~2 m up, pointed at you. **Pass:** "cam ≈2.0 m up".

## 13. First follow flight
- Wide open field, nobody else around. On the Tune screen set `follow_timeout_s` to **20** for the first tries.
- Put the drone down facing you from ~4 m. Press **Follow** on the phone, or **START FOLLOW** on the laptop, then stay where you are.

Sequence:
1. 3 s countdown
2. take-off to 2 m
3. lock-on
4. walk slowly forward, back and sideways: it should keep ~4 m and keep you centred
5. leave the frame: it hovers 3 s, searches 20 s, then lands
6. the timer lands it in any case

Your fingers stay on the laptop's Space bar. Increase `follow_timeout_s` toward 45 s once you trust it.
