#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <signal.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <unistd.h>

static const CGKeyCode kTriggerKeyCode = 79; // F18
static const int64_t kRepostedEventMarker = 0x524348414E47554C; // RCHANGUL
static const NSTimeInterval kReadyDelay = 0.035;
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
static BOOL gPendingTargetIsKorean = NO;
static BOOL gSourceChangeWasObserved = NO;
static NSUInteger gSwitchGeneration = 0;
static int gNotificationObserver = 0;
static BOOL gNativeProtectionActive = NO;
static NSString *gNativeInitialSource = nil;
static pid_t gNativeTargetPID = 0;
static AXUIElementRef gNativeTargetElement = NULL;
static BOOL gNativeProtectionCancelled = NO;
static BOOL gNativeProtectionUnavailable = NO;

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

static BOOL current_source_is_korean(BOOL *is_korean) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return NO;

    NSString *current_id = source_string(current, kTISPropertyInputSourceID);
    *is_korean = [current_id hasPrefix:kKoreanSourcePrefix];
    CFRelease(current);
    return YES;
}

static BOOL next_target_is_korean(BOOL switch_is_pending,
                                  BOOL pending_target_is_korean,
                                  BOOL current_is_korean) {
    return switch_is_pending ? !pending_target_is_korean : !current_is_korean;
}

static BOOL native_source_is_ready(NSString *initial, NSString *current) {
    return initial != nil && current != nil && ![initial isEqualToString:current];
}

static BOOL needs_event_tap(BOOL enabled, BOOL native_mode, BOOL protection) {
    return enabled && (!native_mode || protection);
}

static NSString *current_source_id(void) {
    TISInputSourceRef source = TISCopyCurrentKeyboardInputSource();
    if (!source) return nil;
    NSString *identifier = [source_string(source, kTISPropertyInputSourceID) copy];
    CFRelease(source);
    return identifier;
}

static AXUIElementRef copy_focused_element(pid_t pid) {
    if (pid <= 0) return NULL;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.005);
    CFTypeRef focused = NULL;
    AXError error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
    CFRelease(app);
    if (error != kAXErrorSuccess || !focused) return NULL;
    if (CFGetTypeID(focused) != AXUIElementGetTypeID()) {
        CFRelease(focused);
        return NULL;
    }
    return (AXUIElementRef)focused;
}

static void clear_native_target(void) {
    gNativeInitialSource = nil;
    gNativeTargetPID = 0;
    if (gNativeTargetElement) CFRelease(gNativeTargetElement);
    gNativeTargetElement = NULL;
}

static void cancel_native_protection(void) {
    if (gHeldEvents.count > 0) {
        gNativeProtectionCancelled = YES;
        NSBeep();
    }
    [gHeldEvents removeAllObjects];
    gSwitchIsPending = NO;
    gSourceChangeWasObserved = NO;
    gTriggerIsDown = NO;
    gSwitchGeneration += 1;
    clear_native_target();
}

static BOOL should_hold_event(CGEventType type, BOOL switch_is_pending,
                              BOOL is_trigger) {
    return switch_is_pending && !is_trigger &&
           (type == kCGEventKeyDown || type == kCGEventKeyUp);
}

static void print_current_source(void) {
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return;
    NSString *source_id = source_string(current, kTISPropertyInputSourceID);
    printf("%s\n", source_id.UTF8String);
    CFRelease(current);
}

static NSArray *updated_key_mapping(NSArray *mappings, BOOL enabled) {
    if (![mappings isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *mapping in mappings) {
        if (![mapping isKindOfClass:NSDictionary.class]) return nil;
        NSNumber *source = mapping[@"HIDKeyboardModifierMappingSrc"];
        NSNumber *destination = mapping[@"HIDKeyboardModifierMappingDst"];
        if (![source isKindOfClass:NSNumber.class] ||
            ![destination isKindOfClass:NSNumber.class]) return nil;
        BOOL our_key = source.unsignedLongLongValue == 30064771303ULL ||
                       source.unsignedLongLongValue == 30064771302ULL;
        BOOL our_mapping = our_key &&
                           destination.unsignedLongLongValue == 30064771181ULL;
        // Do not overwrite a mapping another tool owns for the same key.
        if (enabled && our_key && !our_mapping) return nil;
        if (!our_mapping) [result addObject:mapping];
    }
    if (enabled) {
        for (NSNumber *source in @[@30064771303ULL, @30064771302ULL]) {
            [result addObject:@{@"HIDKeyboardModifierMappingSrc": source,
                                @"HIDKeyboardModifierMappingDst": @30064771181ULL}];
        }
    }
    return result;
}

static NSArray *copy_key_mapping(void) {
    IOHIDEventSystemClientRef client =
        IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (!client) return nil;
    id current = CFBridgingRelease(IOHIDEventSystemClientCopyProperty(
        client, CFSTR("UserKeyMapping")));
    CFRelease(client);
    if (!current) return @[];
    return updated_key_mapping(current, NO) ? current : nil;
}

static int set_key_mapping(BOOL enabled) {
    NSArray *current = copy_key_mapping();
    if (!current) return 1;
    IOHIDEventSystemClientRef client =
        IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (!client) return 1;
    NSArray *mapping = updated_key_mapping(current, enabled);
    BOOL success = mapping && IOHIDEventSystemClientSetProperty(
        client, CFSTR("UserKeyMapping"), (__bridge CFArrayRef)mapping);
    CFRelease(client);
    return success ? 0 : 1;
}

static void release_held_events_at_proxy(NSUInteger generation, CGEventTapProxy proxy) {
    if (!gSwitchIsPending || generation != gSwitchGeneration) return;

    if (gNativeProtectionActive) {
        if (IsSecureEventInputEnabled()) {
            cancel_native_protection();
            return;
        }
        if (gHeldEvents.count > 0) {
            AXUIElementRef focused = copy_focused_element(gNativeTargetPID);
            BOOL same_element = focused && gNativeTargetElement &&
                                CFEqual(focused, gNativeTargetElement);
            if (focused) CFRelease(focused);
            if (!same_element) {
                cancel_native_protection();
                return;
            }
        }
    }

    gSwitchIsPending = NO;
    gSourceChangeWasObserved = NO;
    NSArray *events = [gHeldEvents copy];
    [gHeldEvents removeAllObjects];
    for (id item in events) {
        CGEventRef event = (__bridge CGEventRef)item;
        CGEventSetIntegerValueField(
            event, kCGEventSourceUserData, kRepostedEventMarker);
        if (proxy) {
            CGEventTapPostEvent(proxy, event);
        } else if (gNativeProtectionActive && gNativeTargetPID > 0) {
            CGEventPostToPid(gNativeTargetPID, event);
        } else {
            CGEventPost(kCGSessionEventTap, event);
        }
    }
    clear_native_target();
}

static void release_held_events(NSUInteger generation) {
    release_held_events_at_proxy(generation, NULL);
}

static void schedule_release(NSUInteger generation, NSTimeInterval delay) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            release_held_events(generation);
        });
}

static void check_native_source(NSUInteger generation) {
    if (!gNativeProtectionActive || !gSwitchIsPending ||
        generation != gSwitchGeneration) return;
    if (IsSecureEventInputEnabled()) {
        cancel_native_protection();
        return;
    }
    if (native_source_is_ready(gNativeInitialSource, current_source_id())) {
        gSourceChangeWasObserved = YES;
        if (!gTriggerIsDown) schedule_release(generation, 0);
        return;
    }
    // Poll only during a switch, because macOS can omit the change notification.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ check_native_source(generation); });
}

static void input_source_changed(CFNotificationCenterRef center,
                                 void *observer, CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef user_info) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)user_info;

    if (!gSwitchIsPending) return;
    if (gNativeProtectionActive) {
        check_native_source(gSwitchGeneration);
        return;
    }
    BOOL current_is_korean = NO;
    if (!current_source_is_korean(&current_is_korean) ||
        current_is_korean != gPendingTargetIsKorean) return;

    gSourceChangeWasObserved = YES;
    if (gHeldEvents.count > 0) {
        schedule_release(gSwitchGeneration, kReadyDelay);
    }
}

static CGEventRef event_tap_callback(CGEventTapProxy proxy, CGEventType type,
                                     CGEventRef event, void *user_info) {
    (void)proxy;
    (void)user_info;

    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (gNativeProtectionActive) {
            release_held_events(gSwitchGeneration);
            gTriggerIsDown = NO;
        }
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) ==
        kRepostedEventMarker) return event;

    if (gNativeProtectionActive) {
        if (IsSecureEventInputEnabled()) {
            cancel_native_protection();
            return event;
        }
        if (gSwitchIsPending &&
            NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != gNativeTargetPID) {
            release_held_events(gSwitchGeneration);
            gTriggerIsDown = NO;
            return event;
        }
        if (type != kCGEventKeyDown && type != kCGEventKeyUp && type != kCGEventFlagsChanged) {
            // Forward queued keys before a click or modifier can move focus.
            release_held_events_at_proxy(gSwitchGeneration, proxy);
            return event;
        }
        CGKeyCode key = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (key == kTriggerKeyCode) {
            if (type == kCGEventKeyDown && !gTriggerIsDown &&
                !CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
                release_held_events_at_proxy(gSwitchGeneration, proxy);
                gNativeProtectionCancelled = NO;
                gTriggerIsDown = YES;
                gSwitchGeneration += 1;
                gNativeInitialSource = current_source_id();
                gNativeTargetPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
                gNativeTargetElement = copy_focused_element(gNativeTargetPID);
                gSwitchIsPending = gNativeInitialSource != nil && gNativeTargetElement != NULL;
                gNativeProtectionUnavailable = !gSwitchIsPending;
                gSourceChangeWasObserved = NO;
                schedule_release(gSwitchGeneration, kSafetyTimeout);
                check_native_source(gSwitchGeneration);
            } else if (type == kCGEventKeyUp) {
                gTriggerIsDown = NO;
                check_native_source(gSwitchGeneration);
            } else {
                return NULL;
            }
            return event;
        }
        CGEventFlags shortcuts = kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                                 kCGEventFlagMaskAlternate;
        if ((CGEventGetFlags(event) & shortcuts) || key == 48 || key == 53) {
            release_held_events_at_proxy(gSwitchGeneration, proxy);
            return event;
        }
    }

    CGKeyCode key_code = (CGKeyCode)CGEventGetIntegerValueField(
        event, kCGKeyboardEventKeycode);
    if (key_code == kTriggerKeyCode) {
        if (type == kCGEventKeyDown && !gTriggerIsDown) {
            gTriggerIsDown = YES;
            BOOL current_is_korean = NO;
            if (!gSwitchIsPending &&
                !current_source_is_korean(&current_is_korean)) {
                return NULL;
            }
            gSwitchGeneration += 1;
            gPendingTargetIsKorean = next_target_is_korean(
                gSwitchIsPending, gPendingTargetIsKorean, current_is_korean);
            gSwitchIsPending = YES;
            gSourceChangeWasObserved = NO;
            if (!select_target_source(gPendingTargetIsKorean)) {
                release_held_events(gSwitchGeneration);
            } else if (gHeldEvents.count > 0) {
                schedule_release(gSwitchGeneration, kSafetyTimeout);
            }
        } else if (type == kCGEventKeyUp) {
            gTriggerIsDown = NO;
        }
        return NULL;
    }

    if (should_hold_event(type, gSwitchIsPending, NO) ||
        (gNativeProtectionActive && gSwitchIsPending && type == kCGEventFlagsChanged)) {
        BOOL first_held_event = gHeldEvents.count == 0;
        CGEventRef copy = CGEventCreateCopy(event);
        if (!copy) return event;
        [gHeldEvents addObject:CFBridgingRelease(copy)];
        if (first_held_event) {
            NSUInteger generation = gSwitchGeneration;
            schedule_release(generation, kSafetyTimeout);
            if (gSourceChangeWasObserved && !gNativeProtectionActive) {
                schedule_release(generation, kReadyDelay);
            }
        }
        return NULL;
    }
    return event;
}

static BOOL start_event_tap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventKeyUp);
    if (gNativeProtectionActive) {
        mask |= CGEventMaskBit(kCGEventFlagsChanged) |
                CGEventMaskBit(kCGEventLeftMouseDown) |
                CGEventMaskBit(kCGEventRightMouseDown) |
                CGEventMaskBit(kCGEventOtherMouseDown);
    }
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
    CFRunLoopAddSource(CFRunLoopGetMain(), gEventTapSource,
                       kCFRunLoopCommonModes);
    CGEventTapEnable(gEventTap, true);
    return YES;
}

static void stop_event_tap(void) {
    if (gSwitchIsPending) release_held_events(gSwitchGeneration);
    gTriggerIsDown = NO;
    gSwitchGeneration += 1;
    clear_native_target();
    if (gEventTapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), gEventTapSource,
                              kCFRunLoopCommonModes);
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
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

@interface HangulMenuController : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *enabledItem;
@property NSMenuItem *nativeItem;
@property NSMenuItem *directItem;
@property NSMenuItem *protectionItem;
@property NSMenuItem *statusMessage;
@property NSMenuItem *helpItem;
@property NSTimer *timer;
@property BOOL enabled;
@property BOOL nativeMode;
@property BOOL firstCharacterProtection;
@property BOOL mappingActive;
@property BOOL mappingFailed;
@property BOOL prompted;
@end

@implementation HangulMenuController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"MappingEnabled": @YES, @"NativeSwitching": @NO,
                                @"NativeFirstCharacterProtection": @NO}];
    self.enabled = [defaults boolForKey:@"MappingEnabled"];
    self.nativeMode = [defaults boolForKey:@"NativeSwitching"];
    self.firstCharacterProtection = [defaults boolForKey:@"NativeFirstCharacterProtection"];
    gHeldEvents = [NSMutableArray array];
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDistributedCenter(), &gNotificationObserver,
        input_source_changed, kTISNotifySelectedKeyboardInputSourceChanged,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    self.statusItem = [NSStatusBar.systemStatusBar
        statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"한/영";
    self.statusItem.button.accessibilityLabel = @"Right Command Hangul";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Right Command Hangul"];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.enabledItem = [menu addItemWithTitle:@"오른쪽 ⌘/Alt → F18 매핑 사용"
        action:@selector(toggleEnabled:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    self.nativeItem = [menu addItemWithTitle:@"macOS 기본 단축키로 전환"
        action:@selector(selectMode:) keyEquivalent:@""];
    self.nativeItem.tag = 1;
    self.directItem = [menu addItemWithTitle:@"앱에서 직접 전환 (기존 방식)"
        action:@selector(selectMode:) keyEquivalent:@""];
    self.protectionItem = [menu addItemWithTitle:@"첫 글자 보호 (실험, 접근성 필요)"
        action:@selector(toggleProtection:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    self.statusMessage = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    self.statusMessage.enabled = NO;
    self.helpItem = [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    self.helpItem.enabled = NO;
    [menu addItemWithTitle:@"키보드 단축키 설정 열기…"
        action:@selector(openKeyboardSettings:) keyEquivalent:@""];
    [menu addItemWithTitle:@"접근성 설정 열기…"
        action:@selector(openAccessibilitySettings:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"종료 (키 매핑 해제)"
        action:@selector(quit:) keyEquivalent:@""];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action) item.target = self;
    }
    self.statusItem.menu = menu;
    [self applyConfiguration];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
        selector:@selector(checkRuntime:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)refreshMenu {
    self.enabledItem.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.nativeItem.state = self.nativeMode ? NSControlStateValueOn : NSControlStateValueOff;
    self.directItem.state = self.nativeMode ? NSControlStateValueOff : NSControlStateValueOn;
    self.protectionItem.state = self.firstCharacterProtection ? NSControlStateValueOn : NSControlStateValueOff;
    self.protectionItem.enabled = self.nativeMode;
    self.statusItem.button.title = self.enabled ? @"한/영" : @"한/영 꺼짐";
    if (self.mappingFailed) {
        self.statusMessage.title = @"키 매핑 변경에 실패했습니다. 충돌 여부를 확인하세요.";
    } else if (!self.enabled) {
        self.statusMessage.title = @"매핑이 꺼져 있습니다.";
    } else if (!self.nativeMode && !gEventTap) {
        self.statusMessage.title = @"접근성 권한을 허용해 주세요.";
    } else if (!self.mappingActive) {
        self.statusMessage.title = @"키 매핑을 적용하지 못했습니다. 충돌 여부를 확인하세요.";
    } else if (self.nativeMode && self.firstCharacterProtection && IsSecureEventInputEnabled()) {
        self.statusMessage.title = @"보안 입력 중에는 첫 글자 보호를 사용할 수 없습니다.";
    } else if (self.nativeMode && self.firstCharacterProtection && !gEventTap) {
        self.statusMessage.title = @"첫 글자 보호에 접근성 권한이 필요합니다.";
    } else if (self.nativeMode && self.firstCharacterProtection && gNativeProtectionCancelled) {
        self.statusMessage.title = @"입력란 변경으로 보호 입력을 취소했습니다. 다시 입력해 주세요.";
    } else if (self.nativeMode && self.firstCharacterProtection && gNativeProtectionUnavailable) {
        self.statusMessage.title = @"현재 입력란을 확인할 수 없어 기본 F18 방식으로 동작합니다.";
    } else if (!self.nativeMode && IsSecureEventInputEnabled()) {
        self.statusMessage.title = @"보안 입력으로 앱 전환이 차단되어 있습니다.";
    } else {
        self.statusMessage.title = gNativeProtectionActive && gEventTap
            ? @"F18 매핑과 첫 글자 보호가 켜져 있습니다." : @"키 매핑이 켜져 있습니다.";
    }
    self.helpItem.title = self.nativeMode
        ? @"‘이전 입력 소스 선택’ 단축키를 F18로 지정하세요."
        : @"앱이 F18을 받아 한영을 전환합니다.";
}

- (void)startDirectSwitching {
    if (!accessibility_is_trusted(!self.prompted)) {
        self.prompted = YES;
        return;
    }
    self.prompted = YES;
    if (!start_event_tap()) NSLog(@"Could not create the keyboard event tap");
}

- (void)applyConfiguration {
    stop_event_tap();
    gNativeProtectionActive = self.nativeMode && self.firstCharacterProtection;
    if (needs_event_tap(self.enabled, self.nativeMode, self.firstCharacterProtection)) {
        [self startDirectSwitching];
    }
    BOOL should_map = self.enabled && (self.nativeMode || gEventTap != NULL);
    if (set_key_mapping(should_map) != 0) {
        NSLog(@"Could not update the Right Command and Right Alt mapping");
        self.mappingFailed = YES;
        stop_event_tap();
    } else {
        self.mappingFailed = NO;
        self.mappingActive = should_map;
    }
    [self refreshMenu];
}

- (void)toggleEnabled:(id)sender {
    (void)sender;
    self.enabled = !self.enabled;
    [NSUserDefaults.standardUserDefaults setBool:self.enabled forKey:@"MappingEnabled"];
    [self applyConfiguration];
}

- (void)selectMode:(NSMenuItem *)sender {
    self.nativeMode = sender.tag == 1;
    [NSUserDefaults.standardUserDefaults setBool:self.nativeMode forKey:@"NativeSwitching"];
    [self applyConfiguration];
}

- (void)toggleProtection:(id)sender {
    (void)sender;
    self.firstCharacterProtection = !self.firstCharacterProtection;
    gNativeProtectionCancelled = NO;
    gNativeProtectionUnavailable = NO;
    [NSUserDefaults.standardUserDefaults setBool:self.firstCharacterProtection
                                         forKey:@"NativeFirstCharacterProtection"];
    [self applyConfiguration];
}

- (void)openKeyboardSettings:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"]];
}

- (void)openAccessibilitySettings:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self refreshMenu];
}

- (void)checkRuntime:(NSTimer *)timer {
    (void)timer;
    if (!gRunning) {
        [NSApp terminate:nil];
        return;
    }
    if (needs_event_tap(self.enabled, self.nativeMode, self.firstCharacterProtection) && !gEventTap &&
        accessibility_is_trusted(NO)) {
        [self applyConfiguration];
    }
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.timer invalidate];
    stop_event_tap();
    if (set_key_mapping(NO) != 0) {
        NSLog(@"Could not clear the Right Command and Right Alt mapping");
    }
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDistributedCenter(), &gNotificationObserver,
        kTISNotifySelectedKeyboardInputSourceChanged, NULL);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--print-mapping") == 0) {
            NSArray *mapping = copy_key_mapping();
            if (!mapping) return 1;
            NSData *data = [NSJSONSerialization dataWithJSONObject:
                @{@"UserKeyMapping": mapping} options:0 error:NULL];
            if (!data) return 1;
            return fwrite(data.bytes, 1, data.length, stdout) == data.length ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--current") == 0) {
            print_current_source();
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--toggle") == 0) {
            BOOL current_is_korean = NO;
            return current_source_is_korean(&current_is_korean) &&
                   select_target_source(!current_is_korean) ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--apply-mapping") == 0) {
            return set_key_mapping(YES);
        }
        if (argc == 2 && strcmp(argv[1], "--clear-mapping") == 0) {
            return set_key_mapping(NO);
        }
        signal(SIGTERM, stop_handler);
        signal(SIGINT, stop_handler);
        for (NSRunningApplication *running in
             [NSRunningApplication runningApplicationsWithBundleIdentifier:
                 @"com.github.right-command-hangul"]) {
            if (running.processIdentifier != getpid()) return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        HangulMenuController *controller = [HangulMenuController new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
