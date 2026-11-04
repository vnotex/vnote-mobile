// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_NOTEBOOK_IMPORT_H
#define VNOTE_MOBILE_NOTEBOOK_IMPORT_H

#include <cstdint>
#include <atomic>
#include <mutex>
#include <nlohmann/json.hpp>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

struct VxmImportCancel;
namespace vxm_import {
// One process-wide gate for filesystem admission, export work and activation.
// Recursive because owner jobs reuse TransferRun while holding this gate.
std::recursive_mutex &AdmissionMutex();
// Historical scans/intent schemas remain bounded at 4 GiB. Only new positive
// admission is capped here; zero scans above this ceiling return remaining=0.
constexpr uint64_t kAdmissionBytes = 3ULL * 1024 * 1024 * 1024;
int32_t CheckAdmission(const std::filesystem::path &support_root, uint64_t required) noexcept;
int32_t CheckShareExport(const char *support_root, uint64_t required) noexcept;
int32_t ActivateInbox(const char *support_root, const char *inbox_root) noexcept;
int32_t ProveInbox(const char *support_root, const char *claim_json, const char *disposition) noexcept;
void ReleaseCloneBudget(const std::string &transaction_root) noexcept;
// These are host-internal; no filesystem command can mint a clone permit.
int32_t PreflightClone(const std::string &transaction_root, nlohmann::json &options) noexcept;
// The requested maximum is reduced to current capacity after private owner creation.
int32_t CheckClone(const std::string &transaction_root, const std::string &operation_id, uint64_t &budget) noexcept;
int32_t SealClone(const std::string &transaction_root, const std::string &operation_id,
                  const std::string &notebook_id, bool auto_sync_enabled) noexcept;
// Returns only the routing values authorized by an unsettled committed clone.
int32_t CommittedCloneConfiguration(const std::string &notebook_root, const std::string &notebook_id,
                                    const std::string &import_id, const std::string &operation_id,
                                    nlohmann::json &configuration) noexcept;
struct Inspection {
  std::string notebook_id;
  std::string notebook_name;
  std::vector<std::string> node_ids;
};
// Filesystem only. Also used on the dedicated core owner before its permissive
// collector, so malformed graphs cannot masquerade as complete identity sets.
int32_t inspect_managed(const std::filesystem::path &root,
                        const std::string &expected_id, Inspection &out) noexcept;

// Owner jobs and the public FS command use the same no-follow implementation.
int32_t TransferRun(const nlohmann::json &request, const std::atomic<bool> *cancel,
                    nlohmann::json &out) noexcept;
struct StorageFailure { int32_t code; };
namespace storage {
using Json = nlohmann::json;
void Check(bool condition, int32_t code);
void Name(const std::string &name);
void Relative(const std::string &path);
std::string Fold(const std::string &name);
std::filesystem::path Absolute(const std::string &path);
bool Exists(const std::filesystem::path &path);
Json Info(const std::filesystem::path &path, bool hash = false,
          const std::atomic<bool> *cancel = nullptr, uint64_t limit = 1024ULL * 1024 * 1024);
Json ReadJson(const std::filesystem::path &path, size_t limit = 8 * 1024 * 1024);
Json Parse(std::string_view input, size_t limit);
std::string Hash(std::string_view input);
const std::atomic<bool> *Cancellation(const VxmImportCancel *cancel);
void Bytes(const std::filesystem::path &path, std::string_view bytes);
void Append(const std::filesystem::path &path, uint64_t committed_offset,
            std::string_view bytes, const Json *expected = nullptr);
void Truncate(const std::filesystem::path &path, uint64_t committed_offset,
              const Json *expected = nullptr);
std::string Read(const std::filesystem::path &path, size_t limit);
std::string Header(const std::filesystem::path &path, size_t count);
void Marker(const std::filesystem::path &directory, const std::string &name,
            const Json &value, size_t limit = 16384);
void ReplaceMarker(const std::filesystem::path &directory, const std::string &name,
                   const Json &expected, const Json &value, size_t limit = 16384);
void MakeDirectory(const std::filesystem::path &path);
void Move(const std::filesystem::path &source, const std::filesystem::path &target);
void RemovePrivate(const std::filesystem::path &path);
void FlushDirectory(const std::filesystem::path &path);
Json Copy(const std::filesystem::path &source, const std::filesystem::path &target,
          uint64_t limit, const std::atomic<bool> *cancel = nullptr);
Json CopyChecked(const std::filesystem::path &source, const std::filesystem::path &target,
                 uint64_t limit, const Json &expected,
                 const std::atomic<bool> *cancel = nullptr);
Json Tree(const std::filesystem::path &root, const std::atomic<bool> *cancel = nullptr);
Json CopyTree(const std::filesystem::path &source, const std::filesystem::path &target,
              const std::atomic<bool> *cancel = nullptr);
Json Transaction(const std::string &root, const std::string &scope);
Json Command(const std::string &root, const std::string &scope, const std::string &op);
Inspection Inspect(const std::filesystem::path &root, const std::string &expected_id,
                   bool pending = false);
int32_t ErrorCode() noexcept;
}  // namespace storage
}  // namespace vxm_import
#endif
