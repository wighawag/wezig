/*
 * JNI shim for the wezig Android shell (toolchain proof).
 *
 * This is the thin C-ABI/JNI surface between Java and the wezig Zig static
 * library: Gradle/NDK links the prebuilt `libwezig_mobile.a` into this shared
 * object (`libwezigshell.so`), which Java loads via System.loadLibrary. The
 * shim calls the Zig `export fn`s (declared in wezig_mobile.h) to prove the Zig
 * core is linked and callable from the Android process.
 */
#include <jni.h>
#include <string.h>
#include "wezig_mobile.h"

/*
 * dev.wighawag.wezig.MainActivity.nativeGreeting() -> String
 * Returns "<greeting> (abi vN)" built from the Zig core, proving linkage.
 */
JNIEXPORT jstring JNICALL
Java_dev_wighawag_wezig_MainActivity_nativeGreeting(JNIEnv *env, jobject thiz) {
    (void)thiz;
    int abi = wezig_abi_version();
    const char *greeting = wezig_greeting();

    char buf[256];
    snprintf(buf, sizeof(buf), "%s (abi v%d)", greeting, abi);
    return (*env)->NewStringUTF(env, buf);
}
