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

#include <vxcore/vxcore.h>

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
    CHECK(!notifications);
    notifications = &signals;
    signals.hold = hold;
    VxmOpenOptions options{fixture.app.c_str(), fixture.local.c_str(), fixture.notebook.c_str(),
                           "Personal", "Welcome.md", reinterpret_cast<const uint8_t *>(initial.data()), initial.size()};
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
  // The taken OPEN still reserves 4 MiB until explicitly freed.
  for (uint64_t id = 2; id <= 4; ++id) CHECK(vxm_host_read(host.handle, id, host.generation) == VXCORE_OK);
  CHECK(vxm_host_read(host.handle, 5, host.generation) == VXCORE_ERR_OUT_OF_MEMORY);
  opened.reset();
  CHECK(vxm_host_read(host.handle, 5, host.generation) == VXCORE_OK);
  const std::string maximum(VXM_MAX_SOURCE_BYTES, 'x');
  for (uint64_t id = 6; id <= 13; ++id) CHECK(host.write(id, id, hash, maximum) == VXCORE_OK);
  CHECK(host.write(14, 14, hash, "x") == VXCORE_ERR_OUT_OF_MEMORY);
  vxm_host_request_close(host.handle);
  host.signals.release();
  for (size_t i = 0; i < 12; ++i) CHECK(host.next()->code == VXCORE_ERR_CANCELLED);
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
}  // namespace

int main() {
  try {
    round_trip_and_conflict();
    admission_cancellation_and_close();
    output_and_input_reservations();
    completed_mutation_is_not_cancelled();
    malformed_missing_and_encoding();
    line_ending_policy();
    std::cout << "Native host real-storage tests passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
