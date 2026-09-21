#import <assert.h>

#define main right_command_hangul_main
#include "../src/right-command-hangul.m"
#undef main

int main(void) {
    assert(should_switch_for_event(kEventHotKeyPressed));
    assert(!should_switch_for_event(kEventHotKeyReleased));
    return 0;
}
