# Links the prebuilt wezig Zig static lib into the JNI shared object.
#
# The Zig core is built OUTSIDE Gradle (build-zig-libs.sh) into a per-ABI staging
# dir; here we just import that static archive and link it into libwezigshell.so
# together with the JNI shim. The bridging header (wezig_mobile.h) is shared with
# the iOS shell — copied in by build-zig-libs.sh so this dir is self-contained
# for the NDK build.
cmake_minimum_required(VERSION 3.22.1)
project(wezigshell C)

# WEZIG_ZIG_STAGE_DIR is passed from Gradle (app/build.gradle) as the staging
# BASE dir; the per-ABI lib lives at ${WEZIG_ZIG_STAGE_DIR}/${ANDROID_ABI}. We
# resolve ANDROID_ABI HERE (CMake knows it per-ABI configure), NOT in the Gradle
# argument — AGP does not macro-expand ${ANDROID_ABI} in cmake arguments.
if(NOT DEFINED WEZIG_ZIG_STAGE_DIR)
    message(FATAL_ERROR "WEZIG_ZIG_STAGE_DIR must be set (Zig static-lib staging base dir)")
endif()

set(WEZIG_ZIG_LIB "${WEZIG_ZIG_STAGE_DIR}/${ANDROID_ABI}/libwezig_mobile.a")
if(NOT EXISTS "${WEZIG_ZIG_LIB}")
    message(FATAL_ERROR "missing Zig static lib for ${ANDROID_ABI}: ${WEZIG_ZIG_LIB} (run build-zig-libs.sh first)")
endif()

add_library(wezig_mobile STATIC IMPORTED)
set_target_properties(wezig_mobile PROPERTIES
    IMPORTED_LOCATION "${WEZIG_ZIG_LIB}")

# The JNI shims: the toolchain greeting proof (wezig_jni.c) + the Renderer
# backend bridge (wezig_renderer_jni.c, spec story 5) + the ViewHandle-embedding
# bridge (wezig_embedding_jni.c, spec Q3/story 6) + the real-app shell bridge
# (wezig_shell_jni.c, spec build-mobile-shell stories 2/3/4/5/6). All link the
# Zig core.
add_library(wezigshell SHARED
    wezig_jni.c
    wezig_renderer_jni.c
    wezig_embedding_jni.c
    wezig_shell_jni.c)
target_include_directories(wezigshell PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(wezigshell wezig_mobile log)
