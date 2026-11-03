// SPDX-License-Identifier: LGPL-3.0-only
#include "notebook_sync.h"
#include "notebook_import.h"
#include "vxcore_host.h"
#if defined(VXM_PLATFORM_TLS)
#include "sync_tls.h"
#endif
#include <algorithm>
#include <chrono>
#include <cstring>
#include <set>

namespace vxm_sync {
namespace {
namespace fs = std::filesystem;
namespace disk = vxm_import::storage;
std::atomic<unsigned> workers{0};
std::mutex fixture_mutex;
bool context_created = false;
void Require(bool value, int32_t code = VXCORE_ERR_INVALID_STATE) { disk::Check(value, code); }
void Check(int32_t code) { Require(code == VXCORE_OK, code); }
struct Text {
  char *value = nullptr;
  ~Text() { vxcore_string_free(value); }
  Json Parse(size_t limit = 8 * 1024 * 1024) const {
    Require(value != nullptr, VXCORE_ERR_JSON_PARSE);
    size_t n = 0;
    while (n <= limit && value[n]) ++n;
    Require(n <= limit, VXCORE_ERR_UNSUPPORTED);
    return disk::Parse(std::string_view(value, n), limit);
  }
  std::string String() const {
    Require(value != nullptr, VXCORE_ERR_JSON_PARSE);
    size_t n = 0;
    while (n <= 16384 && value[n]) ++n;
    Require(n <= 16384, VXCORE_ERR_UNSUPPORTED);
    return std::string(value, n);
  }
};
Json Config(const Json &command) {
  const auto &c = command.at("configuration");
  return {{"backend", "webdav"}, {"remoteUrl", c.at("endpoint")}, {"autoSyncEnabled", c.at("autoSyncEnabled")}};
}
void Slot(Work &work) {
  unsigned count = workers.load();
  do { Require(count < 2, VXCORE_ERR_SYNC_IN_PROGRESS); }
  while (!workers.compare_exchange_weak(count, count + 1));
  work.slot = true;
}
}

void ContextCreated() noexcept {
  std::lock_guard<std::mutex> lock(fixture_mutex);
  context_created = true;
}
#if defined(VXM_DESKTOP_TEST_API)
int32_t EnableFixtureMode() noexcept {
  std::lock_guard<std::mutex> lock(fixture_mutex);
  if (context_created) return VXCORE_ERR_INVALID_STATE;
  vxcore_set_test_mode(1);
  return VXCORE_OK;
}
#endif
bool Uuid(const std::string &value) noexcept {
  if (value.size() != 36) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) { if (value[i] != '-') return false; }
    else if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f'))) return false;
  }
  return true;
}
void ValidateCommand(const Json &j, bool clone) {
  Require(j.is_object() && j.contains("action"), VXCORE_ERR_INVALID_PARAM);
  const auto action = j.at("action").get<std::string>();
  std::set<std::string> keys{"action"};
  if (action == "inspect") Require(!clone);
  else {
    keys.insert("operationId");
    Require(Uuid(j.at("operationId").get<std::string>()), VXCORE_ERR_INVALID_PARAM);
    if (action == "enable" || action == "configure" || action == "credentialRecovery" || action == "clone") {
      keys.insert("configuration");
      const auto &c = j.at("configuration");
      Require(c.is_object() && c.size() == 3 && c.at("endpoint").is_string() &&
              c.at("enabled").is_boolean() && c.at("autoSyncEnabled").is_boolean(), VXCORE_ERR_INVALID_PARAM);
      const auto endpoint = c.at("endpoint").get<std::string>();
      Require(endpoint.size() <= 8192 && endpoint.find('\0') == std::string::npos, VXCORE_ERR_INVALID_PARAM);
      if (c.at("enabled") == true || action != "configure")
        Require(endpoint.compare(0, 8, "https://") == 0 && endpoint.find('@') == std::string::npos &&
                endpoint.find('?') == std::string::npos && endpoint.find('#') == std::string::npos, VXCORE_ERR_INVALID_PARAM);
    }
    if (action == "configure" && j.contains("cloneImportId")) {
      keys.insert("cloneImportId");
      const auto &id = j.at("cloneImportId").get_ref<const std::string &>();
      Require(id.size() == 32 && std::all_of(id.begin(), id.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
      }), VXCORE_ERR_INVALID_PARAM);
    }
    if (action == "credentialRecovery") {
      keys.insert("recoveryOperationId");
      Require(Uuid(j.at("recoveryOperationId").get<std::string>()), VXCORE_ERR_INVALID_PARAM);
    } else if (action == "apply") {
      keys.insert({"protectedNodeIds", "protectMetadata"});
      Require(j.at("protectedNodeIds").is_array() && j.at("protectedNodeIds").size() <= 10000 &&
              j.at("protectMetadata").is_boolean(), VXCORE_ERR_INVALID_PARAM);
      for (const auto &id : j.at("protectedNodeIds")) {
        const auto &value = id.get_ref<const std::string &>();
        Require(!value.empty() && value.size() < 128 && value.find('\0') == std::string::npos, VXCORE_ERR_INVALID_PARAM);
      }
    } else if (action == "finish") { keys.insert("settled"); Require(j.at("settled").is_boolean(), VXCORE_ERR_INVALID_PARAM); }
    else if (action == "resolve") {
      keys.insert({"path", "resolution"});
      disk::Relative(j.at("path").get<std::string>());
      const auto r = j.at("resolution").get<std::string>();
      Require(r == "keep_both" || r == "keep_local" || r == "keep_remote", VXCORE_ERR_INVALID_PARAM);
    } else if (action == "clone") {
      keys.insert("stagingBudgetBytes");
      Require(clone && j.at("stagingBudgetBytes").is_number_unsigned(), VXCORE_ERR_INVALID_PARAM);
      const auto budget = j.at("stagingBudgetBytes").get<uint64_t>();
      // This is a requested ceiling; CheckClone clamps current capacity and the
      // owner subtracts metadata/copy headroom before assigning core limits.
      Require(budget > 128 * 1024 && budget <= 4ULL * 1024 * 1024 * 1024, VXCORE_ERR_INVALID_PARAM);
    } else Require(action == "begin" || action == "stage" || action == "network" || action == "refresh" ||
        action == "enable" || action == "credentials" || action == "credentialRecovery" || action == "disable" ||
        action == "unregister" || action == "configure" || action == "providerInspect" || action == "providerBegin" ||
        action == "providerCommit" || action == "providerRestore" || action == "providerRecover", VXCORE_ERR_INVALID_PARAM);
    if ((action == "providerRecover" || action == "providerRestore") && j.contains("recoveryOperationId")) {
      keys.insert("recoveryOperationId");
      Require(Uuid(j.at("recoveryOperationId").get<std::string>()), VXCORE_ERR_INVALID_PARAM);
    }
    Require(!clone || action == "clone", VXCORE_ERR_INVALID_STATE);
  }
  Require(j.size() == keys.size(), VXCORE_ERR_INVALID_PARAM);
  for (auto it = j.begin(); it != j.end(); ++it) Require(keys.count(it.key()) != 0, VXCORE_ERR_INVALID_PARAM);
}
Work::~Work() {
  vxcore_string_free(changed_paths);
  vxcore_sync_free_lifecycle(lifecycle);
  if (slot) workers.fetch_sub(1);
}
Runtime::~Runtime() { Release(); }
void Runtime::Initialize(VxCoreContextHandle context, const std::string &notebook,
    const std::string &root, const std::string &local, bool clone) {
  context_ = context; notebook_ = notebook; root_ = root; local_ = local; clone_ = clone;
  if (clone_) return;
  const auto directory = disk::Absolute(local_) / "sync-refresh";
  if (!disk::Exists(directory)) disk::MakeDirectory(directory);
  marker_ = directory / (disk::Hash(root_ + "\n" + notebook_) + ".json");
  if (!disk::Exists(marker_)) return;
  const auto marker = disk::ReadJson(marker_, 16384);
  Require(marker.at("version") == 1 && marker.at("notebookId") == notebook_ && marker.at("root") == root_ &&
          Uuid(marker.at("operationId").get<std::string>()), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  refresh_required_ = true;
  marker_operation_ = marker.at("operationId").get<std::string>();
  // Rebuild actual owner metadata before admitting any writer, but retain the
  // durable marker until the application explicitly settles recovered sources.
  int32_t actual = VXCORE_ERR_NOT_INITIALIZED;
  vxcore_sync_refresh_notebook_result(context_, notebook_.c_str(), &actual);
  refresh_code_ = actual;
  refreshed_ = actual == VXCORE_OK;
}
void Runtime::ConfigureTls() {
  if (tls_configured_) return;
#if defined(VXM_PLATFORM_TLS)
  Check(vxm_sync_tls::Configure(context_));
#endif
  tls_configured_ = true;
}
Json Runtime::Facts() {
  Require(operation_.empty() || phase_ == "provider", VXCORE_ERR_SYNC_IN_PROGRESS);
  Text config, storage;
  Check(vxcore_notebook_get_config(context_, notebook_.c_str(), &config.value));
  const auto c = config.Parse();
  const auto endpoint = c.value("syncRemoteUrl", "");
  // Corrupt/legacy routing must not copy URL credentials or query tokens into
  // ordinary notifier state. Preserve the disk value; report an invalid URL.
  const auto visible_endpoint = endpoint.find_first_of("@?#\r\n") == std::string::npos ? endpoint : std::string();
  Check(vxcore_sync_inspect_storage(root_.c_str(), notebook_.c_str(), &storage.value));
  auto p = storage.Parse();
  if (phase_ == "provider" && p.at("retirement") == false) Release();
  int registered = 0, ready = 0;
  Check(vxcore_sync_is_registered(context_, notebook_.c_str(), &registered));
  Check(vxcore_sync_is_ready(context_, notebook_.c_str(), &ready));
  uint32_t capabilities = 0;
  Json conflicts = Json::array();
  if (registered) {
    Check(vxcore_sync_get_capabilities(context_, notebook_.c_str(), &capabilities));
    Text conflict_text;
    Check(vxcore_sync_get_conflicts(context_, notebook_.c_str(), &conflict_text.value));
    const auto conflict_json = conflict_text.Parse();
    for (const auto &item : conflict_json.at("conflicts"))
      conflicts.push_back({{"path", item.at("path")}, {"binary", item.at("isBinary")}, {"canKeepBoth", item.at("canKeepBoth")}});
  }
  int64_t last = 0;
  Check(vxcore_sync_get_last_sync_utc(context_, notebook_.c_str(), &last));
  const bool pending = p.at("pending").get<bool>();
  const bool recovery = refresh_required_ || p.at("credentialValidation").get<bool>() || p.at("retirement").get<bool>();
  return {{"notebookId", notebook_}, {"enabled", c.value("syncEnabled", false)},
      {"backend", c.value("syncBackend", "")}, {"endpoint", visible_endpoint},
      {"autoSyncEnabled", c.value("autoSyncEnabled", true)}, {"registered", registered != 0},
      {"ready", ready != 0}, {"capabilities", capabilities}, {"lastSuccessUtcMillis", last},
      {"refreshRequired", refresh_required_}, {"recoveryRequired", recovery}, {"pending", pending},
      {"conflicts", std::move(conflicts)}, {"provider", std::move(p)}};
}
void Runtime::Acquire(const std::string &operation) {
  std::lock_guard<std::mutex> lock(control_);
  Require(operation_.empty() && !stopping_, VXCORE_ERR_SYNC_IN_PROGRESS);
  auto *token = vxcore_sync_create_cancellation();
  Require(token != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
  operation_ = operation; cancel_ = token; cancelled_.store(false);
  overall_code_ = VXCORE_OK; applied_ = refreshed_ = complete_paths_ = recovery_ = false;
  refresh_code_ = VXCORE_ERR_NOT_INITIALIZED;
}
void Runtime::Release() noexcept {
  std::lock_guard<std::mutex> lock(control_);
  vxcore_sync_free_cancellation(cancel_); cancel_ = nullptr;
  operation_.clear(); phase_.clear(); cancelled_.store(false);
  applied_ = refreshed_ = complete_paths_ = recovery_ = false;
}
Json Runtime::Result(const std::string &action, const std::string &operation, int32_t code) const {
  return {{"operationId", operation}, {"action", action}, {"code", code}, {"executed", false},
      {"committed", false}, {"cleanupRequired", false}, {"refreshRequired", refresh_required_},
      {"changedPaths", nullptr}, {"refreshCode", nullptr}, {"didCommit", false}, {"settled", false},
      {"notebookId", notebook_.empty() ? Json(nullptr) : Json(notebook_)}, {"cloneReceipt", nullptr}};
}
void Runtime::MarkRefresh() {
  Require(!refresh_required_);
  disk::Marker(marker_.parent_path(), marker_.filename().u8string(),
      {{"version", 1}, {"notebookId", notebook_}, {"root", root_}, {"operationId", operation_}});
  refresh_required_ = true;
  marker_operation_ = operation_;
}
void Runtime::ClearRefresh() {
  if (disk::Exists(marker_)) {
    const auto marker = disk::ReadJson(marker_, 16384);
    Require(marker.at("notebookId") == notebook_ && marker.at("root") == root_ &&
        marker.at("operationId") == marker_operation_, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    disk::RemovePrivate(marker_);
    disk::FlushDirectory(marker_.parent_path());
  }
  refresh_required_ = false;
}
std::unique_ptr<Work> Runtime::Prepare(const Json &j, const char *credentials, Json &out) {
  ValidateCommand(j, clone_);
  const auto action = j.at("action").get<std::string>();
  if (action == "inspect") { out = Facts(); return {}; }
  const auto operation = j.at("operationId").get<std::string>();
  out = Result(action, operation);
  if (action == "begin") {
    Require(!refresh_required_);
    int registered = 0; uint32_t capabilities = 0;
    Check(vxcore_sync_is_registered(context_, notebook_.c_str(), &registered));
    Require(registered != 0, VXCORE_ERR_SYNC_NOT_ENABLED);
    Check(vxcore_sync_get_capabilities(context_, notebook_.c_str(), &capabilities));
    Acquire(operation); phase_ = "begin"; out["executed"] = true; return {};
  }
  const bool lifecycle = action == "enable" || action == "credentials" || action == "credentialRecovery" || action == "clone";
  if (lifecycle) {
    Require(!refresh_required_ && credentials && *credentials);
    ConfigureTls();
    auto work = std::make_unique<Work>(); Slot(*work);
    work->action = action; work->operation_id = operation;
    Acquire(operation);
    try {
      Json command{{"version", 1}, {"operationId", operation}, {"kind", action}};
      if (action != "credentials") command["config"] = Config(j);
      if (action == "credentialRecovery") command["recoveryOperationId"] = j.at("recoveryOperationId");
      if (action == "clone") {
        work->auto_sync_enabled = j.at("configuration").at("autoSyncEnabled").get<bool>();
        auto budget = j.at("stagingBudgetBytes").get<uint64_t>();
        Check(vxm_import::CheckClone(fs::u8path(root_).parent_path().u8string(), operation, budget));
        Require(budget >= 128 * 1024 + 2, VXCORE_ERR_IO);
        command["target"] = root_;
        // Keep the per-file bound inside the clone's share of the staging
        // budget after reserving the prepared copy and metadata headroom.
        const auto total = (budget - 128 * 1024) / 2;
        command["limits"] = {{"maxFileBytes", std::min<uint64_t>(256ULL * 1024 * 1024, total)},
            {"maxTotalBytes", total}, {"maxEntries", 100000}, {"maxDepth", 32}, {"maxPathBytes", 1024}};
      }
      const auto encoded = command.dump();
      Check(vxcore_sync_prepare_lifecycle(context_, clone_ ? nullptr : notebook_.c_str(),
          encoded.c_str(), credentials, &work->lifecycle));
      phase_ = action;
      return work;
    } catch (...) { Release(); throw; }
  }
  if (action == "stage" || action == "network" || action == "apply") {
    Require(operation_ == operation && !cancelled_.load(), cancelled_.load() ? VXCORE_ERR_CANCELLED : VXCORE_ERR_INVALID_STATE);
    Require(action == "stage" ? phase_ == "begin" : action == "network" ? phase_ == "staged" : phase_ == "networkDone");
    Require(overall_code_ == VXCORE_OK, overall_code_);
    auto work = std::make_unique<Work>(); Slot(*work);
    work->action = action; work->operation_id = operation;
    if (action == "apply") {
      Json paths = Json::array(); std::set<std::string> unique;
      for (const auto &id : j.at("protectedNodeIds")) {
        Text path;
        Check(vxcore_node_get_path_by_id(context_, notebook_.c_str(), id.get_ref<const std::string &>().c_str(), &path.value));
        auto value = path.String(); disk::Relative(value);
        if (unique.insert(value).second) paths.push_back(value);
      }
      if (j.at("protectMetadata") == true) {
        Text notebook, content, metadata;
        Check(vxcore_folder_get_import_paths(context_, notebook_.c_str(), ".", &notebook.value, &content.value, &metadata.value));
        auto relative = fs::u8path(metadata.String()).lexically_relative(fs::u8path(root_)).generic_u8string();
        disk::Relative(relative); paths.push_back(relative);
      }
      work->protected_paths = paths.dump();
      MarkRefresh();
      Check(vxcore_sync_set_apply_in_progress(context_, notebook_.c_str(), 1));
      applied_ = true;
    }
    phase_ = action;
    return work;
  }
  if (action == "refresh") {
    Require((operation_ == operation && applied_ && !refreshed_) || (operation_.empty() && refresh_required_));
    if (operation_.empty()) { Acquire(operation); recovery_ = true; applied_ = true; }
    out = Refresh(operation); return {};
  }
  if (action == "finish") {
    Require(operation_ == operation && (!applied_ || refreshed_));
    out["executed"] = true;
    const bool settled = j.at("settled").get<bool>();
    const bool recovered = recovery_ && settled && refreshed_ && refresh_code_ == VXCORE_OK && !cancelled_.load();
    const bool successful = !recovery_ && settled && applied_ && refreshed_ && complete_paths_ && refresh_code_ == VXCORE_OK &&
        overall_code_ == VXCORE_OK && !cancelled_.load();
    int32_t code = overall_code_;
    if (settled && !successful && !recovered && code == VXCORE_OK) code = VXCORE_ERR_INVALID_STATE;
    if (settled && refreshed_ && refresh_code_ == VXCORE_OK && (complete_paths_ || recovered)) ClearRefresh();
    Check(vxcore_sync_set_apply_in_progress(context_, notebook_.c_str(), 0));
    if (successful) {
      const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
      code = vxcore_sync_set_last_sync_utc(context_, notebook_.c_str(), now);
      if (code == VXCORE_OK) {
        // The legacy setter logs storage failure but returns OK. Do not claim a
        // recorded successful snapshot unless its per-device value is visible.
        int64_t recorded = 0;
        code = vxcore_sync_get_last_sync_utc(context_, notebook_.c_str(), &recorded);
        if (code == VXCORE_OK && recorded != now) code = VXCORE_ERR_IO;
      }
    }
    out["code"] = code; out["settled"] = settled; out["committed"] = successful && code == VXCORE_OK;
    out["refreshRequired"] = refresh_required_; Release(); return {};
  }
  const bool provider_command = action.compare(0, 8, "provider") == 0;
  const bool provider_recovery = action == "providerRecover" || action == "providerRestore";
  const bool selected_provider_lease = phase_ == "provider";
  const bool matching_provider_command = operation_ == operation &&
      (provider_command || action == "configure" || action == "disable" || action == "unregister");
  Require(!refresh_required_ && (operation_.empty() || (selected_provider_lease &&
      (matching_provider_command || provider_recovery || action == "providerInspect"))), VXCORE_ERR_SYNC_IN_PROGRESS);
  if (provider_command && action != "providerInspect") {
    if (provider_recovery && selected_provider_lease && operation_ != operation) Release();
    if (operation_.empty()) Acquire(operation);
    phase_ = "provider";
  }
  out["executed"] = true;
  int32_t code = VXCORE_OK;
  if (action == "disable") code = vxcore_sync_disable(context_, notebook_.c_str());
  else if (action == "unregister") code = vxcore_sync_unregister_notebook(context_, notebook_.c_str());
  else if (action == "configure") {
    Text value; Check(vxcore_notebook_get_config(context_, notebook_.c_str(), &value.value));
    auto config = value.Parse(); const auto &selected = j.at("configuration");
    Json verified;
    int registered = 0;
    Check(vxcore_sync_is_registered(context_, notebook_.c_str(), &registered));
    if (j.contains("cloneImportId")) {
      Check(vxm_import::CommittedCloneConfiguration(root_, notebook_,
          j.at("cloneImportId").get_ref<const std::string &>(), operation, verified));
      Require(selected == verified, VXCORE_ERR_INVALID_PARAM);
      const bool matching = config.value("syncEnabled", false) && config.value("syncBackend", "") == "webdav" &&
          config.value("syncRemoteUrl", "") == verified.at("endpoint") &&
          config.at("autoSyncEnabled") == verified.at("autoSyncEnabled");
      // A promotion/settlement retry must not unregister or rewrite a route
      // which workspace reconciliation has already authenticated.
      if (matching) { out["committed"] = true; return {}; }
      Require(!config.value("syncEnabled", false) && config.value("syncBackend", "").empty() &&
          config.value("syncRemoteUrl", "").empty() && registered == 0, VXCORE_ERR_INVALID_STATE);
      // The projected clone has no preference; get_config materializes true.
      config["syncEnabled"] = verified.at("enabled"); config["syncBackend"] = "webdav";
      config["syncRemoteUrl"] = verified.at("endpoint"); config["autoSyncEnabled"] = verified.at("autoSyncEnabled");
    } else {
      const bool enabled = selected.at("enabled").get<bool>();
      if (!enabled) Require(registered == 0, VXCORE_ERR_SYNC_IN_PROGRESS);
      else if (!config.value("syncEnabled", false) || config.value("syncBackend", "") != "webdav" ||
               config.value("syncRemoteUrl", "") != selected.at("endpoint")) {
        Require(registered != 0, VXCORE_ERR_SYNC_NOT_ENABLED);
        Text binding;
        Check(vxcore_sync_inspect_storage(root_.c_str(), notebook_.c_str(), &binding.value));
        Require(binding.Parse().at("remoteUrl") == selected.at("endpoint"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      }
      config["syncEnabled"] = enabled; config["syncBackend"] = enabled ? "webdav" : "";
      config["syncRemoteUrl"] = enabled ? selected.at("endpoint") : Json("");
      config["autoSyncEnabled"] = selected.at("autoSyncEnabled");
    }
    const auto encoded = config.dump(); code = vxcore_notebook_update_config(context_, notebook_.c_str(), encoded.c_str());
  } else if (action == "resolve") {
    const auto path = j.at("path").get<std::string>(), resolution = j.at("resolution").get<std::string>();
    code = vxcore_sync_resolve_conflict(context_, notebook_.c_str(), path.c_str(), resolution.c_str());
  } else {
    std::string kind = action.substr(8); kind[0] = static_cast<char>(kind[0] - 'A' + 'a');
    Json command{{"version", 1}, {"kind", kind}};
    std::string journal_operation = operation;
    if (provider_recovery) {
      Text storage;
      Check(vxcore_sync_inspect_storage(root_.c_str(), notebook_.c_str(), &storage.value));
      const auto facts = storage.Parse();
      if (facts.at("retirement") == true) {
        journal_operation = facts.at("retirementOperationId").get<std::string>();
        Require(Uuid(journal_operation), VXCORE_ERR_INVALID_STATE);
        if (j.contains("recoveryOperationId")) Require(j.at("recoveryOperationId") == journal_operation, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      }
    }
    if (kind != "inspect") command["operationId"] = journal_operation;
    Text result; const auto encoded = command.dump();
    code = vxcore_sync_provider_transaction(context_, notebook_.c_str(), encoded.c_str(), &result.value);
    if (result.value) {
      const auto actual = result.Parse();
      out["committed"] = actual.value("changed", false);
      out["providerPhase"] = actual.value("phase", Json(nullptr));
      out["provider"] = actual;
      out["cleanupRequired"] = actual.at("retirement");
      if (kind != "inspect" && code == VXCORE_OK && actual.at("retirement") == false) Release();
    } else if (code != VXCORE_OK) out["cleanupRequired"] = true;
  }
  out["code"] = code;
  if (action.compare(0, 8, "provider") != 0) out["committed"] = code == VXCORE_OK;
  return {};
}
void Runtime::Abort(Work &work) noexcept {
  if (work.lifecycle) {
    vxcore_sync_free_lifecycle(work.lifecycle); work.lifecycle = nullptr;
    Release();
  } else {
    if (overall_code_ == VXCORE_OK) overall_code_ = VXCORE_ERR_OUT_OF_MEMORY;
    phase_ = "failed";
  }
}
void Runtime::Execute(Work &work) noexcept {
  try {
    if (work.lifecycle) work.code = vxcore_sync_execute_lifecycle(work.lifecycle, cancel_);
    else if (work.action == "stage") work.code = vxcore_sync_stage_only(context_, notebook_.c_str(), cancel_, &work.did_commit);
    else if (work.action == "network") work.code = vxcore_sync_network_phase(context_, notebook_.c_str(), cancel_);
    else work.code = vxcore_sync_apply_phase(context_, notebook_.c_str(), cancel_, work.protected_paths.c_str(), &work.changed_paths);
  } catch (...) { work.code = disk::ErrorCode(); }
}
Json Runtime::Complete(Work &work) {
  Require(operation_ == work.operation_id && phase_ == work.action);
  auto out = Result(work.action, operation_, work.code);
  out["executed"] = true; out["didCommit"] = work.did_commit != 0;
  if (work.lifecycle) {
    Text value;
    const auto code = vxcore_sync_complete_lifecycle(context_, work.lifecycle, &value.value);
    out["code"] = code;
    // Freeing the lifecycle before releasing the token is part of this owner tail.
    if (value.value) {
      const auto actual = value.Parse(64 * 1024);
      for (const auto *key : {"executed", "committed", "cleanupRequired", "notebookId"}) out[key] = actual.at(key);
      if (clone_ && actual.at("committed") == true) {
        notebook_ = actual.at("notebookId").get<std::string>();
        clone_operation_ = operation_; clone_committed_ = true; clone_auto_sync_ = work.auto_sync_enabled;
      }
    } else out["cleanupRequired"] = true;
    vxcore_sync_free_lifecycle(work.lifecycle); work.lifecycle = nullptr;
    Release(); return out;
  }
  if (overall_code_ == VXCORE_OK) overall_code_ = work.code;
  if (work.action == "stage") phase_ = "staged";
  else if (work.action == "network") phase_ = "networkDone";
  else {
    phase_ = "applied";
    if (work.changed_paths) {
      try {
        size_t length = 0; while (length <= 8 * 1024 * 1024 && work.changed_paths[length]) ++length;
        Require(length <= 8 * 1024 * 1024, VXCORE_ERR_UNSUPPORTED);
        auto paths = Json::parse(work.changed_paths, work.changed_paths + length);
        Require(paths.is_array() && paths.size() <= 100000, VXCORE_ERR_JSON_PARSE);
        for (const auto &path : paths) disk::Relative(path.get<std::string>());
        out["changedPaths"] = std::move(paths); complete_paths_ = true;
      } catch (...) {
        if (overall_code_ == VXCORE_OK) overall_code_ = disk::ErrorCode();
        out["code"] = overall_code_;
      }
    }
    if (!complete_paths_ && overall_code_ == VXCORE_OK) out["code"] = overall_code_ = VXCORE_ERR_UNSUPPORTED;
    out["refreshRequired"] = true;
  }
  return out;
}
Json Runtime::Refresh(const std::string &operation) {
  int32_t actual = VXCORE_ERR_NOT_INITIALIZED;
  const auto code = vxcore_sync_refresh_notebook_result(context_, notebook_.c_str(), &actual);
  refresh_code_ = actual; refreshed_ = true; phase_ = "refreshed";
  if (overall_code_ == VXCORE_OK) overall_code_ = code;
  auto out = Result("refresh", operation, overall_code_);
  out["executed"] = true; out["refreshCode"] = actual;
  // Both ordinary apply and full recovery retain their durable source barrier
  // until the matching application settlement acknowledges finish(settled).
  const auto cleared = vxcore_sync_set_apply_in_progress(context_, notebook_.c_str(), 0);
  if (overall_code_ == VXCORE_OK) overall_code_ = cleared;
  out["code"] = overall_code_;
  return out;
}
int32_t Runtime::Cancel(const std::string &operation) noexcept {
  std::lock_guard<std::mutex> lock(control_);
  if (!cancel_ || operation_ != operation) return VXCORE_ERR_INVALID_STATE;
  cancelled_.store(true); vxcore_sync_cancel(cancel_); return VXCORE_OK;
}
void Runtime::Stop() noexcept {
  std::lock_guard<std::mutex> lock(control_);
  stopping_ = true; cancelled_.store(true); vxcore_sync_cancel(cancel_);
}
int32_t Runtime::Shutdown() noexcept {
  int32_t result = VXCORE_OK;
  try {
    if (applied_ && !refreshed_) result = Refresh(operation_).at("code").get<int32_t>();
    if (!notebook_.empty()) {
      const auto code = vxcore_sync_set_apply_in_progress(context_, notebook_.c_str(), 0);
      if (result == VXCORE_OK) result = code;
    }
  } catch (...) { result = disk::ErrorCode(); }
  Release(); return result;
}
bool Runtime::Allows(int32_t kind) const noexcept {
  if (kind == VXM_EVENT_DRAFT) return true;
  if (refresh_required_) {
    if (kind == VXM_EVENT_READ || kind == VXM_EVENT_PREVIEW) return CanRefreshSource();
    return kind != VXM_EVENT_WRITE && kind != VXM_EVENT_MUTATE && kind != VXM_EVENT_TAG &&
        kind != VXM_EVENT_COHORT && kind != VXM_EVENT_RESOURCE;
  }
  if (operation_.empty()) return true;
  if (kind == VXM_EVENT_WRITE) return phase_ == "staged" || phase_ == "network" || phase_ == "networkDone";
  return kind == VXM_EVENT_READ || kind == VXM_EVENT_LIST || kind == VXM_EVENT_PREVIEW;
}
}  // namespace vxm_sync
