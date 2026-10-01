// Adapted from Scroll Reverser 1.9, MouseTap.m.
// Copyright (c) 2011-2024 Nick Moore / Pilotmoon Software.
// Licensed under Apache License 2.0; see bundled ThirdParty/ScrollReverser.
// MenuCraft changes: dedicated run loop, deterministic wheel/trackpad event routing,
// configuration snapshot, optional HID lookup, horizontal fix, lifecycle/counters.
#import "MCScrollEngine.h"
#import <dlfcn.h>

typedef void *HIDEvent;
typedef HIDEvent (*CopyHID)(CGEventRef);
typedef double (*GetHID)(HIDEvent, uint32_t);
typedef void (*SetHID)(HIDEvent, uint32_t, double);
typedef struct { BOOL mouse, trackpad, vertical, horizontal, raw; NSInteger step; } MCScrollOptions;

@interface MCScrollEngine () {
    NSThread *_thread;
    BOOL _wanted;
    MCScrollOptions _options;
    CFMachPortRef _active;
    CFRunLoopSourceRef _activeSource;
    CFRunLoopRef _runLoop;
    CopyHID _copyHID;
    GetHID _getHID;
    SetHID _setHID;
}
@property(atomic, readwrite) BOOL running;
@property(atomic, readwrite) unsigned long long eventCount;
@property(atomic, readwrite) unsigned long long modifiedCount;
@property(atomic, readwrite) NSInteger lastDevice;
- (CGEventRef)process:(CGEventRef)event type:(CGEventType)type;
@end

static CGEventRef MCCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    @autoreleasepool { return [(__bridge MCScrollEngine *)context process:event type:type]; }
}
@implementation MCScrollEngine
- (instancetype)init {
    if ((self = [super init])) {
        _copyHID = (CopyHID)dlsym(RTLD_DEFAULT, "CGEventCopyIOHIDEvent");
        _getHID = (GetHID)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
        _setHID = (SetHID)dlsym(RTLD_DEFAULT, "IOHIDEventSetFloatValue");
    }
    return self;
}
- (void)configureMouse:(BOOL)mouse trackpad:(BOOL)trackpad vertical:(BOOL)vertical horizontal:(BOOL)horizontal step:(NSInteger)step onlyRawInput:(BOOL)raw {
    @synchronized(self) { _options = (MCScrollOptions){mouse, trackpad, vertical, horizontal, raw, MAX(0, MIN(100, step))}; }
}
- (void)start {
    @synchronized(self) {
        _wanted = YES;
        if (_thread) return;
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        _thread.name = @"MenuCraft scroll events";
        [_thread start];
    }
}
- (void)stop {
    CFRunLoopRef loop = NULL;
    @synchronized(self) {
        _wanted = NO;
        if (_runLoop) loop = (CFRunLoopRef)CFRetain(_runLoop);
    }
    if (loop) {
        // A queued block also handles stop arriving before CFRunLoopRun starts.
        CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{
            @synchronized(self) { if (!_wanted) CFRunLoopStop(loop); }
        });
        CFRunLoopWakeUp(loop);
        CFRelease(loop);
    }
}
- (void)run {
    @autoreleasepool {
        self.lastDevice = 0;
        @synchronized(self) { _runLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent()); }
        _active = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap, kCGEventTapOptionDefault, NSEventMaskScrollWheel, MCCallback, (__bridge void *)self);
        BOOL created = _active != NULL;
        if (_active) {
            _activeSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _active, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), _activeSource, kCFRunLoopCommonModes);
            BOOL wanted;
            @synchronized(self) { wanted = _wanted; }
            self.running = wanted;
            if (wanted) CFRunLoopRun();
        }
        self.running = NO;
        if (_activeSource) { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _activeSource, kCFRunLoopCommonModes); CFRelease(_activeSource); _activeSource = NULL; }
        if (_active) { CFMachPortInvalidate(_active); CFRelease(_active); _active = NULL; }
        BOOL restart;
        @synchronized(self) {
            CFRelease(_runLoop); _runLoop = NULL; _thread = nil;
            // A permission failure is retried by the host, not a spinning thread.
            restart = _wanted && created;
        }
        if (restart) [self start];
    }
}
- (CGEventRef)process:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (_active) CGEventTapEnable(_active, true);
        self.running = _active && CGEventTapIsEnabled(_active);
        return event;
    }
    if (type != kCGEventScrollWheel) return event;
    MCScrollOptions options;
    @synchronized(self) { if (!_wanted) return event; options = _options; }
    BOOL continuous = CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous) != 0;
    // Ordinary wheel events are discrete, Mac trackpad events are continuous.
    // Classify each event independently: missing touches, the first event, momentum,
    // and switching devices must never make a trackpad inherit mouse reversal.
    // Touch mice / software-smoothed wheels also emit continuous events and follow
    // the trackpad option in this mode; do not claim to distinguish that hardware.
    NSInteger device = continuous ? 1 : 0;
    self.lastDevice = device; self.eventCount = self.eventCount + 1;
    if (options.raw && CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) != 0) return event;
    BOOL reverse = device == 1 ? options.trackpad : options.mouse;
    int64_t y = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    int64_t x = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
    int64_t yp = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    int64_t xp = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
    double yf = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
    double xf = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2);
    BOOL discrete = !continuous && options.step > 0 && llabs(y) == 1;
    NSInteger vmul = (reverse && options.vertical ? -1 : 1) * (discrete ? options.step : 1);
    NSInteger hmul = reverse && options.horizontal ? -1 : 1;
    if (vmul == 1 && hmul == 1 && !discrete) return event;
    HIDEvent hid = _copyHID && _getHID && _setHID ? _copyHID(event) : NULL;
    const uint32_t hidY = (6 << 16) | 1, hidX = (6 << 16) | 0;
    double hy = hid ? _getHID(hid, hidY) : 0, hx = hid ? _getHID(hid, hidX) : 0;
    // Set line deltas first: macOS recalculates point and fixed-point fields here.
    if (vmul != 1 || discrete) CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, y * vmul);
    if (!discrete && vmul != 1) {
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, yf * vmul);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, yp * vmul);
        if (hid) _setHID(hid, hidY, hy * vmul);
    }
    if (hmul != 1) {
        CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, x * hmul);
        CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, xf * hmul);
        CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, xp * hmul);
        if (hid) _setHID(hid, hidX, hx * hmul);
    }
    if (hid) CFRelease(hid);
    self.modifiedCount = self.modifiedCount + 1;
    return event;
}
@end
