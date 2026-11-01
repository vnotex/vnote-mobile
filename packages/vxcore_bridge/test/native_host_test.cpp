// SPDX-License-Identifier: LGPL-3.0-only
#include "vxcore_host.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#else
#include <sys/stat.h>
#endif

#include <sqlite3.h>
#include <nlohmann/json.hpp>

#include <vxcore/vxcore.h>
#include <vxcore/mobile/vxcore_mobile.h>

namespace {
namespace fs = std::filesystem;
using Json = nlohmann::json;
#define CHECK(expression) do { if (!(expression)) throw std::runtime_error("Check failed: " #expression); } while (false)
using Event = std::unique_ptr<VxmEvent, decltype(&vxm_event_free)>;

// Tests deliberately latch a notification AFTER native releases its queue lock.
// This controls pending-vs-active boundaries without sleeps or production hooks.
struct Notifications {
  std::mutex mutex;
  std::condition_variable changed;
  uint64_t count = 0;
  uint64_t completed = 0;
  bool hold = false;
  bool entered = false;
  void arrive() {
    std::unique_lock<std::mutex> lock(mutex);
    ++count;
    if (hold) entered = true;
    changed.notify_all();
    changed.wait(lock, [this] { return !hold; });
    ++completed;
    changed.notify_all();
  }
  void wait_entered() {
    std::unique_lock<std::mutex> lock(mutex);
    CHECK(changed.wait_for(lock, std::chrono::seconds(30), [this] { return entered; }));
  }
  void wait_completed(uint64_t expected) {
    std::unique_lock<std::mutex> lock(mutex);
    CHECK(changed.wait_for(lock, std::chrono::seconds(30), [this, expected] { return completed >= expected; }));
  }
  void release() {
    std::lock_guard<std::mutex> lock(mutex);
    hold = false;
    changed.notify_all();
  }
};
Notifications *notifications = nullptr;
void notify(int64_t token) {
  if (token != 7 || !notifications) std::terminate();
  notifications->arrive();
}

struct Fixture {
  fs::path root;
  std::string app, local, notebook;
  std::string notebook_id, node_id;
  Fixture() {
    static std::atomic<unsigned> counter{0};
    root = fs::temp_directory_path() / ("vnote-host-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "-" + std::to_string(++counter));
    fs::create_directories(root);
    app = (root / "app").u8string();
    local = (root / "local").u8string();
    notebook = (root / "book").u8string();
  }
  ~Fixture() { std::error_code ignored; fs::remove_all(root, ignored); }
  fs::path note() const { return fs::u8path(notebook) / "Welcome.md"; }
  void seed(const std::string &initial) {
    if (fs::exists(fs::u8path(notebook))) return;
    VxCoreContextHandle context = nullptr;
    CHECK(vxcore_context_create_with_paths(nullptr, app.c_str(), local.c_str(), &context) == VXCORE_OK);
    char *book = nullptr, *note = nullptr, *buffer = nullptr;
    CHECK(vxcore_notebook_create(context, notebook.c_str(), "{\"name\":\"Personal\"}", VXCORE_NOTEBOOK_BUNDLED, &book) == VXCORE_OK);
    notebook_id = book;
    CHECK(vxcore_file_create(context, book, ".", "Welcome.md", &note) == VXCORE_OK);
    node_id = note;
    CHECK(vxcore_buffer_open_by_node_id(context, note, &buffer) == VXCORE_OK);
    CHECK(vxcore_buffer_set_content_raw(context, buffer, initial.data(), initial.size()) == VXCORE_OK);
    CHECK(vxcore_buffer_save(context, buffer) == VXCORE_OK);
    CHECK(vxcore_buffer_close(context, buffer) == VXCORE_OK);
    CHECK(vxcore_notebook_close(context, book) == VXCORE_OK);
    vxcore_string_free(buffer);
    vxcore_string_free(note);
    vxcore_string_free(book);
    CHECK(vxcore_prepare_shutdown(context) == VXCORE_OK);
    vxcore_context_destroy(context);
  }
};
std::string disk(const fs::path &path) {
  std::ifstream input(path, std::ios::binary);
  CHECK(input.good());
  return std::string(std::istreambuf_iterator<char>(input), {});
}
void external_write(const fs::path &path, const std::string &text) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(text.data(), static_cast<std::streamsize>(text.size()));
  output.close();
  CHECK(!output.fail());
}
std::string text(const Event &event) {
  return event->size ? std::string(reinterpret_cast<const char *>(event->data), static_cast<size_t>(event->size)) : std::string();
}

struct ExportOnly {};
struct Host {
  Notifications signals;
  VxmHost *handle = nullptr;
  uint64_t generation = 0;
  Host(Fixture &fixture, const std::string &initial, bool hold = false) {
    fixture.seed(initial);
    VxmOpenOptions options{fixture.app.c_str(), fixture.local.c_str(), fixture.notebook.c_str(),
                           nullptr, fixture.notebook_id.empty() ? "missing" : fixture.notebook_id.c_str(),
                           fixture.node_id.empty() ? "missing" : fixture.node_id.c_str(), VXM_MODE_NOTE, 0};
    start(options, hold);
  }
  Host(Fixture &fixture, int32_t mode, bool hold = false, const char *expected = nullptr,
       bool create = false, const char *name = "Personal") {
    VxmOpenOptions options{fixture.app.c_str(), fixture.local.c_str(), fixture.notebook.c_str(),
                           create ? name : nullptr, expected, nullptr, mode, create ? 1 : 0};
    start(options, hold);
  }
  Host(Fixture &fixture, ExportOnly, bool hold = false) {
    VxmOpenOptions options{fixture.app.c_str(), fixture.local.c_str(), fixture.notebook.c_str(),
                           nullptr, fixture.notebook_id.c_str(), nullptr, VXM_MODE_CATALOG, 0, 1};
    start(options, hold);
  }
  void start(const VxmOpenOptions &options, bool hold) {
    CHECK(!notifications);
    notifications = &signals;
    signals.hold = hold;
    const auto code = vxm_host_create(&options, notify, 7, &handle);
    if (code != VXCORE_OK) { notifications = nullptr; throw std::runtime_error("Host admission failed: " + std::to_string(code)); }
    generation = vxm_host_generation(handle);
    CHECK(generation > 0);
  }
  ~Host() {
    signals.release();
    if (handle) vxm_host_destroy(handle);
    notifications = nullptr;
  }
  Event next(std::chrono::seconds timeout = std::chrono::seconds(30)) {
    std::unique_lock<std::mutex> lock(signals.mutex);
    for (;;) {
      if (auto *event = vxm_host_take_event(handle)) {
        CHECK(event->generation == generation);
        return Event(event, vxm_event_free);
      }
      const auto before = signals.count;
      CHECK(signals.changed.wait_for(lock, timeout, [&] { return signals.count != before; }));
    }
  }
  int32_t write(uint64_t id, uint64_t revision, const std::string &hash, const std::string &source) {
    return vxm_host_write(handle, id, generation, revision, hash.c_str(), reinterpret_cast<const uint8_t *>(source.data()), source.size());
  }
  int32_t mutate(uint64_t id, int32_t operation, const std::string &node,
                 const char *name = nullptr, const char *destination = nullptr) {
    return vxm_host_catalog_mutate(handle, id, generation, operation, node.c_str(), name, destination);
  }
  int32_t query(uint64_t id, const Json &query) {
    const auto json = query.dump();
    return vxm_host_catalog_query(handle, id, generation, json.c_str());
  }
  int32_t tag(uint64_t id, const Json &mutation) {
    const auto json = mutation.dump();
    return vxm_host_catalog_tag(handle, id, generation, json.c_str());
  }
  void close() {
    vxm_host_request_close(handle);
    auto event = next();
    CHECK(event->kind == VXM_EVENT_CLOSED);
    CHECK(event->request_id == 0);
    CHECK(event->code == VXCORE_OK);
    CHECK(vxm_host_take_event(handle) == nullptr);
    vxm_host_destroy(handle);
    handle = nullptr;
  }
};

std::map<fs::path, std::string> snapshot(const fs::path &root) {
  std::map<fs::path, std::string> result;
  const auto capture = [&](const fs::path &path) {
    const auto status = fs::symlink_status(path);
    const auto key = path.lexically_relative(root);
    if (fs::is_symlink(status)) result[key] = "link:" + fs::read_symlink(path).u8string();
    else if (fs::is_regular_file(status)) result[key] = "file:" + disk(path);
    else if (fs::is_directory(status)) result[key] = "directory";
    else CHECK(false);
  };
  capture(root);
  if (fs::is_directory(fs::symlink_status(root)))
    for (const auto &entry : fs::recursive_directory_iterator(root)) capture(entry.path());
  return result;
}

void catalog_explicit_creation_policy() {
  Fixture missing;
  for (const char *expected : {static_cast<const char *>(nullptr), "missing-id"}) {
    Host host(missing, VXM_MODE_CATALOG, false, expected);
    CHECK(host.next()->code == VXCORE_ERR_NOT_FOUND);
    host.close();
    CHECK(!fs::exists(fs::symlink_status(fs::u8path(missing.notebook))));
  }
  for (const int kind : {0, 1, 2}) {
    Fixture fixture;
    const auto root = fs::u8path(fixture.notebook);
    if (kind == 0) fixture.seed("must survive rejected create");
    else if (kind == 1) {
      fs::create_directory(root);
      external_write(root / "sentinel", "ordinary non-notebook directory");
    } else external_write(root, "ordinary file");
    const auto before = snapshot(root);
    Host host(fixture, VXM_MODE_CATALOG, false, nullptr, true);
    CHECK(host.next()->code == VXCORE_ERR_ALREADY_EXISTS);
    host.close();
    CHECK(snapshot(root) == before);
  }
#if !defined(_WIN32)
  // The Dart suite also exercises Windows junction/reparse roots.
  for (const bool dangling : {false, true}) {
    Fixture fixture;
    const auto target = fixture.root / "target";
    if (!dangling) {
      fs::create_directory(target);
      external_write(target / "sentinel", "link target remains unchanged");
    }
    const auto root = fs::u8path(fixture.notebook);
    fs::create_directory_symlink(target, root);
    const auto before = snapshot(root);
    Host host(fixture, VXM_MODE_CATALOG, false, nullptr, true);
    CHECK(host.next()->code == VXCORE_ERR_ALREADY_EXISTS);
    host.close();
    CHECK(snapshot(root) == before);
    if (dangling) CHECK(!fs::exists(target));
    else CHECK(snapshot(target).size() == 2 && disk(target / "sentinel") == "link target remains unchanged");
  }
#endif
  {
    Host host(missing, VXM_MODE_CATALOG, false, nullptr, true, u8"Personal / 研究: 😀");
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK);
    CHECK(std::string(opened->notebook_name) == u8"Personal / 研究: 😀");
    missing.notebook_id = opened->notebook_id;
    host.close();
  }
  const auto before = snapshot(fs::u8path(missing.notebook));
  {
    Host host(missing, VXM_MODE_CATALOG, false, "wrong-id");
    CHECK(host.next()->code == VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    host.close();
  }
  CHECK(snapshot(fs::u8path(missing.notebook)) == before);
  {
    Host host(missing, VXM_MODE_CATALOG);
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK && std::string(opened->notebook_id) == missing.notebook_id);
    host.close();
  }
}

void catalog_creation_admission_and_display_names() {
  Fixture fixture;
  VxmOpenOptions options{fixture.app.c_str(), fixture.local.c_str(), fixture.notebook.c_str(),
                         "Personal", nullptr, nullptr, VXM_MODE_CATALOG, 1};
  const auto rejected = [&] {
    VxmHost *host = nullptr;
    CHECK(vxm_host_create(&options, notify, 7, &host) == VXCORE_ERR_INVALID_PARAM);
    CHECK(host == nullptr && !fs::exists(fs::u8path(fixture.notebook)));
  };
  for (const auto flag : {-1, 2}) { options.create_notebook = flag; rejected(); }
  options.create_notebook = 1;
  options.mode = VXM_MODE_NOTE;
  rejected();
  options.mode = VXM_MODE_CATALOG;
  options.expected_notebook_id = "unexpected-id";
  rejected();
  options.expected_notebook_id = nullptr;
  options.notebook_name = nullptr;
  rejected();
  const std::vector<std::string> invalid_names{
      "", "  ", u8"\u00a0\u2003\u3000\ufeff", "bad\nname", "bad\x7f", "bad\xc2\x85",
      "bad\xc0\xaf", "bad\xed\xa0\x80", std::string(16385, 'x'), std::string(8193, '\xc2')};
  for (const auto &name : invalid_names) { options.notebook_name = name.c_str(); rejected(); }
  fixture.seed("rename preserves content");
  const auto before = snapshot(fs::u8path(fixture.notebook));
  Host host(fixture, VXM_MODE_CATALOG);
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  const std::string root = opened->node_id;
  for (const auto &name : invalid_names)
    CHECK(host.mutate(2, VXM_RENAME_NOTEBOOK, root, name.c_str()) == VXCORE_ERR_INVALID_PARAM);
  CHECK(host.mutate(2, VXM_RENAME_NOTEBOOK, fixture.node_id, "Wrong node") == VXCORE_OK);
  CHECK(host.next()->code == VXCORE_ERR_INVALID_PARAM);
  CHECK(host.mutate(3, VXM_RENAME, root, "Wrong operation") == VXCORE_OK);
  CHECK(host.next()->code == VXCORE_ERR_INVALID_PARAM);
  CHECK(snapshot(fs::u8path(fixture.notebook)) == before);
  CHECK(host.mutate(4, VXM_RENAME_NOTEBOOK, root, u8"Notebook / 研究: 😀") == VXCORE_OK);
  CHECK(host.next()->code == VXCORE_OK);
  CHECK(vxm_host_catalog_list(host.handle, 5, host.generation, nullptr) == VXCORE_OK);
  auto refreshed = host.next();
  CHECK(refreshed->code == VXCORE_OK && std::string(refreshed->notebook_name) == u8"Notebook / 研究: 😀");
  CHECK(std::string(refreshed->node_id) == root);
  CHECK(disk(fixture.note()) == "rename preserves content");
  host.close();
}

void catalog_rename_preserves_config_and_reopens() {
  Fixture fixture;
  fixture.seed("note and custom assets survive rename");
  const auto root = fs::u8path(fixture.notebook);
  const auto config_path = root / "vx_notebook" / "config.json";
  auto config = Json::parse(disk(config_path));
  config["description"] = "custom notebook description";
  config["assetsFolder"] = "resources/assets";
  config["recycleBinFolder"] = "custom/recycle";
  config["ignored"] = Json::array({"*.private"});
  config["autoSyncEnabled"] = false;
  config["metadata"]["custom"] = Json{{"nested", Json::array({1, true, "retained"})}};
  config["futureField"] = Json{{"keep", "unknown desktop metadata"}};
  config["tags"] = Json::array({Json{{"name", "preserved"}, {"parent", ""}, {"metadata", Json::object()}}});
  config["tagsModifiedUtc"] = 1; // A populated tag set must not trigger legacy open-time migration.
  external_write(config_path, config.dump());
  const auto asset = root / "resources" / "assets" / fs::u8path(fixture.node_id) / "pixel.bin";
  fs::create_directories(asset.parent_path());
  external_write(asset, "custom asset bytes");
  auto before = snapshot(root);
  std::string root_id;
  {
    Host host(fixture, VXM_MODE_CATALOG, false, fixture.notebook_id.c_str());
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK);
    root_id = opened->node_id;
    CHECK(host.mutate(2, VXM_RENAME_NOTEBOOK, root_id, u8"Renamed / 研究: 😀") == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_OK);
    host.close();
  }
  config["name"] = u8"Renamed / 研究: 😀";
  CHECK(Json::parse(disk(config_path)) == config);
  auto after = snapshot(root);
  before.erase(config_path.lexically_relative(root));
  after.erase(config_path.lexically_relative(root));
  CHECK(before == after);
  {
    Host host(fixture, VXM_MODE_CATALOG, false, fixture.notebook_id.c_str());
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK && std::string(opened->node_id) == root_id);
    CHECK(std::string(opened->notebook_name) == u8"Renamed / 研究: 😀");
    CHECK(std::string(opened->notebook_id) == fixture.notebook_id);
    host.close();
  }
}

void round_trip_and_conflict() {
  Fixture fixture;
  const std::string original = u8"\ufeff# 中文 😀\r\ncombining e\u0301\r\nlast\rtail\n";
  const std::string edited = original + u8"مرحبا 日本語\r\n";
  std::string notebook_id, node_id;
  {
    Host host(fixture, original);
    auto opened = host.next();
    CHECK(opened->kind == VXM_EVENT_OPEN && opened->code == VXCORE_OK);
    CHECK(text(opened) == original);
    CHECK(disk(fixture.note()) == original);
    notebook_id = opened->notebook_id;
    node_id = opened->node_id;
    CHECK(!notebook_id.empty() && !node_id.empty());
    CHECK(std::string(opened->core_version).size() > 0);
    CHECK(std::string(opened->base_hash).size() == 64);
    CHECK(host.write(2, 1, opened->base_hash, edited) == VXCORE_OK);
    auto written = host.next();
    CHECK(written->kind == VXM_EVENT_WRITE && written->code == VXCORE_OK && written->revision == 1);
    CHECK(disk(fixture.note()) == edited);
    const std::string hash = written->base_hash;
    CHECK(vxm_host_read(host.handle, 3, host.generation) == VXCORE_OK);
    auto read = host.next();
    CHECK(read->code == VXCORE_OK && text(read) == edited);
    CHECK(std::string(read->base_hash) == hash);
    CHECK(std::string(read->notebook_id) == notebook_id && std::string(read->node_id) == node_id);
    const auto mtime = fs::last_write_time(fixture.note());
    auto external = edited;
    external[external.find('#')] = '!'; // Change ASCII, not part of a UTF-8 sequence.
    external_write(fixture.note(), external);
    fs::last_write_time(fixture.note(), mtime);
    CHECK(host.write(4, 2, hash, "must not replace external bytes") == VXCORE_OK);
    auto conflict = host.next();
    CHECK(conflict->code == VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    CHECK(disk(fixture.note()) == external);
    CHECK(std::string(conflict->message).find(fixture.notebook) == std::string::npos);
    CHECK(vxm_host_read(host.handle, 5, host.generation) == VXCORE_OK);
    auto fresh = host.next();
    CHECK(fresh->code == VXCORE_OK && text(fresh) == external);
    CHECK(host.write(6, 2, fresh->base_hash, edited) == VXCORE_OK);
    auto retry = host.next();
    CHECK(retry->code == VXCORE_OK);
    CHECK(host.write(7, 1, retry->base_hash, "stale revision") == VXCORE_OK);
    auto stale = host.next();
    CHECK(stale->code == VXCORE_ERR_INVALID_STATE);
    CHECK(disk(fixture.note()) == edited);
    host.close();
  }
  {
    Host host(fixture, "do not recreate");
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK && text(opened) == edited);
    CHECK(std::string(opened->notebook_id) == notebook_id && std::string(opened->node_id) == node_id);
    host.close();
  }
}

void admission_cancellation_and_close() {
  Fixture fixture;
  Host host(fixture, "original", true);
  host.signals.wait_entered();
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  const std::string hash = opened->base_hash;
  opened.reset();
  CHECK(vxm_host_read(host.handle, 2, host.generation + 1) == VXCORE_ERR_INVALID_STATE);
  const std::string oversized(VXM_MAX_SOURCE_BYTES + 1, 'x');
  CHECK(host.write(2, 1, hash, oversized) == VXCORE_ERR_INVALID_PARAM);
  const std::string invalid("\xc0\xaf", 2);
  CHECK(host.write(2, 1, hash, invalid) == VXCORE_ERR_UNSUPPORTED);
  CHECK(host.write(2, 1, hash, "cancel me") == VXCORE_OK);
  CHECK(host.write(2, 1, hash, "duplicate") == VXCORE_ERR_INVALID_STATE);
  CHECK(vxm_host_cancel(host.handle, 2, host.generation) == VXCORE_OK);
  // Every admitted operation retains its reserved terminal even at saturation.
  for (uint64_t id = 3; id <= 65; ++id) CHECK(host.write(id, id, hash, "queued") == VXCORE_OK);
  CHECK(host.write(66, 66, hash, "over capacity") == VXCORE_ERR_OUT_OF_MEMORY);
  vxm_host_request_close(host.handle);
  vxm_host_request_close(host.handle);
  CHECK(host.write(66, 66, hash, "closed") == VXCORE_ERR_INVALID_STATE);
  host.signals.release();
  std::set<uint64_t> completed;
  for (size_t count = 0; count < VXM_MAX_OPERATIONS; ++count) {
    auto event = host.next();
    CHECK(event->kind == VXM_EVENT_WRITE && event->code == VXCORE_ERR_CANCELLED);
    CHECK(completed.insert(event->request_id).second);
  }
  CHECK(completed.size() == VXM_MAX_OPERATIONS);
  CHECK(disk(fixture.note()) == "original");
  host.close();
}

void output_and_input_reservations() {
  Fixture fixture;
  Host host(fixture, "source", true);
  host.signals.wait_entered();
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  const std::string hash = opened->base_hash;
  // Saturate actual reserved source + metadata charges, not an incidental count.
  uint64_t id = 2;
  size_t pending = 0;
  while (vxm_host_read(host.handle, id, host.generation) == VXCORE_OK) { ++id; ++pending; }
  CHECK(pending > 0 && pending < VXM_MAX_OPERATIONS);
  CHECK(vxm_host_read(host.handle, id, host.generation) == VXCORE_ERR_OUT_OF_MEMORY);
  opened.reset();
  CHECK(vxm_host_read(host.handle, id++, host.generation) == VXCORE_OK);
  ++pending;
  const std::string maximum(VXM_MAX_SOURCE_BYTES, 'x');
  size_t inputs = 0;
  while (host.write(id, id, hash, maximum) == VXCORE_OK) { ++id; ++inputs; ++pending; }
  CHECK(inputs > 0 && inputs <= VXM_MAX_INPUT_BYTES / VXM_MAX_SOURCE_BYTES);
  CHECK(host.write(id, id, hash, maximum) == VXCORE_ERR_OUT_OF_MEMORY);
  vxm_host_request_close(host.handle);
  host.signals.release();
  for (size_t i = 0; i < pending; ++i) CHECK(host.next()->code == VXCORE_ERR_CANCELLED);
  host.close();
}

void completed_mutation_is_not_cancelled() {
  Fixture fixture;
  Host host(fixture, "base");
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  host.signals.wait_completed(1);
  {
    std::lock_guard<std::mutex> lock(host.signals.mutex);
    host.signals.hold = true;
    host.signals.entered = false;
  }
  CHECK(host.write(2, 42, opened->base_hash, "committed") == VXCORE_OK);
  host.signals.wait_entered(); // WRITE has completed and published, owner is latched.
  CHECK(vxm_host_cancel(host.handle, 2, host.generation) == VXCORE_ERR_INVALID_STATE);
  vxm_host_request_close(host.handle);
  auto written = host.next();
  CHECK(written->code == VXCORE_OK && written->revision == 42);
  CHECK(disk(fixture.note()) == "committed");
  host.signals.release();
  host.close();
  // Borrowed strings belong to this event, not the now-destroyed host.
  CHECK(std::string(written->base_hash).size() == 64);
  CHECK(std::string(opened->node_id).size() > 0);
}

void malformed_missing_and_encoding() {
  {
    Fixture fixture;
    fs::create_directory(fs::u8path(fixture.notebook));
    Host host(fixture, "must not create");
    auto event = host.next();
    CHECK(event->code != VXCORE_OK);
    CHECK(!fs::exists(fixture.note()));
    host.close();
  }
  Fixture fixture;
  std::string id;
  {
    Host host(fixture, "valid");
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK);
    id = opened->node_id;
    const std::string bad("\xff\xfe\x61\x00", 4);
    external_write(fixture.note(), bad);
    CHECK(vxm_host_read(host.handle, 2, host.generation) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_ERR_UNSUPPORTED);
    CHECK(host.write(3, 1, opened->base_hash, "never repair") == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_ERR_UNSUPPORTED);
    CHECK(disk(fixture.note()) == bad);
    host.close();
  }
  fs::remove(fixture.note());
  {
    Host host(fixture, "never recreate");
    auto opened = host.next();
    CHECK(opened->code == VXCORE_ERR_NODE_NOT_EXISTS);
    CHECK(!fs::exists(fixture.note()));
    host.close();
  }
  // Restoring bytes externally is a fixture operation, not a host repair path.
  external_write(fixture.note(), "valid again");
  {
    Host host(fixture, "ignored");
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK && std::string(opened->node_id) == id);
    host.close();
  }
}

void line_ending_policy() {
  Fixture fixture;
  const std::string original = "one\r\ntwo\rthree\n";
  {
    Host host(fixture, original);
    CHECK(host.next()->code == VXCORE_OK);
    host.close();
  }
  VxCoreContextHandle context = nullptr;
  CHECK(vxcore_context_create_with_paths(nullptr, fixture.app.c_str(), fixture.local.c_str(), &context) == VXCORE_OK);
  char *id = nullptr;
  CHECK(vxcore_notebook_open(context, fixture.notebook.c_str(), &id) == VXCORE_OK);
  CHECK(vxcore_notebook_update_config(context, id, "{\"name\":\"Personal\",\"metadata\":{\"lineEnding\":\"crlf\"}}") == VXCORE_OK);
  CHECK(vxcore_notebook_close(context, id) == VXCORE_OK);
  vxcore_string_free(id);
  CHECK(vxcore_prepare_shutdown(context) == VXCORE_OK);
  vxcore_context_destroy(context);
  {
    Host host(fixture, "ignored");
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK && opened->line_ending == VXCORE_LINE_ENDING_CRLF);
    CHECK(text(opened) == original && disk(fixture.note()) == original);
    CHECK(host.write(2, 1, opened->base_hash, original) == VXCORE_OK);
    auto unchanged = host.next();
    CHECK(unchanged->code == VXCORE_OK && disk(fixture.note()) == original);
    CHECK(host.write(3, 2, unchanged->base_hash, "edited\none\rtwo\r\n") == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_OK);
    CHECK(disk(fixture.note()) == "edited\r\none\r\ntwo\r\n");
    host.close();
  }
}

void catalog_lifecycle_and_boundaries() {
  Fixture fixture;
  Event retained(nullptr, vxm_event_free);
  std::string notebook, folder, note;
  {
    Host host(fixture, VXM_MODE_CATALOG, true, nullptr, true);
    host.signals.wait_entered();
    auto opened = host.next();
    CHECK(opened->kind == VXM_EVENT_CATALOG_OPEN && opened->code == VXCORE_OK);
    CHECK(std::string(opened->path) == "." && std::string(opened->parent_id).empty());
    CHECK(std::string(opened->notebook_name) == "Personal");
    notebook = opened->notebook_id;
    const std::string root = opened->node_id;
    CHECK(!fs::exists(fixture.note()));
    CHECK(vxm_host_read(host.handle, 2, host.generation) == VXCORE_ERR_INVALID_STATE);
    CHECK(host.write(2, 1, std::string(64, '0'), "forbidden") == VXCORE_ERR_INVALID_STATE);
    CHECK(vxm_host_catalog_list(host.handle, 2, host.generation, nullptr) == VXCORE_OK);
    // Admission reserves 8 MiB + metadata even though OPEN has already shrunk.
    CHECK(vxm_host_catalog_list(host.handle, 3, host.generation, nullptr) == VXCORE_ERR_OUT_OF_MEMORY);
    CHECK(vxm_host_cancel(host.handle, 2, host.generation) == VXCORE_OK);
    host.signals.release();
    auto cancelled = host.next();
    CHECK(cancelled->code == VXCORE_ERR_CANCELLED);
    cancelled.reset();
    CHECK(vxm_host_catalog_list(host.handle, 3, host.generation, nullptr) == VXCORE_OK);
    retained = host.next();
    CHECK(retained->code == VXCORE_OK && retained->data != nullptr);
    // The completed small list releases its unused reservation before delivery.
    CHECK(host.mutate(4, VXM_CREATE_FOLDER, root, u8"研究") == VXCORE_OK);
    auto created = host.next();
    CHECK(created->code == VXCORE_OK);
    folder = created->node_id;
    CHECK(host.mutate(5, VXM_CREATE_NOTE, folder, u8"筆記.md") == VXCORE_OK);
    auto file = host.next();
    CHECK(file->code == VXCORE_OK && file->size == 0);
    note = file->node_id;
    CHECK(host.mutate(6, VXM_RENAME, note, "renamed.txt") == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_OK);
    CHECK(host.mutate(7, VXM_MOVE, folder, nullptr, folder.c_str()) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_ERR_INVALID_PARAM);
    CHECK(host.mutate(8, VXM_DELETE, root) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_ERR_INVALID_PARAM);
    CHECK(host.mutate(9, VXM_CREATE_NOTE, folder, "opaque.bin") == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_ERR_UNSUPPORTED);
    CHECK(vxm_host_catalog_list(host.handle, 10, host.generation, folder.c_str()) == VXCORE_OK);
    auto nested = host.next();
    CHECK(nested->code == VXCORE_OK && std::string(nested->path) == u8"研究");
    CHECK(std::string(nested->parent_id) == root);
    CHECK(text(nested).find(note) != std::string::npos);
    host.close();
  }
  CHECK(std::string(retained->notebook_id) == notebook);
  CHECK(text(retained).find("files") != std::string::npos);
  retained.reset(); // Core-owned JSON and retained capacity survive host destroy.
  fixture.notebook_id = notebook;
  fixture.node_id = note;
  {
    Host host(fixture, "ignored");
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK && opened->editor_type == VXM_EDITOR_TEXT);
    CHECK(std::string(opened->path) == u8"研究/renamed.txt");
    CHECK(vxm_host_catalog_list(host.handle, 2, host.generation, nullptr) == VXCORE_ERR_INVALID_STATE);
    CHECK(host.mutate(2, VXM_DELETE, note) == VXCORE_ERR_INVALID_STATE);
    host.close();
  }
  {
    Host host(fixture, VXM_MODE_CATALOG, false, "wrong-notebook");
    CHECK(host.next()->code == VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    host.close();
  }
  fs::remove_all(fs::u8path(fixture.notebook));
  {
    Host host(fixture, VXM_MODE_CATALOG, false, notebook.c_str());
    CHECK(host.next()->code == VXCORE_ERR_NOT_FOUND);
    CHECK(!fs::exists(fs::u8path(fixture.notebook)));
    host.close();
  }
}

void catalog_actual_outcome_and_close() {
  Fixture fixture;
  Host host(fixture, VXM_MODE_CATALOG, false, nullptr, true);
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  const std::string root = opened->node_id;
  host.signals.wait_completed(1);
  {
    std::lock_guard<std::mutex> lock(host.signals.mutex);
    host.signals.hold = true;
    host.signals.entered = false;
  }
  CHECK(host.mutate(2, VXM_CREATE_NOTE, root, "committed.md") == VXCORE_OK);
  host.signals.wait_entered();
  CHECK(vxm_host_cancel(host.handle, 2, host.generation) == VXCORE_ERR_INVALID_STATE);
  CHECK(host.mutate(3, VXM_CREATE_NOTE, root, "pending.md") == VXCORE_OK);
  vxm_host_request_close(host.handle);
  auto created = host.next();
  CHECK(created->code == VXCORE_OK && !std::string(created->node_id).empty());
  host.signals.release();
  CHECK(host.next()->code == VXCORE_ERR_CANCELLED);
  host.close();
  CHECK(fs::exists(fs::u8path(fixture.notebook) / "committed.md"));
  CHECK(!fs::exists(fs::u8path(fixture.notebook) / "pending.md"));
}

void catalog_missing_parent_does_not_create_metadata() {
  Fixture fixture;
  Host host(fixture, VXM_MODE_CATALOG, false, nullptr, true);
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  CHECK(host.mutate(2, VXM_CREATE_FOLDER, opened->node_id, "missing") == VXCORE_OK);
  auto created = host.next();
  CHECK(created->code == VXCORE_OK);
  const std::string folder = created->node_id;
  const auto metadata = fs::u8path(fixture.notebook) / "vx_notebook" / "contents" / "missing" / "vx.json";
  const auto before = disk(metadata);
  fs::remove(fs::u8path(fixture.notebook) / "missing");
  CHECK(host.mutate(3, VXM_CREATE_NOTE, folder, "partial.md") == VXCORE_OK);
  CHECK(host.next()->code == VXCORE_ERR_NODE_NOT_EXISTS);
  CHECK(!fs::exists(fs::u8path(fixture.notebook) / "missing" / "partial.md"));
  CHECK(disk(metadata) == before);
  CHECK(host.mutate(4, VXM_DELETE, folder) == VXCORE_OK);
  CHECK(host.next()->code == VXCORE_OK);
  CHECK(!fs::exists(metadata));
  host.close();
}

void catalog_completed_output_accounting() {
  Fixture fixture;
  Host host(fixture, VXM_MODE_CATALOG, false, nullptr, true);
  std::vector<Event> held;
  held.push_back(host.next());
  CHECK(held.back()->code == VXCORE_OK);
  for (uint64_t id = 2; id <= VXM_MAX_OPERATIONS; ++id) {
    CHECK(vxm_host_catalog_list(host.handle, id, host.generation, nullptr) == VXCORE_OK);
    held.push_back(host.next());
    CHECK(held.back()->code == VXCORE_OK && held.back()->data != nullptr);
  }
  // Completed JSON retains only actual bytes + owned metadata, allowing all 64
  // small terminals. Holding them still consumes the operation reservations.
  CHECK(vxm_host_catalog_list(host.handle, 65, host.generation, nullptr) == VXCORE_ERR_OUT_OF_MEMORY);
  held.front().reset();
  CHECK(vxm_host_catalog_list(host.handle, 65, host.generation, nullptr) == VXCORE_OK);
  held.front() = host.next();
  CHECK(held.front()->code == VXCORE_OK);
  host.close();
  for (const auto &event : held) {
    CHECK(text(event).find("files") != std::string::npos);
    CHECK(std::string(event->path) == ".");
  }
  held.clear();
}

void catalog_reports_nonfatal_asset_move_failure() {
#if defined(_WIN32)
  Fixture fixture;
  fixture.seed("source remains truthful");
  const auto assets = fs::u8path(fixture.notebook) / "vx_assets" / fs::u8path(fixture.node_id);
  fs::create_directories(assets);
  external_write(assets / "pixel.bin", "asset bytes");
  Host host(fixture, VXM_MODE_CATALOG);
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  CHECK(host.mutate(2, VXM_CREATE_FOLDER, opened->node_id, "destination") == VXCORE_OK);
  auto folder = host.next();
  CHECK(folder->code == VXCORE_OK);
  // A real Windows directory handle without FILE_SHARE_DELETE forces core's
  // asset rename/remove side effect to fail while allowing stat/read/copy.
  struct LockedDirectory {
    HANDLE handle;
    ~LockedDirectory() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }
  } lock{CreateFileW(assets.c_str(), FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE,
                     nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr)};
  CHECK(lock.handle != INVALID_HANDLE_VALUE);
  CHECK(host.mutate(3, VXM_MOVE, fixture.node_id, nullptr, folder->node_id) == VXCORE_OK);
  auto result = host.next();
  CHECK(result->code != VXCORE_OK);
  CHECK(std::string(result->node_id) == fixture.node_id);
  CHECK(disk(fs::u8path(fixture.notebook) / "destination" / "Welcome.md") == "source remains truthful");
  CHECK(fs::exists(assets));
  CHECK(vxm_host_catalog_list(host.handle, 4, host.generation, folder->node_id) == VXCORE_OK);
  auto refreshed = host.next();
  CHECK(refreshed->code == VXCORE_OK && text(refreshed).find(fixture.node_id) != std::string::npos);
  host.close();
#endif
}

void catalog_resolves_stale_cache_after_metadata_store_failure() {
  Fixture fixture;
  fixture.seed("identity survives a stale derived cache");
  {
    Host host(fixture, VXM_MODE_CATALOG);
    auto opened = host.next();
    CHECK(opened->code == VXCORE_OK);
    struct Cache {
      sqlite3 *value = nullptr;
      ~Cache() { if (value) sqlite3_close(value); }
    } cache;
    const auto path = fs::u8path(fixture.local) / "notebooks" / fs::u8path(fixture.notebook_id) / "metadata.db";
    CHECK(sqlite3_open_v2(path.u8string().c_str(), &cache.value, SQLITE_OPEN_READWRITE, nullptr) == SQLITE_OK);
    // Only the derived cache is wrong; portable metadata/body remain authoritative.
    CHECK(sqlite3_exec(cache.value, "UPDATE files SET name='stale-cache.md'", nullptr, nullptr, nullptr) == SQLITE_OK);
    CHECK(sqlite3_close(cache.value) == SQLITE_OK);
    cache.value = nullptr;
    CHECK(host.mutate(2, VXM_RENAME, fixture.node_id, "Retained.md") == VXCORE_OK);
    auto renamed = host.next();
    CHECK(renamed->code == VXCORE_OK);
    CHECK(disk(fs::u8path(fixture.notebook) / "Retained.md") ==
          "identity survives a stale derived cache");
    CHECK(!fs::exists(fixture.note()));
    host.close();
  }
  {
    Host reopened(fixture, "ignored");
    auto note = reopened.next();
    CHECK(note->code == VXCORE_OK && std::string(note->node_id) == fixture.node_id);
    CHECK(std::string(note->path) == "Retained.md");
    reopened.close();
  }
}

// Fixture-only portable metadata edits model existing desktop notebooks without
// creating thousands of unrelated mutation terminals. Host never writes directly.
fs::path root_metadata(const Fixture &fixture) {
  return fs::u8path(fixture.notebook) / "vx_notebook" / "contents" / "vx.json";
}
void seed_search_files(Fixture &fixture, size_t count, const std::string &body) {
  fixture.seed(body);
  const auto metadata = root_metadata(fixture);
  auto config = Json::parse(disk(metadata));
  const auto prototype = config.at("files").front();
  config["files"] = Json::array();
  for (size_t i = 0; i < count; ++i) {
    auto file = prototype;
    auto suffix = std::to_string(i + 1);
    suffix.insert(0, 12 - suffix.size(), '0');
    file["id"] = "00000000-0000-4000-8000-" + suffix;
    const auto name = "note-" + std::to_string(i) + ".md";
    file["name"] = name;
    file["tags"] = Json::array({"bound"});
    config["files"].push_back(std::move(file));
    external_write(fs::u8path(fixture.notebook) / name, body);
  }
  fs::remove(fixture.note());
  external_write(metadata, config.dump());
}

void catalog_query_admission_and_lifecycle() {
  Fixture fixture;
  fixture.seed("needle");
  Host host(fixture, VXM_MODE_CATALOG, true);
  host.signals.wait_entered();
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  opened.reset();
  const Json search = {{"op", "search"}, {"text", "needle"}, {"caseSensitive", false}};
  CHECK(vxm_host_catalog_query(host.handle, 2, host.generation, nullptr) == VXCORE_ERR_NULL_POINTER);
  CHECK(host.query(2, {{"op", "search"}, {"text", ""}, {"caseSensitive", false}}) == VXCORE_ERR_INVALID_PARAM);
  CHECK(host.query(2, {{"op", "search"}, {"text", std::string(16385, 'x')}, {"caseSensitive", false}}) == VXCORE_ERR_INVALID_PARAM);
  CHECK(host.query(2, {{"op", "search"}, {"text", std::string("a\0b", 3)}, {"caseSensitive", false}}) == VXCORE_ERR_INVALID_PARAM);
  CHECK(host.tag(2, {{"op", "setTags"}, {"nodeId", fixture.node_id}, {"tags", Json::array({"same", "same"})}}) == VXCORE_ERR_INVALID_PARAM);
  CHECK(host.query(2, search) == VXCORE_OK);
  CHECK(host.query(3, search) == VXCORE_ERR_OUT_OF_MEMORY);
  CHECK(vxm_host_cancel(host.handle, 2, host.generation + 1) == VXCORE_ERR_INVALID_STATE);
  CHECK(vxm_host_cancel(host.handle, 2, host.generation) == VXCORE_OK);
  host.signals.release();
  auto cancelled = host.next();
  CHECK(cancelled->kind == VXM_EVENT_QUERY && cancelled->request_id == 2 && cancelled->code == VXCORE_ERR_CANCELLED);
  CHECK(cancelled->size == 0 && cancelled->data == nullptr);
  CHECK(host.query(3, search) == VXCORE_OK);
  auto retained = host.next();
  CHECK(retained->code == VXCORE_OK && retained->size <= VXM_MAX_CATALOG_BYTES);
  CHECK(Json::parse(text(retained)).at("matches").size() == 1);
  CHECK(vxm_host_cancel(host.handle, 3, host.generation) == VXCORE_ERR_INVALID_STATE);
  // The actual 8 MiB allocation remains charged, not merely its small JSON size.
  CHECK(host.query(4, search) == VXCORE_ERR_OUT_OF_MEMORY);
  host.close();
  CHECK(Json::parse(text(retained)).at("notebookId") == fixture.notebook_id);
  retained.reset();
}

void catalog_search_snippets_and_skips() {
  Fixture fixture;
  const std::string unicode = std::string(511, 'a') + u8"😀 needle needle\nneedle";
  fixture.seed(unicode);
  Host host(fixture, VXM_MODE_CATALOG);
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  CHECK(host.query(2, {{"op", "search"}, {"text", "needle"}, {"caseSensitive", false}}) == VXCORE_OK);
  auto result = host.next();
  CHECK(result->code == VXCORE_OK);
  auto decoded = Json::parse(text(result));
  CHECK(decoded.at("matches").size() == 1 && !decoded.at("limited").get<bool>());
  CHECK(decoded.at("matches").front().at("snippet") == std::string(511, 'a'));
  CHECK(decoded.at("matches").front().at("id") == fixture.node_id);
  CHECK(decoded.at("matches").front().at("path") == "Welcome.md");
  CHECK(decoded.at("matches").front().at("line") == 1);
  result.reset();
  // A maximally escaped legal 4 MiB line exceeds the ordinary 8 MiB metadata
  // parse ceiling, but is still one bounded callback and one <=512-byte snippet.
  external_write(fixture.note(), "needle" + std::string(VXM_MAX_SOURCE_BYTES - 6, '\1'));
  CHECK(host.query(3, {{"op", "search"}, {"text", "needle"}, {"caseSensitive", true}}) == VXCORE_OK);
  result = host.next();
  CHECK(result->code == VXCORE_OK);
  decoded = Json::parse(text(result));
  CHECK(decoded.at("matches").size() == 1);
  CHECK(decoded.at("matches").front().at("snippet").get<std::string>().size() == 512);
  result.reset();
  uint64_t id = 4;
  for (const auto &unsupported : {std::string("bad\0needle", 10), std::string("\xffneedle", 7),
                                  std::string(VXM_MAX_SOURCE_BYTES + 1, 'a')}) {
    external_write(fixture.note(), unsupported);
    CHECK(host.query(id++, {{"op", "search"}, {"text", "needle"}, {"caseSensitive", false}}) == VXCORE_OK);
    result = host.next();
    CHECK(result->code == VXCORE_OK);
    decoded = Json::parse(text(result));
    CHECK(decoded.at("matches").empty() && decoded.at("skipped") == 1);
    result.reset();
  }
  fs::remove(fixture.note());
  CHECK(host.query(7, {{"op", "search"}, {"text", "needle"}, {"caseSensitive", false}}) == VXCORE_OK);
  result = host.next();
  CHECK(result->code == VXCORE_OK);
  decoded = Json::parse(text(result));
  CHECK(decoded.at("matches").empty() && decoded.at("skipped") == 1);
  host.close();
}

void catalog_search_result_limits_and_cancellation() {
  Fixture fixture;
  seed_search_files(fixture, 10001, "needle" + std::string(506, '\1'));
  Host host(fixture, VXM_MODE_CATALOG);
  CHECK(host.next(std::chrono::seconds(120))->code == VXCORE_OK);
  const Json search = {{"op", "search"}, {"text", "needle"}, {"caseSensitive", false}};
  CHECK(host.query(2, search) == VXCORE_OK);
  auto result = host.next(std::chrono::seconds(120));
  CHECK(result->code == VXCORE_OK && result->size <= VXM_MAX_CATALOG_BYTES);
  auto decoded = Json::parse(text(result));
  CHECK(decoded.at("limited").get<bool>());
  CHECK(decoded.at("matches").size() > 0 && decoded.at("matches").size() < 10000);
  CHECK(decoded.at("skipped") == 0);
  result.reset();
  CHECK(host.query(3, {{"op", "search"}, {"text", ""}, {"tag", "bound"}, {"caseSensitive", false}}) == VXCORE_OK);
  result = host.next(std::chrono::seconds(120));
  CHECK(result->code == VXCORE_OK && result->size <= VXM_MAX_CATALOG_BYTES);
  decoded = Json::parse(text(result));
  CHECK(decoded.at("limited").get<bool>() && decoded.at("matches").size() == 10000);
  CHECK(decoded.at("matches").front().at("line") == 0);
  CHECK(decoded.at("matches").front().at("snippet") == "");
  result.reset();
  // Exercise the pending/active cancellation race against real multi-file work.
  // Every accepted cancel must have exactly one cancelled, bodyless terminal.
  for (uint64_t id = 4; id < 12; ++id) {
    CHECK(host.query(id, search) == VXCORE_OK);
    std::this_thread::yield();
    const auto cancelled = vxm_host_cancel(host.handle, id, host.generation);
    result = host.next(std::chrono::seconds(120));
    CHECK(result->request_id == id && result->kind == VXM_EVENT_QUERY);
    CHECK(cancelled == VXCORE_OK ? result->code == VXCORE_ERR_CANCELLED :
          cancelled == VXCORE_ERR_INVALID_STATE && result->code == VXCORE_OK);
    if (cancelled == VXCORE_OK) CHECK(result->size == 0 && result->data == nullptr);
    result.reset();
  }
  CHECK(host.query(12, search) == VXCORE_OK);
  std::this_thread::yield();
  vxm_host_request_close(host.handle);
  result = host.next(std::chrono::seconds(120));
  CHECK(result->kind == VXM_EVENT_QUERY && result->request_id == 12);
  CHECK(result->code == VXCORE_ERR_CANCELLED || result->code == VXCORE_OK);
  host.close(); // QUERY must precede the dedicated CLOSED terminal.
}

void catalog_tags_preserve_orphans_and_mutation_outcome() {
  Fixture fixture;
  fixture.seed("body is unchanged");
  auto config = Json::parse(disk(root_metadata(fixture)));
  config["files"][0]["tags"] = Json::array({"orphan"});
  config["files"][0]["metadata"]["custom"] = "retained";
  external_write(root_metadata(fixture), config.dump());
  {
    Host host(fixture, VXM_MODE_CATALOG);
    CHECK(host.next()->code == VXCORE_OK);
    CHECK(host.tag(2, {{"op", "createTag"}, {"name", "defined"}}) == VXCORE_OK);
    auto created = host.next();
    CHECK(created->kind == VXM_EVENT_TAG && created->code == VXCORE_OK && created->size == 0);
    CHECK(host.tag(3, {{"op", "setTags"}, {"nodeId", fixture.node_id}, {"tags", Json::array({"orphan", "defined"})}}) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_OK);
    CHECK(host.query(4, {{"op", "tags"}, {"nodeId", fixture.node_id}}) == VXCORE_OK);
    auto tags = host.next();
    CHECK(tags->code == VXCORE_OK);
    const auto decoded = Json::parse(text(tags));
    CHECK(decoded.at("assigned") == Json::array({"orphan", "defined"}));
    CHECK(decoded.at("tags") == Json::array({Json{{"name", "defined"}, {"parent", ""}}}));
    tags.reset();
    host.signals.wait_completed(4);
    {
      std::lock_guard<std::mutex> lock(host.signals.mutex);
      host.signals.hold = true;
      host.signals.entered = false;
    }
    CHECK(host.tag(5, {{"op", "setTags"}, {"nodeId", fixture.node_id}, {"tags", Json::array({"orphan"})}}) == VXCORE_OK);
    host.signals.wait_entered();
    CHECK(vxm_host_cancel(host.handle, 5, host.generation) == VXCORE_ERR_INVALID_STATE);
    vxm_host_request_close(host.handle);
    CHECK(host.next()->code == VXCORE_OK);
    host.signals.release();
    host.close();
  }
  CHECK(disk(fixture.note()) == "body is unchanged");
  config = Json::parse(disk(root_metadata(fixture)));
  CHECK(config.at("files").front().at("id") == fixture.node_id);
  CHECK(config.at("files").front().at("metadata").at("custom") == "retained");
  {
    Host host(fixture, VXM_MODE_CATALOG);
    CHECK(host.next()->code == VXCORE_OK);
    CHECK(host.query(2, {{"op", "tags"}, {"nodeId", fixture.node_id}}) == VXCORE_OK);
    auto tags = host.next();
    CHECK(tags->code == VXCORE_OK && Json::parse(text(tags)).at("assigned") == Json::array({"orphan"}));
    tags.reset();
    CHECK(host.tag(3, {{"op", "setTags"}, {"nodeId", fixture.node_id}, {"tags", Json::array({"new-unknown"})}}) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_ERR_INVALID_PARAM);
    CHECK(host.tag(4, {{"op", "setTags"}, {"nodeId", fixture.node_id}, {"tags", Json::array()}}) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_OK);
    CHECK(host.tag(5, {{"op", "setTags"}, {"nodeId", fixture.node_id}, {"tags", Json::array({"orphan"})}}) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_ERR_INVALID_PARAM);
    fs::remove(fixture.note());
    CHECK(host.tag(6, {{"op", "setTags"}, {"nodeId", fixture.node_id}, {"tags", Json::array({"defined"})}}) == VXCORE_OK);
    CHECK(host.next()->code != VXCORE_OK);
    CHECK(!fs::exists(fixture.note()));
    host.close();
  }
}

void catalog_tags_are_complete_or_error() {
  for (const bool definitions : {false, true}) {
    Fixture fixture;
    fixture.seed("body");
    const auto path = definitions ? fs::u8path(fixture.notebook) / "vx_notebook" / "config.json" : root_metadata(fixture);
    auto config = Json::parse(disk(path));
    Json tags = Json::array();
    for (size_t i = 0; i < 10001; ++i) {
      const auto name = "tag-" + std::to_string(i);
      if (definitions) tags.push_back(Json{{"name", name}, {"parent", ""}});
      else tags.push_back(name);
    }
    if (definitions) config["tags"] = std::move(tags);
    else config["files"][0]["tags"] = std::move(tags);
    external_write(path, config.dump());
    Host host(fixture, VXM_MODE_CATALOG);
    CHECK(host.next()->code == VXCORE_OK);
    CHECK(host.query(2, {{"op", "tags"}, {"nodeId", fixture.node_id}}) == VXCORE_OK);
    auto result = host.next();
    CHECK(result->code != VXCORE_OK && result->size == 0 && result->data == nullptr);
    // Failure releases its body allocation; holding the terminal doesn't block
    // a separate mutation outcome or falsely expose a truncated assignment set.
    CHECK(host.tag(3, {{"op", "createTag"}, {"name", "after-query-error"}}) == VXCORE_OK);
    CHECK(host.next()->code == VXCORE_OK);
    host.close();
  }
}


constexpr uint64_t kSnapshotBudget = 4ULL * 1024 * 1024 * 1024 - 128 * 1024;
int32_t capture(Host &host, uint64_t id, const fs::path &destination, uint64_t budget = kSnapshotBudget) {
  const auto path = destination.u8string();
  return vxm_host_catalog_export(host.handle, id, host.generation, path.c_str(), budget);
}
void seed_encrypted_export(Fixture &fixture) {
  VxCoreContextHandle context = nullptr;
  CHECK(vxcore_context_create_with_paths(nullptr, fixture.app.c_str(), fixture.local.c_str(), &context) == VXCORE_OK);
  char *notebook = nullptr, *note = nullptr;
  CHECK(vxcore_notebook_open(context, fixture.notebook.c_str(), &notebook) == VXCORE_OK);
  const std::string password = "export-test-password";
  VxCoreEncryptionSetupHandle setup = nullptr;
  CHECK(vxcore_encryption_prepare_notebook(context, notebook, nullptr, password.data(), password.size(), &setup) == VXCORE_OK);
  CHECK(vxcore_encryption_commit_notebook(context, setup) == VXCORE_OK);
  const std::string body = "private encrypted body";
  CHECK(vxcore_encryption_create_note(context, notebook, ".", "protected.md", "markdown",
                                      body.data(), body.size(), &note) == VXCORE_OK);
  vxcore_string_free(note);
  CHECK(vxcore_notebook_close(context, notebook) == VXCORE_OK);
  vxcore_string_free(notebook);
  CHECK(vxcore_prepare_shutdown(context) == VXCORE_OK);
  vxcore_context_destroy(context);
}
void catalog_export_preserves_portable_tree() {
  Fixture fixture;
  fixture.seed("original notebook bytes\r\n");
  seed_encrypted_export(fixture);
  const auto root = fs::u8path(fixture.notebook);
  const auto config_path = root / "vx_notebook" / "config.json";
  auto config = Json::parse(disk(config_path));
  config["metadata"]["custom"] = Json{{"password", "unrelated nested user metadata is not scanned"}};
  config["futureField"] = Json::array({1, true, "retained"});
  config["syncRemoteUrl"] = "https://contributor@gitee.com/team/notes.git";
  config["assetsFolder"] = "resources/assets";
  config["recycleBinFolder"] = "custom/recycle";
  config["ignored"] = Json::array({"*.private", ".hidden"});
  const auto raw = config.dump(3) + "\n";
  external_write(config_path, raw);
  for (const auto *name : {".hidden/empty", "resources/assets/item", "custom/recycle/old",
                           "nested/vx_sync", "vx_notebook/vx_sync/webdav/snapshots"})
    fs::create_directories(root / fs::u8path(name));
  const std::string opaque("\0\xff\xfe\r\n", 5);
  for (const auto *name : {".hidden/data.private", "resources/assets/item/blob", "custom/recycle/old/body",
                           "nested/vx_sync/user.data", ".DS_Store", "scratch.tmp", "scratch.vswp", ".gitignore"})
    external_write(root / fs::u8path(name), opaque);
  external_write(root / "vx_notebook" / "encryption.vne", opaque); // Opaque legacy bytes are not interpreted.
  const Json state = {{"version", 1}, {"notebookId", fixture.notebook_id},
      {"remoteUrl", "https://example.invalid/notes"}, {"usernameHash", std::string(64, '0')},
      {"entries", Json::object()}, {"conflicts", Json::object()}};
  external_write(root / "vx_notebook/vx_sync/webdav/state.json", state.dump());
  external_write(root / "vx_notebook/vx_sync/webdav/snapshots/runtime", "never portable");
  const auto before_open = snapshot(root);
  Host host(fixture, ExportOnly{});
  auto opened = host.next();
  CHECK(opened->code == VXCORE_OK);
  const std::string root_id = opened->node_id;
  opened.reset();
  CHECK(snapshot(root) == before_open);
  CHECK(host.mutate(2, VXM_RENAME_NOTEBOOK, root_id, "must not mutate") == VXCORE_ERR_INVALID_STATE);
  CHECK(host.tag(2, {{"op", "createTag"}, {"name", "must not mutate"}}) == VXCORE_ERR_INVALID_STATE);
  // Residue created after open is still inspected and safely excluded by capture.
  fs::create_directories(root / "vx_notebook/vx_import/empty/deeper");
  fs::create_directories(root / "vx_notebook/vx_transfer/empty/deeper");
  const auto before = snapshot(root);
  const auto destination = fixture.root / "snapshot";
  CHECK(capture(host, 2, destination) == VXCORE_OK);
  auto result = host.next();
  CHECK(result->code == VXCORE_OK && result->kind == VXM_EVENT_EXPORT && result->size <= 1024);
  CHECK(std::string(result->notebook_id) == fixture.notebook_id && std::string(result->notebook_name) == "Personal");
  auto expected = before;
  for (auto it = expected.begin(); it != expected.end();) {
    const auto path = it->first.generic_u8string();
    bool excluded = false;
    for (const auto *prefix : {"vx_notebook/vx_sync", "vx_notebook/vx_import", "vx_notebook/vx_transfer"}) {
      const std::string value(prefix);
      excluded |= path == value || path.compare(0, value.size() + 1, value + "/") == 0;
    }
    if (excluded) it = expected.erase(it); else ++it;
  }
  CHECK(snapshot(destination) == expected);
  CHECK(disk(destination / "vx_notebook/config.json") == raw);
  uint64_t bytes = 0, files = 0, directories = 0;
  for (const auto &entry : fs::recursive_directory_iterator(destination)) {
    if (entry.is_directory()) ++directories;
    else { ++files; bytes += entry.file_size(); }
  }
  const auto summary = Json::parse(text(result));
  CHECK(summary.at("bytes") == bytes && summary.at("files") == files && summary.at("directories") == directories);
  CHECK(summary.at("archiveLimit").get<uint64_t>() + bytes <= kSnapshotBudget);
  CHECK(capture(host, 3, destination) == VXCORE_OK);
  CHECK(host.next()->code == VXCORE_ERR_ALREADY_EXISTS);
  CHECK(snapshot(destination) == expected && snapshot(root) == before);
  host.close();
  CHECK(snapshot(root) == before);
}
void catalog_export_refuses_credentials_and_recovery() {
  Fixture fixture;
  fixture.seed("unchanged");
  const auto root = fs::u8path(fixture.notebook);
  const auto config_path = root / "vx_notebook/config.json";
  const auto original = Json::parse(disk(config_path));
  Host host(fixture, ExportOnly{});
  CHECK(host.next()->code == VXCORE_OK);
  uint64_t id = 2;
  const auto rejected = [&](const char *reason) {
    const auto before = snapshot(root);
    const auto destination = fixture.root / ("refused-" + std::to_string(id));
    CHECK(capture(host, id++, destination) == VXCORE_OK);
    auto result = host.next();
    CHECK(result->code != VXCORE_OK && result->size == 0 && result->data == nullptr);
    CHECK(std::string(result->message).find(reason) != std::string::npos);
    CHECK(std::string(result->message).find(fixture.root.u8string()) == std::string::npos);
    CHECK(!fs::exists(destination) && snapshot(root) == before);
  };
  for (const bool metadata : {false, true}) {
    for (const auto *key : {"credentials", "syncCredentials", "personalAccessToken", "pat", "password"}) {
      auto config = original;
      if (metadata) config["metadata"][key] = "never-log-this-secret";
      else config[key] = "never-log-this-secret";
      external_write(config_path, config.dump());
      rejected("credential");
    }
  }
  for (const auto *url : {"https://name:secret@example.invalid/repo", "https://name%3Asecret@example.invalid/repo",
                          "https://example.invalid/repo?token=secret", "https://example.invalid/repo#secret"}) {
    auto config = original;
    config["syncRemoteUrl"] = url;
    external_write(config_path, config.dump());
    rejected("synchronization URL");
  }
  external_write(config_path, original.dump());
  for (const auto *journal : {"vx_import", "vx_transfer"}) {
    const auto path = root / "vx_notebook" / journal / "transaction";
    fs::create_directories(path);
    external_write(path / "journal.json", "unresolved recovery bytes");
    rejected("recovery");
    fs::remove_all(path.parent_path());
  }
  fs::create_directories(root / ".git");
  rejected("Git");
  fs::remove_all(root / ".git");
  fs::create_directories(root / "vx_notebook/vx_sync/webdav");
  external_write(root / "vx_notebook/vx_sync/webdav/pending.json", "invalid recovery state");
  rejected("synchronization");
  fs::remove_all(root / "vx_notebook/vx_sync");
  fs::create_directories(root / "vx_notebook/vx_sync/webdav");
  // CheckNotebookSyncReconfiguration inspects every conflict, not only keys.
  const Json conflict = {{"version", 1}, {"notebookId", fixture.notebook_id},
      {"remoteUrl", "https://example.invalid/notes"}, {"usernameHash", std::string(64, '0')},
      {"entries", Json::object()}, {"conflicts", Json{{"Welcome.md", Json::object()}}}};
  external_write(root / "vx_notebook/vx_sync/webdav/state.json", conflict.dump());
  const auto conflicted = snapshot(root);
  CHECK(capture(host, id++, fixture.root / "conflicted") == VXCORE_OK);
  auto conflict_result = host.next();
  CHECK(conflict_result->code == VXCORE_ERR_SYNC_CONFLICT && conflict_result->size == 0);
  CHECK(snapshot(root) == conflicted);
  fs::remove_all(root / "vx_notebook/vx_sync");
#if defined(_WIN32)
  fs::create_directory(root / "vx_notebook/VX_SYNC");
  rejected("reserved runtime");
  fs::remove(root / "vx_notebook/VX_SYNC");
#endif
  host.close();
}
void catalog_export_open_does_not_recover_or_migrate() {
  for (const int kind : {0, 1, 2, 3, 4}) {
    Fixture fixture;
    fixture.seed("unchanged before export owner open");
    const auto root = fs::u8path(fixture.notebook);
    if (kind < 2) {
      const auto directory = root / "vx_notebook" / (kind == 0 ? "vx_import" : "vx_transfer") / "unresolved";
      fs::create_directories(directory);
      external_write(directory / "journal.json", "not-json");
    } else if (kind == 2) {
      auto config = Json::parse(disk(root / "vx_notebook/config.json"));
      config["tags"] = Json::array({Json{{"name", "legacy"}, {"parent", ""}}});
      config["tagsModifiedUtc"] = 0;
      external_write(root / "vx_notebook/config.json", config.dump());
    } else if (kind == 3) fs::create_directories(root / "vx_notebook/vx_transfer/empty");
    else fs::remove(root_metadata(fixture));
    const auto before = snapshot(root);
    {
      Host host(fixture, ExportOnly{});
      CHECK(host.next()->code != VXCORE_OK);
      host.close();
    }
    CHECK(snapshot(root) == before);
  }
  // Ordinary opens retain core's documented malformed-import cleanup behavior.
  Fixture ordinary;
  ordinary.seed("ordinary owner recovery");
  const auto directory = fs::u8path(ordinary.notebook) / "vx_notebook/vx_import/stale";
  fs::create_directories(directory);
  external_write(directory / "journal.json", "not-json");
  Host host(ordinary, VXM_MODE_CATALOG);
  CHECK(host.next()->code == VXCORE_OK);
  CHECK(!fs::exists(directory));
  host.close();
}
void catalog_export_guards_and_limits() {
  Fixture fixture;
  fixture.seed("original");
  const auto root = fs::u8path(fixture.notebook);
  Host host(fixture, ExportOnly{});
  CHECK(host.next()->code == VXCORE_OK);
  uint64_t id = 2;
  const auto reject = [&](const fs::path &destination, uint64_t budget = kSnapshotBudget) {
    CHECK(capture(host, id++, destination, budget) == VXCORE_OK);
    auto result = host.next();
    CHECK(result->code != VXCORE_OK && result->size == 0 && result->data == nullptr);
    CHECK(disk(fixture.note()) == "original");
  };
  CHECK(capture(host, id, fixture.root / "invalid", 0) == VXCORE_ERR_INVALID_PARAM);
  CHECK(capture(host, id, fixture.root / "invalid", kSnapshotBudget + 1) == VXCORE_ERR_INVALID_PARAM);
  reject(root / "inside");
  reject(fs::u8path(fixture.app) / "inside");
  reject(fs::u8path(fixture.local) / "inside");
  reject(fixture.root);
  reject(fixture.root / "tiny", 1024);
  CHECK(!fs::exists(root / "inside") && !fs::exists(fixture.root / "tiny"));
  const auto hardlink = root / "hard-link";
  fs::create_hard_link(fixture.note(), hardlink);
  reject(fixture.root / "hardlink");
  fs::remove(hardlink);
  const auto config_path = root / "vx_notebook/config.json";
  const auto raw_config = disk(config_path);
  for (const auto *key : {"assetsFolder", "recycleBinFolder"}) {
    auto config = Json::parse(raw_config);
    config[key] = "../outside";
    external_write(config_path, config.dump());
    reject(fixture.root / "external-resource");
  }
  external_write(config_path, raw_config);
#if defined(_WIN32)
  const auto locked = CreateFileW(fixture.note().c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, 0, nullptr);
  CHECK(locked != INVALID_HANDLE_VALUE);
  CHECK(capture(host, id++, fixture.root / "unreadable") == VXCORE_OK);
  auto unreadable = host.next();
  CHECK(CloseHandle(locked) != 0);
  CHECK(unreadable->code == VXCORE_ERR_IO && unreadable->size == 0);
  CHECK(disk(fixture.note()) == "original");
#endif
  auto deep = root;
  for (size_t i = 0; i < 33; ++i) deep /= "d";
  fs::create_directories(deep);
  reject(fixture.root / "depth");
  fs::remove_all(root / "d");
  const auto huge = root / "huge.bin";
  external_write(huge, "");
  fs::resize_file(huge, 1024ULL * 1024 * 1024);
  reject(fixture.root / "size");
  CHECK(fs::file_size(huge) == 1024ULL * 1024 * 1024);
  fs::remove(huge);
#if !defined(_WIN32)
  const auto outside = fixture.root / "outside";
  external_write(outside, "outside unchanged");
  fs::create_symlink(outside, root / "link");
  reject(fixture.root / "linked");
  fs::remove(root / "link");
  CHECK(disk(outside) == "outside unchanged");
  for (const auto &name : {std::string("back\\slash"), std::string("control\x01"), std::string("invalid\xff")}) {
    external_write(root / name, "unchanged");
    reject(fixture.root / "unsafe-name");
    fs::remove(root / name);
  }
  CHECK(::mkfifo((root / "pipe").c_str(), 0600) == 0);
  reject(fixture.root / "special");
  fs::remove(root / "pipe");
  auto long_path = root;
  for (size_t i = 0; i < 6; ++i) long_path /= std::string(200, 'a');
  fs::create_directories(long_path);
  reject(fixture.root / "long-path");
  fs::remove_all(root / std::string(200, 'a'));
#else
  std::string name;
  for (size_t i = 0; i < 90; ++i) name += u8"界";
  external_write(root / fs::u8path(name), "unchanged");
  reject(fixture.root / "long-component");
  fs::remove(root / fs::u8path(name));
#endif
  host.close();
}
void catalog_export_cancellation_and_accounting() {
  Fixture fixture;
  fixture.seed("unchanged");
  const auto root = fs::u8path(fixture.notebook);
  const auto before = snapshot(root);
  Host host(fixture, ExportOnly{}, true);
  host.signals.wait_entered();
  CHECK(host.next()->code == VXCORE_OK);
  CHECK(capture(host, 2, fixture.root / "pending") == VXCORE_OK);
  CHECK(vxm_host_cancel(host.handle, 2, host.generation) == VXCORE_OK);
  host.signals.release();
  auto result = host.next();
  CHECK(result->code == VXCORE_ERR_CANCELLED && result->size == 0 && result->data == nullptr);
  CHECK(!fs::exists(fixture.root / "pending"));
  result.reset();
  // Holding many snapshot terminals consumes only their actual 1 KiB summaries,
  // not a source-sized or 8 MiB catalog body reservation.
  std::vector<Event> held;
  for (uint64_t id = 3; id < 11; ++id) {
    CHECK(capture(host, id, fixture.root / ("held-" + std::to_string(id))) == VXCORE_OK);
    held.push_back(host.next());
    CHECK(held.back()->code == VXCORE_OK && held.back()->size <= 1024);
  }
  for (uint64_t id = 11; id < 19; ++id) {
    CHECK(capture(host, id, fixture.root / ("race-" + std::to_string(id))) == VXCORE_OK);
    std::this_thread::yield();
    const auto cancelled = vxm_host_cancel(host.handle, id, host.generation);
    result = host.next();
    CHECK(cancelled == VXCORE_OK ? result->code == VXCORE_ERR_CANCELLED :
          cancelled == VXCORE_ERR_INVALID_STATE && result->code == VXCORE_OK);
    if (cancelled == VXCORE_OK) CHECK(result->size == 0 && result->data == nullptr);
  }
  CHECK(capture(host, 19, fixture.root / "close-race") == VXCORE_OK);
  vxm_host_request_close(host.handle);
  result = host.next();
  CHECK(result->request_id == 19 && (result->code == VXCORE_OK || result->code == VXCORE_ERR_CANCELLED));
  host.close();
  CHECK(snapshot(root) == before);
}


void catalog_export_active_copy_and_source_change() {
  Fixture fixture;
  fixture.seed("unchanged");
  const auto root = fs::u8path(fixture.notebook);
  const auto blob = root / "large.bin";
  {
    std::ofstream output(blob, std::ios::binary);
    const std::string chunk(256 * 1024, 'x');
    for (size_t i = 0; i < 128; ++i) output.write(chunk.data(), chunk.size());
    output.close();
    CHECK(!output.fail());
  }
  Host host(fixture, ExportOnly{});
  CHECK(host.next()->code == VXCORE_OK);
  const auto wait_for_destination = [](const fs::path &destination) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (!fs::exists(destination)) {
      CHECK(std::chrono::steady_clock::now() < deadline);
      std::this_thread::yield();
    }
  };
  const auto cancelled_path = fixture.root / "active-cancel";
  CHECK(capture(host, 2, cancelled_path) == VXCORE_OK);
  wait_for_destination(cancelled_path); // Capture has passed inventory and entered copying.
  const auto cancelled = vxm_host_cancel(host.handle, 2, host.generation);
  auto result = host.next();
  CHECK(cancelled == VXCORE_OK ? result->code == VXCORE_ERR_CANCELLED :
        cancelled == VXCORE_ERR_INVALID_STATE && result->code == VXCORE_OK);
  CHECK(fs::file_size(blob) == 32 * 1024 * 1024);
  // An ordinary outside writer changes only its own file. Snapshot must not
  // silently report success with an inventory/copy size mismatch.
  const auto changed_path = fixture.root / "outside-change";
  CHECK(capture(host, 3, changed_path) == VXCORE_OK);
  wait_for_destination(changed_path);
  {
    std::ofstream output(blob, std::ios::binary | std::ios::app);
    output.put('y');
    output.close();
    CHECK(!output.fail());
  }
  result = host.next();
  if (result->code == VXCORE_OK) {
    // Completion can linearize before the external append on a fast filesystem.
    CHECK(fs::file_size(changed_path / "large.bin") == 32 * 1024 * 1024);
  } else {
    CHECK(result->code == VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    CHECK(result->size == 0 && result->data == nullptr);
  }
  const auto closing_path = fixture.root / "active-close";
  CHECK(capture(host, 4, closing_path) == VXCORE_OK);
  wait_for_destination(closing_path);
  vxm_host_request_close(host.handle);
  result = host.next();
  CHECK(result->request_id == 4 && (result->code == VXCORE_ERR_CANCELLED || result->code == VXCORE_OK));
  host.close();
  CHECK(disk(fixture.note()) == "unchanged");
  CHECK(fs::file_size(blob) == 32 * 1024 * 1024 + 1);
}
void catalog_export_entry_limit() {
  std::cout << "Checking export entry-limit preflight..." << std::endl;
  Fixture fixture;
  fixture.seed("unchanged");
  Host host(fixture, ExportOnly{});
  CHECK(host.next()->code == VXCORE_OK);
  const auto directory = fs::u8path(fixture.notebook) / "many";
  fs::create_directory(directory);
  for (size_t i = 0; i < 100000; ++i)
    fs::create_directory(directory / std::to_string(i));
  CHECK(capture(host, 2, fixture.root / "over-entry-limit") == VXCORE_OK);
  auto result = host.next(std::chrono::seconds(120));
  CHECK(result->code == VXCORE_ERR_UNSUPPORTED && result->size == 0);
  CHECK(std::string(result->message).find("100000-entry") != std::string::npos);
  CHECK(!fs::exists(fixture.root / "over-entry-limit"));
  CHECK(disk(fixture.note()) == "unchanged");
  host.close();
}


void catalog_export_refuses_persisted_foreign_restore() {
  Fixture fixture, foreign;
  fixture.seed("selected notebook");
  foreign.seed("foreign notebook");
  const auto foreign_root = fs::u8path(foreign.notebook);
  const auto journal = foreign_root / "vx_notebook/vx_import/unresolved/journal.json";
  fs::create_directories(journal.parent_path());
  external_write(journal, "not-json"); // Ordinary core restore would discard this tree.
  const auto session_path = fs::u8path(fixture.local) / "vxsession.json";
  const auto clean = disk(session_path);
  const auto foreign_before = snapshot(foreign_root);
  const auto selected_before = snapshot(fs::u8path(fixture.notebook));
  Json session = Json::parse(clean);
  session["notebooks"] = Json::array({Json{{"id", foreign.notebook_id}, {"rootFolder", foreign.notebook},
                                           {"type", "bundled"}, {"readOnly", false}}});
  const auto refused = [&] {
    const auto session_bytes = disk(session_path);
    {
      Host host(fixture, ExportOnly{});
      auto opened = host.next();
      CHECK(opened->code != VXCORE_OK);
      CHECK(std::string(opened->message).find("normal notebook open and recovery") != std::string::npos);
      host.close();
    }
    CHECK(disk(session_path) == session_bytes);
    CHECK(snapshot(foreign_root) == foreign_before);
    CHECK(snapshot(fs::u8path(fixture.notebook)) == selected_before);
  };
  external_write(session_path, session.dump());
  refused();
  for (const auto *key : {"buffers", "workspaces"}) {
    session = Json::parse(clean);
    session[key] = Json::array({Json::object()}); // Unsafe restore shape is refused before core parsing.
    external_write(session_path, session.dump());
    refused();
  }
  external_write(session_path, "not-json");
  refused();
  const auto linked_session = fixture.root / "linked-session.json";
  external_write(linked_session, clean);
  fs::remove(session_path);
  fs::create_hard_link(linked_session, session_path);
  refused();
  fs::remove(session_path);
  fs::remove(linked_session);
  external_write(session_path, clean);
  {
    Host host(fixture, ExportOnly{});
    CHECK(host.next()->code == VXCORE_OK);
    host.close();
  }
}

}  // namespace

int main() {
  try {
    round_trip_and_conflict();
    admission_cancellation_and_close();
    output_and_input_reservations();
    completed_mutation_is_not_cancelled();
    malformed_missing_and_encoding();
    line_ending_policy();
    catalog_explicit_creation_policy();
    catalog_creation_admission_and_display_names();
    catalog_rename_preserves_config_and_reopens();
    catalog_lifecycle_and_boundaries();
    catalog_actual_outcome_and_close();
    catalog_missing_parent_does_not_create_metadata();
    catalog_completed_output_accounting();
    catalog_reports_nonfatal_asset_move_failure();
    catalog_resolves_stale_cache_after_metadata_store_failure();
    catalog_query_admission_and_lifecycle();
    catalog_search_snippets_and_skips();
    catalog_search_result_limits_and_cancellation();
    catalog_tags_preserve_orphans_and_mutation_outcome();
    catalog_tags_are_complete_or_error();
    catalog_export_preserves_portable_tree();
    catalog_export_refuses_credentials_and_recovery();
    catalog_export_open_does_not_recover_or_migrate();
    catalog_export_guards_and_limits();
    catalog_export_cancellation_and_accounting();
    catalog_export_active_copy_and_source_change();
    catalog_export_entry_limit();
    catalog_export_refuses_persisted_foreign_restore();
    std::cout << "Native host real-storage tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
