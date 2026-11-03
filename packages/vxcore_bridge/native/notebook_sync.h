// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_NOTEBOOK_SYNC_H
#define VNOTE_MOBILE_NOTEBOOK_SYNC_H
#include <atomic>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <nlohmann/json.hpp>
#include <vxcore/vxcore.h>

namespace vxm_sync {
using Json = nlohmann::json;
struct Work {
  std::string action, operation_id, protected_paths;
  VxCoreSyncLifecycle *lifecycle = nullptr;
  int32_t code = VXCORE_ERR_NOT_INITIALIZED;
  int did_commit = 0;
  char *changed_paths = nullptr;
  bool slot = false;
  bool auto_sync_enabled = false;
  ~Work();
};
// All methods except Cancel/Stop and Execute are called by the existing owner.
// Execute borrows the pinned context; Join is mandatory before Complete/Shutdown.
class Runtime {
 public:
  Runtime() = default;
  ~Runtime();
  void Initialize(VxCoreContextHandle context, const std::string &notebook,
                  const std::string &root, const std::string &local, bool clone);
  Json Facts();
  std::unique_ptr<Work> Prepare(const Json &command, const char *credentials, Json &out);
  void Execute(Work &work) noexcept;
  Json Complete(Work &work);
  void Abort(Work &work) noexcept;
  int32_t Cancel(const std::string &operation) noexcept;
  void Stop() noexcept;
  int32_t Shutdown() noexcept;
  bool Allows(int32_t event_kind) const noexcept;
  bool RefreshRequired() const noexcept { return refresh_required_; }
  bool CanRefreshSource() const noexcept { return refreshed_ && refresh_code_ == VXCORE_OK; }
  const std::string &NotebookId() const noexcept { return notebook_; }
  const std::string &CloneOperation() const noexcept { return clone_operation_; }
  bool CloneCommitted() const noexcept { return clone_committed_; }
  bool CloneAutoSyncEnabled() const noexcept { return clone_auto_sync_; }
 private:
  void Acquire(const std::string &operation);
  void Release() noexcept;
  Json Result(const std::string &action, const std::string &operation, int32_t code = VXCORE_OK) const;
  Json Refresh(const std::string &operation);
  void MarkRefresh();
  void ClearRefresh();
  void ConfigureTls();
  VxCoreContextHandle context_ = nullptr;
  std::string notebook_, root_, local_, operation_, phase_, clone_operation_;
  std::filesystem::path marker_;
  std::string marker_operation_;
  mutable std::mutex control_;
  VxCoreSyncCancellation *cancel_ = nullptr;
  std::atomic<bool> cancelled_{false};
  bool stopping_ = false, clone_ = false, clone_committed_ = false, tls_configured_ = false, clone_auto_sync_ = false;
  bool refresh_required_ = false, applied_ = false, refreshed_ = false, complete_paths_ = false, recovery_ = false;
  int32_t overall_code_ = VXCORE_OK, refresh_code_ = VXCORE_ERR_NOT_INITIALIZED;
};
bool Uuid(const std::string &value) noexcept;
void ValidateCommand(const Json &command, bool clone);
void ContextCreated() noexcept;
#if defined(VXM_DESKTOP_TEST_API)
int32_t EnableFixtureMode() noexcept;
#endif
}  // namespace vxm_sync
#endif
