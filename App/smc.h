// Live SMC sensors. Both return -1e9 on failure.
double juice_smc_float(const char *key);   // 4-byte float, e.g. "PSTR" system watts, "PDTR" charger-in watts
double juice_smc_si16(const char *key);    // signed 16-bit, e.g. "B0AC" battery mA (+ charging), "B0AV" battery mV
