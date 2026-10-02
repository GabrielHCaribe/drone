// =============================================================================
//  pid.h  -  filters and the rate PID with setpoint feedforward
//  Header-only, no allocation, everything inlined into the control loop.
// =============================================================================
#pragma once
#include <math.h>

// First-order low-pass. cutoff_hz <= 0 disables it (pass-through).
struct Pt1 {
  float y = 0;
  inline float apply(float x, float cutoff_hz, float dt) {
    if (cutoff_hz <= 0.0f) { y = x; return x; }
    float rc = 1.0f / (6.2831853f * cutoff_hz);
    float k = dt / (rc + dt);
    y += k * (x - y);
    return y;
  }
  inline void reset(float v) { y = v; }
};

// Rate controller for one axis:
//   out = P*e + I*integral(e) - D*d(measured)/dt + FF*d(setpoint)/dt
//
// - D acts on the measurement (no "derivative kick" on stick moves).
// - FF uses the setpoint derivative: the torque needed to *start* a rotation is
//   sent immediately instead of waiting for an error to build up. This is the
//   "feedforward" part of the cascaded controller.
// - The integrator only runs when `integrate` is true (airborne) and is clamped.
struct RatePid {
  float integ = 0;
  float prev_meas = 0, prev_sp = 0;
  Pt1 d_lpf, ff_lpf;

  inline float update(float sp, float meas, float kp, float ki, float kd, float kff,
                      float i_limit, float d_hz, float ff_hz, float dt, bool integrate) {
    float e = sp - meas;
    if (integrate) {
      integ += ki * e * dt;
      if (integ > i_limit) integ = i_limit;
      if (integ < -i_limit) integ = -i_limit;
    }
    float dmeas = d_lpf.apply((meas - prev_meas) / dt, d_hz, dt);
    float dsp = ff_lpf.apply((sp - prev_sp) / dt, ff_hz, dt);
    prev_meas = meas;
    prev_sp = sp;
    return kp * e + integ - kd * dmeas + kff * dsp;
  }

  inline void reset(float meas, float sp) {
    integ = 0;
    prev_meas = meas;
    prev_sp = sp;
    d_lpf.reset(0);
    ff_lpf.reset(0);
  }
};

static inline float clampf(float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

static inline float wrap180(float a) {
  while (a > 180.0f) a -= 360.0f;
  while (a < -180.0f) a += 360.0f;
  return a;
}
