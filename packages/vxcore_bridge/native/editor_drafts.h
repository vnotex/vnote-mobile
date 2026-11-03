// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_EDITOR_DRAFTS_H
#define VNOTE_MOBILE_EDITOR_DRAFTS_H

#include <atomic>
#include <cstdint>
#include <nlohmann/json.hpp>
#include <string>
#include <string_view>

namespace vxm_drafts {
using Json = nlohmann::json;
// One policy shared by ordinary writes and durable candidate preparation. The
// returned view borrows source or storage; no conversion allocation for no-op.
std::string_view ProjectDisk(std::string_view source, std::string_view opening_source,
                             int32_t eol, std::string &storage);

struct OwnerFacts {
  std::string notebook_id, node_id, notebook_relative, path_hint, editor_type, disk_hash;
  int32_t eol = 0;
  bool exists = false, ordinary = false;
};
struct PreparedSave {
  std::string document_key, token, candidate_id, notebook_id, node_id;
  std::string notebook_relative, path_hint, editor_type;
  std::string source, source_hash, expected_disk_hash, intended_disk_hash;
  uint64_t revision = 0;
  int32_t eol = 0;
};
// All helpers borrow the caller's owner gate; none opens a core context or writes
// notebook content. Facts MUST be obtained by the native owner, never from JSON.
int32_t Describe(const std::string &root, const std::string &document_key,
                 const std::string &token, Json &out) noexcept;
int32_t LoadCandidate(const std::string &root, const std::string &document_key,
                      const std::string &token, const std::string &candidate_id,
                      PreparedSave &out) noexcept;
int32_t Reconcile(const std::string &root, const std::string &document_key,
                  const std::string &token, const OwnerFacts &facts,
                  Json &out) noexcept;
int32_t CommitSaved(const std::string &root, const std::string &document_key,
                    const std::string &token, const std::string &candidate_id,
                    const OwnerFacts &facts, Json &out) noexcept;
int32_t Run(const Json &request, std::string_view payload,
            const std::atomic<bool> *cancel, Json &out) noexcept;
}  // namespace vxm_drafts
#endif
