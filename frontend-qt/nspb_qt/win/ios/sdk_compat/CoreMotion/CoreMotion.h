// Stand-in declaration for iOS 27.0 CMMotionManager.deviceMotionBody when cross-compiling
// on Windows against an iOS 26.x SDK. The call site in DmGamepad.m is already guarded at
// runtime by `if (@available(iOS 27.0, *))`.
#ifndef NSPB_SDK_COMPAT_COREMOTION_H
#define NSPB_SDK_COMPAT_COREMOTION_H

#include_next <CoreMotion/CoreMotion.h>

#if !defined(__IPHONE_27_0)
@interface CMMotionManager (NSPBiOS27SDKCompat)
@property (nonatomic, strong, nullable) id deviceMotionBody;
@end
#endif

#endif
