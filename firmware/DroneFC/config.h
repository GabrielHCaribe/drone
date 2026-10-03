// =============================================================================
//  config.h  -  compile-time hardware configuration for the DroneBoyfriendTracker FC
//
//  Board : ESP32-WROOM-32 on a 38-pin DevKitC ("ESP32 Dev Module" in Arduino IDE)
//  IMU   : MPU6500 breakout wired for SPI
//  ESCs  : generic 30A SimonK/BLHeli-style, standard 1000-2000 us PWM
//
//  Pin choice rules (WROOM-32):
//    - GPIO 6..11 are wired to the SPI flash          -> never used
//    - GPIO 0, 2, 5, 12, 15 are boot strapping pins   -> nothing external pulls them
//      (GPIO 2 only drives the on-board LED, which is fine after boot)
//    - GPIO 34..39 are input-only                     -> used for INT and the ADC
//    - ADC2 pins stop working while WiFi is on        -> battery uses ADC1 (GPIO 35)
// =============================================================================
#pragma once

// ---------------------------------------------------------------- motors / ESC
// Motor numbering follows Betaflight "Quad X" (top view, front at the top):
//
//            FRONT
//    M4 (CW)  o     o  M2 (CCW)
//               [FC]
//    M3 (CCW) o     o  M1 (CW)
//            REAR
//
// "Props-in": the front props sweep toward the centre line.
#define PIN_MOTOR1 25  // rear-right,  CW
#define PIN_MOTOR2 26  // front-right, CCW
#define PIN_MOTOR3 32  // rear-left,   CCW
#define PIN_MOTOR4 33  // front-left,  CW

// Standard ESC PWM. 400 Hz suits SimonK and BLHeli. If your ESCs stutter or
// refuse to arm at 400 Hz, try 250, then 50 (any cheap ESC accepts 50 Hz).
#define ESC_PWM_HZ 400
#define ESC_PWM_MIN_US 1000  // motor stopped / ESC throttle low
#define ESC_PWM_MAX_US 2000  // full throttle
#define ESC_PWM_BITS 16

// ---------------------------------------------------------------- MPU6500 (SPI)
// Breakout label -> function in SPI mode:
//   SCL = SCLK, SDA = MOSI (SDI), AD0 = MISO (SDO), NCS = chip select
#define PIN_IMU_SCLK 18
#define PIN_IMU_MOSI 23
#define PIN_IMU_MISO 19
#define PIN_IMU_CS 27
#define PIN_IMU_INT 34  // data-ready interrupt (input-only pin is fine)

#define IMU_SPI_SLOW_HZ 1000000  // register writes (datasheet limit 1 MHz)
#define IMU_SPI_FAST_HZ 4000000  // sensor reads (chip allows 20 MHz; 4 MHz is robust on a vibrating frame)

// Gyro low-pass in the chip. 2 = 92 Hz bandwidth / 3.9 ms delay (default).
// 1 = 184 Hz / 2.9 ms (less delay, more motor noise). 3 = 41 Hz / 5.9 ms.
#define IMU_GYRO_DLPF_CFG 2
#define IMU_ACCEL_DLPF_CFG 3  // 41 Hz accel bandwidth

// IMU mounting. Recommended: board flat, components facing UP, the printed
// X arrow pointing to the FRONT of the drone -> leave both at 0.
// IMU_ROTATION_DEG: how far the X arrow is turned CLOCKWISE (seen from above)
// away from the front. Allowed: 0, 90, 180, 270.
#define IMU_ROTATION_DEG 0
// Set to 1 if the board is mounted upside down (components facing DOWN).
#define IMU_UPSIDE_DOWN 0

// ---------------------------------------------------------------- misc pins
#define PIN_BATTERY_ADC 35  // via 47k (to battery +) / 10k (to GND) divider
#define PIN_STATUS_LED 2    // on-board blue LED of the DevKitC

// ---------------------------------------------------------------- loop / tasks
#define CONTROL_LOOP_HZ 1000        // set by the IMU sample rate (data-ready interrupt)
#define CONTROL_TASK_CORE 1         // flight control, nothing else
#define LINK_TASK_CORE 0            // WiFi / UDP / battery / housekeeping
#define CONTROL_TASK_PRIORITY 24    // highest app priority
#define LINK_TASK_PRIORITY 5

// ---------------------------------------------------------------- network
// SSID is not secret; the password lives in secrets.h (git-ignored).
#define WIFI_SSID "DroneBoyfriendTracker"
#define WIFI_CHANNEL 6
#define WIFI_MAX_CLIENTS 4
#define UDP_PORT 4210
#define TELEMETRY_HZ 20

// Video from the drone iPhone to the laptop starts disabled after every boot.
// Turn it on from the laptop page once the bench test shows no effect on
// control-link quality (see docs/TESTING.md).
#define VIDEO_DEFAULT_ON 0
