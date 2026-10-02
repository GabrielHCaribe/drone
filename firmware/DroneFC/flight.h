// =============================================================================
//  flight.h  -  the 1 kHz control task (runs alone on core 1)
// =============================================================================
#pragma once

// Creates the control task pinned to CONTROL_TASK_CORE. Call after imu_init(),
// motors_init(), params_init() and shared_init().
void flight_start(bool imu_ok);
