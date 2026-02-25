#pragma once
#include <string>
#include <curl/curl.h>

class InfluxClient {
public:
    InfluxClient();
    ~InfluxClient();
    void init(const std::string& host, int port, const std::string& org, const std::string& bucket, const std::string& token);
    bool send(const std::string& lineProtocol);

private:
    std::string m_url;
    std::string m_token;
    CURL* m_curl;
    struct curl_slist* m_headers;
};
