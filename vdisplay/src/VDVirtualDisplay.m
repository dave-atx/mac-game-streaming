#import "VDVirtualDisplay.h"

// ---- Private CoreGraphics API (CGVirtualDisplay, macOS 11+) ----------------------------------
// Declared here rather than in a header so this file stays self-contained.

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(retain, nonatomic) dispatch_queue_t queue;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// -------------------------------------------------------------------------------------------

static NSString *const VDErrorDomain = @"VDVirtualDisplay";

static NSError *VDError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:VDErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Arbitrary vendor ID outside the range real panels use, so the display is recognizable.
static const unsigned int kVDVendorID = 0x5644;  // "VD"
static const unsigned int kVDProductID = 0x0001;

static BOOL VDDisplayIsOnline(CGDirectDisplayID displayID) {
  CGDirectDisplayID ids[32];
  uint32_t count = 0;
  if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess) {
    return NO;
  }
  for (uint32_t i = 0; i < count; i++) {
    if (ids[i] == displayID) {
      return YES;
    }
  }
  return NO;
}

@implementation VDVirtualDisplay {
  CGVirtualDisplay *_display;
}

- (nullable instancetype)initWithName:(NSString *)name
                                width:(NSUInteger)width
                               height:(NSUInteger)height
                          refreshRate:(double)refreshRate
                                hiDPI:(BOOL)hiDPI
                               serial:(uint32_t)serial
                              timeout:(NSTimeInterval)timeout
                                error:(NSError **)error {
  if (!(self = [super init])) {
    return nil;
  }
  if (!NSClassFromString(@"CGVirtualDisplay")) {
    if (error) *error = VDError(1, @"CGVirtualDisplay is not available on this macOS version");
    return nil;
  }
  if (width < 640 || height < 480 || width > 7680 || height > 4320 || refreshRate < 24 || refreshRate > 240) {
    if (error) *error = VDError(2, [NSString stringWithFormat:@"Unsupported mode %lux%lu@%g",
                                                              (unsigned long)width, (unsigned long)height, refreshRate]);
    return nil;
  }

  CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
  descriptor.name = name;
  descriptor.maxPixelsWide = (unsigned int)width;
  descriptor.maxPixelsHigh = (unsigned int)height;
  // Claim a low-density (96 ppi) panel: macOS marks its "default" mode from the physical size, and
  // Wine resets to that default on fullscreen changes. At 96 ppi the default is our native mode;
  // denser panels default to a smaller "looks like" mode (2560x1440 at 163 ppi defaulted to 1280x720).
  // Limit: at 3840x2160 macOS marks 1920x1080 as default at any density.
  const double mmPerPixel = 25.4 / 96.0;
  // Size from points, so a HiDPI display gets the same low-density treatment.
  descriptor.sizeInMillimeters = CGSizeMake(width / (hiDPI ? 2 : 1) * mmPerPixel, height / (hiDPI ? 2 : 1) * mmPerPixel);
  descriptor.vendorID = kVDVendorID;
  descriptor.productID = kVDProductID;
  descriptor.serialNum = serial;
  descriptor.queue = dispatch_get_main_queue();

  CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
  if (!display || display.displayID == kCGNullDirectDisplay) {
    if (error) *error = VDError(3, @"WindowServer refused to create the virtual display");
    return nil;
  }

  // One mode at exactly the client's pixel size. Without HiDPI, points == pixels. With HiDPI the mode
  // is given in points and macOS backs it at 2x.
  CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
  const NSUInteger scale = hiDPI ? 2 : 1;
  settings.hiDPI = hiDPI ? 1 : 0;
  settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width / scale
                                                                                 height:height / scale
                                                                            refreshRate:refreshRate]];
  if (![display applySettings:settings]) {
    if (error) *error = VDError(4, @"Failed to apply the virtual display mode");
    return nil;
  }

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  while (!VDDisplayIsOnline(display.displayID)) {
    if ([deadline timeIntervalSinceNow] <= 0) {
      if (error) *error = VDError(5, @"Virtual display did not come online in time");
      return nil;
    }
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }

  // A new display can land in a mirror set with an existing one; break that.
  if (CGDisplayIsInMirrorSet(display.displayID)) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
      CGConfigureDisplayMirrorOfDisplay(config, display.displayID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    }
  }

  // macOS adds its own standard modes up to the maximum and picks a default (often 1280x720),
  // so select ours explicitly.
  CGDisplayModeRef chosen = NULL;
  CFArrayRef modes = CGDisplayCopyAllDisplayModes(
      display.displayID, (__bridge CFDictionaryRef) @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
  for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
    if (CGDisplayModeGetPixelWidth(m) == width && CGDisplayModeGetPixelHeight(m) == height &&
        CGDisplayModeGetWidth(m) == width / scale &&
        (!chosen || fabs(CGDisplayModeGetRefreshRate(m) - refreshRate) <
                        fabs(CGDisplayModeGetRefreshRate(chosen) - refreshRate))) {
      chosen = m;
    }
  }
  CGError modeErr = kCGErrorFailure;
  if (chosen) {
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
      modeErr = CGConfigureDisplayWithDisplayMode(config, display.displayID, chosen, NULL);
      modeErr = modeErr == kCGErrorSuccess ? CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly)
                                           : (CGCancelDisplayConfiguration(config), modeErr);
    }
  }
  if (modes) CFRelease(modes);
  if (modeErr != kCGErrorSuccess) {
    if (error) *error = VDError(4, [NSString stringWithFormat:@"Could not select %lux%lu@%g on the virtual display",
                                                              (unsigned long)width, (unsigned long)height, refreshRate]);
    return nil;
  }

  _display = display;
  _displayID = display.displayID;
  _width = width;
  _height = height;
  _refreshRate = refreshRate;
  return self;
}

- (void)invalidate {
  _display = nil;
}

- (void)dealloc {
  [self invalidate];
}

@end
