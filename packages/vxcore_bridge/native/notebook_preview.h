// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_NOTEBOOK_PREVIEW_H
#define VNOTE_MOBILE_NOTEBOOK_PREVIEW_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <nlohmann/json.hpp>
#include <vxcore/vxcore.h>

namespace vxm_preview {
// Borrowed context: only the current ordinary NOTE owner may capture source.
// This operation never opens a competing context or changes a notebook body.
int32_t Prepare(VxCoreContextHandle context, const std::string &notebook_id,
                const std::string &node_id, const std::string &note_path,
                const std::string &notebook_root, const nlohmann::json &request,
                const uint8_t *source, size_t source_size,
                const std::atomic<bool> *cancel, nlohmann::json &out) noexcept;
// Filesystem-only immutable capabilities; callers join readers before release.
int32_t Run(const nlohmann::json &request, const std::atomic<bool> *cancel,
            nlohmann::json &out) noexcept;
}  // namespace vxm_preview
#endif
