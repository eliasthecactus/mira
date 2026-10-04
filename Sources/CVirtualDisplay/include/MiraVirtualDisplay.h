#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A virtual monitor macOS treats like a real one, so the TV can be used as an
/// extended desktop. Built on CoreGraphics' private CGVirtualDisplay classes (the
/// same ones used by display utilities); looked up at runtime, so a macOS release
/// that removes or blocks them makes +isSupported return NO instead of crashing.
@interface MiraVirtualDisplay : NSObject

+ (BOOL)isSupported;

/// Returns nil if the classes are unavailable or WindowServer refuses the settings.
- (nullable instancetype)initWithName:(NSString *)name
                                width:(unsigned int)width
                               height:(unsigned int)height
                          refreshRate:(double)refreshRate;

@property (readonly, nonatomic) CGDirectDisplayID displayID;

@end

NS_ASSUME_NONNULL_END
