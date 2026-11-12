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
    // Turning our mapping off must preserve mappings owned by other tools.
    NSDictionary *other = @{@"HIDKeyboardModifierMappingSrc": @30064771129,
                            @"HIDKeyboardModifierMappingDst": @30064771113};
    NSDictionary *ours = @{@"HIDKeyboardModifierMappingSrc": @30064771303,
                           @"HIDKeyboardModifierMappingDst": @30064771181};
    NSArray *enabled = updated_key_mapping(@[other], YES);
    assert(enabled.count == 3);
    assert([enabled containsObject:other]);
    assert([updated_key_mapping(enabled, YES) isEqual:enabled]);
    assert([updated_key_mapping(@[other, ours], NO) isEqual:@[other]]);
    NSDictionary *conflict = @{@"HIDKeyboardModifierMappingSrc": @30064771303,
                               @"HIDKeyboardModifierMappingDst": @30064771113};
    assert(updated_key_mapping(@[conflict], YES) == nil);
    assert([updated_key_mapping(@[conflict], NO) isEqual:@[conflict]]);
    assert(updated_key_mapping(@[@"invalid"], YES) == nil);
    // Switching modes while the trigger is down must not block the next press.
    gHeldEvents = [NSMutableArray array];
    gTriggerIsDown = YES;
    gSwitchIsPending = YES;
    gSwitchGeneration = 10;
    stop_event_tap();
    assert(!gTriggerIsDown);
    assert(!gSwitchIsPending);
    assert(gSwitchGeneration == 11);
    return 0;
}
