# Cross-compile for ARM HPS on DE10-Nano
CC = arm-linux-gnueabihf-gcc
CFLAGS = -O2 -Wall

TARGET = mem_test

all: $(TARGET)

$(TARGET): mem_test.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
