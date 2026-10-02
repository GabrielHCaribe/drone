// =============================================================================
//  imu.h  -  MPU6500 over SPI, 1 kHz, data-ready interrupt
//  Output is in the drone body frame, FLU convention (x forward, y left, z up),
//  after applying IMU_ROTATION_DEG / IMU_UPSIDE_DOWN from config.h.
// =============================================================================
#pragma once
#include <stdint.h>

struct ImuSample {
  float gx, gy, gz;  // deg/s  (rotation about forward / left / up axes)
  float ax, ay, az;  // g      (specific force: reads +1 on z when level and still)
};

bool imu_init();                 // false if the chip did not answer correctly
uint8_t imu_whoami();            // last WHO_AM_I value read (0x70 for a genuine MPU6500)
bool imu_read(ImuSample& out);   // one burst read of accel + gyro (~30 us at 4 MHz)
