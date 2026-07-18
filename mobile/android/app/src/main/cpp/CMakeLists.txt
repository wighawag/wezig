# Links the prebuilt wezig Zig static lib into the JNI shared object.
#
# The Zig core is built OUTSIDE Gradle (build-zig-libs.sh) into a per-ABI staging
# dir; here we just import that static archive and link it into libwezigshell.so
# together with the JNI shim. The bridging header (wezig_mobile.h) is shared with
# the iOS shell — copied in by build-zig-libs.sh so this dir is self-contained
# for the NDK build.
cmake_minimum_required(VERSION 3.22.1)
project(wezigshell C)

# WEZIG_ZIG_LIB_DIR is passed from Gradle (app/build.gradle) per ABI: it points
# at the dir holding libwezig_mobile.a for ${ANDROID_ABI}.
if(NOT DEFINED WEZIG_ZIG_LIB_DIR)
    message(FATAL_ERROR "WEZIG_ZIG_LIB_DIR must be set (per-ABI Zig static lib dir)")
endif()

add_library(wezig_mobile STATIC IMPORTED)
set_target_properties(wezig_mobile PROPERTIES
    IMPORTED_LOCATION "${WEZIG_ZIG_LIB_DIR}/libwezig_mobile.a")

add_library(wezigshell SHARED wezig_jni.c)
target_include_directories(wezigshell PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(wezigshell wezig_mobile log)
