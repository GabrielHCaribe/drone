// =============================================================================
//  secrets_template.h
//
//  1. Copy this file to "secrets.h" in the same folder.
//  2. Put your WiFi password in it (8-63 characters).
//  3. Use the SAME password for the GitHub secret DRONE_WIFI_PASSWORD so the
//     iPhone app can join the drone network.
//
//  secrets.h is listed in .gitignore and is never committed. The repository is
//  public, and anyone who knows this password can join the drone's network
//  and send it commands.
// =============================================================================
#pragma once

#define WIFI_PASSWORD "change-me-please"
