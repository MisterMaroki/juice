// Reads a 4-byte float SMC sensor (e.g. "PSTR" system total watts, "PDTR" charger-in watts). Returns -1 on failure.
double juice_smc_float(const char *key);
