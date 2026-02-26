#include "dbc_parser.h"
#include <fstream>
#include <sstream>
#include <iostream>
#include <cstring>
#include <algorithm>

DbcParser::DbcParser() {
}

bool DbcParser::parse(const std::string& filename) {
    std::ifstream file(filename);
    if (!file.is_open()) {
        std::cerr << "Failed to open DBC file: " << filename << std::endl;
        return false;
    }

    m_messages.clear();
    std::string line;
    uint32_t currentMessageId = 0;

    while (std::getline(file, line)) {
        // Trim leading whitespace
        size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos) continue;
        line = line.substr(first);

        if (line.substr(0, 3) == "BO_") {
            // Message definition
            // BO_ 2364540192 EEC1: 8 Vector__XXX
            uint32_t id;
            char name[64];
            int dlc;
            char sender[64];

            // sscanf might be tricky with spaces in name? usually message names don't have spaces.
            if (sscanf(line.c_str(), "BO_ %u %63[^:]: %d %63s", &id, name, &dlc, sender) >= 3) {
                DbcMessage msg;
                msg.id = id;
                msg.name = name;
                msg.dlc = dlc;
                msg.enabled = false;
                m_messages[id] = msg;
                currentMessageId = id;
            }
        }
        else if (line.substr(0, 3) == "SG_" && currentMessageId != 0) {
            // Signal definition
            // SG_ EngineSpeed : 24|16@1+ (0.125,0) [0|8031.875] "rpm" Vector__XXX
            // Using simpler parsing logic as sscanf is complex for this line format

            // Basic parsing logic
            // char name[64]; // Unused
            int startBit, length, endian, sign;
            double factor, offset, min, max;
            char unit[32];
            // char receiver[64]; // Unused

            // Replace special chars with space to simplify sscanf?
            // "SG_ Name : Start|Len@EndSign (Factor,Offset) [Min|Max] \"Unit\" Receiver"

            // Find colon
            size_t colonPos = line.find(':');
            if (colonPos == std::string::npos) continue;

            std::string sName = line.substr(3, colonPos - 3);
            // Trim name
            sName.erase(sName.find_last_not_of(" \t") + 1);
            sName.erase(0, sName.find_first_not_of(" \t"));

            std::string remaining = line.substr(colonPos + 1);

            // Parse: 24|16@1+ (0.125,0) [0|8031.875] "rpm"
            int scanned = sscanf(remaining.c_str(), " %d|%d@%d%c (%lf,%lf) [%lf|%lf] \"%[^\"]\"",
                &startBit, &length, &endian, (char*)&sign, &factor, &offset, &min, &max, unit);

            if (scanned >= 6) { // At least up to offset
                DbcSignal sig;
                sig.name = sName;
                sig.startBit = startBit;
                sig.length = length;
                sig.isBigEndian = (endian == 0); // @0 = Big, @1 = Little usually
                sig.isSigned = ((char)sign == '-');
                sig.factor = factor;
                sig.offset = offset;
                if (scanned >= 8) {
                    sig.min = min;
                    sig.max = max;
                } else {
                    sig.min = 0;
                    sig.max = 0;
                }
                if (scanned >= 9) {
                    sig.unit = unit;
                } else {
                    sig.unit = "";
                }

                m_messages[currentMessageId].signals.push_back(sig);
            }
        }
    }
    file.close();
    return true;
}

const std::map<uint32_t, DbcMessage>& DbcParser::getMessages() const {
    return m_messages;
}

DbcMessage* DbcParser::getMessage(uint32_t id) {
    auto it = m_messages.find(id);
    if (it != m_messages.end()) {
        return &(it->second);
    }
    return nullptr;
}

void DbcParser::setAllEnabled(bool enabled) {
    for (auto& pair : m_messages) {
        pair.second.enabled = enabled;
    }
}

void DbcParser::setEnabled(uint32_t id, bool enabled) {
    auto it = m_messages.find(id);
    if (it != m_messages.end()) {
        it->second.enabled = enabled;
    }
}
