// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_NOTEBOOK_IMPORT_H
#define VNOTE_MOBILE_NOTEBOOK_IMPORT_H

#include <cstdint>
#include <atomic>
#include <nlohmann/json.hpp>
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
std::string Read(const std::filesystem::path &path, size_t limit);
std::string Header(const std::filesystem::path &path, size_t count);
void Marker(const std::filesystem::path &directory, const std::string &name,
            const Json &value, size_t limit = 16384);
void ReplaceMarker(const std::filesystem::path &directory, const std::string &name,
                   const Json &expected, const Json &value);
void MakeDirectory(const std::filesystem::path &path);
void Move(const std::filesystem::path &source, const std::filesystem::path &target);
void RemovePrivate(const std::filesystem::path &path);
Json Copy(const std::filesystem::path &source, const std::filesystem::path &target,
          uint64_t limit, const std::atomic<bool> *cancel = nullptr);
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
