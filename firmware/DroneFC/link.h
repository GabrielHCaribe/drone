// =============================================================================
//  link.h  -  WiFi access point + UDP link task (runs on core 0 with the WiFi stack)
// =============================================================================
#pragma once

void link_start();  // creates the link task pinned to LINK_TASK_CORE
