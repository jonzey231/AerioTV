//
//  MPMediaItemArtworkShim.m
//  Aerio
//
//  See MPMediaItemArtworkShim.h for the why.
//

#import "MPMediaItemArtworkShim.h"

MPMediaItemArtwork *AerioMakeMPMediaItemArtwork(UIImage *image) {
    // The diagnostic push/pop pair is the only correct way to silence
    // a single-call-site deprecation warning in Clang. Wider scopes
    // (per-file, project-wide) would mask future legitimate
    // deprecations elsewhere in this translation unit.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[MPMediaItemArtwork alloc] initWithImage:image];
#pragma clang diagnostic pop
}
