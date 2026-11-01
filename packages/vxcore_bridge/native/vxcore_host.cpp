// SPDX-License-Identifier: LGPL-3.0-only
#include "vxcore_host.h"

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>
#include <sodium.h>
#include <vxcore/notebook_json_keys.h>
#include <vxcore/vxcore.h>
#include <vxcore/vxcore_log.h>

namespace {
namespace fs = std::filesystem;
using Json = nlohmann::json;
constexpr size_t kSource = VXM_MAX_SOURCE_BYTES;
constexpr size_t kString = 16384;
constexpr size_t kJson = 1048576;
constexpr uint64_t kMaxRevision = 9007199254740991ULL;
// Core's UUID generator has process-global mutable state. Serialize owner jobs
// across hosts too; control/event delivery never acquires this disk-operation gate.
std::mutex core_owner_gate;

struct Failure { int32_t code; };
void require(bool condition, int32_t code = VXCORE_ERR_INVALID_PARAM) {
  if (!condition) throw Failure{code};
}
void check(VxCoreError code) { require(code == VXCORE_OK, code); }

bool utf8(const uint8_t *data, size_t size) {
  for (size_t i = 0; i < size;) {
    const uint8_t c = data[i++];
    if (c < 0x80) continue;
    unsigned count;
    uint32_t value;
    uint32_t minimum;
    if (c >= 0xc2 && c <= 0xdf) { count = 1; value = c & 31; minimum = 0x80; }
    else if (c >= 0xe0 && c <= 0xef) { count = 2; value = c & 15; minimum = 0x800; }
    else if (c >= 0xf0 && c <= 0xf4) { count = 3; value = c & 7; minimum = 0x10000; }
    else return false;
    if (count > size - i) return false;
    while (count--) {
      const uint8_t next = data[i++];
      if ((next & 0xc0) != 0x80) return false;
      value = (value << 6) | (next & 63);
    }
    if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
  }
  return true;
}
size_t bounded_length(const char *text, size_t maximum) {
  require(text != nullptr, VXCORE_ERR_NULL_POINTER);
  size_t size = 0;
  while (size <= maximum && text[size]) ++size;
  require(size <= maximum);
  return size;
}
std::string input_string(const char *text) {
  const auto size = bounded_length(text, kString);
  require(size && utf8(reinterpret_cast<const uint8_t *>(text), size));
  return std::string(text, size);
}
void source_valid(const uint8_t *data, uint64_t size) {
  require(size <= kSource, VXCORE_ERR_INVALID_PARAM);
  require(data || !size, VXCORE_ERR_NULL_POINTER);
  require(utf8(data, static_cast<size_t>(size)), VXCORE_ERR_UNSUPPORTED);
}
void relative_path(const std::string &path) {
  require(path.find('\\') == std::string::npos && path.find(':') == std::string::npos);
  const auto value = fs::u8path(path);
  require(!value.is_absolute() && !value.has_root_path());
  for (const auto &part : value) require(part != "." && part != ".." && !part.empty());
  require(!value.filename().empty());
}
bool valid_hash(const char *hash) {
  if (bounded_length(hash, 64) != 64) return false;
  for (size_t i = 0; i < 64; ++i)
    if (!((hash[i] >= '0' && hash[i] <= '9') || (hash[i] >= 'a' && hash[i] <= 'f'))) return false;
  return true;
}
void hash_bytes(const uint8_t *data, size_t size, char *out) {
  unsigned char digest[crypto_hash_sha256_BYTES];
  static const uint8_t empty = 0;
  crypto_hash_sha256(digest, size ? data : &empty, static_cast<unsigned long long>(size));
  sodium_bin2hex(out, 65, digest, sizeof(digest));
}
const char *redacted(int32_t code) {
  switch (code) {
    case VXCORE_OK: return "Completed";
    case VXCORE_ERR_FILE_CHANGED_OUTSIDE: return "The note changed on disk; reopen or preserve your edits before retrying";
    case VXCORE_ERR_CANCELLED: return "The pending operation was cancelled";
    case VXCORE_ERR_OUT_OF_MEMORY: return "Native request capacity is exhausted";
    case VXCORE_ERR_UNSUPPORTED: return "This note or text encoding is not supported";
    case VXCORE_ERR_INVALID_PARAM: return "Invalid or oversized native request";
    case VXCORE_ERR_INVALID_STATE: return "The notebook session or request is no longer usable";
    case VXCORE_ERR_NODE_NOT_EXISTS: return "The indexed note is missing on disk";
    case VXCORE_ERR_ENCRYPTION_LOCKED:
    case VXCORE_ERR_ENCRYPTION_AUTH_FAILED:
    case VXCORE_ERR_ENCRYPTION_FORMAT:
    case VXCORE_ERR_ENCRYPTION_RECOVERY_REQUIRED: return "Encrypted notes are not supported by this editor";
    case VXCORE_ERR_IO: return "Notebook disk operation failed";
    case VXCORE_ERR_READ_ONLY:
    case VXCORE_ERR_PERMISSION_DENIED: return "The notebook cannot be written";
    default: return "The core notebook operation failed";
  }
}
struct CoreString {
  char *value = nullptr;
  ~CoreString() { vxcore_string_free(value); }
  std::string take() const {
    const auto size = bounded_length(value, kJson);
    return std::string(value, size);
  }
  Json json() const {
    const auto size = bounded_length(value, kJson);
    auto result = Json::parse(value, value + size, nullptr, false);
    require(!result.is_discarded() && result.is_object(), VXCORE_ERR_JSON_PARSE);
    return result;
  }
};
std::string identity(const Json &json) {
  const auto found = json.find(vxcore::kJsonKeyId);
  require(found != json.end() && found->is_string(), VXCORE_ERR_INVALID_STATE);
  auto value = found->get<std::string>();
  require(!value.empty() && value.size() < 128 && utf8(reinterpret_cast<const uint8_t *>(value.data()), value.size()), VXCORE_ERR_INVALID_STATE);
  require(value.find('\0') == std::string::npos, VXCORE_ERR_INVALID_STATE);
  return value;
}

// Accounting outlives the host when a consumer has taken an event. Input is
// released on execution; operation and output reservations on event release.
struct Capacity {
  std::mutex mutex;
  size_t operations = 0;
  size_t input = 0;
  size_t output = 0;
};
struct EventStorage : VxmEvent {
  VxmEvent &event;
  std::shared_ptr<Capacity> capacity;
  std::unique_ptr<uint8_t[]> body;
  size_t reserved_output = 0;
  bool counted = false;
  char notebook[128]{};
  char node[128]{};
  char hash[65]{};
  char version[64]{};
  EventStorage() : VxmEvent{}, event(*this) {
    event.message = redacted(VXCORE_OK);
    event.notebook_id = notebook;
    event.node_id = node;
    event.base_hash = hash;
    event.core_version = version;
  }
  ~EventStorage() {
    if (counted) {
      std::lock_guard<std::mutex> lock(capacity->mutex);
      --capacity->operations;
      capacity->output -= reserved_output;
    }
  }
};
struct Request {
  std::unique_ptr<EventStorage> result;
  std::vector<uint8_t> input;
  std::string expected_hash;
  size_t input_cost = 0;
  bool cancelled = false;
};
std::atomic<uint64_t> next_generation{1};
uint64_t new_generation() {
  auto current = next_generation.load();
  for (;;) {
    require(current && current < static_cast<uint64_t>(INT64_MAX), VXCORE_ERR_INVALID_STATE);
    if (next_generation.compare_exchange_weak(current, current + 1)) return current;
  }
}
}  // namespace

struct VxmHost {
  std::mutex mutex;
  std::condition_variable wake;
  std::array<Request *, VXM_MAX_OPERATIONS> pending{};
  size_t pending_start = 0;
  size_t pending_size = 0;
  std::array<EventStorage *, VXM_MAX_OPERATIONS + 1> events{};
  size_t event_start = 0;
  size_t event_size = 0;
  std::shared_ptr<Capacity> capacity = std::make_shared<Capacity>();
  std::unique_ptr<EventStorage> closed = std::make_unique<EventStorage>();
  bool stopping = false;
  uint64_t generation = new_generation();
  uint64_t last_request = 0;
  VxmNotify notify = nullptr;
  int64_t token = 0;
  std::thread owner;
  std::string app_path, local_path, notebook_path, notebook_name, note_path;
  VxCoreContextHandle context = nullptr;
  std::string notebook_id, node_id, buffer_id;
  int32_t init_error = VXCORE_ERR_NOT_INITIALIZED;
  uint64_t written_revision = 0;
  bool wrote_revision = false;

  ~VxmHost() {
    // Covers thread-creation failure; ordinary destruction has drained the ring.
    for (size_t i = 0; i < pending_size; ++i)
      delete pending[(pending_start + i) % pending.size()];
  }
  void publish(std::unique_ptr<EventStorage> event) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      // At most 64 admitted operations plus the dedicated close terminal.
      events[(event_start + event_size) % events.size()] = event.release();
      ++event_size;
    }
    notify(token);
  }
  void note_metadata() {
    CoreString config;
    check(vxcore_node_get_config(context, notebook_id.c_str(), note_path.c_str(), &config.value));
    const auto json = config.json();
    require(json.value(vxcore::kJsonKeyType, std::string()) == "file", VXCORE_ERR_UNSUPPORTED);
    const auto id = identity(json);
    require(node_id.empty() || id == node_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    node_id = id;
    if (json.value(vxcore::kJsonKeyEncrypted, false)) throw Failure{VXCORE_ERR_ENCRYPTION_LOCKED};
    const auto metadata = json.find(vxcore::kJsonKeyMetadata);
    if (metadata != json.end() && metadata->is_object() && metadata->value(vxcore::kJsonKeyEncrypted, false))
      throw Failure{VXCORE_ERR_ENCRYPTION_LOCKED};
  }
  void check_disk_size() {
    uint64_t size = 0;
    check(vxcore_node_get_file_size(context, notebook_id.c_str(), note_path.c_str(), &size));
    require(size <= kSource, VXCORE_ERR_UNSUPPORTED);
    // Reject linked source paths instead of loading outside the managed tree.
    auto path = fs::u8path(notebook_path);
    for (const auto &component : fs::u8path(note_path)) {
      path /= component;
      require(!fs::is_symlink(fs::symlink_status(path)), VXCORE_ERR_UNSUPPORTED);
    }
  }
  void buffer_metadata() {
    CoreString config;
    check(vxcore_buffer_get(context, buffer_id.c_str(), &config.value));
    const auto json = config.json();
    if (json.value(vxcore::kJsonKeyEncrypted, false)) throw Failure{VXCORE_ERR_ENCRYPTION_LOCKED};
    require(!json.value(vxcore::kJsonKeyIsVirtual, false) && !json.value(vxcore::kJsonKeyIsMemoryBacked, false), VXCORE_ERR_UNSUPPORTED);
    require(json.value(vxcore::kJsonKeyCanSave, false) && json.value(vxcore::kJsonKeyCanReload, false), VXCORE_ERR_UNSUPPORTED);
  }
  void reload(const uint8_t *&data, size_t &size) {
    note_metadata();
    check_disk_size();
    buffer_metadata();
    check(vxcore_buffer_reload(context, buffer_id.c_str()));
    const void *raw = nullptr;
    check(vxcore_buffer_get_content_raw(context, buffer_id.c_str(), &raw, &size));
    data = static_cast<const uint8_t *>(raw);
    source_valid(data, size);
    buffer_metadata();
  }
  void fill_note(EventStorage &out, const uint8_t *data, size_t size) {
    require(notebook_id.size() < sizeof(out.notebook) && node_id.size() < sizeof(out.node), VXCORE_ERR_INVALID_STATE);
    std::memcpy(out.notebook, notebook_id.c_str(), notebook_id.size() + 1);
    std::memcpy(out.node, node_id.c_str(), node_id.size() + 1);
    const char *version = vxcore_get_version_string();
    const auto length = bounded_length(version, sizeof(out.version) - 1);
    std::memcpy(out.version, version, length + 1);
    VxCoreLineEnding ending;
    check(vxcore_buffer_get_line_ending_override(context, buffer_id.c_str(), &ending));
    out.event.line_ending = ending;
    hash_bytes(data, size, out.hash);
    if (size) std::memcpy(out.body.get(), data, size);
    out.event.data = out.body.get();
    out.event.size = size;
  }
  void initialize(Request &request) {
    check(vxcore_log_set_level(VXCORE_LOG_LEVEL_OFF));
    check(vxcore_log_enable_console(0));
    check(vxcore_log_set_file(""));
    require(sodium_init() >= 0, VXCORE_ERR_NOT_INITIALIZED);
    check(vxcore_context_create_with_paths(nullptr, app_path.c_str(), local_path.c_str(), &context));
    check(vxcore_context_update_config(context, "{\"search\":{\"backends\":[\"simple\"]}}"));
    const auto root = fs::u8path(notebook_path);
    require(root.is_absolute());
    const auto status = fs::symlink_status(root);
    const bool exists = fs::exists(status);
    require(!fs::is_symlink(status), VXCORE_ERR_UNSUPPORTED);
    CoreString notebook;
    if (exists) {
      require(fs::is_directory(status), VXCORE_ERR_IO);
      check(vxcore_notebook_open(context, notebook_path.c_str(), &notebook.value));
    } else {
      const auto config = Json{{vxcore::kJsonKeyName, notebook_name}}.dump();
      check(vxcore_notebook_create(context, notebook_path.c_str(), config.c_str(), VXCORE_NOTEBOOK_BUNDLED, &notebook.value));
    }
    notebook_id = notebook.take();
    CoreString config;
    check(vxcore_notebook_get_config(context, notebook_id.c_str(), &config.value));
    require(identity(config.json()) == notebook_id, VXCORE_ERR_INVALID_STATE);
    if (!exists) {
      const auto path = fs::u8path(note_path);
      const auto parent = path.parent_path().generic_u8string();
      if (!parent.empty()) {
        CoreString folder;
        check(vxcore_folder_create_path(context, notebook_id.c_str(), parent.c_str(), &folder.value));
      }
      CoreString note;
      check(vxcore_file_create(context, notebook_id.c_str(), parent.c_str(), path.filename().u8string().c_str(), &note.value));
      node_id = note.take();
    }
    note_metadata();
    check_disk_size();
    CoreString buffer;
    check(vxcore_buffer_open_by_node_id(context, node_id.c_str(), &buffer.value));
    buffer_id = buffer.take();
    buffer_metadata();
    if (!exists && !request.input.empty()) {
      check(vxcore_buffer_set_content_raw(context, buffer_id.c_str(), request.input.data(), request.input.size()));
      check(vxcore_buffer_save(context, buffer_id.c_str()));
    }
    const uint8_t *data = nullptr;
    size_t size = 0;
    reload(data, size);
    fill_note(*request.result, data, size);
  }
  void read_note(Request &request) {
    const uint8_t *data = nullptr;
    size_t size = 0;
    reload(data, size);
    fill_note(*request.result, data, size);
  }
  void write_note(Request &request) {
    auto &out = *request.result;
    require(!wrote_revision || out.event.revision > written_revision, VXCORE_ERR_INVALID_STATE);
    const uint8_t *disk = nullptr;
    size_t disk_size = 0;
    reload(disk, disk_size); // Always read bytes, never use an mtime-only check.
    hash_bytes(disk, disk_size, out.hash);
    require(request.expected_hash == out.hash, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    const uint8_t *source = request.input.data();
    size_t size = request.input.size();
    const bool changed = size != disk_size || (size && std::memcmp(source, disk, size) != 0);
    if (changed) {
      VxCoreLineEnding ending;
      check(vxcore_buffer_get_line_ending_override(context, buffer_id.c_str(), &ending));
      std::vector<uint8_t> normalized;
      if (ending != VXCORE_LINE_ENDING_UNSPECIFIED) {
        require(ending >= VXCORE_LINE_ENDING_LF && ending <= VXCORE_LINE_ENDING_CR, VXCORE_ERR_UNSUPPORTED);
        size_t output_size = 0;
        bool conversion = false;
        for (size_t i = 0; i < size; ++i) {
          if (source[i] != '\r' && source[i] != '\n') { ++output_size; continue; }
          const bool pair = source[i] == '\r' && i + 1 < size && source[i + 1] == '\n';
          conversion |= ending == VXCORE_LINE_ENDING_CRLF ? !pair : pair || source[i] != (ending == VXCORE_LINE_ENDING_LF ? '\n' : '\r');
          if (pair) ++i;
          output_size += ending == VXCORE_LINE_ENDING_CRLF ? 2 : 1;
        }
        require(output_size <= kSource, VXCORE_ERR_INVALID_PARAM);
        if (conversion) {
          normalized.resize(output_size);
          size_t next = 0;
          for (size_t i = 0; i < size; ++i) {
            if (source[i] != '\r' && source[i] != '\n') { normalized[next++] = source[i]; continue; }
            if (source[i] == '\r' && i + 1 < size && source[i + 1] == '\n') ++i;
            if (ending != VXCORE_LINE_ENDING_LF) normalized[next++] = '\r';
            if (ending != VXCORE_LINE_ENDING_CR) normalized[next++] = '\n';
          }
          source = normalized.data();
          size = normalized.size();
        }
      }
      check(vxcore_buffer_set_content_raw(context, buffer_id.c_str(), source, size));
      // No cancellation boundary after mutation: finish and publish actual outcome.
      check(vxcore_buffer_save(context, buffer_id.c_str()));
      reload(disk, disk_size);
      require(size == disk_size && (!size || std::memcmp(source, disk, size) == 0), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      hash_bytes(disk, disk_size, out.hash);
    }
    written_revision = out.event.revision;
    wrote_revision = true;
  }
  int32_t teardown() noexcept {
    std::lock_guard<std::mutex> core_lock(core_owner_gate);
    int32_t result = VXCORE_OK;
    if (context) {
      if (!buffer_id.empty()) result = vxcore_buffer_close(context, buffer_id.c_str());
      if (!notebook_id.empty()) {
        const auto code = vxcore_notebook_close(context, notebook_id.c_str());
        if (result == VXCORE_OK) result = code;
      }
      const auto code = vxcore_prepare_shutdown(context);
      if (result == VXCORE_OK) result = code;
      vxcore_context_destroy(context);
      context = nullptr;
    }
    return result;
  }
  void run() noexcept {
    for (;;) {
      std::unique_ptr<Request> request;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [this] { return pending_size || stopping; });
        if (!pending_size) break;
        request.reset(pending[pending_start]);
        pending_start = (pending_start + 1) % pending.size();
        --pending_size;
        request->cancelled |= stopping;
      }
      auto &event = request->result->event;
      try {
        require(!request->cancelled, VXCORE_ERR_CANCELLED);
        std::lock_guard<std::mutex> core_lock(core_owner_gate);
        if (event.kind == VXM_EVENT_OPEN) initialize(*request);
        else {
          require(init_error == VXCORE_OK, init_error);
          if (event.kind == VXM_EVENT_READ) read_note(*request);
          else write_note(*request);
        }
      } catch (const Failure &failure) { event.code = failure.code; }
      catch (const std::bad_alloc &) { event.code = VXCORE_ERR_OUT_OF_MEMORY; }
      catch (const Json::exception &) { event.code = VXCORE_ERR_JSON_PARSE; }
      catch (const fs::filesystem_error &) { event.code = VXCORE_ERR_IO; }
      catch (...) { event.code = VXCORE_ERR_UNKNOWN; }
      if (event.kind == VXM_EVENT_OPEN) init_error = event.code;
      event.message = redacted(event.code);
      if (event.code != VXCORE_OK) { event.size = 0; event.data = nullptr; }
      auto result = std::move(request->result);
      const auto input_cost = request->input_cost;
      request.reset();
      {
        std::lock_guard<std::mutex> lock(capacity->mutex);
        capacity->input -= input_cost;
      }
      publish(std::move(result));
    }
    closed->event.kind = VXM_EVENT_CLOSED;
    closed->event.generation = generation;
    closed->event.code = teardown();
    closed->event.message = redacted(closed->event.code);
    publish(std::move(closed));
  }
};

namespace {
int32_t admit(VxmHost &host, int32_t kind, uint64_t id, uint64_t generation,
              uint64_t revision, const char *hash, const uint8_t *data, uint64_t size,
              size_t metadata_cost = 0) {
  try {
    require(revision <= kMaxRevision);
    source_valid(data, size);
    if (kind == VXM_EVENT_WRITE) require(valid_hash(hash));
    std::lock_guard<std::mutex> lock(host.mutex);
    require(!host.stopping && generation == host.generation && id > host.last_request && id <= kMaxRevision, VXCORE_ERR_INVALID_STATE);
    std::lock_guard<std::mutex> capacity_lock(host.capacity->mutex);
    const size_t input_cost = static_cast<size_t>(size) + metadata_cost;
    const size_t output_cost = kind == VXM_EVENT_WRITE ? 0 : kSource;
    auto &capacity = *host.capacity;
    require(capacity.operations < VXM_MAX_OPERATIONS && input_cost <= VXM_MAX_INPUT_BYTES - capacity.input && output_cost <= VXM_MAX_OUTPUT_BYTES - capacity.output, VXCORE_ERR_OUT_OF_MEMORY);
    auto request = std::make_unique<Request>();
    request->result = std::make_unique<EventStorage>();
    auto &result = *request->result;
    if (output_cost) result.body.reset(new uint8_t[output_cost]);
    if (size) request->input.assign(data, data + static_cast<size_t>(size));
    if (hash) request->expected_hash = hash;
    request->input_cost = input_cost;
    result.capacity = host.capacity;
    result.reserved_output = output_cost;
    result.event.request_id = id;
    result.event.generation = generation;
    result.event.revision = revision;
    result.event.kind = kind;
    // No throwing allocation or operation after reservation/admission commits.
    result.counted = true;
    ++capacity.operations;
    capacity.input += input_cost;
    capacity.output += output_cost;
    host.pending[(host.pending_start + host.pending_size) % host.pending.size()] = request.release();
    ++host.pending_size;
    host.last_request = id;
    host.wake.notify_one();
    return VXCORE_OK;
  } catch (const Failure &failure) { return failure.code; }
  catch (const std::bad_alloc &) { return VXCORE_ERR_OUT_OF_MEMORY; }
  catch (...) { return VXCORE_ERR_UNKNOWN; }
}
}  // namespace

extern "C" {
int32_t vxm_host_create(const VxmOpenOptions *options, VxmNotify notify, int64_t token, VxmHost **out_host) {
  if (out_host) *out_host = nullptr;
  if (!options || !notify || !out_host || token <= 0) return VXCORE_ERR_INVALID_PARAM;
  std::unique_ptr<VxmHost> host;
  try {
    source_valid(options->initial_data, options->initial_size);
    host = std::make_unique<VxmHost>();
    host->notify = notify;
    host->token = token;
    host->app_path = input_string(options->app_data_path);
    host->local_path = input_string(options->local_data_path);
    host->notebook_path = input_string(options->notebook_path);
    host->notebook_name = input_string(options->notebook_name);
    host->note_path = input_string(options->note_path);
    relative_path(host->note_path);
    const auto cost = host->app_path.size() + host->local_path.size() + host->notebook_path.size() + host->notebook_name.size() + host->note_path.size();
    const auto code = admit(*host, VXM_EVENT_OPEN, 1, host->generation, 0, nullptr, options->initial_data, options->initial_size, cost);
    require(code == VXCORE_OK, code);
    host->owner = std::thread([pointer = host.get()] { pointer->run(); });
    *out_host = host.release();
    return VXCORE_OK;
  } catch (const Failure &failure) { return failure.code; }
  catch (const std::bad_alloc &) { return VXCORE_ERR_OUT_OF_MEMORY; }
  catch (...) { return VXCORE_ERR_UNKNOWN; }
}
uint64_t vxm_host_generation(const VxmHost *host) { return host ? host->generation : 0; }
int32_t vxm_host_read(VxmHost *host, uint64_t id, uint64_t generation) {
  return host ? admit(*host, VXM_EVENT_READ, id, generation, 0, nullptr, nullptr, 0) : VXCORE_ERR_NULL_POINTER;
}
int32_t vxm_host_write(VxmHost *host, uint64_t id, uint64_t generation, uint64_t revision,
                       const char *hash, const uint8_t *data, uint64_t size) {
  return host ? admit(*host, VXM_EVENT_WRITE, id, generation, revision, hash, data, size) : VXCORE_ERR_NULL_POINTER;
}
int32_t vxm_host_cancel(VxmHost *host, uint64_t id, uint64_t generation) {
  if (!host) return VXCORE_ERR_NULL_POINTER;
  std::lock_guard<std::mutex> lock(host->mutex);
  if (generation != host->generation) return VXCORE_ERR_INVALID_STATE;
  for (size_t i = 0; i < host->pending_size; ++i) {
    auto &request = *host->pending[(host->pending_start + i) % host->pending.size()];
    if (request.result->event.request_id == id) {
      request.cancelled = true;
      return VXCORE_OK;
    }
  }
  return VXCORE_ERR_INVALID_STATE;
}
void vxm_host_request_close(VxmHost *host) {
  if (!host) return;
  std::lock_guard<std::mutex> lock(host->mutex);
  host->stopping = true;
  host->wake.notify_one();
}
VxmEvent *vxm_host_take_event(VxmHost *host) {
  if (!host) return nullptr;
  std::lock_guard<std::mutex> lock(host->mutex);
  if (!host->event_size) return nullptr;
  auto *result = host->events[host->event_start];
  host->event_start = (host->event_start + 1) % host->events.size();
  --host->event_size;
  return &result->event;
}
void vxm_event_free(VxmEvent *event) { delete static_cast<EventStorage *>(event); }
void vxm_host_destroy(VxmHost *host) {
  if (!host) return;
  vxm_host_request_close(host);
  if (host->owner.joinable()) host->owner.join();
  while (auto *event = vxm_host_take_event(host)) vxm_event_free(event);
  delete host;
}
}  // extern "C"
