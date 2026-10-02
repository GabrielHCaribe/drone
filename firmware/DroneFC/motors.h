// =============================================================================
//  motors.h  -  ESC outputs (LEDC hardware PWM) and the Quad-X mixer
// =============================================================================
#pragma once
#include <stdint.h>

void motors_init();                      // outputs ESC_PWM_MIN_US on all four channels
void motors_write(const float cmd[4]);   // 0..1 per motor -> pulse width
void motors_write_us(uint16_t us);       // same pulse on all motors (stop / ESC calibration)
void motors_stop();                      // ESC_PWM_MIN_US on all motors

// Quad-X mixer (Betaflight motor order, see config.h).
// throttle 0..1, roll/pitch/yaw in "fraction of motor range" (PID outputs).
// When airborne, attitude authority wins over collective if a motor would
// saturate (collective is shifted, then corrections are scaled down).
// On the ground each motor is simply clamped, so a resting drone never revs up.
// Writes 0..1 into out[4] with idle as the floor.
void mixer_mix(float throttle, float roll, float pitch, float yaw, float idle, bool airborne, float out[4]);
