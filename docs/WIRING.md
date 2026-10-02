# Wiring

Board: **ESP32-WROOM-32 on a 38-pin DevKitC** (Arduino board "ESP32 Dev Module").

## Pin table

| Function | ESP32 GPIO | Connects to | Notes |
|---|---|---|---|
| Motor 1 signal (rear-right, CW) | **25** | ESC 1 signal (white/yellow) | |
| Motor 2 signal (front-right, CCW) | **26** | ESC 2 signal | |
| Motor 3 signal (rear-left, CCW) | **32** | ESC 3 signal | |
| Motor 4 signal (front-left, CW) | **33** | ESC 4 signal | |
| ESC ground | **GND** | all 4 ESC signal grounds (black/brown) | required: common ground |
| MPU6500 SCL (= SPI clock) | **18** | MPU `SCL` | |
| MPU6500 SDA (= SPI data in) | **23** | MPU `SDA` | |
| MPU6500 AD0 (= SPI data out) | **19** | MPU `AD0` | |
| MPU6500 NCS (= chip select) | **27** | MPU `NCS` | |
| MPU6500 INT (data ready) | **34** | MPU `INT` | required: drives the 1 kHz loop |
| MPU6500 power | **3V3**, **GND** | MPU `VCC`, `GND` | |
| MPU6500 FSYNC | — | MPU `GND` | tie to ground if your board doesn't already |
| MPU6500 EDA, ECL | — | leave unconnected | |
| Battery voltage | **35** | middle of the divider below | ADC1 (ADC2 doesn't work with WiFi on) |
| Status LED | **2** | on-board blue LED | nothing to wire |
| Power | **5V** (VIN) + **GND** | 5 V output of your step-down converter | |

Why these pins:
- GPIO 6–11 are connected to the flash chip, so they're never used.
- GPIO 0, 2, 5, 12 and 15 are boot-mode "strapping" pins. Nothing external is connected to them (GPIO 2 only drives the on-board LED).
- GPIO 34–39 can only be inputs, which is fine for INT and the ADC.

## Battery divider (3S, max 12.6 V)

```
Battery + ──[ 47 kΩ ]──┬──[ 10 kΩ ]── GND
                       │
                    GPIO 35   (optional: 100 nF from GPIO 35 to GND)
```

A full 12.6 V reads 2.21 V at the pin, safely inside the ESP32 ADC range. To calibrate:
1. Measure the battery with a multimeter.
2. Compare it with the voltage shown in the app or on the laptop page.
3. Set `batt_scale = batt_scale × real / shown` on the Tune screen, then press Save.

If you skip the divider, the firmware sees less than 5 V, treats it as "no flight battery" and disables the low-battery landing.

## Power

```
3S battery ──┬──► 4 × ESC (power)
             └──► step-down 5 V ──► ESP32 5V/VIN + GND
```

- **Disconnect the red (5 V) wire of every ESC signal lead.** The ESP32 already gets 5 V from the step-down, and joining several ESC BECs together, or a BEC with the step-down, can damage them. Only signal and ground go to the ESP32.
- Never power the ESP32 from USB *and* the step-down at the same time. Many DevKits have no protection diode. During ESC calibration (docs/TESTING.md) and while uploading, unplug the step-down's 5 V wire from the ESP32.

## IMU mounting (I chose this; the firmware assumes it)

- **Flat**, components facing **up**, near the centre of the frame.
- The **X arrow printed on the board points to the FRONT** of the drone.
- Mount it on a piece of double-sided foam tape or a soft gel pad to reduce motor vibration.
- If you have to mount it differently, change `IMU_ROTATION_DEG` / `IMU_UPSIDE_DOWN` in `firmware/DroneFC/config.h`.

## Motors and props (Betaflight "Quad X", props-in)

```
            FRONT
   M4 (CW)  o     o  M2 (CCW)
              [FC]
   M3 (CCW) o     o  M1 (CW)
            REAR
```

- CW = clockwise seen from above. Fit CW props on M1/M4 and CCW props on M2/M3.
- Check each motor's direction in the props-off motor test. Swap any two of the three motor wires to reverse one.

## Phone mount

- Phone in **landscape**, screen facing the **front** of the drone (the front camera looks forward, toward you).
- Tilted about **15° downward**.
- Use a **soft or damped mount**. Vibration can damage the iPhone camera's stabilisation mechanism.
- During the tethered tests, use a ~175 g dummy weight in the same place.
