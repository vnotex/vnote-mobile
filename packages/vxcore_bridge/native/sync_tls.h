#pragma once

#include <vxcore/vxcore.h>

// Mobile only. Desktop callers retain the core's ordinary curl trust policy.
// Install once, before the context owns any sync backend or lifecycle task.
namespace vxm_sync_tls {
bool Available() noexcept;
VxCoreError Configure(VxCoreContextHandle context) noexcept;
}  // namespace vxm_sync_tls
