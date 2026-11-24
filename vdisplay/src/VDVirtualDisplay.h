// VDVirtualDisplay: a headless macOS display backed by the private CGVirtualDisplay API.
// The display lives exactly as long as this object (and its process).
//
// Self-contained so it can be dropped into other projects (e.g. Sunshine's macOS platform code).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface VDVirtualDisplay : NSObject

@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) double refreshRate;

/// Creates the display and waits (up to `timeout` seconds) for it to come online.
/// `width` x `height` is always the pixel size. With `hiDPI`, macOS presents it at 2x
/// ("looks like" width/2 x height/2), which is what Wine's RetinaMode expects.
/// `serial` should be stable across runs so macOS remembers the display's arrangement.
/// Returns nil and sets `error` on failure.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                               serial:(uint32_t)serial
                              timeout:(NSTimeInterval)timeout
                                error:(NSError **)error;

/// Destroys the display now instead of waiting for deallocation.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
