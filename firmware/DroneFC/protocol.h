// =============================================================================
//  protocol.h  -  binary UDP protocol shared by ESP32, iPhone app and laptop.
//  The authoritative description is docs/PROTOCOL.md; keep all three in sync.
//
//  Every packet:  [Header 8 bytes][payload][CRC16 2 bytes]   (little-endian)
//  CRC = CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over header + payload.
// =============================================================================
#pragma once
#include <stdint.h>
#include <stddef.h>

#define PROTO_MAGIC 0x4450  // bytes 'P','D' on the wire
#define PROTO_VERSION 1

// ---- sources (who sent the packet) ------------------------------------------
enum Source : uint8_t {
  SRC_ESP32 = 0,
  SRC_LAPTOP = 1,        // ground station: kill switch, land, follow start, video
  SRC_PHONE_REMOTE = 2,  // iPhone held in hand: sticks (manual flight), tuning
  SRC_PHONE_DRONE = 3,   // iPhone mounted on the drone: vision + follow setpoints
};
#define NUM_CLIENTS 3  // laptop, remote, drone  (index = source - 1)

// ---- header flags -----------------------------------------------------------
#define HDR_FLAG_KILL 0x01  // sender's kill switch is latched -> motors off NOW

// ---- packet types -----------------------------------------------------------
enum PacketType : uint8_t {
  // client -> ESP32
  PKT_HEARTBEAT = 0x01,   // no payload (laptop, 50 Hz)
  PKT_RC = 0x02,          // RcPayload (remote phone, 50 Hz)
  PKT_FOLLOW = 0x03,      // FollowPayload (drone phone, 50 Hz)
  PKT_MOTOR_TEST = 0x04,  // MotorTestPayload (remote phone, props off)
  PKT_COMMAND = 0x10,     // CommandPayload
  PKT_PARAM_GET = 0x11,   // no payload -> ESP32 replies with every PKT_PARAM_INFO
  PKT_PARAM_SET = 0x12,   // ParamSetPayload -> ESP32 replies with that PKT_PARAM_INFO
  // ESP32 -> client
  PKT_TELEMETRY = 0x80,   // TelemetryPayload (20 Hz to every known client)
  PKT_CMD_ACK = 0x81,     // CmdAckPayload (to the sender of a command)
  PKT_PARAM_INFO = 0x82,  // ParamInfoPayload
};

// ---- commands ---------------------------------------------------------------
enum Command : uint8_t {
  CMD_ARM = 1,            // arm in MANUAL (remote phone only)
  CMD_DISARM = 2,         // motors off immediately (also clears a kill latch)
  CMD_LAND = 3,           // arg = LandReason (COMMAND or TARGET_LOST)
  CMD_START_FOLLOW = 4,   // laptop or drone phone: countdown -> arm -> follow
  CMD_CANCEL_FOLLOW = 5,  // abort the countdown
  CMD_CAL_GYRO = 6,
  CMD_CAL_LEVEL = 7,
  CMD_PARAM_SAVE = 8,     // write params to flash (disarmed only)
  CMD_PARAM_RESET = 9,    // restore defaults in RAM (save afterwards to keep)
  CMD_ESC_CAL_HIGH = 10,  // PROPS OFF: all ESC outputs at max pulse
  CMD_ESC_CAL_LOW = 11,   // PROPS OFF: all ESC outputs at min pulse
  CMD_ESC_CAL_EXIT = 12,
  CMD_VIDEO_ON = 13,
  CMD_VIDEO_OFF = 14,
  CMD_KILL = 15,
};

// ---- result codes (command acks, and "why can't I arm right now") ------------
enum Result : uint8_t {
  RES_OK = 0,
  RES_WRONG_STATE = 1,
  RES_NO_LAPTOP = 2,
  RES_NO_PILOT = 3,
  RES_THROTTLE_HIGH = 4,
  RES_NOT_LEVEL = 5,
  RES_IMU_NOT_READY = 6,
  RES_BATTERY_LOW = 7,
  RES_KILL_LATCHED = 8,
  RES_NO_DRONE_PHONE = 9,
  RES_PHONE_NOT_READY = 10,
  RES_ARMED = 11,
  RES_BAD_PARAM = 12,
  RES_NOT_ALLOWED = 13,  // command not accepted from this source
  RES_UNKNOWN = 14,
};

// ---- flight states ------------------------------------------------------------
enum FlightState : uint8_t {
  ST_BOOT = 0,              // IMU start-up and gyro calibration
  ST_DISARMED = 1,
  ST_MOTOR_TEST = 2,
  ST_ESC_CAL = 3,
  ST_FOLLOW_COUNTDOWN = 4,  // still disarmed; arms when the countdown hits 0
  ST_MANUAL = 5,
  ST_FOLLOW = 6,
  ST_FAILSAFE_HOVER = 7,    // level, hover throttle, then LANDING
  ST_LANDING = 8,
  ST_KILLED = 9,            // latched motors-off; DISARM clears it
  ST_IMU_FAULT = 10,
};

// ---- events (why the last landing/disarm happened) ----------------------------
enum LandReason : uint8_t {
  LR_NONE = 0,
  LR_COMMAND = 1,
  LR_LAPTOP_LOST = 2,
  LR_PILOT_LOST = 3,
  LR_DRONE_PHONE_LOST = 4,
  LR_BATTERY = 5,
  LR_FOLLOW_TIMEOUT = 6,
  LR_TARGET_LOST = 7,
  LR_CRASH = 8,
  LR_KILLED = 9,
  LR_AUTO_DISARM = 10,
  LR_TOUCHDOWN = 11,
  LR_DISARM_CMD = 12,
  LR_IMU_FAULT = 13,
};

// ---- follow phases reported by the drone phone ---------------------------------
enum FollowPhase : uint8_t {
  FP_IDLE = 0,
  FP_TAKEOFF = 1,
  FP_ACQUIRE = 2,
  FP_TRACK = 3,
  FP_LOST_HOVER = 4,
  FP_SEARCH = 5,
  FP_LANDING = 6,
};

// ---- payloads -----------------------------------------------------------------
#pragma pack(push, 1)

struct Header {
  uint16_t magic;
  uint8_t version;
  uint8_t type;
  uint8_t source;
  uint8_t flags;
  uint16_t seq;
};

// Sticks, already shaped by the app (deadzone + expo).
struct RcPayload {
  int16_t roll;       // -1000..1000, + = right
  int16_t pitch;      // -1000..1000, + = stick FORWARD (nose down)
  int16_t yaw;        // -1000..1000, + = nose right
  uint16_t throttle;  // 0..1000
};

#define FOLLOW_FLAG_READY 0x01         // camera + sensors running, baro zeroed
#define FOLLOW_FLAG_TRACKING 0x02      // target locked and visible
#define FOLLOW_FLAG_HEIGHT_VALID 0x04  // height_cm / vz_cms are meaningful
#define FOLLOW_FLAG_ACTIVE 0x08        // setpoints are valid and meant to be flown

// Outer-loop output of the phone. Angles use the ESP32 convention:
// roll + = right side down, pitch + = nose UP.
struct FollowPayload {
  int16_t roll_cdeg;      // centi-degrees
  int16_t pitch_cdeg;     // centi-degrees
  int16_t yaw_rate_ddps;  // deci-degrees/s, + = nose right (0 = hold heading)
  uint16_t throttle;      // 0..1000 collective (before tilt compensation)
  int16_t height_cm;      // phone height estimate above take-off point
  int16_t vz_cms;         // vertical speed, + = up
  uint8_t phase;          // FollowPhase
  uint8_t pflags;         // FOLLOW_FLAG_*
};

struct MotorTestPayload {
  uint16_t motor[4];  // 0..1000, capped by the ESP32 at 150 (15 %)
};

struct CommandPayload {
  uint8_t cmd;
  uint8_t arg;
};

struct ParamSetPayload {
  uint8_t id;
  float value;
};

#define TELEM_ARMED 0x01
#define TELEM_KILL_LATCHED 0x02
#define TELEM_IMU_OK 0x04
#define TELEM_GYRO_CAL_OK 0x08
#define TELEM_BATT_WARN 0x10
#define TELEM_BATT_PRESENT 0x20
#define TELEM_VIDEO_ON 0x40
#define TELEM_PARAMS_DIRTY 0x80  // RAM params differ from what is saved

struct TelemetryPayload {
  uint8_t state;        // FlightState
  uint8_t sflags;       // TELEM_*
  uint8_t arm_block;    // Result: why arming would be refused right now (0 = would arm)
  uint8_t last_event;   // LandReason of the last landing / disarm
  int16_t roll_cdeg;    // + = right side down
  int16_t pitch_cdeg;   // + = nose up
  int16_t yaw_cdeg;     // + = nose right (gyro-integrated, drifts slowly)
  uint16_t vbat_mv;
  uint16_t throttle;    // collective actually sent to the mixer, 0..1000
  uint16_t hover_thr;   // learned hover throttle, 0..1000
  uint16_t motor[4];    // 0..1000
  uint16_t loop_hz;
  uint16_t loop_max_us;     // worst control-loop execution time in the last second
  uint16_t loop_jitter_us;  // worst |period - 1000 us| in the last second
  uint8_t link_rate[NUM_CLIENTS];      // packets/s received (laptop, remote, drone)
  uint8_t link_loss[NUM_CLIENTS];      // % lost in the last second
  uint16_t link_age_ms[NUM_CLIENTS];   // ms since the last packet (65535 = never)
  uint16_t follow_left_ds;  // follow-mode time left, deci-seconds
  uint16_t countdown_ds;    // follow countdown left, deci-seconds
  int16_t height_cm;        // echo of the drone phone's estimate
  uint8_t laptop_ip[4];     // so the drone phone can stream video to the laptop
  uint32_t uptime_ms;
};

struct CmdAckPayload {
  uint8_t cmd;
  uint8_t result;  // Result
  uint16_t seq;    // seq of the command packet
};

#define PARAM_NAME_LEN 24
struct ParamInfoPayload {
  uint8_t id;
  uint8_t count;  // total number of params
  float value;
  float min;
  float max;
  char name[PARAM_NAME_LEN];  // zero-terminated
};

#pragma pack(pop)

#define PROTO_OVERHEAD (sizeof(Header) + 2)
#define PROTO_MAX_PACKET 128

static_assert(sizeof(Header) == 8, "header size");
static_assert(sizeof(RcPayload) == 8, "rc size");
static_assert(sizeof(FollowPayload) == 14, "follow size");
static_assert(sizeof(TelemetryPayload) == 56, "telemetry size");
static_assert(sizeof(ParamInfoPayload) == 38, "param info size");

static inline uint16_t crc16_ccitt(const uint8_t* data, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < len; i++) {
    crc ^= (uint16_t)data[i] << 8;
    for (int b = 0; b < 8; b++) crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
  }
  return crc;
}
