#include "influx_client.h"
#include <sstream>
#include <iostream>

InfluxClient::InfluxClient() : m_curl(nullptr), m_headers(nullptr) {
    curl_global_init(CURL_GLOBAL_ALL);
    m_curl = curl_easy_init();
}

InfluxClient::~InfluxClient() {
    if (m_headers) {
        curl_slist_free_all(m_headers);
    }
    if (m_curl) {
        curl_easy_cleanup(m_curl);
    }
    curl_global_cleanup();
}

void InfluxClient::init(const std::string& host, int port, const std::string& org, const std::string& bucket, const std::string& token) {
    // URL: http://host:port/api/v2/write?org=ORG&bucket=BUCKET
    std::stringstream ss;
    ss << "http://" << host << ":" << port << "/api/v2/write?org=" << org << "&bucket=" << bucket << "&precision=ms";
    m_url = ss.str();
    m_token = token;

    if (m_headers) {
        curl_slist_free_all(m_headers);
        m_headers = nullptr;
    }

    std::string authHeader = "Authorization: Token " + m_token;
    m_headers = curl_slist_append(m_headers, authHeader.c_str());
    m_headers = curl_slist_append(m_headers, "Content-Type: text/plain; charset=utf-8");
    m_headers = curl_slist_append(m_headers, "Accept: application/json");
}

bool InfluxClient::send(const std::string& lineProtocol) {
    if (!m_curl) return false;

    curl_easy_setopt(m_curl, CURLOPT_URL, m_url.c_str());
    curl_easy_setopt(m_curl, CURLOPT_POST, 1L);
    curl_easy_setopt(m_curl, CURLOPT_POSTFIELDS, lineProtocol.c_str());
    curl_easy_setopt(m_curl, CURLOPT_HTTPHEADER, m_headers);
    curl_easy_setopt(m_curl, CURLOPT_TIMEOUT_MS, 100L); // Short timeout

    CURLcode res = curl_easy_perform(m_curl);
    if (res != CURLE_OK) {
        // std::cerr << "InfluxDB send failed: " << curl_easy_strerror(res) << std::endl;
        return false;
    }
    return true;
}
