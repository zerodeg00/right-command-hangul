#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#import <signal.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static const CGKeyCode kTriggerKeyCode = 79; // F18
static NSString *const kDefaultLatinSource = @"com.apple.keylayout.ABC";
static NSString *const kDefaultKoreanSource =
    @"com.apple.inputmethod.Korean.2SetKorean";
static NSString *const kKoreanSourcePrefix = @"com.apple.inputmethod.Korean";
static volatile sig_atomic_t gRunning = 1;

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
    if (status == noErr) {
        usleep(30000);
        status = TISSelectInputSource(target);
    }

    if (status != noErr) {
        NSLog(@"Could not switch input source (status: %d)", status);
        return NO;
    }
    return YES;
}

static BOOL toggle_source(BOOL *target_is_korean_out) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return NO;

    NSString *current_id = source_string(current, kTISPropertyInputSourceID);
    BOOL target_is_korean = [current_id hasPrefix:kKoreanSourcePrefix] == NO;
    CFRelease(current);

    if (target_is_korean_out) *target_is_korean_out = target_is_korean;
    return select_target_source(target_is_korean);
}

static void print_current_source(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return;
    NSString *source_id = source_string(current, kTISPropertyInputSourceID);
    printf("%s\n", source_id.UTF8String);
    CFRelease(current);
}

static int set_right_command_mapping(BOOL enabled) {
    const char *mapping = enabled
        ? "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":"
          "30064771303,\"HIDKeyboardModifierMappingDst\":30064771181}]}"
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--current") == 0) {
            print_current_source();
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--toggle") == 0) {
            return toggle_source(NULL) ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--apply-mapping") == 0) {
            return set_right_command_mapping(YES);
        }
        if (argc == 2 && strcmp(argv[1], "--clear-mapping") == 0) {
            return set_right_command_mapping(NO);
        }
        if (set_right_command_mapping(YES) != 0) {
            NSLog(@"Could not map Right Command to F18");
            return 1;
        }

        signal(SIGTERM, stop_handler);
        signal(SIGINT, stop_handler);

        EventHotKeyID hotkey_id = {
            .signature = 0x52434847, // RCHG
            .id = 1
        };
        EventHotKeyRef hotkey = NULL;
        OSStatus registration_status = RegisterEventHotKey(
            kTriggerKeyCode, 0, hotkey_id, GetApplicationEventTarget(), 0,
            &hotkey);
        if (registration_status != noErr) {
            NSLog(@"Could not register F18 hotkey (status: %d)",
                  registration_status);
            return 1;
        }

        EventTypeSpec event_types[] = {
            {
                .eventClass = kEventClassKeyboard,
                .eventKind = kEventHotKeyPressed
            },
            {
                .eventClass = kEventClassKeyboard,
                .eventKind = kEventHotKeyReleased
            }
        };
        BOOL pending_target_is_korean = NO;
        BOOL has_pending_target = NO;
        while (gRunning) {
            EventRef event = NULL;
            OSStatus receive_status = ReceiveNextEvent(
                2, event_types, 1.0, true, &event);
            if (receive_status == eventLoopTimedOutErr) continue;
            if (receive_status != noErr) {
                NSLog(@"Could not receive hotkey event (status: %d)",
                      receive_status);
                continue;
            }

            EventHotKeyID received_id = {0};
            OSStatus parameter_status = GetEventParameter(
                event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                sizeof(received_id), NULL, &received_id);
            if (parameter_status == noErr && received_id.id == hotkey_id.id) {
                UInt32 event_kind = GetEventKind(event);
                if (event_kind == kEventHotKeyPressed) {
                    has_pending_target = toggle_source(
                        &pending_target_is_korean);
                } else if (event_kind == kEventHotKeyReleased &&
                           has_pending_target) {
                    select_target_source(pending_target_is_korean);
                    has_pending_target = NO;
                }
            }
            ReleaseEvent(event);
        }

        UnregisterEventHotKey(hotkey);
    }
    return 0;
}
