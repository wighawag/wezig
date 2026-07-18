/*
 * C-ABI surface for the wezig mobile static library (src/mobile_abi.zig).
 *
 * This is the bridging header the iOS Swift shell imports (via
 * `-import-objc-header`) to call the Zig `export fn`s and prove the Zig core is
 * linked and live. The same functions are used by the Android JNI shim. Keep
 * these declarations in lock-step with `src/mobile_abi.zig`.
 */
#ifndef WEZIG_MOBILE_H
#define WEZIG_MOBILE_H

#ifdef __cplusplus
extern "C" {
#endif

/* The mobile C-ABI contract version (matches mobile_abi.abi_version). */
int wezig_abi_version(void);

/* A NUL-terminated greeting owned by the library (do NOT free it). */
const char *wezig_greeting(void);

#ifdef __cplusplus
}
#endif

#endif /* WEZIG_MOBILE_H */
