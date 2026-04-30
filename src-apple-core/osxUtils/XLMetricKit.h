#pragma once

// Apple MetricKit collector — shared between macOS and iOS.
//
// Subscribes to MXMetricManager and writes each delivered metric /
// diagnostic payload to `diagnosticsDir` as a JSON file. The payloads
// arrive ~24h after the events that produced them, so the directory
// builds up between launches; consumers (desktop crash zip, iPad
// "Package Logs") fold whatever's there into the next bundle and
// optionally delete after upload.
//
// No-op on older OS versions (pre-macOS 12 / pre-iOS 13). Safe to
// call multiple times; only the first call subscribes.

#include <string>

void StartMetricKitCollection(const std::string& diagnosticsDir);
