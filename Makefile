CC := clang
CFLAGS := -fobjc-arc -Wall -Wextra -Werror -O2
FRAMEWORKS := -framework Foundation -framework Carbon -framework ApplicationServices
TARGET := build/right-command-hangul
SOURCE := src/right-command-hangul.m

.PHONY: all clean install uninstall

all: $(TARGET)

$(TARGET): $(SOURCE)
	mkdir -p build
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(SOURCE) -o $(TARGET)

clean:
	rm -rf build

install:
	./scripts/install.sh

uninstall:
	./scripts/uninstall.sh
