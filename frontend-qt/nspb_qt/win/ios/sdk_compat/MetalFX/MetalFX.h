// Stand-in declarations for iOS 27.0 MetalFX properties when cross-compiling on Windows
// against an iOS 26.x SDK (xybp888/iOS-SDKs). The call sites in nvn_mtl.m are already guarded
// at runtime by `if (@available(macOS 27.0, iOS 27.0, *))`.
#ifndef NSPB_SDK_COMPAT_METALFX_H
#define NSPB_SDK_COMPAT_METALFX_H

#define MTL4FXTemporalScaler MTL4FXTemporalScaler_SDK26
#include_next <MetalFX/MetalFX.h>
#undef MTL4FXTemporalScaler

@protocol MTL4FXTemporalScaler <MTL4FXTemporalScaler_SDK26>
@property (nonatomic) NSUInteger colorContentOffsetX;
@property (nonatomic) NSUInteger colorContentOffsetY;
@property (nonatomic) NSUInteger depthContentOffsetX;
@property (nonatomic) NSUInteger depthContentOffsetY;
@property (nonatomic) NSUInteger motionContentOffsetX;
@property (nonatomic) NSUInteger motionContentOffsetY;
@property (nonatomic) NSUInteger outputOffsetX;
@property (nonatomic) NSUInteger outputOffsetY;
@end

#endif
