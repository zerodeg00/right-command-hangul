#import <assert.h>

#define main right_command_hangul_main
#include "../src/right-command-hangul.m"
#undef main

int main(void) {
    assert(should_hold_event(kCGEventKeyDown, YES, NO));
    assert(should_hold_event(kCGEventKeyUp, YES, NO));
    assert(!should_hold_event(kCGEventKeyDown, NO, NO));
    assert(!should_hold_event(kCGEventKeyDown, YES, YES));
    assert(next_target_is_korean(NO, NO, NO));
    assert(!next_target_is_korean(NO, NO, YES));
    assert(!next_target_is_korean(YES, YES, NO));
    assert(next_target_is_korean(YES, NO, YES));
    return 0;
}
