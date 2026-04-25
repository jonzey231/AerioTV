//
//  Aerio-Bridging-Header.h
//  Aerio_iOS target only.
//
//  Imports the Aerio ObjC shims so Swift code sees their declarations.
//  Wired via the `SWIFT_OBJC_BRIDGING_HEADER` build setting on the
//  Aerio_iOS target's Debug + Release configurations. The tvOS target
//  has no bridging header because there's no ObjC code on tvOS — every
//  shim here is iOS / Mac Catalyst only.
//
//  Adding new shims:
//    1. Drop the `.h` + `.m` into Shared/AerioObjC/
//    2. Add the `.m` to the Aerio_iOS target's Compile Sources build phase
//    3. `#import "YourShim.h"` here
//

#ifndef Aerio_Bridging_Header_h
#define Aerio_Bridging_Header_h

#import "MPMediaItemArtworkShim.h"

#endif /* Aerio_Bridging_Header_h */
