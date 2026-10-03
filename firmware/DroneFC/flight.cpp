// =============================================================================
//  flight.cpp  -  INNER LOOPS (ESP32, core 1, 1 kHz)
//
//  What runs HERE, on the ESP32:
//    * attitude estimation (Mahony)            1 kHz
//    * angle loop  (angle error -> rate setpoint, + setpoint feedforward)
//    * rate loop   (PID + setpoint feedforward -> motor corrections)
//    * mixer + ESC output
//    * arming checks, failsafe, landing, follow-mode timer, low-battery landing,
//      crash detection, kill switch
//  These need deterministic sub-millisecond timing, and they must keep working
//  when every phone and the laptop are gone. That is why they are here.
//
//  What runs on the PHONE (see ios/DroneBoyfriendTracker/Follow/FollowController.swift):
//    * person detection, distance / height estimation, the follow outer loops
//      (distance -> pitch, sideways offset -> roll, height -> throttle).
//    They need the camera, and they work at 1-2 Hz bandwidth, so 30 Hz updates
//    plus ~10-30 ms of WiFi delay cost nothing. The ESP32 treats their output
//    as setpoints and clamps them to its own limits.
//
//  No heap allocation, no blocking calls and no flash writes in this file.
// =============================================================================
#include "flight.h"
#include <Arduino.h>
#include "attitude.h"
#include "config.h"
#include "imu.h"
#include "motors.h"
#include "params.h"
#include "pid.h"
#include "shared.h"

static TaskHandle_t s_task = nullptr;
static bool s_imu_ok_at_boot = false;

static void IRAM_ATTR imu_isr() {
  BaseType_t woken = pdFALSE;
  if (s_task) vTaskNotifyGiveFromISR(s_task, &woken);
  if (woken) portYIELD_FROM_ISR();
}

// ----------------------------------------------------------------------------
//  Controller state (all static, lives for the whole program)
// ----------------------------------------------------------------------------
namespace {

Params P;
uint32_t param_ver = 0;
Ahrs ahrs;
LinkInputs in;

FlightState state = ST_BOOT;
int64_t state_us = 0;  // time the current state was entered
uint8_t last_event = LR_NONE;

// gyro calibration
float gyro_bias[3] = {0, 0, 0};
float cal_sum[3], cal_min[3], cal_max[3], cal_acc[3];
int cal_n = 0;
bool gyro_cal_ok = false;
bool imu_ok = false;

// level calibration
bool level_cal_active = false;
float level_sum_r = 0, level_sum_p = 0;
int level_n = 0;
uint8_t level_cal_source = 0;
uint16_t level_cal_seq = 0;

// controllers
RatePid pid_roll, pid_pitch, pid_yaw;
Pt1 sp_rate_roll, sp_rate_pitch;
Pt1 gyro_lpf[3];
float prev_roll_sp = 0, prev_pitch_sp = 0;
float yaw_target = 0;

// flight bookkeeping
bool airborne = false;
float throttle_out = 0;
float motor_out[4] = {0, 0, 0, 0};
float hover_est = 0.5f;
float hover_learn_s = 0;
float hover_push_s = 0;
float vz_est = 0;
uint32_t last_follow_count = 0;
Pt1 az_lpf;
int64_t follow_start_us = 0;
int64_t countdown_end_us = 0;
int64_t low_thr_since_us = 0;
int64_t batt_low_since_us = 0;
int64_t crash_since_us = 0;
int64_t touchdown_us = 0;
float esc_cal_us = ESC_PWM_MIN_US;
int imu_fail_count = 0;

// loop statistics
int64_t last_loop_us = 0;
int64_t stats_window_us = 0;
uint32_t loops_in_window = 0;
uint32_t max_exec_us = 0, max_jitter_us = 0;
uint16_t stat_hz = 0, stat_exec = 0, stat_jitter = 0;
uint32_t status_div = 0;

inline bool fresh(int64_t t, int64_t now, float timeout_s) {
  return t != 0 && (now - t) < (int64_t)(timeout_s * 1e6f);
}

inline bool is_armed_state(FlightState s) {
  return s == ST_MANUAL || s == ST_FOLLOW || s == ST_FAILSAFE_HOVER || s == ST_LANDING;
}

inline float roll_c(const Attitude& a) { return a.roll - P[P_TRIM_ROLL]; }
inline float pitch_c(const Attitude& a) { return a.pitch - P[P_TRIM_PITCH]; }

void ack(const CmdMsg& m, uint8_t result) {
  AckMsg a = {m.source, m.cmd, result, m.seq};
  shared_push_ack(a);
}

void reset_controllers(const Attitude& a) {
  pid_roll.reset(a.p, 0);
  pid_pitch.reset(a.q, 0);
  pid_yaw.reset(a.r, 0);
  sp_rate_roll.reset(0);
  sp_rate_pitch.reset(0);
  prev_roll_sp = roll_c(a);
  prev_pitch_sp = pitch_c(a);
  yaw_target = a.yaw;
}

void enter(FlightState s, int64_t now) {
  state = s;
  state_us = now;
}

void on_arm(const Attitude& a, int64_t now) {
  reset_controllers(a);
  airborne = false;
  vz_est = 0;
  hover_est = P[P_HOVER_THR];
  hover_learn_s = 0;
  hover_push_s = 0;
  low_thr_since_us = 0;
  batt_low_since_us = 0;
  crash_since_us = 0;
  touchdown_us = 0;
  last_follow_count = in.follow_count;
}

void disarm(uint8_t reason, int64_t now) {
  bool was_armed = is_armed_state(state);
  motors_stop();
  for (int i = 0; i < 4; i++) motor_out[i] = 0;
  throttle_out = 0;
  if (was_armed) {
    last_event = reason;
    // Save the learned hover throttle once we have learned for a while.
    if (P[P_HOVER_LEARN] > 0.5f && hover_learn_s > 10.0f) g_hover_save_request = true;
  }
  enter(ST_DISARMED, now);
}

void begin_landing(uint8_t reason, int64_t now) {
  if (!airborne) {  // still on the ground: just stop
    disarm(reason, now);
    return;
  }
  last_event = reason;
  touchdown_us = 0;
  yaw_target = ahrs.att().yaw;
  enter(ST_LANDING, now);
}

void begin_failsafe(uint8_t reason, int64_t now) {
  if (!airborne) {
    disarm(reason, now);
    return;
  }
  last_event = reason;
  yaw_target = ahrs.att().yaw;
  enter(ST_FAILSAFE_HOVER, now);
}

// Why would arming be refused right now? follow=true checks the follow-start rules.
uint8_t arm_check(bool follow, int64_t now) {
  const Attitude& a = ahrs.att();
  if (follow) {
    if (state != ST_DISARMED && state != ST_FOLLOW_COUNTDOWN) return RES_WRONG_STATE;
  } else if (state != ST_DISARMED) {
    return is_armed_state(state) ? RES_ARMED : RES_WRONG_STATE;
  }
  if (!imu_ok || !gyro_cal_ok) return RES_IMU_NOT_READY;
  if (g_kill_request) return RES_KILL_LATCHED;
  float to = P[P_LINK_TIMEOUT_S];
  if (!fresh(in.last_us[CL_LAPTOP], now, to)) return RES_NO_LAPTOP;
  if (follow) {
    if (!fresh(in.follow_us, now, to)) return RES_NO_DRONE_PHONE;
    if (!(in.follow.pflags & FOLLOW_FLAG_READY)) return RES_PHONE_NOT_READY;
  } else {
    if (!fresh(in.rc_us, now, to)) return RES_NO_PILOT;
    if (in.rc.throttle > 50) return RES_THROTTLE_HIGH;
  }
  if (fabsf(roll_c(a)) > P[P_ARM_MAX_TILT] || fabsf(pitch_c(a)) > P[P_ARM_MAX_TILT]) return RES_NOT_LEVEL;
  if (in.batt_present && in.vbat < P[P_BATT_LAND_V]) return RES_BATTERY_LOW;
  return RES_OK;
}

// ----------------------------------------------------------------------------
void handle_command(const CmdMsg& m, int64_t now) {
  const Attitude& a = ahrs.att();
  switch (m.cmd) {
    case CMD_KILL:
      g_kill_request = true;  // processed at the top of the loop
      ack(m, RES_OK);
      break;

    case CMD_DISARM:
      g_kill_request = false;
      if (state == ST_BOOT || state == ST_IMU_FAULT) { ack(m, RES_WRONG_STATE); break; }
      if (state != ST_DISARMED) disarm(LR_DISARM_CMD, now);
      ack(m, RES_OK);
      break;

    case CMD_ARM: {
      if (m.source != SRC_PHONE_REMOTE) { ack(m, RES_NOT_ALLOWED); break; }
      uint8_t r = arm_check(false, now);
      if (r == RES_OK) {
        on_arm(a, now);
        enter(ST_MANUAL, now);
      }
      ack(m, r);
      break;
    }

    case CMD_START_FOLLOW: {
      if (m.source != SRC_LAPTOP && m.source != SRC_PHONE_DRONE) { ack(m, RES_NOT_ALLOWED); break; }
      if (state != ST_DISARMED) { ack(m, RES_WRONG_STATE); break; }
      uint8_t r = arm_check(true, now);
      if (r == RES_OK) {
        countdown_end_us = now + (int64_t)(P[P_FOLLOW_COUNTDOWN_S] * 1e6f);
        enter(ST_FOLLOW_COUNTDOWN, now);
      }
      ack(m, r);
      break;
    }

    case CMD_CANCEL_FOLLOW:
      if (state == ST_FOLLOW_COUNTDOWN) { enter(ST_DISARMED, now); ack(m, RES_OK); }
      else ack(m, RES_WRONG_STATE);
      break;

    case CMD_LAND:
      if (state == ST_FOLLOW_COUNTDOWN) { enter(ST_DISARMED, now); ack(m, RES_OK); break; }
      if (state == ST_MANUAL || state == ST_FOLLOW || state == ST_FAILSAFE_HOVER) {
        begin_landing(m.arg == LR_TARGET_LOST ? LR_TARGET_LOST : LR_COMMAND, now);
        ack(m, RES_OK);
      } else {
        ack(m, state == ST_LANDING ? RES_OK : RES_WRONG_STATE);
      }
      break;

    case CMD_CAL_GYRO:
      if (!imu_ok) { ack(m, RES_IMU_NOT_READY); break; }
      if (state != ST_DISARMED) { ack(m, RES_WRONG_STATE); break; }
      cal_n = 0;
      gyro_cal_ok = false;
      enter(ST_BOOT, now);
      ack(m, RES_OK);
      break;

    case CMD_CAL_LEVEL:
      if (state != ST_DISARMED || !gyro_cal_ok) { ack(m, RES_WRONG_STATE); break; }
      level_cal_active = true;
      level_sum_r = level_sum_p = 0;
      level_n = 0;
      level_cal_source = m.source;
      level_cal_seq = m.seq;
      // acked when finished (0.5 s)
      break;

    case CMD_ESC_CAL_HIGH:
    case CMD_ESC_CAL_LOW:
      if (m.source != SRC_PHONE_REMOTE) { ack(m, RES_NOT_ALLOWED); break; }
      if (state != ST_DISARMED && state != ST_ESC_CAL) { ack(m, RES_WRONG_STATE); break; }
      esc_cal_us = (m.cmd == CMD_ESC_CAL_HIGH) ? ESC_PWM_MAX_US : ESC_PWM_MIN_US;
      enter(ST_ESC_CAL, now);
      ack(m, RES_OK);
      break;

    case CMD_ESC_CAL_EXIT:
      if (state == ST_ESC_CAL) {
        motors_stop();
        enter(ST_DISARMED, now);
      }
      ack(m, RES_OK);
      break;

    default:
      ack(m, RES_UNKNOWN);
      break;
  }
}

// ----------------------------------------------------------------------------
//  Angle -> rate -> motors. roll/pitch setpoints in degrees (aircraft convention),
//  yaw_rate_sp in deg/s, throttle 0..1 (collective, already tilt-compensated).
// ----------------------------------------------------------------------------
void run_controllers(const Attitude& a, float gyro_p, float gyro_q, float gyro_r, float roll_sp, float pitch_sp,
                     float yaw_rate_sp, float throttle, float dt) {
  float max_rate = P[P_MAX_RATE_RP];

  // Angle loop with setpoint feedforward (rate of change of the angle setpoint).
  float droll_sp = sp_rate_roll.apply((roll_sp - prev_roll_sp) / dt, P[P_FF_LPF_HZ], dt);
  float dpitch_sp = sp_rate_pitch.apply((pitch_sp - prev_pitch_sp) / dt, P[P_FF_LPF_HZ], dt);
  prev_roll_sp = roll_sp;
  prev_pitch_sp = pitch_sp;

  float rate_sp_p = P[P_ANGLE_ROLL_P] * (roll_sp - roll_c(a)) + P[P_ANGLE_FF] * droll_sp;
  float rate_sp_q = P[P_ANGLE_PITCH_P] * (pitch_sp - pitch_c(a)) + P[P_ANGLE_FF] * dpitch_sp;
  rate_sp_p = clampf(rate_sp_p, -max_rate, max_rate);
  rate_sp_q = clampf(rate_sp_q, -max_rate, max_rate);

  bool integrate = airborne && throttle > P[P_LIFTOFF_THR] * 0.6f;
  float il = P[P_I_LIMIT], dhz = P[P_DTERM_LPF_HZ], ffhz = P[P_FF_LPF_HZ];

  float out_r = pid_roll.update(rate_sp_p, gyro_p, P[P_RATE_ROLL_P], P[P_RATE_ROLL_I], P[P_RATE_ROLL_D],
                                P[P_RATE_ROLL_FF], il, dhz, ffhz, dt, integrate);
  float out_p = pid_pitch.update(rate_sp_q, gyro_q, P[P_RATE_PITCH_P], P[P_RATE_PITCH_I], P[P_RATE_PITCH_D],
                                 P[P_RATE_PITCH_FF], il, dhz, ffhz, dt, integrate);
  float out_y = pid_yaw.update(yaw_rate_sp, gyro_r, P[P_RATE_YAW_P], P[P_RATE_YAW_I], 0.0f, P[P_RATE_YAW_FF], il,
                               dhz, ffhz, dt, integrate);
  if (!integrate) {
    pid_roll.integ = 0;
    pid_pitch.integ = 0;
    pid_yaw.integ = 0;
  }
  // Yaw has little authority on a quad; keep it from eating roll/pitch headroom.
  out_y = clampf(out_y, -0.25f, 0.25f);

  throttle_out = throttle;
  mixer_mix(throttle, out_r, out_p, out_y, P[P_MOTOR_IDLE], airborne, motor_out);
  motors_write(motor_out);
}

inline float tilt_comp(float thr, const Attitude& a) {
  if (P[P_TILT_COMP] < 0.5f) return thr;
  return thr / fmaxf(a.cos_tilt, 0.7f);
}

// Heading hold for the automatic modes: zero yaw-rate request = keep the heading.
inline float heading_hold(const Attitude& a, float yaw_rate_req, float max_rate) {
  if (fabsf(yaw_rate_req) < 1.0f) {
    return clampf(P[P_HEADING_P] * (yaw_target - a.yaw), -max_rate, max_rate);
  }
  yaw_target = a.yaw;
  return clampf(yaw_rate_req, -max_rate, max_rate);
}

// ----------------------------------------------------------------------------
void control_step(const ImuSample& raw, float dt, int64_t now) {
  // 1. Params (only copied when the link task changed something)
  uint32_t v = params_version();
  if (v != param_ver) {
    param_ver = v;
    params_snapshot(P);
  }

  // 2. Inputs from the link task
  shared_read_inputs(in);

  // 3. Gyro bias, optional software low-pass, attitude
  ImuSample s = raw;
  s.gx -= gyro_bias[0];
  s.gy -= gyro_bias[1];
  s.gz -= gyro_bias[2];
  float glpf = P[P_GYRO_LPF_HZ];
  s.gx = gyro_lpf[0].apply(s.gx, glpf, dt);
  s.gy = gyro_lpf[1].apply(s.gy, glpf, dt);
  s.gz = gyro_lpf[2].apply(s.gz, glpf, dt);

  if (state != ST_BOOT) ahrs.update(s, dt, (now - state_us < 2000000 && !is_armed_state(state)) ? 2.0f : P[P_AHRS_KP]);
  const Attitude& a = ahrs.att();
  float az_f = az_lpf.apply(a.az_up, 20.0f, dt);

  // 4. Kill switch beats everything
  if (g_kill_request && state != ST_KILLED && state != ST_BOOT && state != ST_IMU_FAULT) {
    bool was_armed = is_armed_state(state);
    motors_stop();
    for (int i = 0; i < 4; i++) motor_out[i] = 0;
    throttle_out = 0;
    if (was_armed || state == ST_FOLLOW_COUNTDOWN || state == ST_MOTOR_TEST || state == ST_ESC_CAL) last_event = LR_KILLED;
    enter(ST_KILLED, now);
  }

  // 5. Commands
  CmdMsg cm;
  while (shared_pop_cmd(cm)) handle_command(cm, now);

  const float to = P[P_LINK_TIMEOUT_S];
  const bool laptop_ok = fresh(in.last_us[CL_LAPTOP], now, to);

  // 6. Global armed-state protections
  if (is_armed_state(state)) {
    // crash / flip: motors off
    if (fabsf(roll_c(a)) > P[P_CRASH_ANGLE] || fabsf(pitch_c(a)) > P[P_CRASH_ANGLE]) {
      if (crash_since_us == 0) crash_since_us = now;
      if (now - crash_since_us > 300000) disarm(LR_CRASH, now);
    } else {
      crash_since_us = 0;
    }
    // low battery: land (sustained 3 s so a throttle punch does not trigger it)
    if (in.batt_present && in.vbat < P[P_BATT_LAND_V] && state != ST_LANDING) {
      if (batt_low_since_us == 0) batt_low_since_us = now;
      if (now - batt_low_since_us > 3000000) begin_landing(LR_BATTERY, now);
    } else {
      batt_low_since_us = 0;
    }
    // vertical speed estimate: accelerometer integration with a slow leak,
    // corrected by the drone phone's baro/vision estimate whenever it is fresh.
    vz_est += a.az_up * dt;
    vz_est -= vz_est * dt / 4.0f;
    if (in.follow_count != last_follow_count) {
      last_follow_count = in.follow_count;
      if ((in.follow.pflags & FOLLOW_FLAG_HEIGHT_VALID) && fresh(in.follow_us, now, 0.2f))
        vz_est += 0.3f * (in.follow.vz_cms * 0.01f - vz_est);
    }
  }

  // 7. State machine
  switch (state) {
    case ST_BOOT: {
      // Gyro calibration: 1 s of samples while the drone sits still.
      motors_stop();
      if (cal_n == 0) {
        for (int i = 0; i < 3; i++) {
          cal_sum[i] = 0;
          cal_min[i] = 1e9f;
          cal_max[i] = -1e9f;
          cal_acc[i] = 0;
        }
      }
      float g[3] = {raw.gx, raw.gy, raw.gz};
      float ac[3] = {raw.ax, raw.ay, raw.az};
      for (int i = 0; i < 3; i++) {
        cal_sum[i] += g[i];
        cal_acc[i] += ac[i];
        if (g[i] < cal_min[i]) cal_min[i] = g[i];
        if (g[i] > cal_max[i]) cal_max[i] = g[i];
      }
      cal_n++;
      if (cal_n >= 1000) {
        bool still = true;
        for (int i = 0; i < 3; i++)
          if (cal_max[i] - cal_min[i] > 10.0f) still = false;
        if (still) {
          for (int i = 0; i < 3; i++) gyro_bias[i] = cal_sum[i] / cal_n;
          ImuSample avg = {0, 0, 0, cal_acc[0] / cal_n, cal_acc[1] / cal_n, cal_acc[2] / cal_n};
          ahrs.reset_from_accel(avg);
          gyro_cal_ok = true;
          enter(ST_DISARMED, now);
        }
        cal_n = 0;  // moving: try again
      }
      break;
    }

    case ST_IMU_FAULT:
    case ST_KILLED:
      motors_stop();
      break;

    case ST_DISARMED:
      motors_stop();
      for (int i = 0; i < 4; i++) motor_out[i] = 0;
      throttle_out = 0;
      reset_controllers(a);
      if (level_cal_active) {
        level_sum_r += a.roll;
        level_sum_p += a.pitch;
        if (++level_n >= 500) {
          level_cal_active = false;
          float r = level_sum_r / level_n, p = level_sum_p / level_n;
          AckMsg am = {level_cal_source, CMD_CAL_LEVEL, RES_NOT_LEVEL, level_cal_seq};
          if (fabsf(r) < 15.0f && fabsf(p) < 15.0f) {
            params_set(P_TRIM_ROLL, r);
            params_set(P_TRIM_PITCH, p);
            am.result = RES_OK;
          }
          shared_push_ack(am);
        }
      }
      if (fresh(in.motor_test_us, now, 0.3f)) enter(ST_MOTOR_TEST, now);
      break;

    case ST_MOTOR_TEST: {
      // PROPS OFF. Each motor individually, capped at 15 %.
      if (!fresh(in.motor_test_us, now, 0.5f)) {
        motors_stop();
        for (int i = 0; i < 4; i++) motor_out[i] = 0;
        enter(ST_DISARMED, now);
        break;
      }
      for (int i = 0; i < 4; i++) {
        uint16_t m = in.motor_test.motor[i];
        if (m > 150) m = 150;
        motor_out[i] = m * 0.001f;
      }
      motors_write(motor_out);
      break;
    }

    case ST_ESC_CAL:
      // PROPS OFF. Leaves this state if the remote phone disappears.
      if (!fresh(in.last_us[CL_REMOTE], now, 1.0f)) {
        motors_stop();
        enter(ST_DISARMED, now);
        break;
      }
      motors_write_us((uint16_t)esc_cal_us);
      for (int i = 0; i < 4; i++) motor_out[i] = (esc_cal_us - ESC_PWM_MIN_US) / (float)(ESC_PWM_MAX_US - ESC_PWM_MIN_US);
      break;

    case ST_FOLLOW_COUNTDOWN:
      motors_stop();
      reset_controllers(a);
      if (!laptop_ok || !fresh(in.follow_us, now, to)) {
        enter(ST_DISARMED, now);
        break;
      }
      if (now >= countdown_end_us) {
        if (arm_check(true, now) == RES_OK) {
          on_arm(a, now);
          follow_start_us = now;
          enter(ST_FOLLOW, now);
        } else {
          enter(ST_DISARMED, now);
        }
      }
      break;

    case ST_MANUAL: {
      if (!laptop_ok) { begin_failsafe(LR_LAPTOP_LOST, now); break; }
      if (!fresh(in.rc_us, now, to)) { begin_failsafe(LR_PILOT_LOST, now); break; }
      float stick_thr = in.rc.throttle * 0.001f;
      float idle = P[P_MOTOR_IDLE];
      float thr = idle + stick_thr * (1.0f - idle);
      if (thr > P[P_LIFTOFF_THR]) airborne = true;

      float max_ang = P[P_MAX_ANGLE_MANUAL];
      float roll_sp = in.rc.roll * 0.001f * max_ang;
      float pitch_sp = -in.rc.pitch * 0.001f * max_ang;  // stick forward = nose down
      float yaw_rate_sp = in.rc.yaw * 0.001f * P[P_MAX_YAW_RATE];
      run_controllers(a, s.gx, -s.gy, -s.gz, roll_sp, pitch_sp, yaw_rate_sp, thr, dt);

      // auto-disarm: throttle stick at the bottom for a few seconds
      if (stick_thr < 0.05f) {
        if (low_thr_since_us == 0) low_thr_since_us = now;
        if (now - low_thr_since_us > 500000) airborne = false;  // landed: stop air-mode mixing
        if (now - low_thr_since_us > (int64_t)(P[P_AUTO_DISARM_S] * 1e6f)) disarm(LR_AUTO_DISARM, now);
      } else {
        low_thr_since_us = 0;
      }
      break;
    }

    case ST_FOLLOW: {
      if (!laptop_ok) { begin_failsafe(LR_LAPTOP_LOST, now); break; }
      int64_t active_us = in.follow_active_us > state_us ? in.follow_active_us : state_us;
      if (!fresh(active_us, now, to)) { begin_failsafe(LR_DRONE_PHONE_LOST, now); break; }
      if (now - follow_start_us > (int64_t)(P[P_FOLLOW_TIMEOUT_S] * 1e6f)) {
        begin_landing(LR_FOLLOW_TIMEOUT, now);
        break;
      }
      const FollowPayload& f = in.follow;
      float max_ang = P[P_MAX_ANGLE_FOLLOW];
      bool active = (f.pflags & FOLLOW_FLAG_ACTIVE) && in.follow_active_us >= state_us;
      float roll_sp = active ? clampf(f.roll_cdeg * 0.01f, -max_ang, max_ang) : 0.0f;
      float pitch_sp = active ? clampf(f.pitch_cdeg * 0.01f, -max_ang, max_ang) : 0.0f;
      float yaw_req = active ? f.yaw_rate_ddps * 0.1f : 0.0f;
      // No valid setpoint yet (phone catching up) or a gap: hold hover if flying.
      float thr = active ? f.throttle * 0.001f : (airborne ? hover_est : P[P_MOTOR_IDLE]);
      if (thr > P[P_LIFTOFF_THR]) airborne = true;
      float yaw_rate_sp = heading_hold(a, yaw_req, P[P_MAX_YAW_RATE_FOLLOW]);
      run_controllers(a, s.gx, -s.gy, -s.gz, roll_sp, pitch_sp, yaw_rate_sp, clampf(tilt_comp(thr, a), 0.0f, 0.95f), dt);
      break;
    }

    case ST_FAILSAFE_HOVER: {
      // Level, hold heading, hover throttle with vertical-speed damping.
      float hover = hover_est;
      float thr = hover + P[P_LAND_VZ_GAIN] * (0.0f - vz_est);
      thr = clampf(thr, hover - 0.15f, hover + 0.10f);
      float yaw_rate_sp = heading_hold(a, 0.0f, P[P_MAX_YAW_RATE_FOLLOW]);
      run_controllers(a, s.gx, -s.gy, -s.gz, 0.0f, 0.0f, yaw_rate_sp, tilt_comp(thr, a), dt);
      if (now - state_us > (int64_t)(P[P_FS_HOVER_S] * 1e6f)) {
        touchdown_us = 0;
        enter(ST_LANDING, now);
      }
      break;
    }

    case ST_LANDING: {
      float t = (now - state_us) * 1e-6f;
      float hover = hover_est;
      float thr;
      if (touchdown_us != 0) {
        // On the ground: idle for 0.5 s, then disarm.
        thr = P[P_MOTOR_IDLE];
        if (now - touchdown_us > 500000) { disarm(LR_TOUCHDOWN, now); break; }
      } else if (t > P[P_LAND_MAX_S]) {
        // Taking too long (no height information): ramp down to idle over 2 s.
        float k = clampf((t - P[P_LAND_MAX_S]) / 2.0f, 0.0f, 1.0f);
        thr = (hover - 0.05f) * (1.0f - k) + P[P_MOTOR_IDLE] * k;
        if (k >= 1.0f) {
          touchdown_us = now;
          airborne = false;
        }
      } else {
        float vz_sp = -P[P_LAND_SPEED] * clampf(t / 1.0f, 0.0f, 1.0f);
        thr = hover + P[P_LAND_VZ_GAIN] * (vz_sp - vz_est);
        thr = clampf(thr, hover - 0.15f, hover + 0.10f);

        // Touchdown detection
        bool phone_h = (in.follow.pflags & FOLLOW_FLAG_HEIGHT_VALID) && fresh(in.follow_us, now, 0.3f);
        float phone_height = in.follow.height_cm * 0.01f;
        bool impact = t > 0.8f && az_f > P[P_LAND_IMPACT_G] * 9.81f;
        if (phone_h && phone_height > 0.5f) impact = false;  // phone says we are still well above ground
        bool still_low = phone_h && phone_height < 0.25f && fabsf(a.p) < 10 && fabsf(a.q) < 10 && t > 1.0f;
        if (impact || still_low) {
          touchdown_us = now;
          airborne = false;  // plain clamped mixing from here: no revving against the ground
        }
      }
      float yaw_rate_sp = heading_hold(a, 0.0f, P[P_MAX_YAW_RATE_FOLLOW]);
      run_controllers(a, s.gx, -s.gy, -s.gz, 0.0f, 0.0f, yaw_rate_sp, tilt_comp(thr, a), dt);
      break;
    }
  }

  // 8. Hover-throttle learning (level, not accelerating vertically, airborne)
  if ((state == ST_MANUAL || state == ST_FOLLOW) && airborne && fabsf(roll_c(a)) < 10.0f &&
      fabsf(pitch_c(a)) < 10.0f && fabsf(az_f) < 0.6f && throttle_out > P[P_LIFTOFF_THR]) {
    float level_thr = throttle_out * a.cos_tilt;
    hover_est += (level_thr - hover_est) * dt / 3.0f;
    hover_learn_s += dt;
    hover_push_s += dt;
    if (hover_push_s > 1.0f && P[P_HOVER_LEARN] > 0.5f) {
      hover_push_s = 0;
      params_set_learned(P_HOVER_THR, hover_est);
    }
  }

  // 9. Status for telemetry (100 Hz is plenty)
  if (++status_div >= 10) {
    status_div = 0;
    ControlStatus st;
    st.state = state;
    st.armed = is_armed_state(state);
    st.imu_ok = imu_ok;
    st.gyro_cal_ok = gyro_cal_ok;
    st.arm_block = (uint8_t)((arm_check(false, now) & 0x0F) | ((arm_check(true, now) & 0x0F) << 4));
    st.last_event = last_event;
    st.roll = roll_c(a);
    st.pitch = pitch_c(a);
    st.yaw = a.yaw;
    st.throttle = throttle_out;
    st.hover_thr = is_armed_state(state) ? hover_est : P[P_HOVER_THR];
    for (int i = 0; i < 4; i++) st.motor[i] = motor_out[i];
    st.loop_hz = stat_hz;
    st.loop_max_us = stat_exec;
    st.loop_jitter_us = stat_jitter;
    st.follow_left_s = (state == ST_FOLLOW) ? P[P_FOLLOW_TIMEOUT_S] - (now - follow_start_us) * 1e-6f : 0.0f;
    st.countdown_s = (state == ST_FOLLOW_COUNTDOWN) ? (countdown_end_us - now) * 1e-6f : 0.0f;
    shared_write_status(st);
  }
}

void control_task(void*) {
  attachInterrupt(digitalPinToInterrupt(PIN_IMU_INT), imu_isr, RISING);  // ISR on this core
  imu_ok = s_imu_ok_at_boot;
  params_snapshot(P);
  param_ver = params_version();
  // Bench mode: no IMU at boot. Run the loop on a fake level, still reading so the
  // app, motor test and ESC calibration work. imu_ok stays false, so arming is refused.
  const bool bench = !imu_ok;
  const ImuSample level = {0, 0, 0, 0, 0, 1.0f};
  if (bench) {
    last_event = LR_IMU_FAULT;
    ahrs.reset_from_accel(level);
    enter(ST_DISARMED, esp_timer_get_time());
  } else {
    enter(ST_BOOT, esp_timer_get_time());
  }
  last_loop_us = esp_timer_get_time();
  stats_window_us = last_loop_us;

  for (;;) {
    ImuSample raw;
    uint32_t got;
    bool ok;
    if (bench) {
      vTaskDelay(1);
      got = 1;
      raw = level;
      ok = true;
    } else {
      // Wait for the IMU data-ready interrupt (1 kHz). 3 ms timeout = missed interrupt.
      got = ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(3));
      ok = imu_ok && imu_read(raw);
    }
    int64_t start = esp_timer_get_time();
    if (!ok || got == 0) {
      if (++imu_fail_count > 20 && state != ST_IMU_FAULT) {
        // No attitude = no safe way to fly. Motors off.
        imu_ok = false;
        motors_stop();
        for (int i = 0; i < 4; i++) motor_out[i] = 0;
        throttle_out = 0;
        last_event = LR_IMU_FAULT;
        enter(ST_IMU_FAULT, start);
      }
      if (!ok) {
        if (state == ST_IMU_FAULT) {
          // keep publishing status while faulted
          if (++status_div >= 10) {
            status_div = 0;
            ControlStatus st = {};
            st.state = state;
            st.last_event = last_event;
            st.arm_block = RES_IMU_NOT_READY | (RES_IMU_NOT_READY << 4);
            shared_write_status(st);
          }
        }
        continue;
      }
    } else {
      imu_fail_count = 0;
    }

    float dt = (start - last_loop_us) * 1e-6f;
    uint32_t period = (uint32_t)(start - last_loop_us);
    last_loop_us = start;
    if (dt <= 0.0f || dt > 0.01f) dt = 0.001f;

    control_step(raw, dt, start);

    // loop statistics
    uint32_t exec = (uint32_t)(esp_timer_get_time() - start);
    if (exec > max_exec_us) max_exec_us = exec;
    uint32_t jit = period > 1000 ? period - 1000 : 1000 - period;
    if (jit > max_jitter_us) max_jitter_us = jit;
    loops_in_window++;
    if (start - stats_window_us >= 1000000) {
      stat_hz = (uint16_t)loops_in_window;
      stat_exec = (uint16_t)(max_exec_us > 65535 ? 65535 : max_exec_us);
      stat_jitter = (uint16_t)(max_jitter_us > 65535 ? 65535 : max_jitter_us);
      loops_in_window = 0;
      max_exec_us = 0;
      max_jitter_us = 0;
      stats_window_us = start;
    }
  }
}

}  // namespace

void flight_start(bool imu_ok_at_boot) {
  s_imu_ok_at_boot = imu_ok_at_boot;
  xTaskCreatePinnedToCore(control_task, "control", 8192, nullptr, CONTROL_TASK_PRIORITY, &s_task, CONTROL_TASK_CORE);
}
