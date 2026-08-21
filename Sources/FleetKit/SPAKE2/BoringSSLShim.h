// The only BoringSSL surface FleetKit is allowed to see.
//
// Importing <openssl/curve25519.h> directly would put every other BoringSSL
// declaration into FleetKit's module namespace, where any of it could be reached
// by accident and none of it is reviewed for use here. SPAKE2 is the entire
// reason this dependency exists.
#ifndef FLEETKIT_BORINGSSL_SHIM_H
#define FLEETKIT_BORINGSSL_SHIM_H

#include <openssl/curve25519.h>

// Turns one specific silent failure into a loud one. If the openssl headers are ever
// reachable from a directory that another module's umbrella header claims — which is what
// happens the moment they are copied into BUILT_PRODUCTS_DIR/include, where libghostty's
// `module.modulemap` declares an umbrella for the whole directory — then the #include above
// resolves to `@import ThatModule` instead, this module builds perfectly clean, and every
// SPAKE2 declaration silently vanishes. What you see is Swift reporting "cannot find
// 'SPAKE2_CTX_new' in scope" against a module that imported fine, which is a long way from
// the cause. See the header-staging note in scripts/build-boringssl.sh.
#if !defined(SPAKE2_MAX_MSG_SIZE)
#error "openssl/curve25519.h resolved without its declarations — another module's umbrella \
header has almost certainly claimed the openssl headers. Check HEADER_SEARCH_PATHS."
#endif

#endif
