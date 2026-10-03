# Uploading the ESP32 firmware (Arduino IDE, Windows)

**Why Arduino IDE:** you asked for it, and this firmware needs **no extra libraries**. I wrote the MPU6500 driver myself. The only install is the ESP32 board package. Everything else (WiFi, UDP, flash storage, PWM) comes with it.

## One-time setup

1. Install **Arduino IDE 2** from arduino.cc.
2. **File → Preferences → Additional boards manager URLs**, add:
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
3. **Tools → Board → Boards Manager**, search **esp32** and install **"esp32 by Espressif Systems"** (version 3.x).
4. USB driver. Look at the small chip next to the USB port on your board:
   - `CP2102` → install the "CP210x Universal Windows Driver" from Silicon Labs.
   - `CH340` → install the CH340 driver from wch-ic.com.

## Every upload

1. Get the code: on GitHub, **Code → Download ZIP**, unzip.
2. In `firmware/DroneFC/`, copy `secrets_template.h` to **`secrets.h`** and set `WIFI_PASSWORD` to your password.
   - It must be the same password you put in the GitHub secret `DRONE_WIFI_PASSWORD`.
   - Arduino needs the folder name to match the `.ino` name, so keep the `DroneFC` folder as it is.
3. Open `firmware/DroneFC/DroneFC.ino`. All the other files open as tabs.
4. **Tools** menu:
   - Board: **ESP32 Dev Module**
   - Upload Speed: 921600
   - CPU Frequency: 240 MHz
   - Flash Size: 4 MB
   - Partition Scheme: Default
   - Port: the COM port that appears when you plug the board in
5. Unplug the step-down's 5 V wire from the ESP32 (see WIRING.md), then connect USB.
6. Click **Upload** (→).
   - If it hangs at `Connecting.....___`, hold the board's **BOOT** button until it starts writing.
7. Open **Tools → Serial Monitor** at **115200** baud and press the board's EN/RST button. You should see:
   ```
   [boot] PinkDrone FC
   [boot] MPU WHO_AM_I = 0x70 -> OK
   [link] AP "PinkDrone" on channel 6, 192.168.4.1:4210
   [boot] keep the drone still: calibrating gyro (LED blinks fast)
   ```
   - `0x71`, `0x73`, `0x74` or `0x75` are also fine (relabelled chips).
   - `NOT FOUND` means you should check the IMU wiring. The board then starts in **bench mode**: the app connects and motor test / ESC calibration work (props off), but arming is refused. The LED shows the normal "disarmed" flash.

## LED

| Pattern | Meaning |
|---|---|
| fast blink | calibrating the gyro: keep the drone still |
| short flash every second | disarmed, ready |
| solid | armed (motors live) |
| very fast flicker | killed or IMU fault |
| slow blink | follow countdown |

## Settings you might change (`config.h`)

| Setting | Default | When to change |
|---|---|---|
| `ESC_PWM_HZ` | 400 | ESCs stutter, beep oddly or won't arm: try 250, then 50 |
| `ESC_PWM_MIN_US` / `MAX_US` | 1000 / 2000 | only if your ESCs use different end points |
| `IMU_GYRO_DLPF_CFG` | 2 (92 Hz) | 1 if tuning shows the gyro filter delay is the limit |
| `IMU_ROTATION_DEG`, `IMU_UPSIDE_DOWN` | 0, 0 | IMU mounted another way |
| `WIFI_CHANNEL` | 6 | lots of 2.4 GHz WiFi nearby on channel 6 |
| `VIDEO_DEFAULT_ON` | 0 | after the bench test shows video doesn't hurt the link |

Everything else (gains, limits, failsafe timings, battery thresholds, follow timer) is set **from the app's Tune screen** without reflashing.
