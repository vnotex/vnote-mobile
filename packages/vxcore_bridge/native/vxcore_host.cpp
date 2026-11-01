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
#include <set>
#include <string>
#include <thread>
#include <vector>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#endif

#include <cmark.h>
#include <nlohmann/json.hpp>
#include <sodium.h>
#include <vxcore/notebook_json_keys.h>
#include <vxcore/vxcore.h>
#include <vxcore/mobile/vxcore_mobile.h>
#include <vxcore/vxcore_log.h>

namespace {
namespace fs = std::filesystem;
using Json = nlohmann::json;
constexpr size_t kSource = VXM_MAX_SOURCE_BYTES;
constexpr size_t kString = 16384;
constexpr size_t kJson = VXM_MAX_CATALOG_BYTES;
constexpr size_t kCatalog = VXM_MAX_CATALOG_BYTES;
// Every terminal owns bounded metadata, including terminals taken past close.
constexpr size_t kMetadata = 2 * (kString + 1) + 3 * 128 + 65 + 64;
constexpr uint64_t kMaxRevision = 9007199254740991ULL;
// Core's UUID generator has process-global mutable state. Serialize owner jobs
// across hosts too; control/event delivery never acquires this disk-operation gate.
std::mutex core_owner_gate;
// Accessed only under core_owner_gate, never from control/cancellation calls.
std::set<fs::path> owned_notebooks;

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
std::string optional_string(const char *text) {
  return text && *text ? input_string(text) : std::string();
}
std::string lower_ascii(std::string value) {
  for (auto &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
  return value;
}
void basename(const std::string &name) {
  require(!name.empty() && name.size() <= 255 && name != "." && name != "..");
  require(name.back() != '.' && name.back() != ' ');
  for (const unsigned char c : name)
    require(c >= 32 && c != 127 && std::strchr("<>:\"/\\|?*", c) == nullptr);
  for (size_t i = 1; i < name.size(); ++i)
    require(!(static_cast<unsigned char>(name[i - 1]) == 0xc2 && static_cast<unsigned char>(name[i]) >= 0x80 && static_cast<unsigned char>(name[i]) <= 0x9f));
  auto stem = lower_ascii(name.substr(0, name.find('.')));
  while (!stem.empty() && stem.back() == ' ') stem.pop_back();
  require(stem != "con" && stem != "prn" && stem != "aux" && stem != "nul" &&
          stem != "conin$" && stem != "conout$");
  require(!(stem.size() == 4 && (stem.compare(0, 3, "com") == 0 || stem.compare(0, 3, "lpt") == 0) && stem[3] >= '0' && stem[3] <= '9'));
  for (const auto *digit : {u8"¹", u8"²", u8"³"})
    require(stem != std::string("com") + digit && stem != std::string("lpt") + digit);
}
void source_valid(const uint8_t *data, uint64_t size) {
  require(size <= kSource, VXCORE_ERR_INVALID_PARAM);
  require(data || !size, VXCORE_ERR_NULL_POINTER);
  require(utf8(data, static_cast<size_t>(size)), VXCORE_ERR_UNSUPPORTED);
}
void relative_path(const std::string &path) {
  require(path.find('\\') == std::string::npos && path.find(':') == std::string::npos && path.find("//") == std::string::npos);
  const auto value = fs::u8path(path);
  require(!value.is_absolute() && !value.has_root_path());
  for (const auto &part : value) require(part != "." && part != ".." && !part.empty());
  require(!value.filename().empty());
}
void no_link(const fs::path &path) {
  require(!fs::is_symlink(fs::symlink_status(path)), VXCORE_ERR_UNSUPPORTED);
#if defined(_WIN32)
  const auto attributes = GetFileAttributesW(path.c_str());
  require(attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_REPARSE_POINT), VXCORE_ERR_UNSUPPORTED);
#endif
}
void confined(const fs::path &root, const std::string &relative) {
  auto current = root.root_path();
  for (const auto &part : root.relative_path()) { current /= part; no_link(current); }
  if (relative == ".") return;
  relative_path(relative);
  for (const auto &part : fs::u8path(relative)) { current /= part; no_link(current); }
}
void safe_tree(const fs::path &path) {
  no_link(path);
  if (!fs::exists(path) || !fs::is_directory(path)) return;
  for (const auto &entry : fs::recursive_directory_iterator(path)) no_link(entry.path());
}
template <size_t N> void copy_field(char (&target)[N], const std::string &value) {
  require(value.size() < N && value.find('\0') == std::string::npos &&
          utf8(reinterpret_cast<const uint8_t *>(value.data()), value.size()), VXCORE_ERR_INVALID_STATE);
  std::memcpy(target, value.c_str(), value.size() + 1);
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
    case VXCORE_ERR_UNSUPPORTED: return "This node, text encoding, or notebook layout is not supported";
    case VXCORE_ERR_INVALID_PARAM: return "Invalid or oversized native request";
    case VXCORE_ERR_INVALID_STATE: return "The notebook session or request is no longer usable";
    case VXCORE_ERR_NODE_NOT_EXISTS: return "The indexed node is missing on disk";
    case VXCORE_ERR_NOT_FOUND: return "The requested notebook or node was not found";
    case VXCORE_ERR_ALREADY_EXISTS: return "A node with that name already exists";
    case VXCORE_ERR_JSON_PARSE: return "The notebook metadata is malformed";
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
  Json json(size_t maximum = kJson) const {
    const auto size = bounded_length(value, maximum);
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
  char *catalog = nullptr;
  size_t reserved_output = 0;
  bool counted = false;
  char notebook[128]{};
  char node[128]{};
  char hash[65]{};
  char version[64]{};
  char path_storage[kString + 1]{};
  char title[kString + 1]{};
  char parent[128]{};
  EventStorage() : VxmEvent{}, event(*this) {
    event.message = redacted(VXCORE_OK);
    event.notebook_id = notebook;
    event.node_id = node;
    event.base_hash = hash;
    event.core_version = version;
    event.path = path_storage;
    event.notebook_name = title;
    event.parent_id = parent;
  }
  ~EventStorage() {
    vxcore_string_free(catalog);
    if (counted) {
      std::lock_guard<std::mutex> lock(capacity->mutex);
      --capacity->operations;
      capacity->output -= reserved_output;
    }
  }
  void shrink(size_t payload) {
    const auto charge = payload + kMetadata;
    require(charge <= reserved_output, VXCORE_ERR_INVALID_STATE);
    std::lock_guard<std::mutex> lock(capacity->mutex);
    capacity->output -= reserved_output - charge;
    reserved_output = charge;
  }
};
struct Request {
  std::unique_ptr<EventStorage> result;
  std::vector<uint8_t> input;
  std::string expected_hash;
  std::string node, name, destination;
  int32_t operation = 0;
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
  std::string expected_notebook_id;
  int32_t mode = 0;
  int32_t editor_type = 0;
  std::string assets = "vx_assets", recycle = "vx_notebook/recycle_bin";
  fs::path owned_root;
  bool owns_root = false;
  VxCoreContextHandle context = nullptr;
  std::string notebook_id, node_id, buffer_id, root_id;
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
  struct Node { std::string id, path; bool folder; Json config; };
  void notebook_config() {
    CoreString value;
    check(vxcore_notebook_get_config(context, notebook_id.c_str(), &value.value));
    auto config = value.json();
    require(identity(config) == notebook_id, VXCORE_ERR_INVALID_STATE);
    notebook_name = config.at(vxcore::kJsonKeyName).get<std::string>();
    require(notebook_name.size() <= kString, VXCORE_ERR_INVALID_STATE);
    assets = config.at(vxcore::kJsonKeyAssetsFolder).get<std::string>();
    recycle = config.at(vxcore::kJsonKeyRecycleBinFolder).get<std::string>();
  }
  void ordinary(const std::string &path) {
    if (path == ".") return;
    relative_path(path);
    const auto asset_first = lower_ascii(assets.substr(0, assets.find('/')));
    const auto recycle_first = lower_ascii(recycle.substr(0, recycle.find('/')));
    bool first = true;
    for (const auto &part : fs::u8path(path)) {
      const auto name = lower_ascii(part.u8string());
      require(name != "vx_notebook" && name != asset_first && (!first || name != recycle_first), VXCORE_ERR_UNSUPPORTED);
      first = false;
    }
  }
  Node load_node(std::string path, const std::string &expected = {}) {
    if (path.empty()) path = ".";
    require(path.size() <= kString, VXCORE_ERR_UNSUPPORTED);
    ordinary(path);
    confined(fs::u8path(notebook_path), path);
    CoreString value;
    check(vxcore_node_get_config(context, notebook_id.c_str(), path.c_str(), &value.value));
    auto config = value.json(kCatalog);
    auto actual = identity(config);
    require(expected.empty() || actual == expected, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    const auto type = config.at(vxcore::kJsonKeyType).get<std::string>();
    require(type == "file" || type == "folder", VXCORE_ERR_UNSUPPORTED);
    return {std::move(actual), std::move(path), type == "folder", std::move(config)};
  }
  Node resolve(const std::string &id, bool root_allowed = false, bool allow_missing = false) {
    if (id.empty()) { require(root_allowed); return load_node("."); }
    if (id == root_id) return load_node(".", id);
    CoreString cached;
    const auto error = vxcore_node_get_path_by_id(context, notebook_id.c_str(), id.c_str(), &cached.value);
    if (error == VXCORE_OK) {
      try { return load_node(cached.take(), id); }
      catch (const Failure &failure) {
        if (failure.code == VXCORE_ERR_OUT_OF_MEMORY) throw;
        // A contradictory derived-cache hit is no more authoritative than a miss.
      }
      catch (const Json::exception &) { /* Verify portable metadata below. */ }
      catch (const fs::filesystem_error &) { /* Re-resolve the stale cached path. */ }
    } else if (error != VXCORE_ERR_NOT_FOUND) check(error);

    // SQLite is a lazy cache, not an authoritative absence oracle. Core listings
    // materialize metadata and also expose phantom nodes that may be deleted.
    std::vector<std::string> folders{"."};
    size_t queued_bytes = 1;
    size_t inspected = 0;
    bool skipped_unsafe_branch = false;
    while (!folders.empty()) {
      auto path = std::move(folders.back());
      folders.pop_back();
      queued_bytes -= path.size();
      ordinary(path);
      confined(fs::u8path(notebook_path), path);
      CoreString listing;
      check(vxcore_folder_list_children(context, notebook_id.c_str(), path.c_str(), &listing.value));
      auto config = listing.json(kCatalog);
      for (const bool folder : {false, true}) {
        auto &children = config.at(folder ? vxcore::kJsonKeyFolders : vxcore::kJsonKeyFiles);
        require(children.is_array(), VXCORE_ERR_JSON_PARSE);
        require(children.size() <= 100000 - inspected, VXCORE_ERR_UNSUPPORTED);
        inspected += children.size();
        for (auto &child : children) {
          const auto &candidate = child.at(vxcore::kJsonKeyId).get_ref<const std::string &>();
          const auto &name = child.at(vxcore::kJsonKeyName).get_ref<const std::string &>();
          require(!candidate.empty() && candidate.size() < 128, VXCORE_ERR_JSON_PARSE);
          if (candidate != id && !folder) continue;
          const bool exists = child.at(vxcore::kJsonKeyNodeExists).get<bool>();
          if (candidate != id && !exists) continue;
          try {
            require(name.size() <= kString && name.find('\0') == std::string::npos);
            relative_path(name);
            require(fs::u8path(name).filename() == fs::u8path(name));
          } catch (const Failure &) {
            if (candidate == id) throw;
            skipped_unsafe_branch = true;
            continue;
          }
          auto next = joined(path, name);
          if (candidate == id) {
            ordinary(next);
            confined(fs::u8path(notebook_path), next);
            if (!exists) {
              require(allow_missing, VXCORE_ERR_NODE_NOT_EXISTS);
              return {id, std::move(next), folder, std::move(child)};
            }
            return load_node(std::move(next), id);
          }
          if (folder && exists) {
            require(next.size() <= kCatalog - queued_bytes, VXCORE_ERR_UNSUPPORTED);
            queued_bytes += next.size();
            folders.push_back(std::move(next));
          }
        }
      }
    }
    throw Failure{skipped_unsafe_branch ? VXCORE_ERR_UNSUPPORTED : VXCORE_ERR_NOT_FOUND};
  }
  std::string parent_id(const std::string &path) {
    if (path == ".") return {};
    auto parent = fs::u8path(path).parent_path().generic_u8string();
    if (parent.empty()) parent = ".";
    confined(fs::u8path(notebook_path), parent);
    CoreString config;
    check(vxcore_node_get_config(context, notebook_id.c_str(), parent.c_str(), &config.value));
    return identity(config.json(kCatalog));
  }
  void fill_metadata(EventStorage &out, const Node &node) {
    copy_field(out.notebook, notebook_id);
    copy_field(out.node, node.id);
    copy_field(out.path_storage, node.path);
    copy_field(out.parent, parent_id(node.path));
    copy_field(out.title, notebook_name);
    copy_field(out.version, input_string(vxcore_get_version_string()));
  }
  int32_t classify(const std::string &name) {
    auto suffix = fs::u8path(name).extension().u8string();
    if (!suffix.empty()) suffix.erase(0, 1);
    CoreString value;
    check(vxcore_filetype_get_by_suffix(context, suffix.c_str(), &value.value));
    const auto type = value.json().at(vxcore::kJsonKeyName).get<std::string>();
    if (type == "Markdown") return VXM_EDITOR_MARKDOWN;
    if (type == "Text") return VXM_EDITOR_TEXT;
    throw Failure{VXCORE_ERR_UNSUPPORTED};
  }
  void layout() {
    notebook_config();
    const auto root = fs::u8path(notebook_path);
    for (const auto *resource : {&assets, &recycle}) {
      try {
        relative_path(*resource);
        for (const auto &part : fs::u8path(*resource)) basename(part.u8string());
      } catch (const Failure &) { throw Failure{VXCORE_ERR_UNSUPPORTED}; }
    }
    // The default recycler is deliberately inside metadata; it is not a node.
    require(lower_ascii(fs::u8path(assets).begin()->u8string()) != "vx_notebook", VXCORE_ERR_UNSUPPORTED);
    confined(root, "vx_notebook");
    safe_tree(root / "vx_notebook");
    confined(root, recycle);
    safe_tree(root / fs::u8path(recycle));
  }
  void resources(const std::string &parent) {
    const auto relative = parent == "." ? assets : parent + "/" + assets;
    confined(fs::u8path(notebook_path), relative);
    safe_tree(fs::u8path(notebook_path) / fs::u8path(relative));
  }
  struct MovedResource {
    std::string source, destination;
    uint64_t size;
    bool directory;
  };
  static std::string joined(const std::string &parent, const std::string &child) {
    auto path = (fs::u8path(parent) / fs::u8path(child)).lexically_normal().generic_u8string();
    require(path.size() <= kString, VXCORE_ERR_UNSUPPORTED);
    return path;
  }
  void destination_absent(const std::string &path) {
    const auto root = fs::u8path(notebook_path);
    confined(root, path);
    auto current = root;
    const auto relative = fs::u8path(path);
    for (const auto &part : relative.parent_path()) {
      current /= part;
      require(!fs::exists(current) || fs::is_directory(current), VXCORE_ERR_ALREADY_EXISTS);
    }
    require(!fs::exists(root / relative), VXCORE_ERR_ALREADY_EXISTS);
  }
  void unindexed(const std::string &path) {
    CoreString config;
    const auto code = vxcore_node_get_config(context, notebook_id.c_str(), path.c_str(), &config.value);
    if (code == VXCORE_OK) throw Failure{VXCORE_ERR_UNSUPPORTED};
    require(code == VXCORE_ERR_NOT_FOUND, code);
  }
  void capture_resource(std::vector<MovedResource> &result, std::string source,
                        std::string destination, bool directory) {
    require(result.size() < 10000, VXCORE_ERR_UNSUPPORTED);
    const auto path = fs::u8path(notebook_path) / fs::u8path(source);
    require(directory ? fs::is_directory(path) : fs::is_regular_file(path), VXCORE_ERR_UNSUPPORTED);
    const auto size = directory ? 0 : fs::file_size(path);
    result.push_back({std::move(source), std::move(destination), size, directory});
  }
  std::vector<MovedResource> preflight_file_move(const Node &target, const std::string &parent,
                                                const std::string &destination) {
    std::vector<MovedResource> result;
    const auto root = fs::u8path(notebook_path);
    const auto destination_note = joined(destination, fs::u8path(target.path).filename().u8string());
    destination_absent(destination_note);
    const auto source_assets = joined(parent, assets + "/" + target.id);
    const auto destination_assets = joined(destination, assets + "/" + target.id);
    confined(root, source_assets);
    destination_absent(destination_assets);
    const auto asset_root = root / fs::u8path(source_assets);
    if (fs::exists(asset_root)) {
      capture_resource(result, source_assets, destination_assets, true);
      for (const auto &entry : fs::recursive_directory_iterator(asset_root)) {
        no_link(entry.path());
        const auto suffix = entry.path().lexically_relative(asset_root).generic_u8string();
        capture_resource(result, joined(source_assets, suffix), joined(destination_assets, suffix), entry.is_directory());
      }
    }
    // Exactly the pinned core handler set, independent of user editor types.
    const auto suffix = lower_ascii(fs::u8path(target.path).extension().u8string());
    if (suffix != ".md" && suffix != ".mkd" && suffix != ".rmd" && suffix != ".markdown") return result;
    uint64_t size = 0;
    check(vxcore_node_get_file_size(context, notebook_id.c_str(), target.path.c_str(), &size));
    require(size <= kSource, VXCORE_ERR_UNSUPPORTED);
    CoreString source;
    check(vxcore_file_peek(context, notebook_id.c_str(), target.path.c_str(), static_cast<size_t>(size), &source.value));
    require(source.value != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
    const auto length = bounded_length(source.value, kSource);
    require(length == size && utf8(reinterpret_cast<const uint8_t *>(source.value), length), VXCORE_ERR_UNSUPPORTED);
    using Document = std::unique_ptr<cmark_node, decltype(&cmark_node_free)>;
    using Iterator = std::unique_ptr<cmark_iter, decltype(&cmark_iter_free)>;
    Document document(cmark_parse_document(source.value, length, CMARK_OPT_DEFAULT), cmark_node_free);
    require(document != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
    Iterator iterator(cmark_iter_new(document.get()), cmark_iter_free);
    require(iterator != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
    std::set<std::string> seen;
    cmark_event_type event;
    while ((event = cmark_iter_next(iterator.get())) != CMARK_EVENT_DONE) {
      if (event != CMARK_EVENT_ENTER) continue;
      auto *node = cmark_iter_get_node(iterator.get());
      const auto type = cmark_node_get_type(node);
      if (type != CMARK_NODE_LINK && type != CMARK_NODE_IMAGE) continue;
      const auto *url = cmark_node_get_url(node);
      if (!url || !*url) continue;
      std::string relative(url, bounded_length(url, kString));
      if (relative == "." || relative.find("://") != std::string::npos || relative.front() == '/') continue;
      const auto fragment = relative.find_first_of("#?");
      if (fragment != std::string::npos) relative.resize(fragment);
      if (relative.empty()) continue;
      relative = fs::u8path(relative).lexically_normal().generic_u8string();
      if (relative == ".") continue;
      // Core skips only an initial '/', not drive paths or a root introduced
      // by normalization. Those ambiguous platform-specific forms are refused.
      require(relative.find(':') == std::string::npos && relative.find('\\') == std::string::npos && !fs::u8path(relative).has_root_path(), VXCORE_ERR_UNSUPPORTED);
      const auto position = seen.lower_bound(relative);
      if (position != seen.end() && *position == relative) continue;
      const auto from = joined(parent, relative);
      const auto to = joined(destination, relative);
      try { relative_path(from); relative_path(to); }
      catch (const Failure &) { throw Failure{VXCORE_ERR_UNSUPPORTED}; }
      confined(root, from);
      confined(root, to);
      const auto source_path = root / fs::u8path(from);
      if (relative.compare(0, assets.size() + 1, assets + "/") == 0) {
        const auto own_prefix = assets + "/" + target.id;
        const bool own = relative == own_prefix || relative.compare(0, own_prefix.size() + 1, own_prefix + "/") == 0;
        require(own || !fs::exists(source_path) || from == to, VXCORE_ERR_UNSUPPORTED);
        continue;
      }
      ordinary(from);
      ordinary(to);
      if (relative.compare(0, 3, "../") == 0 || relative == "..") {
        require(!fs::exists(source_path) || from == to, VXCORE_ERR_UNSUPPORTED);
        continue;
      }
      if (from == target.path && to == destination_note) continue;
      if (!fs::exists(source_path) || !fs::is_regular_file(source_path)) continue;
      seen.insert(position, relative);
      require(seen.size() <= 10000, VXCORE_ERR_UNSUPPORTED);
      require(from != "." && to != "." && to != destination_note, VXCORE_ERR_UNSUPPORTED);
      destination_absent(to);
      unindexed(from);
      unindexed(to);
      capture_resource(result, from, to, false);
    }
    return result;
  }
  void moved_resources(const std::vector<MovedResource> &resources) {
    const auto root = fs::u8path(notebook_path);
    for (const auto &resource : resources) {
      const auto source = root / fs::u8path(resource.source);
      const auto destination = root / fs::u8path(resource.destination);
      // Core logs several resource failures and still returns OK. Surface a
      // partial outcome instead of claiming success or repairing behind core.
      require(!fs::exists(source), VXCORE_ERR_IO);
      try { confined(root, resource.destination); }
      catch (const Failure &) { throw Failure{VXCORE_ERR_IO}; }
      require(resource.directory ? fs::is_directory(destination) :
              fs::is_regular_file(destination) && fs::file_size(destination) == resource.size, VXCORE_ERR_IO);
    }
  }
  void list_catalog(Request &request) {
    require(mode == VXM_MODE_CATALOG, VXCORE_ERR_INVALID_STATE);
    const auto folder = resolve(request.node, true);
    require(folder.folder, VXCORE_ERR_INVALID_PARAM);
    auto &out = *request.result;
    fill_metadata(out, folder);
    CoreString listing;
    check(vxcore_folder_list_children(context, notebook_id.c_str(), folder.path.c_str(), &listing.value));
    require(listing.value != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
    const auto size = bounded_length(listing.value, kCatalog);
    require(utf8(reinterpret_cast<const uint8_t *>(listing.value), size), VXCORE_ERR_JSON_PARSE);
    // No parsing, copying, or unused body allocation: this is core-owned JSON.
    out.catalog = listing.value;
    listing.value = nullptr;
    out.event.data = reinterpret_cast<const uint8_t *>(out.catalog);
    out.event.size = size;
    out.shrink(size);
  }
  void mutate_catalog(Request &request) {
    require(mode == VXM_MODE_CATALOG, VXCORE_ERR_INVALID_STATE);
    layout();
    const auto target = resolve(request.node, false, request.operation == VXM_DELETE);
    if (target.path != ".")
      for (const auto &part : fs::u8path(target.path)) basename(part.u8string());
    auto &out = *request.result;
    copy_field(out.node, target.id);
    const auto root = fs::u8path(notebook_path);
    const auto operation = request.operation;
    if (operation == VXM_CREATE_NOTE || operation == VXM_CREATE_FOLDER) {
      require(target.folder);
      basename(request.name);
      const auto path = target.path == "." ? request.name : target.path + "/" + request.name;
      ordinary(path);
      confined(root, path);
      resources(target.path);
      if (operation == VXM_CREATE_NOTE) classify(request.name);
      CoreString created;
      if (operation == VXM_CREATE_NOTE)
        check(vxcore_file_create(context, notebook_id.c_str(), target.path.c_str(), request.name.c_str(), &created.value));
      else
        check(vxcore_folder_create(context, notebook_id.c_str(), target.path.c_str(), request.name.c_str(), &created.value));
      copy_field(out.node, created.take());
      // Core can publish metadata even when opening the physical file failed.
      // Report that actual error; the caller refreshes to expose partial state.
      if (operation == VXM_CREATE_NOTE) {
        uint64_t size = 0;
        check(vxcore_node_get_file_size(context, notebook_id.c_str(), path.c_str(), &size));
        require(size == 0, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      }
      return;
    }
    require(target.path != ".", VXCORE_ERR_INVALID_PARAM);
    auto parent = fs::u8path(target.path).parent_path().generic_u8string();
    if (parent.empty()) parent = ".";
    resources(parent);
    if (target.folder) safe_tree(root / fs::u8path(target.path));
    if (operation == VXM_RENAME) {
      basename(request.name);
      const auto path = parent == "." ? request.name : parent + "/" + request.name;
      ordinary(path);
      confined(root, path);
      check(vxcore_node_rename(context, notebook_id.c_str(), target.path.c_str(), request.name.c_str()));
    } else if (operation == VXM_MOVE) {
      const auto destination = resolve(request.destination);
      require(destination.folder);
      const auto source_lower = lower_ascii(target.path);
      const auto destination_lower = lower_ascii(destination.path);
      require(!target.folder || (destination_lower != source_lower && destination_lower.compare(0, source_lower.size() + 1, source_lower + "/") != 0));
      resources(destination.path);
      const auto name = fs::u8path(target.path).filename().u8string();
      const auto path = destination.path == "." ? name : destination.path + "/" + name;
      ordinary(path);
      confined(root, path);
      const auto moved = target.folder ? std::vector<MovedResource>() : preflight_file_move(target, parent, destination.path);
      check(vxcore_node_move(context, notebook_id.c_str(), target.path.c_str(), destination.path.c_str()));
      moved_resources(moved);
    } else {
      require(operation == VXM_DELETE);
      check(vxcore_node_delete(context, notebook_id.c_str(), target.path.c_str()));
    }
  }
  void note_metadata() {
    const auto node = resolve(node_id);
    require(!node.folder, VXCORE_ERR_UNSUPPORTED);
    require(note_path.empty() || note_path == node.path, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    note_path = node.path;
    const auto &json = node.config;
    if (json.value(vxcore::kJsonKeyEncrypted, false)) throw Failure{VXCORE_ERR_ENCRYPTION_LOCKED};
    const auto metadata = json.find(vxcore::kJsonKeyMetadata);
    if (metadata != json.end()) {
      require(metadata->is_object(), VXCORE_ERR_JSON_PARSE);
      if (metadata->value(vxcore::kJsonKeyEncrypted, false)) throw Failure{VXCORE_ERR_ENCRYPTION_LOCKED};
    }
    editor_type = classify(note_path);
  }
  void check_disk_size() {
    uint64_t size = 0;
    check(vxcore_node_get_file_size(context, notebook_id.c_str(), note_path.c_str(), &size));
    require(size <= kSource, VXCORE_ERR_UNSUPPORTED);
    confined(fs::u8path(notebook_path), note_path);
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
    fill_metadata(out, resolve(node_id));
    out.event.editor_type = editor_type;
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
    const auto root = fs::u8path(notebook_path);
    require(root.is_absolute());
    const auto status = fs::symlink_status(root);
    const bool exists = fs::exists(status);
    confined(root, ".");
    confined(root, "vx_notebook/config.json");
    safe_tree(root / "vx_notebook");
    const auto canonical = fs::weakly_canonical(root);
    for (const auto &active : owned_notebooks) {
      std::error_code error;
      require(canonical != active && !fs::equivalent(canonical, active, error), VXCORE_ERR_INVALID_STATE);
    }
    owned_root = canonical;
    owned_notebooks.insert(owned_root);
    owns_root = true;
    check(vxcore_context_create_with_paths(nullptr, app_path.c_str(), local_path.c_str(), &context));
    check(vxcore_context_update_config(context, "{\"search\":{\"backends\":[\"simple\"]}}"));
    CoreString notebook;
    if (exists) {
      require(fs::is_directory(status), VXCORE_ERR_IO);
      check(vxcore_notebook_open(context, notebook_path.c_str(), &notebook.value));
    } else {
      require(mode == VXM_MODE_CATALOG && expected_notebook_id.empty(), VXCORE_ERR_NOT_FOUND);
      const auto config = Json{{vxcore::kJsonKeyName, notebook_name}}.dump();
      check(vxcore_notebook_create(context, notebook_path.c_str(), config.c_str(), VXCORE_NOTEBOOK_BUNDLED, &notebook.value));
    }
    notebook_id = notebook.take();
    require(expected_notebook_id.empty() || notebook_id == expected_notebook_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    notebook_config();
    root_id = load_node(".").id;
    if (mode == VXM_MODE_CATALOG) {
      list_catalog(request);
      return;
    }
    note_metadata();
    check_disk_size();
    CoreString buffer;
    check(vxcore_buffer_open_by_node_id(context, node_id.c_str(), &buffer.value));
    buffer_id = buffer.take();
    buffer_metadata();
    require(mode == VXM_MODE_NOTE, VXCORE_ERR_INVALID_STATE);
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
    if (owns_root) owned_notebooks.erase(owned_root);
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
        if (event.kind == VXM_EVENT_OPEN || event.kind == VXM_EVENT_CATALOG_OPEN) initialize(*request);
        else {
          require(init_error == VXCORE_OK, init_error);
          if (event.kind == VXM_EVENT_READ) read_note(*request);
          else if (event.kind == VXM_EVENT_WRITE) write_note(*request);
          else if (event.kind == VXM_EVENT_LIST) list_catalog(*request);
          else if (event.kind == VXM_EVENT_MUTATE) mutate_catalog(*request);
          else throw Failure{VXCORE_ERR_INVALID_STATE};
        }
      } catch (const Failure &failure) { event.code = failure.code; }
      catch (const std::bad_alloc &) { event.code = VXCORE_ERR_OUT_OF_MEMORY; }
      catch (const Json::exception &) { event.code = VXCORE_ERR_JSON_PARSE; }
      catch (const fs::filesystem_error &) { event.code = VXCORE_ERR_IO; }
      catch (...) { event.code = VXCORE_ERR_UNKNOWN; }
      if (event.kind == VXM_EVENT_OPEN || event.kind == VXM_EVENT_CATALOG_OPEN) init_error = event.code;
      event.message = redacted(event.code);
      if (event.code != VXCORE_OK) {
        event.size = 0;
        event.data = nullptr;
        if (event.kind == VXM_EVENT_CATALOG_OPEN || event.kind == VXM_EVENT_LIST) request->result->shrink(0);
      }
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
              size_t metadata_cost = 0, int32_t operation = 0,
              const char *node = nullptr, const char *name = nullptr, const char *destination = nullptr) {
  try {
    require(revision <= kMaxRevision);
    source_valid(data, size);
    if (kind == VXM_EVENT_WRITE) require(valid_hash(hash));
    const bool catalog = kind == VXM_EVENT_CATALOG_OPEN || kind == VXM_EVENT_LIST;
    const bool source = kind == VXM_EVENT_OPEN || kind == VXM_EVENT_READ;
    require((catalog || kind == VXM_EVENT_MUTATE) ? host.mode == VXM_MODE_CATALOG : host.mode == VXM_MODE_NOTE, VXCORE_ERR_INVALID_STATE);
    auto node_value = optional_string(node);
    auto name_value = optional_string(name);
    auto destination_value = optional_string(destination);
    require(node_value.size() < 128 && destination_value.size() < 128);
    if (kind == VXM_EVENT_MUTATE) {
      require(operation >= VXM_CREATE_NOTE && operation <= VXM_DELETE && !node_value.empty());
      const bool named = operation == VXM_CREATE_NOTE || operation == VXM_CREATE_FOLDER || operation == VXM_RENAME;
      require(named == !name_value.empty() && (operation == VXM_MOVE) == !destination_value.empty());
    }
    std::lock_guard<std::mutex> lock(host.mutex);
    require(!host.stopping && generation == host.generation && id > host.last_request && id <= kMaxRevision, VXCORE_ERR_INVALID_STATE);
    std::lock_guard<std::mutex> capacity_lock(host.capacity->mutex);
    const size_t input_cost = static_cast<size_t>(size) + metadata_cost + node_value.size() + name_value.size() + destination_value.size() + (hash ? 64 : 0);
    const size_t output_cost = kMetadata + (catalog ? kCatalog : source ? kSource : 0);
    auto &capacity = *host.capacity;
    require(capacity.operations < VXM_MAX_OPERATIONS && input_cost <= VXM_MAX_INPUT_BYTES - capacity.input && output_cost <= VXM_MAX_OUTPUT_BYTES - capacity.output, VXCORE_ERR_OUT_OF_MEMORY);
    auto request = std::make_unique<Request>();
    request->result = std::make_unique<EventStorage>();
    auto &result = *request->result;
    if (source) result.body.reset(new uint8_t[kSource]);
    if (size) request->input.assign(data, data + static_cast<size_t>(size));
    if (hash) request->expected_hash = hash;
    request->node = std::move(node_value);
    request->name = std::move(name_value);
    request->destination = std::move(destination_value);
    request->operation = operation;
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
    require(options->mode == VXM_MODE_NOTE || options->mode == VXM_MODE_CATALOG);
    host = std::make_unique<VxmHost>();
    host->notify = notify;
    host->token = token;
    host->app_path = input_string(options->app_data_path);
    host->local_path = input_string(options->local_data_path);
    host->notebook_path = input_string(options->notebook_path);
    host->mode = options->mode;
    host->notebook_name = optional_string(options->notebook_name);
    host->expected_notebook_id = optional_string(options->expected_notebook_id);
    host->node_id = optional_string(options->node_id);
    require(host->expected_notebook_id.size() < 128 && host->node_id.size() < 128);
    if (host->mode == VXM_MODE_NOTE) require(!host->expected_notebook_id.empty() && !host->node_id.empty());
    else require(!host->notebook_name.empty() && host->node_id.empty());
    const auto cost = host->app_path.size() + host->local_path.size() + host->notebook_path.size() + host->notebook_name.size() + host->expected_notebook_id.size() + host->node_id.size();
    const auto kind = host->mode == VXM_MODE_NOTE ? VXM_EVENT_OPEN : VXM_EVENT_CATALOG_OPEN;
    const auto code = admit(*host, kind, 1, host->generation, 0, nullptr, nullptr, 0, cost);
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
int32_t vxm_host_catalog_list(VxmHost *host, uint64_t id, uint64_t generation, const char *folder) {
  return host ? admit(*host, VXM_EVENT_LIST, id, generation, 0, nullptr, nullptr, 0, 0, 0, folder) : VXCORE_ERR_NULL_POINTER;
}
int32_t vxm_host_catalog_mutate(VxmHost *host, uint64_t id, uint64_t generation, int32_t operation,
                               const char *node, const char *name, const char *destination) {
  return host ? admit(*host, VXM_EVENT_MUTATE, id, generation, 0, nullptr, nullptr, 0, 0, operation, node, name, destination) : VXCORE_ERR_NULL_POINTER;
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
