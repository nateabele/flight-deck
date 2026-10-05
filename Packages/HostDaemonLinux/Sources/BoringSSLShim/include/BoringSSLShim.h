// The only BoringSSL surface the Linux hostd's pairing code is allowed to see.
//
// A copy of FleetKit's shim header, so FleetKit's SPAKE2 sources compile unchanged inside
// this package (see the `PairingCore` symlinks). Importing <openssl/curve25519.h> directly
// would put every other BoringSSL declaration into the module namespace, where any of it
// could be reached by accident and none of it is reviewed for use here. SPAKE2 is the entire
// reason this dependency exists.
#ifndef FLEETKIT_BORINGSSL_SHIM_H
#define FLEETKIT_BORINGSSL_SHIM_H

#include <openssl/curve25519.h>

// Turns one specific silent failure into a loud one. If the include path ever stops
// reaching the pinned BoringSSL headers (`Vendor/boringssl-include`, a symlink to
// vendor/boringssl/include, plus the `-Xcc -I` flag in Package.swift), or reaches a different
// OpenSSL's that lacks SPAKE2, this module can build clean while every SPAKE2 declaration is
// missing. What you see is Swift reporting "cannot find 'SPAKE2_CTX_new' in scope" against
// a module that imported fine, which is a long way from the cause.
#if !defined(SPAKE2_MAX_MSG_SIZE)
#error "openssl/curve25519.h resolved without its declarations. Check that \
Vendor/boringssl-include points at vendor/boringssl/include (run scripts/build-boringssl-linux.sh) \
and that Package.swift passes it with -Xcc -I."
#endif

#endif
