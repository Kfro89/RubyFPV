#pragma once
#include <linux/can.h>
#include <linux/can/raw.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

class SocketCAN {
public:
    SocketCAN();
    ~SocketCAN();
    int open(const char* interface);
    void close();
    int read(struct can_frame* frame);
    int write(const struct can_frame* frame);
private:
    int m_socket;
};
