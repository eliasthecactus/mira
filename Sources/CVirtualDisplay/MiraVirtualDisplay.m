#import "MiraVirtualDisplay.h"

// Private CoreGraphics interfaces (macOS 11+). Declared here only so the compiler
// knows the selectors; classes are resolved with NSClassFromString at runtime.
@interface CGVirtualDisplayDescriptor : NSObject
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@property (copy, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id _Nullable, id _Nullable);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end

@implementation MiraVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor")
        && NSClassFromString(@"CGVirtualDisplayMode") && NSClassFromString(@"CGVirtualDisplaySettings");
}

- (nullable instancetype)initWithName:(NSString *)name width:(unsigned int)width
                               height:(unsigned int)height refreshRate:(double)refreshRate {
    if (!(self = [super init])) return nil;
    if (![MiraVirtualDisplay isSupported]) return nil;

    CGVirtualDisplayDescriptor *d = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    [d setDispatchQueue:dispatch_get_main_queue()];
    d.name = name;
    d.maxPixelsWide = width;
    d.maxPixelsHigh = height;
    // A 55" 16:9 TV; only affects the DPI macOS assumes.
    d.sizeInMillimeters = CGSizeMake(1218, 685);
    d.vendorID = 0x4D52;           // "MR"
    d.productID = 0x4D49;          // "MI"
    d.serialNum = 1;
    // sRGB / D65 primaries; some macOS versions reject displays without colorimetry.
    d.redPrimary = CGPointMake(0.6400, 0.3300);
    d.greenPrimary = CGPointMake(0.3000, 0.6000);
    d.bluePrimary = CGPointMake(0.1500, 0.0600);
    d.whitePoint = CGPointMake(0.3127, 0.3290);
    d.terminationHandler = ^(id reason, id display) { NSLog(@"Mira: virtual display terminated"); };

    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
    if (!_display) return nil;

    CGVirtualDisplaySettings *s = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    s.hiDPI = 0;
    s.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:refreshRate]];
    if (![_display applySettings:s]) return nil;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
