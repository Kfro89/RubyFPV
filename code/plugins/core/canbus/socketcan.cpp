#include "socketcan.h"
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

SocketCAN::SocketCAN() : m_socket(-1) {
}

SocketCAN::~SocketCAN() {
    close();
}

int SocketCAN::open(const char* interface) {
    struct sockaddr_can addr;
    struct ifreq ifr;

    if ((m_socket = socket(PF_CAN, SOCK_RAW, CAN_RAW)) < 0) {
        return -1;
    }

    strcpy(ifr.ifr_name, interface);
    if (ioctl(m_socket, SIOCGIFINDEX, &ifr) < 0) {
        ::close(m_socket);
        m_socket = -1;
        return -2;
    }

    memset(&addr, 0, sizeof(addr));
    addr.can_family = AF_CAN;
    addr.can_ifindex = ifr.ifr_ifindex;

    if (bind(m_socket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ::close(m_socket);
        m_socket = -1;
        return -3;
    }

    // Set non-blocking
    int flags = fcntl(m_socket, F_GETFL, 0);
    fcntl(m_socket, F_SETFL, flags | O_NONBLOCK);

    return 0;
}

void SocketCAN::close() {
    if (m_socket >= 0) {
        ::close(m_socket);
        m_socket = -1;
    }
}

int SocketCAN::read(struct can_frame* frame) {
    if (m_socket < 0) return -1;

    int nbytes = ::read(m_socket, frame, sizeof(struct can_frame));
    if (nbytes < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
    if (nbytes < (int)sizeof(struct can_frame)) return 0;

    return 1; // 1 frame read
}

int SocketCAN::write(const struct can_frame* frame) {
    if (m_socket < 0) return -1;
    return ::write(m_socket, frame, sizeof(struct can_frame));
}
