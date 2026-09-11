#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static const CGKeyCode kTriggerKeyCode = 79; // F18
static const int64_t kRepostedEventMarker = 0x524348414E47554C; // RCHANGUL
static const NSTimeInterval kPostNotificationDelay = 0.035;
static const NSTimeInterval kSafetyTimeout = 0.250;
static NSString *const kDefaultLatinSource = @"com.apple.keylayout.ABC";
static NSString *const kDefaultKoreanSource =
    @"com.apple.inputmethod.Korean.2SetKorean";
static NSString *const kKoreanSourcePrefix = @"com.apple.inputmethod.Korean";

static volatile sig_atomic_t gRunning = 1;
static CFMachPortRef gEventTap = NULL;
static CFRunLoopSourceRef gEventTapSource = NULL;
static NSMutableArray *gHeldEvents = nil;
static BOOL gTriggerIsDown = NO;
static BOOL gSwitchIsPending = NO;
static NSUInteger gSwitchGeneration = 0;
static int gNotificationObserver = 0;

static void stop_handler(int signal_number) {
    (void)signal_number;
    gRunning = 0;
}

static NSString *source_string(TISInputSourceRef source, CFStringRef property) {
    if (!source) return nil;
    return (__bridge NSString *)TISGetInputSourceProperty(source, property);
}

static NSArray *enabled_keyboard_sources(void) {
    NSDictionary *filter = @{
        (__bridge NSString *)kTISPropertyInputSourceCategory:
            (__bridge NSString *)kTISCategoryKeyboardInputSource,
        (__bridge NSString *)kTISPropertyInputSourceIsEnabled: @YES,
        (__bridge NSString *)kTISPropertyInputSourceIsSelectCapable: @YES
    };
    return CFBridgingRelease(
        TISCreateInputSourceList((__bridge CFDictionaryRef)filter, false));
}

static TISInputSourceRef find_source(NSArray *sources, BOOL korean) {
    NSString *preferred = korean ? kDefaultKoreanSource : kDefaultLatinSource;

    for (id item in sources) {
        TISInputSourceRef source = (__bridge TISInputSourceRef)item;
        if ([source_string(source, kTISPropertyInputSourceID)
                isEqualToString:preferred]) {
            return source;
        }
    }

    for (id item in sources) {
        TISInputSourceRef source = (__bridge TISInputSourceRef)item;
        NSString *source_id = source_string(source, kTISPropertyInputSourceID);
        if (korean && [source_id hasPrefix:kKoreanSourcePrefix]) return source;
        if (!korean &&
            [source_string(source, kTISPropertyInputSourceIsASCIICapable)
                boolValue]) {
            return source;
        }
    }
    return nil;
}

static BOOL select_target_source(BOOL target_is_korean) {
    NSArray *sources = enabled_keyboard_sources();
    TISInputSourceRef target = find_source(sources, target_is_korean);
    OSStatus status = target ? TISSelectInputSource(target) : paramErr;
    if (status != noErr) {
        NSLog(@"Could not switch input source (status: %d)", status);
        return NO;
    }
    return YES;
}

static BOOL toggle_source(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return NO;

    NSString *current_id = source_string(current, kTISPropertyInputSourceID);
    BOOL target_is_korean = [current_id hasPrefix:kKoreanSourcePrefix] == NO;
    CFRelease(current);
    return select_target_source(target_is_korean);
}

static void print_current_source(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return;
    NSString *source_id = source_string(current, kTISPropertyInputSourceID);
    printf("%s\n", source_id.UTF8String);
    CFRelease(current);
}

static int set_key_mapping(BOOL enabled) {
    const char *mapping = enabled
        ? "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":"
          "30064771303,\"HIDKeyboardModifierMappingDst\":30064771181},"
          "{\"HIDKeyboardModifierMappingSrc\":30064771302,"
          "\"HIDKeyboardModifierMappingDst\":30064771181}]}"
        : "{\"UserKeyMapping\":[]}";
    char *const arguments[] = {
        "hidutil", "property", "--set", (char *)mapping, NULL
    };
    pid_t process = 0;
    int spawn_status = posix_spawn(
        &process, "/usr/bin/hidutil", NULL, NULL, arguments, environ);
    if (spawn_status != 0) return spawn_status;

    int status = 0;
    if (waitpid(process, &status, 0) < 0) return 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static void release_held_events(NSUInteger generation) {
    if (!gSwitchIsPending || generation != gSwitchGeneration) return;

    gSwitchIsPending = NO;
    NSArray *events = [gHeldEvents copy];
    [gHeldEvents removeAllObjects];
    for (id item in events) {
        CGEventRef event = (__bridge CGEventRef)item;
        CGEventSetIntegerValueField(
            event, kCGEventSourceUserData, kRepostedEventMarker);
        CGEventPost(kCGSessionEventTap, event);
    }
}

static void schedule_release(NSUInteger generation,
                             NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            release_held_events(generation);
        });
}

static void input_source_changed(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef user_info) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)user_info;

    if (!gSwitchIsPending) return;
    schedule_release(gSwitchGeneration, kPostNotificationDelay);
}

static CGEventRef event_tap_callback(CGEventTapProxy proxy,
                                     CGEventType type,
                                     CGEventRef event,
                                     void *user_info) {
    (void)proxy;
    (void)user_info;

    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return event;
    }

    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) ==
        kRepostedEventMarker) {
        return event;
    }

    CGKeyCode key_code = (CGKeyCode)CGEventGetIntegerValueField(
        event, kCGKeyboardEventKeycode);
    if (key_code == kTriggerKeyCode) {
        if (type == kCGEventKeyDown && !gTriggerIsDown) {
            gTriggerIsDown = YES;

            if (gSwitchIsPending) {
                release_held_events(gSwitchGeneration);
            }
            gSwitchGeneration += 1;
            gSwitchIsPending = YES;
            NSUInteger generation = gSwitchGeneration;

            if (!toggle_source()) {
                release_held_events(generation);
            } else {
                schedule_release(generation, kSafetyTimeout);
            }
        } else if (type == kCGEventKeyUp) {
            gTriggerIsDown = NO;
        }
        return NULL;
    }

    if (gSwitchIsPending &&
        (type == kCGEventKeyDown || type == kCGEventKeyUp)) {
        CGEventRef copy = CGEventCreateCopy(event);
        if (copy) {
            [gHeldEvents addObject:CFBridgingRelease(copy)];
            return NULL;
        }
    }
    return event;
}

static BOOL start_event_tap(void) {
    if (gEventTap) return YES;

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventKeyUp);
    gEventTap = CGEventTapCreate(
        kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
        mask, event_tap_callback, NULL);
    if (!gEventTap) return NO;

    gEventTapSource = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault, gEventTap, 0);
    if (!gEventTapSource) {
        CFRelease(gEventTap);
        gEventTap = NULL;
        return NO;
    }

    CFRunLoopAddSource(
        CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(gEventTap, true);
    return YES;
}

static void stop_event_tap(void) {
    if (gSwitchIsPending) release_held_events(gSwitchGeneration);
    if (gEventTapSource) {
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes);
        CFRelease(gEventTapSource);
        gEventTapSource = NULL;
    }
    if (gEventTap) {
        CGEventTapEnable(gEventTap, false);
        CFRelease(gEventTap);
        gEventTap = NULL;
    }
}

static BOOL accessibility_is_trusted(BOOL prompt) {
    if (!prompt) return AXIsProcessTrusted();
    NSDictionary *options = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES
    };
    return AXIsProcessTrustedWithOptions(
        (__bridge CFDictionaryRef)options);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--current") == 0) {
            print_current_source();
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--toggle") == 0) {
            return toggle_source() ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--apply-mapping") == 0) {
            return set_key_mapping(YES);
        }
        if (argc == 2 && strcmp(argv[1], "--clear-mapping") == 0) {
            return set_key_mapping(NO);
        }
        signal(SIGTERM, stop_handler);
        signal(SIGINT, stop_handler);
        gHeldEvents = [NSMutableArray array];

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            &gNotificationObserver,
            input_source_changed,
            kTISNotifySelectedKeyboardInputSourceChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        BOOL prompted = NO;
        BOOL active = NO;
        while (gRunning) {
            if (!active && accessibility_is_trusted(!prompted)) {
                prompted = YES;
                if (!start_event_tap()) {
                    NSLog(@"Could not create the keyboard event tap");
                } else if (set_key_mapping(YES) != 0) {
                    NSLog(@"Could not map Right Command and Right Alt to F18");
                    stop_event_tap();
                } else {
                    active = YES;
                    NSLog(@"Right Command input source switching is active");
                }
            } else {
                prompted = YES;
            }

            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        }

        if (active) set_key_mapping(NO);
        stop_event_tap();
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            &gNotificationObserver,
            kTISNotifySelectedKeyboardInputSourceChanged, NULL);
    }
    return 0;
}
