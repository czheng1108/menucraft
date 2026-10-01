#import "../Sources/Scroll/MCScrollEngine.h"
@interface MCScrollEngine (Testing)
- (CGEventRef)process:(CGEventRef)event type:(CGEventType)type;
@end
static void Check(BOOL value, const char *message) {
    if (!value) { fprintf(stderr,"FAIL %s\n",message); exit(1); }
    printf("PASS %s\n",message);
}
static CGEventRef Event(int64_t y, int64_t x, BOOL continuous) {
    CGEventRef e=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitLine,2,(int32_t)y,(int32_t)x);
    CGEventSetIntegerValueField(e,kCGScrollWheelEventIsContinuous,continuous);
    return e;
}
int main(void) {
    @autoreleasepool {
        MCScrollEngine *engine=[MCScrollEngine new];
        // In-memory inputs only; no generated input is posted to macOS.
        [engine setValue:@YES forKey:@"wanted"];
        [engine configureMouse:YES trackpad:NO vertical:YES horizontal:NO step:0 onlyRawInput:NO];
        CGEventRef e=Event(3,2,NO); [engine process:e type:kCGEventScrollWheel];
        Check(CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis1)==-3 && CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis2)==2,"Ordinary mouse reverses vertically at system magnitude"); CFRelease(e);
        e=Event(2,1,YES); [engine process:e type:kCGEventScrollWheel];
        Check(engine.lastDevice==1 && CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis1)==2,"First trackpad event after mouse preserves native direction without touch events"); CFRelease(e);
        int phases[]={kCGScrollPhaseMayBegin,kCGScrollPhaseBegan,kCGScrollPhaseChanged,kCGScrollPhaseEnded,kCGScrollPhaseCancelled,0};
        for (int i=0;i<6;i++) {
            e=Event(2,1,YES); CGEventSetIntegerValueField(e,kCGScrollWheelEventScrollPhase,phases[i]);
            [engine process:e type:kCGEventScrollWheel];
            Check(CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis1)==2,"Trackpad phase changes and missing phases never change direction"); CFRelease(e);
        }
        for (int phase=kCGMomentumScrollPhaseBegin;phase<=kCGMomentumScrollPhaseEnd;phase++) {
            e=Event(2,0,NO); [engine process:e type:kCGEventScrollWheel]; CFRelease(e);
            e=Event(2,1,YES); CGEventSetIntegerValueField(e,kCGScrollWheelEventMomentumPhase,phase);
            [engine process:e type:kCGEventScrollWheel];
            Check(engine.lastDevice==1 && CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis1)==2,"Trackpad momentum stays native after an interleaved mouse event"); CFRelease(e);
        }
        [engine configureMouse:NO trackpad:YES vertical:NO horizontal:YES step:0 onlyRawInput:NO];
        e=Event(4,2,YES); CGEventSetIntegerValueField(e,kCGScrollWheelEventPointDeltaAxis2,37); CGEventSetDoubleValueField(e,kCGScrollWheelEventFixedPtDeltaAxis2,2.25);
        [engine process:e type:kCGEventScrollWheel];
        Check(CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis1)==4 && CGEventGetIntegerValueField(e,kCGScrollWheelEventPointDeltaAxis2)==-37 && CGEventGetDoubleValueField(e,kCGScrollWheelEventFixedPtDeltaAxis2)==-2.25,"Trackpad horizontal switch reverses precise deltas while preserving vertical scrolling"); CFRelease(e);
        BOOL combinations=YES;
        for (int mask=0;mask<16;mask++) {
            BOOL mouse=!!(mask&1),trackpad=!!(mask&2),vertical=!!(mask&4),horizontal=!!(mask&8);
            [engine configureMouse:mouse trackpad:trackpad vertical:vertical horizontal:horizontal step:0 onlyRawInput:NO];
            for (int source=0;source<2;source++) {
                e=Event(3,2,source==1); [engine process:e type:kCGEventScrollWheel];
                BOOL reverse=source ? trackpad : mouse;
                combinations &= CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis1)==(reverse&&vertical?-3:3);
                combinations &= CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis2)==(reverse&&horizontal?-2:2);
                CFRelease(e);
            }
        }
        Check(combinations,"All 16 four-switch combinations keep devices and axes independent");
        [engine stop]; e=Event(2,0,NO); [engine process:e type:kCGEventScrollWheel];
        Check(CGEventGetIntegerValueField(e,kCGScrollWheelEventDeltaAxis1)==2,"Stopped controller passes events unchanged"); CFRelease(e);
        puts("Scroll direction regression checks completed.");
    }
    return 0;
}
