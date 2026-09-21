CC := clang
CFLAGS := -fobjc-arc -Wall -Wextra -Werror -O2
FRAMEWORKS := -framework Foundation -framework Carbon -framework ApplicationServices
TARGET := build/right-command-hangul
SOURCE := src/right-command-hangul.m

.PHONY: all clean install uninstall test

all: $(TARGET)

$(TARGET): $(SOURCE)
	mkdir -p build
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(SOURCE) -o $(TARGET)

clean:
	rm -rf build

test:
	mkdir -p build
	$(CC) $(CFLAGS) $(FRAMEWORKS) tests/test-event-kind.m -o build/test-event-kind
	build/test-event-kind

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh
