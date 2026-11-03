// SPDX-License-Identifier: LGPL-3.0-only
#include "vxcore_host.h"
#include "notebook_sync.h"
#if !defined(VXM_DESKTOP_TEST_API) || defined(__ANDROID__) || defined(VXM_PLATFORM_TLS)
#error The sync fixture helper must never be compiled into a mobile host
#endif
extern "C" VXM_API int32_t vxm_host_test_enable_sync_fixture(void) {
  return vxm_sync::EnableFixtureMode();
}
