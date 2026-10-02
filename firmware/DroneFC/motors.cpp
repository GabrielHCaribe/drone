#include "motors.h"
#include <Arduino.h>
#include "config.h"
#include "pid.h"

static const uint8_t MOTOR_PINS[4] = {PIN_MOTOR1, PIN_MOTOR2, PIN_MOTOR3, PIN_MOTOR4};
static const uint32_t PWM_PERIOD_US = 1000000UL / ESC_PWM_HZ;
static const uint32_t PWM_FULL = (1UL << ESC_PWM_BITS) - 1;

// Mixer table: { roll, pitch, yaw } sign per motor.
//   roll  + = right side down -> left motors up
//   pitch + = nose up         -> front motors up
//   yaw   + = nose right      -> CCW props up (their drag twists the frame clockwise)
static const float MIX[4][3] = {
    {-1.0f, -1.0f, -1.0f},  // M1 rear-right  CW
    {-1.0f, +1.0f, +1.0f},  // M2 front-right CCW
    {+1.0f, -1.0f, +1.0f},  // M3 rear-left   CCW
    {+1.0f, +1.0f, -1.0f},  // M4 front-left  CW
};

static inline uint32_t us_to_duty(uint32_t us) { return (uint32_t)(((uint64_t)us * PWM_FULL) / PWM_PERIOD_US); }

static inline void write_pin(int i, uint32_t us) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(MOTOR_PINS[i], us_to_duty(us));
#else
  ledcWrite(i, us_to_duty(us));
#endif
}

void motors_init() {
  for (int i = 0; i < 4; i++) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
    ledcAttach(MOTOR_PINS[i], ESC_PWM_HZ, ESC_PWM_BITS);
#else
    ledcSetup(i, ESC_PWM_HZ, ESC_PWM_BITS);
    ledcAttachPin(MOTOR_PINS[i], i);
#endif
    write_pin(i, ESC_PWM_MIN_US);
  }
}

void motors_write(const float cmd[4]) {
  for (int i = 0; i < 4; i++) {
    float c = clampf(cmd[i], 0.0f, 1.0f);
    write_pin(i, ESC_PWM_MIN_US + (uint32_t)(c * (ESC_PWM_MAX_US - ESC_PWM_MIN_US) + 0.5f));
  }
}

void motors_write_us(uint16_t us) {
  for (int i = 0; i < 4; i++) write_pin(i, us);
}

void motors_stop() { motors_write_us(ESC_PWM_MIN_US); }

void mixer_mix(float throttle, float roll, float pitch, float yaw, float idle, bool airborne, float out[4]) {
  float d[4];
  float dmin = 1e9f, dmax = -1e9f;
  for (int i = 0; i < 4; i++) {
    d[i] = MIX[i][0] * roll + MIX[i][1] * pitch + MIX[i][2] * yaw;
    if (d[i] < dmin) dmin = d[i];
    if (d[i] > dmax) dmax = d[i];
  }
  if (!airborne) {
    for (int i = 0; i < 4; i++) out[i] = clampf(throttle + d[i], idle, 1.0f);
    return;
  }
  float avail = 1.0f - idle;
  float range = dmax - dmin;
  if (range > avail && range > 1e-6f) {
    float k = avail / range;
    for (int i = 0; i < 4; i++) d[i] *= k;
    dmin *= k;
    dmax *= k;
  }
  float thr = clampf(throttle, idle - dmin, 1.0f - dmax);
  for (int i = 0; i < 4; i++) out[i] = clampf(thr + d[i], idle, 1.0f);
}
