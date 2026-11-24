// juice-helper: tiny root helper for Juice.
//   juice-helper status              print battery %, limit, charging-inhibit state (no root needed)
//   juice-helper read KEY            print raw SMC key bytes (no root needed)
//   juice-helper powermode 0|1|2     0 = automatic, 1 = low power, 2 = high power (root)
//   juice-helper setlimit N          N = 20..100, 100 = no limit (root)
//   juice-helper daemon              enforce the charge limit (run by launchd as root)

#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LIMIT_DIR  "/Library/Application Support/Juice"
#define LIMIT_FILE LIMIT_DIR "/limit"
#define RESUME_GAP 3   // resume charging once battery drops this far below the limit

// ---------- SMC ----------
#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    char result, status, data8; UInt32 data32; unsigned char bytes[32];
} SMCKeyData;

static io_connect_t smc_conn = 0;

static int smc_open(void) {
    if (smc_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &smc_conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? 0 : -1;
}

static UInt32 fourcc(const char *k) {
    return ((UInt32)k[0] << 24) | ((UInt32)k[1] << 16) | ((UInt32)k[2] << 8) | (UInt32)k[3];
}

static int smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    kern_return_t kr = IOConnectCallStructMethod(smc_conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData), out, &outSize);
    if (kr != KERN_SUCCESS || out->result != 0) return -1;
    return 0;
}

static int smc_keyinfo(const char *key, SMCKeyInfo *info) {
    if (smc_open()) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out)) return -1;
    *info = out.keyInfo;
    return 0;
}

static int smc_read(const char *key, unsigned char *buf, UInt32 *size) {
    SMCKeyInfo info;
    if (smc_keyinfo(key, &info)) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out)) return -1;
    *size = info.dataSize;
    memcpy(buf, out.bytes, info.dataSize);
    return 0;
}

static int smc_write(const char *key, const unsigned char *buf, UInt32 size) {
    SMCKeyInfo info;
    if (smc_keyinfo(key, &info)) return -1;
    if (info.dataSize != size) return -1;
    SMCKeyData in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, buf, size);
    return smc_call(&in, &out);
}

// ---------- charging inhibit (newer firmware: CHTE, older: CH0B/CH0C) ----------
static int has_key(const char *k) { SMCKeyInfo i; return smc_keyinfo(k, &i) == 0; }

static int charging_inhibited(void) {
    unsigned char b[32]; UInt32 n;
    if (has_key("CHTE")) {
        if (smc_read("CHTE", b, &n)) return -1;
        return (b[0] | b[1] | b[2] | b[3]) != 0;
    }
    if (smc_read("CH0B", b, &n)) return -1;
    return b[0] != 0;
}

static int set_charging_inhibited(int inhibit) {
    if (has_key("CHTE")) {
        unsigned char v[4] = { inhibit ? 1 : 0, 0, 0, 0 };
        return smc_write("CHTE", v, 4);
    }
    unsigned char v = inhibit ? 0x02 : 0x00;
    int a = smc_write("CH0B", &v, 1);
    int b = smc_write("CH0C", &v, 1);
    return (a || b) ? -1 : 0;
}

// ---------- battery ----------
static int battery_percent(int *on_ac) {
    int pct = -1;
    *on_ac = 0;
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return -1;
    CFStringRef type = IOPSGetProvidingPowerSourceType(blob);
    if (type && CFStringCompare(type, CFSTR(kIOPMACPowerKey), 0) == kCFCompareEqualTo) *on_ac = 1;
    CFArrayRef list = IOPSCopyPowerSourcesList(blob);
    if (list) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
            if (!d) continue;
            CFNumberRef cur = CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey));
            CFNumberRef max = CFDictionaryGetValue(d, CFSTR(kIOPSMaxCapacityKey));
            int c = 0, m = 100;
            if (cur) CFNumberGetValue(cur, kCFNumberIntType, &c); else continue;
            if (max) CFNumberGetValue(max, kCFNumberIntType, &m);
            pct = m > 0 ? (c * 100) / m : c;
            break;
        }
        CFRelease(list);
    }
    CFRelease(blob);
    return pct;
}

static int read_limit(void) {
    FILE *f = fopen(LIMIT_FILE, "r");
    if (!f) return 100;
    int v = 100;
    if (fscanf(f, "%d", &v) != 1) v = 100;
    fclose(f);
    if (v < 20 || v > 100) v = 100;
    return v;
}

static void logmsg(const char *fmt, int a, int b, int c) {
    time_t t = time(NULL); char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(stderr, "%s ", ts); fprintf(stderr, fmt, a, b, c); fputc('\n', stderr);
}

// Decide and apply. Stateless: current SMC state is the hysteresis memory.
static void evaluate(void) {
    int on_ac, pct = battery_percent(&on_ac);
    int limit = read_limit();
    int inhibited = charging_inhibited();
    if (pct < 0 || inhibited < 0) return;
    int want;
    if (limit >= 100)                    want = 0;
    else if (pct >= limit)               want = 1;
    else if (pct <= limit - RESUME_GAP)  want = 0;
    else                                 want = inhibited;
    if (want != inhibited) {
        if (set_charging_inhibited(want) == 0)
            logmsg(want ? "battery %d%%, limit %d%% -> charging paused%.0d" : "battery %d%%, limit %d%% -> charging resumed%.0d", pct, limit, 0);
        else
            logmsg("failed to set charging inhibit (pct %d, limit %d, want %d)", pct, limit, want);
    }
}

// ---------- daemon ----------
static io_connect_t root_port;

static void power_cb(void *ref, io_service_t svc, natural_t msg, void *arg) {
    (void)ref; (void)svc;
    switch (msg) {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(root_port, (long)arg);
            break;
        case kIOMessageSystemWillSleep:
            // Don't let it charge past the limit while asleep: pause charging for the night.
            if (read_limit() < 100) set_charging_inhibited(1);
            IOAllowPowerChange(root_port, (long)arg);
            break;
        case kIOMessageSystemHasPoweredOn:
            evaluate();
            break;
    }
}

static void timer_cb(CFRunLoopTimerRef t, void *info) { (void)t; (void)info; evaluate(); }

static void on_term(void) {
    set_charging_inhibited(0);  // never leave the Mac unable to charge
    exit(0);
}

static int run_daemon(void) {
    setvbuf(stderr, NULL, _IOLBF, 0);
    if (smc_open()) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }

    IONotificationPortRef port;
    io_object_t notifier;
    root_port = IORegisterForSystemPower(NULL, &port, power_cb, &notifier);
    if (root_port) CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);

    int sigs[] = { SIGTERM, SIGINT };
    for (int i = 0; i < 2; i++) {
        signal(sigs[i], SIG_IGN);
        dispatch_source_t s = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(s, ^{ on_term(); });
        dispatch_resume(s);
    }

    CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 20.0, 0, 0, timer_cb, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
    fprintf(stderr, "juice-helper daemon started (key %s)\n", has_key("CHTE") ? "CHTE" : "CH0B/CH0C");
    CFRunLoopRun();
    return 0;
}

// ---------- main ----------
static int usage(void) {
    fprintf(stderr, "usage: juice-helper status | read KEY | powermode 0|1|2 | setlimit 20..100 | daemon\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 2) return usage();
    const char *cmd = argv[1];

    if (!strcmp(cmd, "status")) {
        int on_ac, pct = battery_percent(&on_ac);
        printf("battery=%d\nac=%d\nlimit=%d\ninhibited=%d\n", pct, on_ac, read_limit(), charging_inhibited());
        return 0;
    }
    if (!strcmp(cmd, "read") && argc == 3 && strlen(argv[2]) == 4) {
        unsigned char b[32]; UInt32 n;
        if (smc_read(argv[2], b, &n)) { printf("%s: not found\n", argv[2]); return 1; }
        printf("%s:", argv[2]); for (UInt32 i = 0; i < n; i++) printf(" %02x", b[i]); printf("\n");
        return 0;
    }
    if (!strcmp(cmd, "daemon")) return run_daemon();

    if (geteuid() != 0) { fprintf(stderr, "must run as root\n"); return 1; }

    if (!strcmp(cmd, "powermode") && argc == 3) {
        const char *m = argv[2];
        if (strcmp(m, "0") && strcmp(m, "1") && strcmp(m, "2")) return usage();
        execl("/usr/bin/pmset", "pmset", "-a", "powermode", m, (char *)NULL);
        perror("pmset"); return 1;
    }
    if (!strcmp(cmd, "setlimit") && argc == 3) {
        char *end; long v = strtol(argv[2], &end, 10);
        if (*end || v < 20 || v > 100) return usage();
        mkdir(LIMIT_DIR, 0755);
        FILE *f = fopen(LIMIT_FILE, "w");
        if (!f) { perror(LIMIT_FILE); return 1; }
        fprintf(f, "%ld\n", v); fclose(f);
        evaluate();
        return 0;
    }
    return usage();
}
