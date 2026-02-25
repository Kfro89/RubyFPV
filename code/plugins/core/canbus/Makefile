LDFLAGS=-lrt -lpcap -lpthread -lcurl
CPPFLAGS=-Wall -O0 -D _GNU_SOURCE -std=c++17 -fPIC
CFLAGS := $(CFLAGS) -Wall -O0 -D _GNU_SOURCE -fPIC
RELEASE_DIR = ../../../

all: canbus_plugin

core_plugins_utils.o: ../../../../public_sdk_core/utils/core_plugins_utils.c
	gcc -c -o $@ $< $(CFLAGS)

%.o: %.cpp
	g++ $(CFLAGS) -c -o $@ $< $(CPPFLAGS)

canbus_plugin: core_plugins_utils.o canbus_plugin.o dbc_parser.o influx_client.o socketcan.o
	g++ canbus_plugin.o core_plugins_utils.o dbc_parser.o influx_client.o socketcan.o -shared -Wl,-soname,canbus_plugin.so.1 -o canbus_plugin.so.1.0.1 -lc -lcurl
	cp -f canbus_plugin.so.1.0.1 $(RELEASE_DIR)
	$(info Copy canbus_plugin)
	$(info ----------------------------------------------------)

clean:
	rm -f canbus_plugin.so.* *.o
