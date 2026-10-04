// Empty on purpose: SwiftPM will not build a C target with no translation unit, and this target
// exists only to carry include/BoringSSLShim.h (the SPAKE2 surface) and the -lcrypto link line.
