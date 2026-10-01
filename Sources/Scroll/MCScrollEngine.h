#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// Device detection and delta handling adapted from Scroll Reverser 1.9 (Apache 2.0).
@interface MCScrollEngine : NSObject
@property(atomic, readonly) BOOL running;
@property(atomic, readonly) unsigned long long eventCount;
@property(atomic, readonly) unsigned long long modifiedCount;
@property(atomic, readonly) NSInteger lastDevice;
- (void)configureMouse:(BOOL)mouse trackpad:(BOOL)trackpad vertical:(BOOL)vertical horizontal:(BOOL)horizontal step:(NSInteger)step onlyRawInput:(BOOL)onlyRawInput;
- (void)start;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
