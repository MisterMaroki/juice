#include <IOKit/IOKitLib.h>
#include <string.h>
#include "smc.h"

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    char result, status, data8; UInt32 data32; unsigned char bytes[32];
} SMCKeyData;

static io_connect_t conn = 0;

static int call(SMCKeyData *in, SMCKeyData *out) {
    size_t n = sizeof(SMCKeyData);
    return (IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData), out, &n) == KERN_SUCCESS && out->result == 0) ? 0 : -1;
}

static int read_key(const char *k, unsigned char *buf, UInt32 want) {
    if (!conn) {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!svc) return -1;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
        IOObjectRelease(svc);
        if (kr != KERN_SUCCESS) { conn = 0; return -1; }
    }
    UInt32 key = ((UInt32)k[0] << 24) | ((UInt32)k[1] << 16) | ((UInt32)k[2] << 8) | (UInt32)k[3];
    SMCKeyData in = {0}, out = {0};
    in.key = key; in.data8 = 9;                     // key info
    if (call(&in, &out) || out.keyInfo.dataSize != want) return -1;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key; in.keyInfo.dataSize = want; in.data8 = 5;   // read bytes
    if (call(&in, &out)) return -1;
    memcpy(buf, out.bytes, want);
    return 0;
}

double juice_smc_float(const char *k) {
    unsigned char b[4]; float f;
    if (read_key(k, b, 4)) return -1e9;
    memcpy(&f, b, 4);
    return (double)f;
}

double juice_smc_si16(const char *k) {
    unsigned char b[2]; SInt16 v;
    if (read_key(k, b, 2)) return -1e9;
    memcpy(&v, b, 2);
    return (double)v;
}
