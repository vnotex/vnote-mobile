// SPDX-License-Identifier: LGPL-3.0-only
#include "vxcore_host.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#endif

#include <sqlite3.h>

#include <vxcore/vxcore.h>
#include <vxcore/mobile/vxcore_mobile.h>

namespace {
namespace fs = std::filesystem;
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

struct Host {
  Notifications signals;
  VxmHost *handle = nullptr;
  uint64_t generation = 0;
  Host(Fixture &fixture, const std::string &initial, bool hold = false) {
    fixture.seed(initial);
    VxmOpenOptions options{fixture.app.c_str(), fixture.local.c_str(), fixture.notebook.c_str(),
                           nullptr, fixture.notebook_id.empty() ? "missing" : fixture.notebook_id.c_str(),
                           fixture.node_id.empty() ? "missing" : fixture.node_id.c_str(), VXM_MODE_NOTE};
    start(options, hold);
  }
  Host(Fixture &fixture, int32_t mode, bool hold = false, const char *expected = nullptr) {
    VxmOpenOptions options{fixture.app.c_str(), fixture.local.c_str(), fixture.notebook.c_str(),
                           "Personal", expected, nullptr, mode};
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
  Event next() {
    std::unique_lock<std::mutex> lock(signals.mutex);
    for (;;) {
      if (auto *event = vxm_host_take_event(handle)) {
        CHECK(event->generation == generation);
        return Event(event, vxm_event_free);
      }
      const auto before = signals.count;
      CHECK(signals.changed.wait_for(lock, std::chrono::seconds(30), [&] { return signals.count != before; }));
    }
  }
  int32_t write(uint64_t id, uint64_t revision, const std::string &hash, const std::string &source) {
    return vxm_host_write(handle, id, generation, revision, hash.c_str(), reinterpret_cast<const uint8_t *>(source.data()), source.size());
  }
  int32_t mutate(uint64_t id, int32_t operation, const std::string &node,
                 const char *name = nullptr, const char *destination = nullptr) {
    return vxm_host_catalog_mutate(handle, id, generation, operation, node.c_str(), name, destination);
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
    Host host(fixture, VXM_MODE_CATALOG, true);
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
  Host host(fixture, VXM_MODE_CATALOG);
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
  Host host(fixture, VXM_MODE_CATALOG);
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
  Host host(fixture, VXM_MODE_CATALOG);
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

}  // namespace

int main() {
  try {
    round_trip_and_conflict();
    admission_cancellation_and_close();
    output_and_input_reservations();
    completed_mutation_is_not_cancelled();
    malformed_missing_and_encoding();
    line_ending_policy();
    catalog_lifecycle_and_boundaries();
    catalog_actual_outcome_and_close();
    catalog_missing_parent_does_not_create_metadata();
    catalog_completed_output_accounting();
    catalog_reports_nonfatal_asset_move_failure();
    catalog_resolves_stale_cache_after_metadata_store_failure();
    std::cout << "Native host real-storage tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
