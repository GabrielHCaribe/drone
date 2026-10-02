// =============================================================================
//  PinkDrone flight controller  -  ESP32-WROOM-32 (38-pin DevKitC)
//
//  Arduino IDE: Tools > Board > "ESP32 Dev Module". Full instructions are in
//  docs/ESP32_UPLOAD.md.
//
//  Task layout:
//    core 1  "control"  1 kHz, woken by the MPU6500 data-ready interrupt:
//                       IMU -> attitude -> angle/rate PID + FF -> mixer -> ESCs,
//                       arming, failsafe, landing, follow timer   (flight.cpp)
//    core 0  "link"     WiFi access point, UDP protocol, telemetry, battery,
//                       flash writes                               (link.cpp)
//  The Arduino loop() task is deleted after setup().
// =============================================================================
#include <Arduino.h>
#include "config.h"
#include "flight.h"
#include "imu.h"
#include "link.h"
#include "motors.h"
#include "params.h"
#include "shared.h"

void setup() {
  // ESC outputs first: the ESCs must see a "throttle low" pulse right away.
  motors_init();

  Serial.begin(115200);
  delay(200);
  Serial.println();
  Serial.println("[boot] PinkDrone FC");

  params_init();
  shared_init();

  bool imu_ok = imu_init();
  Serial.printf("[boot] MPU WHO_AM_I = 0x%02X -> %s\n", imu_whoami(), imu_ok ? "OK" : "NOT FOUND / BAD CONFIG");
  if (!imu_ok) Serial.println("[boot] Check the IMU wiring (docs/WIRING.md). Motors stay disabled.");

  link_start();
  flight_start(imu_ok);
  Serial.println("[boot] keep the drone still: calibrating gyro (LED blinks fast)");
}

void loop() {
  vTaskDelete(nullptr);  // nothing runs here; all work happens in the two pinned tasks
}
