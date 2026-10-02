#include "params.h"
#include <Arduino.h>
#include <Preferences.h>

const ParamDef PARAM_DEFS[PARAM_COUNT] = {
#define X_DEF(id, name, def, mn, mx) {name, def, mn, mx},
    PARAM_LIST(X_DEF)
#undef X_DEF
};

static Params g_params;
static volatile uint32_t g_version = 1;
static bool g_dirty = false;
static portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;

// Bump when the parameter list changes so stale flash data is ignored.
static const uint32_t PARAM_STORE_MAGIC = 0x50440000u | PARAM_COUNT;

struct StoredParams {
  uint32_t magic;
  float v[PARAM_COUNT];
};

void params_reset_defaults() {
  portENTER_CRITICAL(&g_mux);
  for (int i = 0; i < PARAM_COUNT; i++) g_params.v[i] = PARAM_DEFS[i].def;
  g_version = g_version + 1;
  g_dirty = true;
  portEXIT_CRITICAL(&g_mux);
}

void params_init() {
  for (int i = 0; i < PARAM_COUNT; i++) g_params.v[i] = PARAM_DEFS[i].def;
  Preferences prefs;
  if (prefs.begin("fc", true)) {
    StoredParams sp;
    size_t n = prefs.getBytes("params", &sp, sizeof(sp));
    if (n == sizeof(sp) && sp.magic == PARAM_STORE_MAGIC) {
      for (int i = 0; i < PARAM_COUNT; i++) {
        float x = sp.v[i];
        if (isfinite(x) && x >= PARAM_DEFS[i].min && x <= PARAM_DEFS[i].max) g_params.v[i] = x;
      }
    }
    float hover = prefs.getFloat("hover", NAN);
    if (isfinite(hover) && hover >= PARAM_DEFS[P_HOVER_THR].min && hover <= PARAM_DEFS[P_HOVER_THR].max)
      g_params.v[P_HOVER_THR] = hover;
    prefs.end();
  }
  g_dirty = false;
  g_version = g_version + 1;
}

bool params_set(uint8_t id, float value) {
  if (id >= PARAM_COUNT || !isfinite(value)) return false;
  if (value < PARAM_DEFS[id].min) value = PARAM_DEFS[id].min;
  if (value > PARAM_DEFS[id].max) value = PARAM_DEFS[id].max;
  portENTER_CRITICAL(&g_mux);
  if (g_params.v[id] != value) {
    g_params.v[id] = value;
    g_version = g_version + 1;
    g_dirty = true;
  }
  portEXIT_CRITICAL(&g_mux);
  return true;
}

float params_get(uint8_t id) {
  if (id >= PARAM_COUNT) return 0.0f;
  return g_params.v[id];
}

bool params_save() {
  StoredParams sp;
  sp.magic = PARAM_STORE_MAGIC;
  portENTER_CRITICAL(&g_mux);
  memcpy(sp.v, g_params.v, sizeof(sp.v));
  portEXIT_CRITICAL(&g_mux);
  Preferences prefs;
  if (!prefs.begin("fc", false)) return false;
  bool ok = prefs.putBytes("params", &sp, sizeof(sp)) == sizeof(sp);
  ok = ok && prefs.putFloat("hover", sp.v[P_HOVER_THR]) == sizeof(float);
  prefs.end();
  if (ok) g_dirty = false;
  return ok;
}

uint32_t params_version() { return g_version; }

void params_snapshot(Params& out) {
  portENTER_CRITICAL(&g_mux);
  memcpy(out.v, g_params.v, sizeof(out.v));
  portEXIT_CRITICAL(&g_mux);
}

bool params_dirty() { return g_dirty; }

bool params_save_hover() {
  Preferences prefs;
  if (!prefs.begin("fc", false)) return false;
  bool ok = prefs.putFloat("hover", g_params.v[P_HOVER_THR]) == sizeof(float);
  prefs.end();
  return ok;
}

void params_set_learned(uint8_t id, float value) {
  if (id >= PARAM_COUNT || !isfinite(value)) return;
  if (value < PARAM_DEFS[id].min) value = PARAM_DEFS[id].min;
  if (value > PARAM_DEFS[id].max) value = PARAM_DEFS[id].max;
  portENTER_CRITICAL(&g_mux);
  g_params.v[id] = value;
  g_version = g_version + 1;
  portEXIT_CRITICAL(&g_mux);
}
