// =============================================================================
//  params.h  -  runtime-tunable parameters (PID/FF gains, limits, failsafe)
//
//  - Changed live from the app (PKT_PARAM_SET), effective within 1 ms.
//  - Saved to flash (NVS) only on CMD_PARAM_SAVE and only while DISARMED,
//    because a flash write stalls both CPU cores for several milliseconds.
//  - The app discovers names and limits from the ESP32 (PKT_PARAM_INFO), so the
//    list below is the only place parameters are defined.
// =============================================================================
#pragma once
#include <stdint.h>

// X-macro: id, name (max 23 chars), default, min, max
// Gain units: rate loop output is in "fraction of full motor range".
//   rate P  : per deg/s of rate error
//   rate I  : per deg of accumulated rate error
//   rate D  : per deg/s^2 (derivative of measured rate)
//   rate FF : per deg/s^2 (derivative of the rate setpoint)
//   angle P : deg/s of rate setpoint per deg of angle error
//   angle FF: fraction of the angle-setpoint rate passed straight to the rate loop
#define PARAM_LIST(X)                                                      \
  X(RATE_ROLL_P, "rate_roll_p", 0.0007f, 0.0f, 0.01f)                      \
  X(RATE_ROLL_I, "rate_roll_i", 0.0020f, 0.0f, 0.05f)                      \
  X(RATE_ROLL_D, "rate_roll_d", 0.000012f, 0.0f, 0.0005f)                  \
  X(RATE_ROLL_FF, "rate_roll_ff", 0.000015f, 0.0f, 0.0005f)                \
  X(RATE_PITCH_P, "rate_pitch_p", 0.0007f, 0.0f, 0.01f)                    \
  X(RATE_PITCH_I, "rate_pitch_i", 0.0020f, 0.0f, 0.05f)                    \
  X(RATE_PITCH_D, "rate_pitch_d", 0.000012f, 0.0f, 0.0005f)                \
  X(RATE_PITCH_FF, "rate_pitch_ff", 0.000015f, 0.0f, 0.0005f)              \
  X(RATE_YAW_P, "rate_yaw_p", 0.0025f, 0.0f, 0.02f)                        \
  X(RATE_YAW_I, "rate_yaw_i", 0.0030f, 0.0f, 0.05f)                        \
  X(RATE_YAW_FF, "rate_yaw_ff", 0.0f, 0.0f, 0.001f)                        \
  X(ANGLE_ROLL_P, "angle_roll_p", 5.0f, 0.0f, 20.0f)                       \
  X(ANGLE_PITCH_P, "angle_pitch_p", 5.0f, 0.0f, 20.0f)                     \
  X(ANGLE_FF, "angle_ff", 0.8f, 0.0f, 1.5f)                                \
  X(HEADING_P, "heading_p", 3.0f, 0.0f, 10.0f)                             \
  X(DTERM_LPF_HZ, "dterm_lpf_hz", 40.0f, 5.0f, 200.0f)                     \
  X(GYRO_LPF_HZ, "gyro_lpf_hz", 0.0f, 0.0f, 400.0f)                        \
  X(FF_LPF_HZ, "ff_lpf_hz", 15.0f, 2.0f, 100.0f)                           \
  X(I_LIMIT, "i_limit", 0.25f, 0.0f, 0.5f)                                 \
  X(MAX_ANGLE_MANUAL, "max_angle_manual", 25.0f, 5.0f, 45.0f)              \
  X(MAX_ANGLE_FOLLOW, "max_angle_follow", 15.0f, 3.0f, 30.0f)              \
  X(MAX_YAW_RATE, "max_yaw_rate", 120.0f, 10.0f, 360.0f)                   \
  X(MAX_YAW_RATE_FOLLOW, "max_yaw_rate_follow", 30.0f, 5.0f, 120.0f)       \
  X(MAX_RATE_RP, "max_rate_rp", 200.0f, 30.0f, 600.0f)                     \
  X(MOTOR_IDLE, "motor_idle", 0.05f, 0.0f, 0.20f)                          \
  X(HOVER_THR, "hover_thr", 0.50f, 0.20f, 0.80f)                           \
  X(HOVER_LEARN, "hover_learn", 1.0f, 0.0f, 1.0f)                          \
  X(LIFTOFF_THR, "liftoff_thr", 0.25f, 0.05f, 0.60f)                       \
  X(TILT_COMP, "tilt_comp", 1.0f, 0.0f, 1.0f)                              \
  X(LINK_TIMEOUT_S, "link_timeout_s", 0.5f, 0.2f, 2.0f)                    \
  X(FS_HOVER_S, "failsafe_hover_s", 1.0f, 0.0f, 5.0f)                      \
  X(LAND_SPEED, "land_speed_mps", 0.5f, 0.2f, 1.5f)                        \
  X(LAND_VZ_GAIN, "land_vz_gain", 0.12f, 0.0f, 0.5f)                       \
  X(LAND_MAX_S, "land_max_s", 10.0f, 3.0f, 30.0f)                          \
  X(LAND_IMPACT_G, "land_impact_g", 0.4f, 0.1f, 2.0f)                      \
  X(BATT_SCALE, "batt_scale", 5.70f, 1.0f, 20.0f)                          \
  X(BATT_WARN_V, "batt_warn_v", 10.5f, 0.0f, 30.0f)                        \
  X(BATT_LAND_V, "batt_land_v", 9.9f, 0.0f, 30.0f)                         \
  X(FOLLOW_TIMEOUT_S, "follow_timeout_s", 45.0f, 5.0f, 600.0f)             \
  X(FOLLOW_COUNTDOWN_S, "follow_countdown_s", 3.0f, 1.0f, 15.0f)           \
  X(CRASH_ANGLE, "crash_angle", 70.0f, 30.0f, 90.0f)                       \
  X(AUTO_DISARM_S, "auto_disarm_s", 5.0f, 1.0f, 30.0f)                     \
  X(ARM_MAX_TILT, "arm_max_tilt", 10.0f, 2.0f, 30.0f)                      \
  X(AHRS_KP, "ahrs_kp", 0.5f, 0.0f, 5.0f)                                  \
  X(TRIM_ROLL, "trim_roll", 0.0f, -15.0f, 15.0f)                           \
  X(TRIM_PITCH, "trim_pitch", 0.0f, -15.0f, 15.0f)

enum ParamId : uint8_t {
#define X_ENUM(id, name, def, mn, mx) P_##id,
  PARAM_LIST(X_ENUM)
#undef X_ENUM
  PARAM_COUNT
};

struct ParamDef {
  const char* name;
  float def;
  float min;
  float max;
};

extern const ParamDef PARAM_DEFS[PARAM_COUNT];

// Plain array of floats. The control task keeps its own copy and refreshes it
// whenever params_version() changes (copy happens inside a short spinlock).
struct Params {
  float v[PARAM_COUNT];
  inline float operator[](ParamId id) const { return v[id]; }
};

void params_init();                         // load from NVS (or defaults)
bool params_set(uint8_t id, float value);   // clamps; false if id is invalid
float params_get(uint8_t id);
void params_reset_defaults();
bool params_save();                         // NVS write. Caller ensures DISARMED.
uint32_t params_version();                  // increments on every change
void params_snapshot(Params& out);          // consistent copy for the control task
bool params_dirty();                        // RAM differs from flash
// The learned hover throttle is stored under its own key so it can be saved
// automatically after each landing without also saving unsaved tuning changes.
bool params_save_hover();
// Update a value learned in flight (hover throttle) without marking the
// parameter set as having unsaved user changes.
void params_set_learned(uint8_t id, float value);
