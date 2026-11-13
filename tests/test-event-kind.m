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
    // Native switching can select any source, and a missing source is not ready.
    assert(native_source_is_ready(@"ABC", @"Korean"));
    assert(native_source_is_ready(@"ABC", @"US"));
    assert(!native_source_is_ready(@"ABC", @"ABC"));
    assert(!native_source_is_ready(@"ABC", nil));
    assert(!native_source_is_ready(nil, @"Korean"));
    assert(needs_event_tap(YES, YES, YES));
    assert(!needs_event_tap(YES, YES, NO));
    assert(needs_event_tap(YES, NO, NO));
    assert(!needs_event_tap(NO, NO, YES));
    // Native protection forwards F18 without selecting an input source itself.
    gNativeProtectionActive = YES;
    gHeldEvents = [NSMutableArray array];
    CGEventRef triggerDown = CGEventCreateKeyboardEvent(NULL, 79, true);
    CGEventRef triggerUp = CGEventCreateKeyboardEvent(NULL, 79, false);
    NSString *initialSource = current_source_id();
    assert(event_tap_callback(NULL, kCGEventKeyDown, triggerDown, NULL) == triggerDown);
    assert(gTriggerIsDown);
    assert([current_source_id() isEqual:initialSource]);
    // Queue tests do not depend on the user's foreground app exposing AX focus.
    gSwitchIsPending = YES;
    assert(event_tap_callback(NULL, kCGEventKeyDown, triggerDown, NULL) == NULL);
    CGEventRef shift = CGEventCreateKeyboardEvent(NULL, 56, true);
    CGEventSetType(shift, kCGEventFlagsChanged);
    CGEventSetFlags(shift, kCGEventFlagMaskShift);
    assert(event_tap_callback(NULL, kCGEventFlagsChanged, shift, NULL) == NULL);
    CGEventRef letterDown = CGEventCreateKeyboardEvent(NULL, 0, true);
    CGEventRef letterUp = CGEventCreateKeyboardEvent(NULL, 0, false);
    CGEventSetFlags(letterDown, kCGEventFlagMaskShift);
    CGEventSetFlags(letterUp, kCGEventFlagMaskShift);
    assert(event_tap_callback(NULL, kCGEventKeyDown, letterDown, NULL) == NULL);
    assert(event_tap_callback(NULL, kCGEventKeyUp, letterUp, NULL) == NULL);
    assert(gHeldEvents.count == 3);
    assert(CGEventGetType((__bridge CGEventRef)gHeldEvents[0]) == kCGEventFlagsChanged);
    assert(CGEventGetType((__bridge CGEventRef)gHeldEvents[1]) == kCGEventKeyDown);
    assert(CGEventGetType((__bridge CGEventRef)gHeldEvents[2]) == kCGEventKeyUp);
    CGEventSetIntegerValueField(letterDown, kCGEventSourceUserData, kRepostedEventMarker);
    assert(event_tap_callback(NULL, kCGEventKeyDown, letterDown, NULL) == letterDown);
    assert(gHeldEvents.count == 3);
    assert(event_tap_callback(NULL, kCGEventKeyUp, triggerUp, NULL) == triggerUp);
    assert(!gTriggerIsDown);
    // Keep unit tests from posting synthetic characters into the user's app.
    [gHeldEvents removeAllObjects];
    stop_event_tap();
    gTriggerIsDown = YES;
    gSwitchIsPending = YES;
    NSUInteger cancelledGeneration = gSwitchGeneration;
    cancel_native_protection();
    assert(!gTriggerIsDown && !gSwitchIsPending);
    assert(gSwitchGeneration > cancelledGeneration);
    assert(gNativeTargetPID == 0 && gNativeTargetElement == NULL);
    CGEventSetIntegerValueField(triggerDown, kCGKeyboardEventAutorepeat, 1);
    assert(event_tap_callback(NULL, kCGEventKeyDown, triggerDown, NULL) == NULL);
    assert(!gTriggerIsDown);
    gNativeProtectionActive = NO;
    CFRelease(triggerDown);
    CFRelease(triggerUp);
    CFRelease(shift);
    CFRelease(letterDown);
    CFRelease(letterUp);
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
