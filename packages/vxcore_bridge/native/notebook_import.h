// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_NOTEBOOK_IMPORT_H
#define VNOTE_MOBILE_NOTEBOOK_IMPORT_H

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace vxm_import {
struct Inspection {
  std::string notebook_id;
  std::string notebook_name;
  std::vector<std::string> node_ids;
};
// Filesystem only. Also used on the dedicated core owner before its permissive
// collector, so malformed graphs cannot masquerade as complete identity sets.
int32_t inspect_managed(const std::filesystem::path &root,
                        const std::string &expected_id, Inspection &out) noexcept;
}  // namespace vxm_import
#endif
