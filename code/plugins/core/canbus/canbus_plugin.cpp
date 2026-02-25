#include <stdio.h>
#include <math.h>
#include <vector>
#include <string>
#include <mutex>
#include <dirent.h>
#include <algorithm>
#include <sys/stat.h>
#include <time.h>

#include "../../../../public_sdk_core/ruby_core_plugin.h"
#include "../../../../public_sdk_core/utils/core_plugins_utils.h"
#include "dbc_parser.h"
#include "socketcan.h"
#include "influx_client.h"

// Constants
#define PACKET_TYPE_CAN_FRAME 0x01
#define PACKET_TYPE_CONFIG    0x02

#define SETTING_DBC_FILE 0
#define SETTING_INFLUX_HOST 1
#define SETTING_INFLUX_PORT 2
#define SETTING_INFLUX_ORG 3
#define SETTING_INFLUX_BUCKET 4
#define SETTING_INFLUX_TOKEN 5
#define SETTING_SENSORS_START 6

const char* g_szPluginName = "CAN Bus Telemetry";
const char* g_szUID = "CANBUS-TELEM-V1.0";

// Global State
u32 g_uRuntimeLocation = 0;
u32 g_uAllocatedCapabilities = 0;

DbcParser g_Parser;
SocketCAN g_Socket;
InfluxClient g_Influx;
std::vector<std::string> g_DbcFiles;
std::mutex g_Mutex;
std::vector<uint32_t> g_FilterList;
bool g_bConfigDirty = false;
time_t g_LastConfigSendTime = 0;

// Settings Cache
int g_iDbcFileIndex = 0;
char g_szInfluxHost[64] = "192.168.1.50";
int g_iInfluxPort = 8086;
char g_szInfluxOrg[64] = "myorg";
char g_szInfluxBucket[64] = "mybucket";
char g_szInfluxToken[128] = "mytoken";

// Helper to find DBC folder
std::string getDbcFolder() {
    if (access("/home/pi/ruby/plugins/core/dbc/", R_OK) == 0) return "/home/pi/ruby/plugins/core/dbc/";
    if (access("/home/radxa/ruby/plugins/core/dbc/", R_OK) == 0) return "/home/radxa/ruby/plugins/core/dbc/";
    if (access("/root/ruby/plugins/core/dbc/", R_OK) == 0) return "/root/ruby/plugins/core/dbc/";
    return "./";
}

void scanDbcFiles() {
    g_DbcFiles.clear();
    std::string folder = getDbcFolder();
    DIR* d = opendir(folder.c_str());
    if (d) {
        struct dirent* dir;
        while ((dir = readdir(d)) != NULL) {
            if (strstr(dir->d_name, ".dbc")) {
                g_DbcFiles.push_back(dir->d_name);
            }
        }
        closedir(d);
    }
    std::sort(g_DbcFiles.begin(), g_DbcFiles.end());
}

#ifdef __cplusplus
extern "C" {
#endif

u32 core_plugin_on_requested_capabilities() {
    return CORE_PLUGIN_CAPABILITY_DATA_STREAM;
}

const char* core_plugin_get_name() {
    return g_szPluginName;
}

const char* core_plugin_get_guid() {
    return g_szUID;
}

int core_plugin_get_version() {
    return 1;
}

int core_plugin_init(u32 uRuntimeLocation, u32 uAllocatedCapabilities) {
    g_uRuntimeLocation = uRuntimeLocation;
    g_uAllocatedCapabilities = uAllocatedCapabilities;

    core_plugin_util_log_line("[CANBus] Init plugin");

    if (g_uRuntimeLocation & CORE_PLUGIN_RUNTIME_LOCATION_VEHICLE) {
        // Init SocketCAN
        if (g_Socket.open("can0") < 0) {
             core_plugin_util_log_line("[CANBus] Failed to open can0");
        } else {
             core_plugin_util_log_line("[CANBus] Opened can0");
        }
    }

    if (g_uRuntimeLocation & CORE_PLUGIN_RUNTIME_LOCATION_CONTROLLER) {
        scanDbcFiles();
        // DBC Loading is deferred until settings are applied or now if index valid
    }
    return 0;
}

void core_plugin_uninit() {
    g_Socket.close();
}

// Settings API
int core_plugin_get_settings_count() {
    return SETTING_SENSORS_START + g_Parser.getMessages().size();
}

const char* core_plugin_get_setting_name(int i) {
    if (i == SETTING_DBC_FILE) return "DBC File";
    if (i == SETTING_INFLUX_HOST) return "Influx Host";
    if (i == SETTING_INFLUX_PORT) return "Influx Port";
    if (i == SETTING_INFLUX_ORG) return "Influx Org";
    if (i == SETTING_INFLUX_BUCKET) return "Influx Bucket";
    if (i == SETTING_INFLUX_TOKEN) return "Influx Token";

    int msgIdx = i - SETTING_SENSORS_START;
    int k = 0;
    for (auto const& [id, msg] : g_Parser.getMessages()) {
        if (k == msgIdx) {
            static char szBuff[128];
            snprintf(szBuff, sizeof(szBuff), "Msg: %s (0x%X)", msg.name.c_str(), id);
            return szBuff;
        }
        k++;
    }
    return "Unknown";
}

int core_plugin_get_setting_type(int i) {
    if (i == SETTING_DBC_FILE) return CORE_PLUGIN_SETTING_TYPE_ENUM;
    if (i == SETTING_INFLUX_HOST) return CORE_PLUGIN_SETTING_TYPE_STRING;
    if (i == SETTING_INFLUX_PORT) return CORE_PLUGIN_SETTING_TYPE_INT;
    if (i == SETTING_INFLUX_ORG) return CORE_PLUGIN_SETTING_TYPE_STRING;
    if (i == SETTING_INFLUX_BUCKET) return CORE_PLUGIN_SETTING_TYPE_STRING;
    if (i == SETTING_INFLUX_TOKEN) return CORE_PLUGIN_SETTING_TYPE_STRING;
    return CORE_PLUGIN_SETTING_TYPE_BOOL;
}

int core_plugin_get_setting_min_value(int i) {
    if (i == SETTING_INFLUX_PORT) return 1;
    return 0;
}

int core_plugin_get_setting_max_value(int i) {
    if (i == SETTING_INFLUX_PORT) return 65535;
    return 1;
}

int core_plugin_get_setting_default_value(int i) {
    if (i == SETTING_INFLUX_PORT) return 8086;
    return 0;
}

int core_plugin_get_setting_options_count(int i) {
    if (i == SETTING_DBC_FILE) return g_DbcFiles.size();
    return 0;
}

const char* core_plugin_get_setting_option_name(int i, int opt) {
    if (i == SETTING_DBC_FILE) {
        if (opt >= 0 && opt < (int)g_DbcFiles.size()) return g_DbcFiles[opt].c_str();
    }
    return "";
}

int core_plugin_get_setting_value(int i) {
    if (i == SETTING_DBC_FILE) return g_iDbcFileIndex;
    if (i == SETTING_INFLUX_PORT) return g_iInfluxPort;

    if (i >= SETTING_SENSORS_START) {
        int msgIdx = i - SETTING_SENSORS_START;
        int k = 0;
        for (auto const& [id, msg] : g_Parser.getMessages()) {
            if (k == msgIdx) return msg.enabled ? 1 : 0;
            k++;
        }
    }
    return 0;
}

void core_plugin_set_setting_value(int i, int val) {
    if (i == SETTING_DBC_FILE) {
        g_iDbcFileIndex = val;
        // Load new DBC
        if (val >= 0 && val < (int)g_DbcFiles.size()) {
            std::string path = getDbcFolder() + g_DbcFiles[val];
            std::lock_guard<std::mutex> lock(g_Mutex);
            g_Parser.parse(path);
            g_bConfigDirty = true;
            char szLog[256];
            snprintf(szLog, sizeof(szLog), "[CANBus] Loaded DBC: %s", g_DbcFiles[val].c_str());
            core_plugin_util_log_line(szLog);
        }
    }
    else if (i == SETTING_INFLUX_PORT) {
        g_iInfluxPort = val;
        g_Influx.init(g_szInfluxHost, g_iInfluxPort, g_szInfluxOrg, g_szInfluxBucket, g_szInfluxToken);
    }
    else if (i >= SETTING_SENSORS_START) {
        int msgIdx = i - SETTING_SENSORS_START;
        int k = 0;
        std::lock_guard<std::mutex> lock(g_Mutex);
        for (auto const& [id, msg] : g_Parser.getMessages()) {
            if (k == msgIdx) {
                g_Parser.setEnabled(id, (val != 0));
                g_bConfigDirty = true;
                break;
            }
            k++;
        }
    }
}

const char* core_plugin_get_setting_string_value(int i) {
    if (i == SETTING_INFLUX_HOST) return g_szInfluxHost;
    if (i == SETTING_INFLUX_ORG) return g_szInfluxOrg;
    if (i == SETTING_INFLUX_BUCKET) return g_szInfluxBucket;
    if (i == SETTING_INFLUX_TOKEN) return g_szInfluxToken;
    return "";
}

void core_plugin_set_setting_string_value(int i, const char* val) {
    if (val == NULL) return;
    if (i == SETTING_INFLUX_HOST) strncpy(g_szInfluxHost, val, 63);
    else if (i == SETTING_INFLUX_ORG) strncpy(g_szInfluxOrg, val, 63);
    else if (i == SETTING_INFLUX_BUCKET) strncpy(g_szInfluxBucket, val, 63);
    else if (i == SETTING_INFLUX_TOKEN) strncpy(g_szInfluxToken, val, 127);

    g_Influx.init(g_szInfluxHost, g_iInfluxPort, g_szInfluxOrg, g_szInfluxBucket, g_szInfluxToken);
}

void core_plugin_on_settings_changed() {
    // Notify controller needs to send update
    g_bConfigDirty = true;
}

// Runtime Data Handling

void core_plugin_on_rx_data(u8* pData, int iDataLength, int iDataType, u32 uSegmentIndex) {
    if (iDataType != CORE_PLUGIN_TYPE_DATA_SEGMENT || iDataLength < 1) return;

    u8 type = pData[0];

    // Vehicle receiving Config
    if ((g_uRuntimeLocation & CORE_PLUGIN_RUNTIME_LOCATION_VEHICLE) && type == PACKET_TYPE_CONFIG) {
        if (iDataLength < 2) return;
        int count = pData[1];
        if (iDataLength < 2 + count * 4) return;

        std::lock_guard<std::mutex> lock(g_Mutex);
        g_FilterList.clear();
        u32 idTmp;
        for (int i=0; i<count; i++) {
            memcpy(&idTmp, pData + 2 + i*sizeof(u32), sizeof(u32));
            g_FilterList.push_back(idTmp);
        }
        char szLog[256];
        snprintf(szLog, sizeof(szLog), "[CANBus] Received config update. %d sensors enabled.", count);
        core_plugin_util_log_line(szLog);
    }

    // Controller receiving CAN Data
    if ((g_uRuntimeLocation & CORE_PLUGIN_RUNTIME_LOCATION_CONTROLLER) && type == PACKET_TYPE_CAN_FRAME) {
        if (iDataLength < 14) return; // 1 + 4 + 1 + 8

        u32 id;
        memcpy(&id, pData + 1, sizeof(u32));
        u8 dlc = pData[5];
        u8* data = pData + 6;
        (void)dlc; // unused

        std::lock_guard<std::mutex> lock(g_Mutex);
        DbcMessage* msg = g_Parser.getMessage(id);
        if (msg) {
             // Parse signals
             for (const auto& sig : msg->signals) {
                 // Simple extraction: Assuming 1 byte signal for demo
                 if (sig.length == 8 && (sig.startBit % 8 == 0)) {
                     int byteIdx = sig.startBit / 8;
                     if (byteIdx < 8) {
                         double val = data[byteIdx] * sig.factor + sig.offset;
                         char line[256];
                         // measurement,sensor=Name value=X
                         // Use msg name as measurement, signal name as field key?
                         // InfluxDB Line Protocol: measurement,tag_set field_set timestamp
                         // E.g. Telemetry,sensor=EngineSpeed value=2500

                         // Sanitize names (replace spaces with _)
                         std::string sMsgName = msg->name;
                         std::string sSigName = sig.name;
                         std::replace(sMsgName.begin(), sMsgName.end(), ' ', '_');
                         std::replace(sSigName.begin(), sSigName.end(), ' ', '_');

                         snprintf(line, sizeof(line), "%s %s=%f", sMsgName.c_str(), sSigName.c_str(), val);
                         g_Influx.send(line);
                     }
                 }
             }
        }
    }
}

// TX Buffering
u8 g_TxBuffer[256];
int g_TxBufferLen = 0;

u32 core_plugin_has_pending_tx_data() {
    g_TxBufferLen = 0;

    // If buffer is empty, try to fill it
    if (g_TxBufferLen == 0) {
        if (g_uRuntimeLocation & CORE_PLUGIN_RUNTIME_LOCATION_VEHICLE) {
            struct can_frame frame;
            // Drain socket until we find a frame or empty
            while (g_Socket.read(&frame) > 0) {
                // Check filter
                bool allow = false;
                {
                    std::lock_guard<std::mutex> lock(g_Mutex);
                    // If filter list is empty, block all (safe default) or allow all?
                    // Requirement says "select which sensors... to be transmitted". So block by default.
                    for (u32 id : g_FilterList) {
                        if (id == frame.can_id) { allow = true; break; }
                    }
                }

                if (allow) {
                     g_TxBuffer[0] = PACKET_TYPE_CAN_FRAME;
                     memcpy(g_TxBuffer + 1, &frame.can_id, sizeof(u32));
                     g_TxBuffer[5] = frame.can_dlc;
                     memcpy(g_TxBuffer + 6, frame.data, 8);
                     g_TxBufferLen = 14;
                     return 1;
                }
            }
        }

        if (g_uRuntimeLocation & CORE_PLUGIN_RUNTIME_LOCATION_CONTROLLER) {
            if (g_bConfigDirty || (time(NULL) - g_LastConfigSendTime > 5)) {
                g_TxBuffer[0] = PACKET_TYPE_CONFIG;
                std::lock_guard<std::mutex> lock(g_Mutex);
                int count = 0;
                for (auto const& [id, msg] : g_Parser.getMessages()) {
                    if (msg.enabled) {
                        memcpy(g_TxBuffer + 2 + count*sizeof(u32), &id, sizeof(u32));
                        count++;
                        if (count >= 50) break; // Limit size
                    }
                }
                g_TxBuffer[1] = count;
                g_TxBufferLen = 2 + count * 4;

                g_bConfigDirty = false;
                g_LastConfigSendTime = time(NULL);
                return 1;
            }
        }
    }

    return (g_TxBufferLen > 0) ? 1 : 0;
}

u8* core_plugin_on_get_segment_data(u32 uSegmentIndex) {
    return g_TxBuffer;
}

int core_plugin_on_get_segment_length(u32 uSegmentIndex) {
    return g_TxBufferLen;
}

int core_plugin_on_get_segment_type(u32 uSegmentIndex) {
    return CORE_PLUGIN_TYPE_DATA_SEGMENT;
}

// Stubs for video
int core_plugin_on_get_video_stream_source_type() { return CORE_PLUGIN_VIDEO_STREAM_SOURCE_NONE; }
int core_plugin_on_setup_video_stream_source() { return 1; }
void core_plugin_on_start_video_stream_capture(int iWidth, int iHeight, int iFPS) {}
void core_plugin_on_stop_video_stream_capture() {}
void core_plugin_on_start_video_stream_playback(int iXPos, int iYPos, int iWidth, int iHeight) {}
void core_plugin_on_stop_video_stream_playback() {}
void core_plugin_on_lower_video_capture_rate(int iMaxkbps) {}
void core_plugin_on_higher_video_capture_rate(int iMaxkbps) {}
void core_plugin_on_allocated_uart(char* szUARTName) {}
void core_plugin_on_stop_using_uart() {}

#ifdef __cplusplus
}
#endif