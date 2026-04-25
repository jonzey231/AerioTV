//
//  MPMediaItemArtworkShim.h
//  Aerio
//
//  Wraps the pre-iOS-10 `-[MPMediaItemArtwork initWithImage:]` initializer
//  inside `#pragma clang diagnostic` markers so the deprecation warning
//  doesn't pollute the iOS / Mac Catalyst build log.
//
//  Why we still use the deprecated init:
//  --------------------------------------
//  Apple's recommended replacement is the closure-based
//  `+[MPMediaItemArtwork initWithBoundsSize:requestHandler:]`. iOS resolves
//  that closure on an internal serial queue inside MediaPlayer.framework.
//  When the lockscreen requests artwork during playback transitions
//  (especially on iOS 17+ devices we've reproduced this on), the resolution
//  path triggers `_dispatch_assert_queue_fail`, which crashes the now-playing
//  publisher. Crash reports symbolicate to dispatch internals; we can't
//  intervene from app code.
//
//  The deprecated `initWithImage:` retains the UIImage at construction time —
//  no closure for iOS to dispatch — and avoids the crash entirely. It still
//  works on every version of iOS we ship to (deprecated since iOS 10 means
//  "discouraged but functional", not "removed"). Apple has not signalled an
//  upcoming removal.
//
//  Wiring:
//      Aerio_iOS target only.
//      SWIFT_OBJC_BRIDGING_HEADER → Shared/AerioObjC/Aerio-Bridging-Header.h
//      Aerio-Bridging-Header.h #imports this header so Swift sees the function.
//      tvOS target doesn't compile this — its NowPlaying flow is gated
//      behind `#if os(iOS)` in the call site, so the shim is unreachable there.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns an `MPMediaItemArtwork` constructed with the deprecated
/// `-initWithImage:` initializer. See header docstring for why we
/// don't use the closure-based replacement.
///
/// @param image  The artwork image. Retained directly by the returned
///               artwork object.
/// @return       A newly-constructed `MPMediaItemArtwork`.
MPMediaItemArtwork *AerioMakeMPMediaItemArtwork(UIImage *image);

NS_ASSUME_NONNULL_END
