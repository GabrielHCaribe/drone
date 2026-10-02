// =============================================================================
//  shared.h  -  data exchanged between the two tasks
//
//    core 1: control task  (IMU -> attitude -> PID -> motors, state machine)
//    core 0: link task     (WiFi AP, UDP, telemetry, battery ADC, flash writes)
//
//  Everything is fixed-size and statically allocated. Structs are copied under
//  a spinlock (a few hundred nanoseconds), so neither task ever waits on the other.
// =============================================================================
#pragma once
#include <Arduino.h>
#include "protocol.h"

enum ClientIndex : uint8_t { CL_LAPTOP = 0, CL_REMOTE = 1, CL_DRONE = 2 };
static inline int client_index(uint8_t source) {
  return (source >= SRC_LAPTOP && source <= SRC_PHONE_DRONE) ? (int)source - 1 : -1;
}

// Link task -> control task
struct LinkInputs {
  int64_t last_us[NUM_CLIENTS];  // time of the last valid packet per client (0 = never)
  RcPayload rc;
  int64_t rc_us;
  FollowPayload follow;
  int64_t follow_us;          // last FOLLOW packet of any kind
  int64_t follow_active_us;   // last FOLLOW packet with FOLLOW_FLAG_ACTIVE
  uint32_t follow_count;      // increments per FOLLOW packet (lets the controller see new data)
  MotorTestPayload motor_test;
  int64_t motor_test_us;
  float vbat;                 // volts, filtered
  bool batt_present;
};

// Control task -> link task (telemetry)
struct ControlStatus {
  uint8_t state;
  bool armed;
  bool imu_ok;
  bool gyro_cal_ok;
  uint8_t arm_block;  // low nibble: manual arming result, high nibble: follow start result
  uint8_t last_event;
  float roll, pitch, yaw;
  float throttle;
  float hover_thr;
  float motor[4];
  uint16_t loop_hz;
  uint16_t loop_max_us;
  uint16_t loop_jitter_us;
  float follow_left_s;
  float countdown_s;
};

struct CmdMsg {
  uint8_t cmd;
  uint8_t arg;
  uint8_t source;
  uint16_t seq;
};

struct AckMsg {
  uint8_t source;
  uint8_t cmd;
  uint8_t result;
  uint16_t seq;
};

void shared_init();

void shared_write_inputs(const LinkInputs& in);  // link task
void shared_read_inputs(LinkInputs& out);        // control task
LinkInputs& shared_inputs_unlocked();            // link task only (its working copy)

void shared_write_status(const ControlStatus& st);  // control task
void shared_read_status(ControlStatus& out);        // link task

bool shared_push_cmd(const CmdMsg& m);   // link -> control (never blocks)
bool shared_pop_cmd(CmdMsg& m);
bool shared_push_ack(const AckMsg& m);   // control -> link (never blocks)
bool shared_pop_ack(AckMsg& m);

// Kill is not queued: any kill request sets this flag and the very next
// control-loop iteration (<= 1 ms later) stops the motors.
extern volatile bool g_kill_request;

// Learned hover throttle should be saved (set by control after a flight,
// executed by the link task only when disarmed).
extern volatile bool g_hover_save_request;

extern volatile bool g_video_on;
