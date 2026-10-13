// Build-compatibility header for compiling the FV8 patch inside Node.js.
// NOT part of FV8.
//
// FV8's patch (tools/fv8/patches/V8_patch_122.diff) adds
// `#include "build/build_config.h"` to src/runtime/runtime-test.cc and uses
// BUILDFLAG(IS_ANDROID) twice to choose the VisibleV8 log path. That header
// comes from Chromium's //build directory, which a Chromium checkout provides
// but Node.js's deps/v8 does not include. This file supplies only the macros
// the patch uses, with the meaning Chromium's build/buildflag.h gives them.
// On Linux x64, IS_ANDROID is 0, so the patch takes its non-Android branch
// (log file "vv8-<ms>-<pid>-<tid>-<thread>.<n>.log" in the working directory),
// as it does in the authors' Linux Chromium build.
//
// build-node-runtime.sh copies this file to deps/v8/build/build_config.h only
// for the FV8 variant, and only if that path does not already exist.

#ifndef FV8_NODE_COMPAT_BUILD_CONFIG_H_
#define FV8_NODE_COMPAT_BUILD_CONFIG_H_

#define BUILDFLAG_CAT_INDIRECT(a, b) a##b
#define BUILDFLAG_CAT(a, b) BUILDFLAG_CAT_INDIRECT(a, b)
#define BUILDFLAG(flag) (BUILDFLAG_CAT(BUILDFLAG_INTERNAL_, flag)())

#if defined(__ANDROID__)
#define BUILDFLAG_INTERNAL_IS_ANDROID() (1)
#else
#define BUILDFLAG_INTERNAL_IS_ANDROID() (0)
#endif

#endif  // FV8_NODE_COMPAT_BUILD_CONFIG_H_
