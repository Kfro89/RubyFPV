#pragma once
#include <string>
#include <vector>
#include <map>
#include <stdint.h>

struct DbcSignal {
    std::string name;
    int startBit;
    int length;
    bool isBigEndian; // 0=Big (Motorola), 1=Little (Intel) in some formats, check spec. usually @1 = Little, @0 = Big.
    bool isSigned;
    double factor;
    double offset;
    double min;
    double max;
    std::string unit;
};

struct DbcMessage {
    uint32_t id;
    std::string name;
    int dlc;
    std::vector<DbcSignal> signals;
    bool enabled;
};

class DbcParser {
public:
    DbcParser();
    bool parse(const std::string& filename);
    const std::map<uint32_t, DbcMessage>& getMessages() const;
    void setAllEnabled(bool enabled);
    void setEnabled(uint32_t id, bool enabled);
    DbcMessage* getMessage(uint32_t id);

private:
    std::map<uint32_t, DbcMessage> m_messages;
};
