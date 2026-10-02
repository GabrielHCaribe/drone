// =============================================================================
//  attitude.h  -  Mahony complementary filter (gyro + accelerometer, no magnetometer)
//
//  Runs in the IMU's FLU frame and reports angles in the usual aircraft
//  convention used everywhere else in this project:
//    roll  + = right side down     p + = rolling right
//    pitch + = nose up             q + = pitching nose up
//    yaw   + = nose right          r + = yawing right
//  Yaw comes from the gyro only. It drifts a few degrees per minute, which is
//  fine for heading hold during a 45 s follow flight.
// =============================================================================
#pragma once
#include "imu.h"

struct Attitude {
  float roll, pitch, yaw;  // deg (yaw is unbounded / continuous)
  float p, q, r;           // deg/s
  float az_up;             // vertical acceleration in the world frame, m/s^2, gravity removed
  float cos_tilt;          // cos(roll) * cos(pitch)
};

class Ahrs {
 public:
  void reset_from_accel(const ImuSample& s);
  void update(const ImuSample& s, float dt, float kp);
  const Attitude& att() const { return att_; }

 private:
  float q0_ = 1, q1_ = 0, q2_ = 0, q3_ = 0;
  float yaw_unwrapped_ = 0, yaw_prev_ = 0;
  Attitude att_ = {};
};
