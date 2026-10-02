#include "attitude.h"
#include <math.h>

static const float DEG2RAD = 0.01745329252f;
static const float RAD2DEG = 57.2957795131f;
static const float GRAVITY = 9.80665f;

void Ahrs::reset_from_accel(const ImuSample& s) {
  float roll = atan2f(s.ay, s.az);
  float norm = sqrtf(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
  float pitch_flu = (norm > 0.1f) ? asinf(fmaxf(-1.0f, fminf(1.0f, -s.ax / norm))) : 0.0f;
  float cr = cosf(roll * 0.5f), sr = sinf(roll * 0.5f);
  float cp = cosf(pitch_flu * 0.5f), sp = sinf(pitch_flu * 0.5f);
  q0_ = cr * cp;
  q1_ = sr * cp;
  q2_ = cr * sp;
  q3_ = -sr * sp;
  yaw_unwrapped_ = 0;
  yaw_prev_ = 0;
}

void Ahrs::update(const ImuSample& s, float dt, float kp) {
  float gx = s.gx * DEG2RAD, gy = s.gy * DEG2RAD, gz = s.gz * DEG2RAD;

  // Estimated "up" direction in the body frame.
  float vx = 2.0f * (q1_ * q3_ - q0_ * q2_);
  float vy = 2.0f * (q0_ * q1_ + q2_ * q3_);
  float vz = q0_ * q0_ - q1_ * q1_ - q2_ * q2_ + q3_ * q3_;

  float an = sqrtf(s.ax * s.ax + s.ay * s.ay + s.az * s.az);
  // Only trust the accelerometer when it measures roughly 1 g (not during
  // hard manoeuvres or impacts). Fades the correction out between 0.15 and 0.3 g error.
  float err_g = fabsf(an - 1.0f);
  float trust = err_g < 0.15f ? 1.0f : (err_g > 0.30f ? 0.0f : (0.30f - err_g) / 0.15f);
  if (an > 0.1f && trust > 0.0f) {
    float ax = s.ax / an, ay = s.ay / an, az = s.az / an;
    float ex = ay * vz - az * vy;
    float ey = az * vx - ax * vz;
    float ez = ax * vy - ay * vx;
    float k = kp * trust;
    gx += k * ex;
    gy += k * ey;
    gz += k * ez;
  }

  float hdt = 0.5f * dt;
  float qa = q0_, qb = q1_, qc = q2_;
  q0_ += (-qb * gx - qc * gy - q3_ * gz) * hdt;
  q1_ += (qa * gx + qc * gz - q3_ * gy) * hdt;
  q2_ += (qa * gy - qb * gz + q3_ * gx) * hdt;
  q3_ += (qa * gz + qb * gy - qc * gx) * hdt;
  float n = 1.0f / sqrtf(q0_ * q0_ + q1_ * q1_ + q2_ * q2_ + q3_ * q3_);
  q0_ *= n; q1_ *= n; q2_ *= n; q3_ *= n;

  // Euler angles (ZYX), converted from FLU to the aircraft convention.
  float roll = atan2f(2.0f * (q0_ * q1_ + q2_ * q3_), 1.0f - 2.0f * (q1_ * q1_ + q2_ * q2_));
  float sp = 2.0f * (q0_ * q2_ - q3_ * q1_);
  sp = fmaxf(-1.0f, fminf(1.0f, sp));
  float pitch_flu = asinf(sp);
  float yaw_flu = atan2f(2.0f * (q0_ * q3_ + q1_ * q2_), 1.0f - 2.0f * (q2_ * q2_ + q3_ * q3_));

  float yaw = -yaw_flu * RAD2DEG;
  float dy = yaw - yaw_prev_;
  if (dy > 180.0f) dy -= 360.0f;
  if (dy < -180.0f) dy += 360.0f;
  yaw_unwrapped_ += dy;
  yaw_prev_ = yaw;

  vx = 2.0f * (q1_ * q3_ - q0_ * q2_);
  vy = 2.0f * (q0_ * q1_ + q2_ * q3_);
  vz = q0_ * q0_ - q1_ * q1_ - q2_ * q2_ + q3_ * q3_;

  att_.roll = roll * RAD2DEG;
  att_.pitch = -pitch_flu * RAD2DEG;
  att_.yaw = yaw_unwrapped_;
  att_.p = s.gx;
  att_.q = -s.gy;
  att_.r = -s.gz;
  att_.az_up = ((s.ax * vx + s.ay * vy + s.az * vz) - 1.0f) * GRAVITY;
  att_.cos_tilt = vz;
}
