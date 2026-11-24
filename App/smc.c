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

double juice_smc_float(const char *k) {
    if (!conn) {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!svc) return -1;
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
        IOObjectRelease(svc);
        if (kr != KERN_SUCCESS) { conn = 0; return -1; }
    }
    SMCKeyData in = {0}, out = {0};
    in.key = ((UInt32)k[0] << 24) | ((UInt32)k[1] << 16) | ((UInt32)k[2] << 8) | (UInt32)k[3];
    in.data8 = 9;                                   // key info
    if (call(&in, &out) || out.keyInfo.dataSize != 4) return -1;
    memset(&in, 0, sizeof in); 
    in.key = ((UInt32)k[0] << 24) | ((UInt32)k[1] << 16) | ((UInt32)k[2] << 8) | (UInt32)k[3];
    in.keyInfo.dataSize = 4;
    in.data8 = 5;                                   // read bytes
    memset(&out, 0, sizeof out);
    if (call(&in, &out)) return -1;
    float f; memcpy(&f, out.bytes, 4);
    return (double)f;
}
