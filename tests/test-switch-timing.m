#import <assert.h>

#define main right_command_hangul_main
#include "../src/right-command-hangul.m"
#undef main

int main(void) {
    // The fast path (source-change notification observed) must flush sooner
    // than the safety fallback.
    assert(flush_delay(YES) == kReadyDelay);
    assert(flush_delay(NO) == kSafetyTimeout);
    assert(kReadyDelay < kSafetyTimeout);

    // The safety fallback must be short: when the notification is dropped we
    // still release held keys quickly instead of the old 0.25s stall.
    assert(kSafetyTimeout <= 0.08);
    return 0;
}
