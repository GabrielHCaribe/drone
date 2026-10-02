// =============================================================================
//  link.cpp  -  WiFi AP, UDP protocol, telemetry, battery, flash writes
//
//  Runs on core 0 next to the WiFi driver, so network processing never takes
//  time away from the control loop on core 1. Uses a plain lwIP socket with a
//  static receive buffer: no allocation per packet.
// =============================================================================
#include "link.h"
#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <lwip/sockets.h>
#include "config.h"
#include "params.h"
#include "shared.h"

#if __has_include("secrets.h")
#include "secrets.h"
#else
#error "Missing secrets.h: copy secrets_template.h to secrets.h and set WIFI_PASSWORD (see docs/ESP32_UPLOAD.md)"
#endif

namespace {

struct Client {
  bool known;
  sockaddr_in addr;
  int64_t last_us;
  uint16_t last_seq;
  uint32_t rx_window;
  uint32_t lost_window;
  uint8_t rate;  // packets/s, last window
  uint8_t loss;  // %, last window
};

int s_sock = -1;
Client s_clients[NUM_CLIENTS];
uint16_t s_tx_seq = 0;
uint8_t s_rx_buf[256];
uint8_t s_tx_buf[PROTO_MAX_PACKET];
float s_vbat = 0;
bool s_vbat_init = false;

// -------------------------------------------------------------------- sending
void send_packet(const sockaddr_in& to, uint8_t type, const void* payload, size_t len) {
  if (s_sock < 0 || len + PROTO_OVERHEAD > sizeof(s_tx_buf)) return;
  Header h;
  h.magic = PROTO_MAGIC;
  h.version = PROTO_VERSION;
  h.type = type;
  h.source = SRC_ESP32;
  h.flags = 0;
  h.seq = s_tx_seq++;
  memcpy(s_tx_buf, &h, sizeof(h));
  if (len) memcpy(s_tx_buf + sizeof(h), payload, len);
  uint16_t crc = crc16_ccitt(s_tx_buf, sizeof(h) + len);
  memcpy(s_tx_buf + sizeof(h) + len, &crc, 2);
  sendto(s_sock, s_tx_buf, sizeof(h) + len + 2, 0, (const sockaddr*)&to, sizeof(to));
}

void send_param_info(const sockaddr_in& to, uint8_t id) {
  if (id >= PARAM_COUNT) return;
  ParamInfoPayload p;
  memset(&p, 0, sizeof(p));
  p.id = id;
  p.count = PARAM_COUNT;
  p.value = params_get(id);
  p.min = PARAM_DEFS[id].min;
  p.max = PARAM_DEFS[id].max;
  strncpy(p.name, PARAM_DEFS[id].name, PARAM_NAME_LEN - 1);
  send_packet(to, PKT_PARAM_INFO, &p, sizeof(p));
}

void send_ack(const sockaddr_in& to, uint8_t cmd, uint8_t result, uint16_t seq) {
  CmdAckPayload a = {cmd, result, seq};
  send_packet(to, PKT_CMD_ACK, &a, sizeof(a));
}

inline int16_t to_i16(float x) {
  if (x > 32767.0f) return 32767;
  if (x < -32768.0f) return -32768;
  return (int16_t)lrintf(x);
}
inline uint16_t to_u16(float x) {
  if (x > 65535.0f) return 65535;
  if (x < 0.0f) return 0;
  return (uint16_t)lrintf(x);
}

void send_telemetry(int64_t now) {
  ControlStatus st;
  shared_read_status(st);
  const LinkInputs& in = shared_inputs_unlocked();

  TelemetryPayload t;
  memset(&t, 0, sizeof(t));
  t.state = st.state;
  uint8_t f = 0;
  if (st.armed) f |= TELEM_ARMED;
  if (st.state == ST_KILLED || g_kill_request) f |= TELEM_KILL_LATCHED;
  if (st.imu_ok) f |= TELEM_IMU_OK;
  if (st.gyro_cal_ok) f |= TELEM_GYRO_CAL_OK;
  if (in.batt_present && in.vbat < params_get(P_BATT_WARN_V)) f |= TELEM_BATT_WARN;
  if (in.batt_present) f |= TELEM_BATT_PRESENT;
  if (g_video_on) f |= TELEM_VIDEO_ON;
  if (params_dirty()) f |= TELEM_PARAMS_DIRTY;
  t.sflags = f;
  t.arm_block = st.arm_block;
  t.last_event = st.last_event;
  t.roll_cdeg = to_i16(st.roll * 100.0f);
  t.pitch_cdeg = to_i16(st.pitch * 100.0f);
  float yaw = fmodf(st.yaw, 360.0f);
  if (yaw > 180.0f) yaw -= 360.0f;
  if (yaw < -180.0f) yaw += 360.0f;
  t.yaw_cdeg = to_i16(yaw * 100.0f);
  t.vbat_mv = to_u16(in.vbat * 1000.0f);
  t.throttle = to_u16(st.throttle * 1000.0f);
  t.hover_thr = to_u16(st.hover_thr * 1000.0f);
  for (int i = 0; i < 4; i++) t.motor[i] = to_u16(st.motor[i] * 1000.0f);
  t.loop_hz = st.loop_hz;
  t.loop_max_us = st.loop_max_us;
  t.loop_jitter_us = st.loop_jitter_us;
  for (int i = 0; i < NUM_CLIENTS; i++) {
    t.link_rate[i] = s_clients[i].rate;
    t.link_loss[i] = s_clients[i].loss;
    int64_t age = s_clients[i].known ? (now - s_clients[i].last_us) / 1000 : 65535;
    t.link_age_ms[i] = age > 65535 ? 65535 : (uint16_t)age;
  }
  t.follow_left_ds = to_u16(st.follow_left_s * 10.0f);
  t.countdown_ds = to_u16(st.countdown_s * 10.0f);
  t.height_cm = in.follow.height_cm;
  if (s_clients[CL_LAPTOP].known) memcpy(t.laptop_ip, &s_clients[CL_LAPTOP].addr.sin_addr.s_addr, 4);
  t.uptime_ms = (uint32_t)(now / 1000);

  for (int i = 0; i < NUM_CLIENTS; i++) {
    // Keep talking to a client for 3 s after its last packet.
    if (s_clients[i].known && now - s_clients[i].last_us < 3000000) send_packet(s_clients[i].addr, PKT_TELEMETRY, &t, sizeof(t));
  }
}

// -------------------------------------------------------------------- receiving
void handle_packet(const uint8_t* buf, int len, const sockaddr_in& from, int64_t now) {
  if (len < (int)PROTO_OVERHEAD) return;
  Header h;
  memcpy(&h, buf, sizeof(h));
  if (h.magic != PROTO_MAGIC || h.version != PROTO_VERSION) return;
  uint16_t crc;
  memcpy(&crc, buf + len - 2, 2);
  if (crc != crc16_ccitt(buf, len - 2)) return;
  int ci = client_index(h.source);
  if (ci < 0) return;
  const uint8_t* pl = buf + sizeof(Header);
  int plen = len - (int)PROTO_OVERHEAD;

  // The kill flag works on EVERY packet type from every client, and is honoured
  // even if the packet would be dropped as a duplicate below.
  if (h.flags & HDR_FLAG_KILL) g_kill_request = true;

  // Sequence check: drop duplicates / reordered packets, count gaps as loss.
  Client& c = s_clients[ci];
  bool idle = !c.known || (now - c.last_us) > 1000000;
  int16_t gap = (int16_t)(h.seq - c.last_seq);
  if (!idle && gap <= 0) return;
  if (!idle && gap > 1) c.lost_window += (uint32_t)(gap - 1);
  c.last_seq = h.seq;
  c.known = true;
  c.addr = from;
  c.last_us = now;
  c.rx_window++;

  LinkInputs& in = shared_inputs_unlocked();
  in.last_us[ci] = now;

  switch (h.type) {
    case PKT_HEARTBEAT:
      break;

    case PKT_RC:
      if (h.source != SRC_PHONE_REMOTE || plen != sizeof(RcPayload)) break;
      memcpy(&in.rc, pl, sizeof(RcPayload));
      in.rc_us = now;
      break;

    case PKT_FOLLOW:
      if (h.source != SRC_PHONE_DRONE || plen != sizeof(FollowPayload)) break;
      memcpy(&in.follow, pl, sizeof(FollowPayload));
      in.follow_us = now;
      if (in.follow.pflags & FOLLOW_FLAG_ACTIVE) in.follow_active_us = now;
      in.follow_count++;
      break;

    case PKT_MOTOR_TEST:
      if (h.source != SRC_PHONE_REMOTE || plen != sizeof(MotorTestPayload)) break;
      memcpy(&in.motor_test, pl, sizeof(MotorTestPayload));
      in.motor_test_us = now;
      break;

    case PKT_COMMAND: {
      if (plen != sizeof(CommandPayload)) break;
      CommandPayload cp;
      memcpy(&cp, pl, sizeof(cp));
      ControlStatus st;
      shared_read_status(st);
      bool disarmed = st.state == ST_DISARMED;
      switch (cp.cmd) {
        // Handled here (core 0): flash writes and link settings.
        case CMD_PARAM_SAVE:
          if (!disarmed) { send_ack(from, cp.cmd, RES_WRONG_STATE, h.seq); break; }
          send_ack(from, cp.cmd, params_save() ? RES_OK : RES_UNKNOWN, h.seq);
          break;
        case CMD_PARAM_RESET:
          if (!disarmed) { send_ack(from, cp.cmd, RES_WRONG_STATE, h.seq); break; }
          params_reset_defaults();
          send_ack(from, cp.cmd, RES_OK, h.seq);
          break;
        case CMD_VIDEO_ON:
        case CMD_VIDEO_OFF:
          g_video_on = cp.cmd == CMD_VIDEO_ON;
          send_ack(from, cp.cmd, RES_OK, h.seq);
          break;
        case CMD_KILL:
          g_kill_request = true;  // immediate, no queue
          send_ack(from, cp.cmd, RES_OK, h.seq);
          break;
        default: {
          CmdMsg m = {cp.cmd, cp.arg, h.source, h.seq};
          if (!shared_push_cmd(m)) send_ack(from, cp.cmd, RES_UNKNOWN, h.seq);
          break;
        }
      }
      break;
    }

    case PKT_PARAM_GET:
      for (uint8_t i = 0; i < PARAM_COUNT; i++) send_param_info(from, i);
      break;

    case PKT_PARAM_SET: {
      if (plen != sizeof(ParamSetPayload)) break;
      ParamSetPayload ps;
      memcpy(&ps, pl, sizeof(ps));
      params_set(ps.id, ps.value);
      send_param_info(from, ps.id);
      break;
    }

    default:
      break;
  }
}

// -------------------------------------------------------------------- battery
void update_battery() {
  // 47k / 10k divider -> 12.6 V reads 2.21 V at the pin (inside the ADC's linear range).
  uint32_t mv = analogReadMilliVolts(PIN_BATTERY_ADC);
  float v = mv * 0.001f * params_get(P_BATT_SCALE);
  if (!s_vbat_init) {
    s_vbat = v;
    s_vbat_init = true;
  } else {
    s_vbat += (v - s_vbat) * 0.05f;  // ~1 s time constant at 50 Hz
  }
  LinkInputs& in = shared_inputs_unlocked();
  in.vbat = s_vbat;
  // Below 5 V there is no flight battery (ESP32 on USB, or no divider fitted).
  in.batt_present = s_vbat > 5.0f;
}

// -------------------------------------------------------------------- status LED
void update_led(int64_t now) {
  ControlStatus st;
  shared_read_status(st);
  uint32_t ms = (uint32_t)(now / 1000);
  bool on;
  switch (st.state) {
    case ST_BOOT: on = (ms / 100) % 2; break;                          // fast blink: calibrating, keep still
    case ST_DISARMED: on = (ms % 1000) < 100; break;                   // short flash every second
    case ST_KILLED:
    case ST_IMU_FAULT: on = (ms / 50) % 2; break;                      // very fast: fault / killed
    case ST_FOLLOW_COUNTDOWN: on = (ms / 250) % 2; break;
    default: on = true; break;                                         // armed / spinning: solid
  }
  digitalWrite(PIN_STATUS_LED, on ? HIGH : LOW);
}

// -------------------------------------------------------------------- task
void link_task(void*) {
  // WiFi is started from this task so its interrupts are allocated on core 0.
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  WiFi.softAP(WIFI_SSID, WIFI_PASSWORD, WIFI_CHANNEL, 0, WIFI_MAX_CLIENTS);
  esp_wifi_set_ps(WIFI_PS_NONE);  // no power save: lowest latency

  s_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  sockaddr_in local;
  memset(&local, 0, sizeof(local));
  local.sin_family = AF_INET;
  local.sin_port = htons(UDP_PORT);
  local.sin_addr.s_addr = htonl(INADDR_ANY);
  bind(s_sock, (sockaddr*)&local, sizeof(local));
  timeval tv = {0, 2000};  // 2 ms receive timeout keeps the housekeeping ticking
  setsockopt(s_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

  Serial.printf("[link] AP \"%s\" on channel %d, 192.168.4.1:%d\n", WIFI_SSID, WIFI_CHANNEL, UDP_PORT);

  int64_t next_telem = 0, next_batt = 0, next_window = 0, next_led = 0;
  for (;;) {
    sockaddr_in from;
    socklen_t flen = sizeof(from);
    int n = recvfrom(s_sock, s_rx_buf, sizeof(s_rx_buf), 0, (sockaddr*)&from, &flen);
    int64_t now = esp_timer_get_time();
    bool dirty = false;
    if (n > 0) {
      handle_packet(s_rx_buf, n, from, now);
      dirty = true;
      // Drain anything else already waiting before publishing.
      for (int k = 0; k < 8; k++) {
        flen = sizeof(from);
        n = recvfrom(s_sock, s_rx_buf, sizeof(s_rx_buf), MSG_DONTWAIT, (sockaddr*)&from, &flen);
        if (n <= 0) break;
        handle_packet(s_rx_buf, n, from, now);
      }
    }

    if (now >= next_batt) {
      next_batt = now + 20000;
      update_battery();
      dirty = true;
    }
    if (dirty) shared_write_inputs(shared_inputs_unlocked());

    // Acks from the control task
    AckMsg am;
    while (shared_pop_ack(am)) {
      int ci = client_index(am.source);
      if (ci >= 0 && s_clients[ci].known) send_ack(s_clients[ci].addr, am.cmd, am.result, am.seq);
    }

    if (now >= next_telem) {
      next_telem = now + 1000000 / TELEMETRY_HZ;
      send_telemetry(now);
    }

    if (now >= next_window) {
      next_window = now + 1000000;
      for (int i = 0; i < NUM_CLIENTS; i++) {
        Client& c = s_clients[i];
        uint32_t total = c.rx_window + c.lost_window;
        c.rate = c.rx_window > 255 ? 255 : (uint8_t)c.rx_window;
        c.loss = total ? (uint8_t)((c.lost_window * 100) / total) : 0;
        c.rx_window = 0;
        c.lost_window = 0;
      }
    }

    if (now >= next_led) {
      next_led = now + 20000;
      update_led(now);
    }

    // Flash writes only while disarmed (they stall both cores for a few ms).
    if (g_hover_save_request) {
      ControlStatus st;
      shared_read_status(st);
      if (st.state == ST_DISARMED) {
        params_save_hover();
        g_hover_save_request = false;
      }
    }
  }
}

}  // namespace

void link_start() {
  memset(s_clients, 0, sizeof(s_clients));
  pinMode(PIN_STATUS_LED, OUTPUT);
  analogSetPinAttenuation(PIN_BATTERY_ADC, ADC_11db);
  xTaskCreatePinnedToCore(link_task, "link", 8192, nullptr, LINK_TASK_PRIORITY, nullptr, LINK_TASK_CORE);
}
