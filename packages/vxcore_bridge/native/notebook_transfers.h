// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_NOTEBOOK_TRANSFERS_H
#define VNOTE_MOBILE_NOTEBOOK_TRANSFERS_H

#include <atomic>
#include <cstdint>
#include <string>
#include <nlohmann/json.hpp>
#include <vxcore/vxcore.h>

namespace vxm_transfer {
// Synchronous borrowed arguments: call only on the host's core owner/gate.
// Preflight is mandatory BEFORE creating a notebook or opening a buffer.
int32_t PreflightCohortBuilder(const std::string &transaction_root,
                              nlohmann::json &options) noexcept;
int32_t PreflightResource(VxCoreContextHandle context,
                          const std::string &notebook_id,
                          const std::string &node_id,
                          const std::string &notebook_root,
                          nlohmann::json &metadata) noexcept;
int32_t Cohort(VxCoreContextHandle context, const std::string &notebook_id,
               const std::string &notebook_root, const nlohmann::json &request,
               const std::atomic<bool> *cancel, nlohmann::json &out) noexcept;
int32_t Resource(VxCoreContextHandle context, const std::string &notebook_id,
                 const std::string &node_id, const std::string &note_path,
                 const std::string &buffer_id, const std::string &notebook_root,
                 const nlohmann::json &request, const std::atomic<bool> *cancel,
                 nlohmann::json &out) noexcept;
}  // namespace vxm_transfer
#endif
