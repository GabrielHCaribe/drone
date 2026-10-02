#include "shared.h"
#include "config.h"

volatile bool g_kill_request = false;
volatile bool g_hover_save_request = false;
volatile bool g_video_on = VIDEO_DEFAULT_ON;

static portMUX_TYPE s_in_mux = portMUX_INITIALIZER_UNLOCKED;
static portMUX_TYPE s_st_mux = portMUX_INITIALIZER_UNLOCKED;
static LinkInputs s_inputs;      // published copy
static LinkInputs s_inputs_wip;  // link task's working copy
static ControlStatus s_status;

static QueueHandle_t s_cmd_q = nullptr;
static QueueHandle_t s_ack_q = nullptr;

void shared_init() {
  memset(&s_inputs, 0, sizeof(s_inputs));
  memset(&s_inputs_wip, 0, sizeof(s_inputs_wip));
  memset(&s_status, 0, sizeof(s_status));
  s_cmd_q = xQueueCreate(16, sizeof(CmdMsg));
  s_ack_q = xQueueCreate(16, sizeof(AckMsg));
}

LinkInputs& shared_inputs_unlocked() { return s_inputs_wip; }

void shared_write_inputs(const LinkInputs& in) {
  portENTER_CRITICAL(&s_in_mux);
  s_inputs = in;
  portEXIT_CRITICAL(&s_in_mux);
}

void shared_read_inputs(LinkInputs& out) {
  portENTER_CRITICAL(&s_in_mux);
  out = s_inputs;
  portEXIT_CRITICAL(&s_in_mux);
}

void shared_write_status(const ControlStatus& st) {
  portENTER_CRITICAL(&s_st_mux);
  s_status = st;
  portEXIT_CRITICAL(&s_st_mux);
}

void shared_read_status(ControlStatus& out) {
  portENTER_CRITICAL(&s_st_mux);
  out = s_status;
  portEXIT_CRITICAL(&s_st_mux);
}

bool shared_push_cmd(const CmdMsg& m) { return xQueueSend(s_cmd_q, &m, 0) == pdTRUE; }
bool shared_pop_cmd(CmdMsg& m) { return xQueueReceive(s_cmd_q, &m, 0) == pdTRUE; }
bool shared_push_ack(const AckMsg& m) { return xQueueSend(s_ack_q, &m, 0) == pdTRUE; }
bool shared_pop_ack(AckMsg& m) { return xQueueReceive(s_ack_q, &m, 0) == pdTRUE; }
