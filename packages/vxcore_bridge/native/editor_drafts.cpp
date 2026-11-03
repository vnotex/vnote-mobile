// SPDX-License-Identifier: LGPL-3.0-only
#include "editor_drafts.h"
#include "notebook_import.h"
#include "vxcore_host.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <set>
#include <vector>
#include <sodium.h>
#include <utf8proc.h>

namespace vxm_drafts {
namespace {
namespace fs = std::filesystem;
namespace disk = vxm_import::storage;
constexpr uint64_t kSource = 4 * 1024 * 1024, kBatch = 8 * 1024 * 1024;
constexpr uint64_t kDocument = 32 * 1024 * 1024, kTotal = 256 * 1024 * 1024;
constexpr uint64_t kRevision = 9007199254740991ULL;
constexpr size_t kManifest = 65536, kFrame = 512 * 1024, kRecords = 10000;
std::mutex journal_mutex;
void check(bool value, int32_t code = VXCORE_ERR_JSON_PARSE) { disk::Check(value, code); }
void cancelled(const std::atomic<bool> *cancel) {
  check(!cancel || !cancel->load(std::memory_order_relaxed), VXCORE_ERR_CANCELLED);
}
bool hex(std::string_view value, size_t count) {
  return value.size() == count && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
const std::string &text(const Json &value, size_t limit = 1024, bool empty = false) {
  check(value.is_string());
  const auto &out = value.get_ref<const std::string &>();
  check((empty || !out.empty()) && out.size() <= limit && out.find('\0') == std::string::npos);
  return out;
}
uint64_t number(const Json &value, uint64_t maximum = kRevision) {
  check(value.is_number_integer() && (value.is_number_unsigned() || value.get<int64_t>() >= 0));
  const auto out = value.get<uint64_t>(); check(out <= maximum); return out;
}
void keys(const Json &value, std::initializer_list<const char *> names) {
  check(value.is_object() && value.size() == names.size());
  for (const auto *name : names) check(value.contains(name));
}
std::string random_id() {
  check(sodium_init() >= 0, VXCORE_ERR_NOT_INITIALIZED);
  std::array<unsigned char, 16> value{}; randombytes_buf(value.data(), value.size());
  std::array<char, 33> result{}; sodium_bin2hex(result.data(), result.size(), value.data(), value.size());
  return result.data();
}
uint64_t now() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
      std::chrono::system_clock::now().time_since_epoch()).count());
}
std::string document_key(const std::string &notebook, const std::string &node) {
  disk::Name(notebook); disk::Name(node);
  std::string combined; combined.reserve(notebook.size() + node.size() + 1);
  combined.append(notebook); combined.push_back('\0'); combined.append(node);
  return disk::Hash(combined);
}
Json seal(const Json &body) { return {{"version", 1}, {"body", body}, {"sha256", disk::Hash(body.dump())}}; }
Json unseal(const Json &value) {
  keys(value, {"version", "body", "sha256"});
  check(value.at("version") == 1 && value.at("body").is_object() &&
        value.at("sha256") == disk::Hash(value.at("body").dump()));
  return value.at("body");
}
void descriptor(const Json &value, const std::string &key) {
  keys(value, {"notebookRelative", "notebookId", "nodeId", "pathHint", "editorType", "openingDiskHash", "eol"});
  disk::Name(text(value.at("notebookRelative"), 255));
  disk::Name(text(value.at("notebookId"), 127)); disk::Name(text(value.at("nodeId"), 127));
  disk::Relative(text(value.at("pathHint"), 1024));
  check(document_key(text(value.at("notebookId")), text(value.at("nodeId"))) == key);
  check(value.at("editorType") == "markdown" || value.at("editorType") == "text");
  check(hex(text(value.at("openingDiskHash"), 64), 64)); number(value.at("eol"), 3);
}
// UTF-8 is retained byte-exact. Only UTF-16 boundaries are mapped; no newline,
// Unicode normalization, or lossy surrogate replacement is permitted.
uint64_t units(std::string_view source) {
  check(source.size() <= kSource, VXCORE_ERR_UNSUPPORTED);
  uint64_t out = 0;
  for (size_t offset = 0; offset < source.size();) {
    utf8proc_int32_t point = 0;
    const auto count = utf8proc_iterate(reinterpret_cast<const utf8proc_uint8_t *>(source.data() + offset),
                                        source.size() - offset, &point);
    check(count > 0 && point != 0 && !(point >= 0xd800 && point <= 0xdfff), VXCORE_ERR_UNSUPPORTED);
    offset += static_cast<size_t>(count); out += point > 0xffff ? 2 : 1;
  }
  check(out <= kSource, VXCORE_ERR_UNSUPPORTED); return out;
}
size_t boundary(std::string_view source, uint64_t wanted, size_t &byte, uint64_t &unit) {
  while (unit < wanted && byte < source.size()) {
    const auto lead = static_cast<unsigned char>(source[byte]);
    const size_t count = lead < 0x80 ? 1 : lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4;
    byte += count; unit += count == 4 ? 2 : 1;
  }
  check(unit == wanted, VXCORE_ERR_UNSUPPORTED); return byte;
}
void apply(std::string &source, const Json &frame, const std::string &token, uint64_t revision) {
  keys(frame, {"token", "baseRevision", "revision", "requestId", "changes", "selection"});
  check(frame.at("token") == token && number(frame.at("baseRevision")) == revision &&
        revision < kRevision && number(frame.at("revision")) == revision + 1);
  text(frame.at("requestId"), 128);
  const auto &changes = frame.at("changes");
  check(changes.is_array() && !changes.empty() && changes.size() <= 256);
  const auto source_units = units(source);
  struct Change { size_t from, to; const std::string *insert; };
  std::vector<Change> mapped; mapped.reserve(changes.size());
  size_t byte = 0; uint64_t unit = 0, previous = 0, inserted = 0, size = source.size();
  for (const auto &change : changes) {
    keys(change, {"from", "to", "insert"});
    const auto from = number(change.at("from"), source_units), to = number(change.at("to"), source_units);
    check(from >= previous && from <= to);
    const auto &insert = text(change.at("insert"), kSource, true);
    inserted += units(insert); check(inserted <= 65536, VXCORE_ERR_UNSUPPORTED);
    const auto start = boundary(source, from, byte, unit), end = boundary(source, to, byte, unit);
    size = size - (end - start) + insert.size();
    mapped.push_back({start, end, &insert}); previous = to;
  }
  check(size <= kSource, VXCORE_ERR_UNSUPPORTED);
  std::string result; result.reserve(static_cast<size_t>(size)); byte = 0;
  for (const auto &change : mapped) {
    result.append(source, byte, change.from - byte); result.append(*change.insert); byte = change.to;
  }
  result.append(source, byte, source.size() - byte);
  keys(frame.at("selection"), {"anchor", "head"});
  const auto result_units = units(result);
  for (const auto *part : {"anchor", "head"}) {
    size_t at = 0; uint64_t seen = 0;
    boundary(result, number(frame.at("selection").at(part), result_units), at, seen);
  }
  source.swap(result);
}
struct RecordPath { fs::path path; std::string key, token; uint64_t bytes; };
fs::path root_path(const std::string &value) {
  auto root = disk::Absolute(value);
  check(root.filename() == "drafts" && disk::Info(root).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
  return root;
}
std::vector<RecordPath> records(const fs::path &root, const std::atomic<bool> *cancel = nullptr) {
  std::vector<RecordPath> out; size_t documents = 0;
  for (const auto &document : fs::directory_iterator(root)) {
    cancelled(cancel); check(++documents <= kRecords, VXCORE_ERR_UNSUPPORTED);
    const auto key = document.path().filename().u8string();
    check(hex(key, 64) && disk::Info(document.path()).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
    for (const auto &capture : fs::directory_iterator(document.path())) {
      cancelled(cancel); check(out.size() < kRecords, VXCORE_ERR_UNSUPPORTED);
      const auto token = capture.path().filename().u8string();
      if (token.size() == 42 && token.rfind("discarded-", 0) == 0 && hex(token.substr(10), 32)) {
        check(disk::Info(capture.path()).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
        disk::RemovePrivate(capture.path()); continue;
      }
      check(hex(token, 32) && disk::Info(capture.path()).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
      uint64_t bytes = 0; size_t count = 0;
      for (const auto &file : fs::directory_iterator(capture.path())) {
        check(++count <= 2048, VXCORE_ERR_UNSUPPORTED);
        const auto info = disk::Info(file.path());
        check(info.at("directory") == false, VXCORE_ERR_UNSUPPORTED);
        bytes += number(info.at("bytes"), kDocument); check(bytes <= kDocument, VXCORE_ERR_UNSUPPORTED);
      }
      out.push_back({capture.path(), key, token, bytes});
    }
  }
  std::sort(out.begin(), out.end(), [](const RecordPath &a, const RecordPath &b) {
    return a.key < b.key || (a.key == b.key && a.token < b.token);
  });
  return out;
}
void reserve(const fs::path &root, const std::string &key, uint64_t required, bool unresolved = false) {
  uint64_t total = 0, document = 0; std::set<std::string> dirty;
  for (const auto &entry : records(root)) {
    total += entry.bytes; if (entry.key == key) document += entry.bytes;
    try {
      const auto body = unseal(disk::ReadJson(entry.path / "manifest.json", kManifest));
      if (!body.at("supersededBy").is_null()) continue;
      if (body.at("saved").is_null() || !body.at("intent").is_null()) dirty.insert(entry.key);
      else {
        const auto saved = unseal(disk::ReadJson(entry.path / text(body.at("saved"), 80), kManifest));
        if (saved.at("sourceHash") != body.at("sourceHash")) dirty.insert(entry.key);
      }
    } catch (...) { dirty.insert(entry.key); }
  }
  if (unresolved) dirty.insert(key);
  check(dirty.size() <= 32 && required <= kDocument && document <= kDocument - required &&
        total <= kTotal - required, VXCORE_ERR_UNSUPPORTED);
  const auto available = fs::space(root).available;
  check(available >= required + 1024 * 1024, VXCORE_ERR_IO);
}
void reference(const Json &ref) {
  keys(ref, {"file", "sha256"});
  const auto &name = text(ref.at("file"), 80); disk::Name(name);
  check(name.size() == 44 && name.substr(0, 7) == "source-" && hex(name.substr(7, 32), 32) && name.substr(39) == ".utf8");
  check(hex(text(ref.at("sha256"), 64), 64));
}
struct Journal;
Json export_record(const Journal &journal, const std::string &id);
struct Journal {
  fs::path root, path;
  std::string key, token;
  Json envelope, body, log_identity;
  std::string source, opening;
  Journal(const std::string &root_value, const std::string &document, const std::string &capture)
      : root(root_path(root_value)), key(document), token(capture) {
    check(hex(key, 64) && hex(token, 32)); path = root / key / token;
  }
  Json read_record(const std::string &name) const {
    disk::Name(name); return unseal(disk::ReadJson(path / name, kManifest));
  }
  std::string read_source(const Json &ref) const {
    reference(ref); auto bytes = disk::Read(path / text(ref.at("file")), kSource);
    check(disk::Hash(bytes) == ref.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE); units(bytes); return bytes;
  }
  void verify_source(const Json &ref) const {
    reference(ref);
    const auto info = disk::Info(path / text(ref.at("file")), true, nullptr, kSource);
    check(info.at("sha256") == ref.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  }
  Json save_record(const std::string &name, const Json &value) const {
    auto wrapped = seal(value); disk::Marker(path, name, wrapped, kManifest); return wrapped;
  }
  Json save_source(std::string_view bytes) const {
    const auto name = "source-" + random_id() + ".utf8"; disk::Bytes(path / name, bytes);
    return {{"file", name}, {"sha256", disk::Hash(bytes)}};
  }
  void publish(Json next) {
    auto wrapped = seal(next);
    // A previous failed publication can leave .next. It has no authority until
    // rename; the still-validated committed manifest permits safe replacement.
    if (disk::Exists(path / "manifest.json.next")) disk::RemovePrivate(path / "manifest.json.next");
    disk::ReplaceMarker(path, "manifest.json", envelope, wrapped, kManifest);
    envelope = std::move(wrapped); body = std::move(next);
  }
  Json intent(const std::string &name) const {
    check(name.size() == 44 && name.substr(0, 7) == "intent-" && hex(name.substr(7, 32), 32) && name.substr(39) == ".json");
    auto value = read_record(name);
    keys(value, {"documentKey", "token", "candidateId", "revision", "requestId", "source", "sourceHash",
                 "expectedDiskHash", "intendedDiskHash", "eol", "descriptor"});
    check(value.at("documentKey") == key && value.at("token") == token &&
          value.at("candidateId") == name.substr(7, 32) && value.at("descriptor") == body.at("descriptor"));
    number(value.at("revision"), number(body.at("revision"))); text(value.at("requestId"), 128);
    check(value.at("eol") == body.at("descriptor").at("eol"));
    for (const auto *part : {"sourceHash", "expectedDiskHash", "intendedDiskHash"}) check(hex(text(value.at(part), 64), 64));
    reference(value.at("source")); check(value.at("sourceHash") == value.at("source").at("sha256"));
    verify_source(value.at("source")); return value;
  }
  Json receipt() const {
    if (body.at("saved").is_null()) return nullptr;
    const auto &name = text(body.at("saved"), 80);
    check(name.size() == 45 && name.substr(0, 8) == "receipt-" && hex(name.substr(8, 32), 32) && name.substr(40) == ".json");
    auto value = read_record(name);
    keys(value, {"documentKey", "token", "revision", "source", "sourceHash", "diskHash", "eol", "savedAt", "candidateId", "requestId"});
    check(value.at("documentKey") == key && value.at("token") == token && value.at("eol") == body.at("descriptor").at("eol"));
    number(value.at("revision"), number(body.at("revision"))); number(value.at("savedAt"), UINT64_MAX);
    check(value.at("candidateId").is_null() == value.at("requestId").is_null());
    if (!value.at("candidateId").is_null()) { check(hex(text(value.at("candidateId"), 32), 32)); text(value.at("requestId"), 128); }
    check(hex(text(value.at("diskHash"), 64), 64) && value.at("sourceHash") == value.at("source").at("sha256"));
    verify_source(value.at("source")); return value;
  }
  void load(bool trim = true) {
    check(disk::Info(path).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
    envelope = disk::ReadJson(path / "manifest.json", kManifest); body = unseal(envelope);
    keys(body, {"documentKey", "token", "descriptor", "opening", "base", "baseRevision", "log", "offset", "frames",
               "revision", "sourceHash", "intent", "saved", "created", "supersededBy", "reconciledDiskHash"});
    check(body.at("documentKey") == key && body.at("token") == token); descriptor(body.at("descriptor"), key);
    number(body.at("created"), UINT64_MAX);
    if (!body.at("supersededBy").is_null()) check(hex(text(body.at("supersededBy"), 32), 32) && body.at("supersededBy") != token);
    if (!body.at("reconciledDiskHash").is_null()) check(hex(text(body.at("reconciledDiskHash"), 64), 64));
    opening = read_source(body.at("opening")); source = read_source(body.at("base"));
    uint64_t revision = number(body.at("baseRevision"));
    const auto target = number(body.at("revision")); check(revision <= target);
    const auto &log_name = text(body.at("log"), 80);
    check(log_name.size() == 40 && log_name.substr(0, 4) == "log-" && hex(log_name.substr(4, 32), 32) && log_name.substr(36) == ".bin");
    const auto offset = number(body.at("offset"), kBatch + kFrame + 256 * 68);
    log_identity = disk::Info(path / log_name);
    const auto log = disk::Read(path / log_name, kDocument);
    check(log.size() >= offset && disk::Info(path / log_name) == log_identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    size_t at = 0; uint64_t frames = 0;
    while (at < offset) {
      check(offset - at >= 68, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      uint32_t length = 0;
      for (unsigned i = 0; i < 4; ++i) length |= uint32_t(static_cast<unsigned char>(log[at + i])) << (8 * i);
      check(length > 0 && length <= kFrame && length <= offset - at - 68, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      const std::string_view frame(log.data() + at + 68, length);
      check(disk::Hash(frame) == log.substr(at + 4, 64), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      apply(source, disk::Parse(frame, kFrame), token, revision++);
      at += 68 + length; check(++frames <= 287, VXCORE_ERR_UNSUPPORTED);
    }
    check(at == offset && revision == target && number(body.at("frames"), 287) == frames &&
          body.at("sourceHash") == disk::Hash(source), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    receipt(); if (!body.at("intent").is_null()) intent(text(body.at("intent"), 80));
    size_t entries = 0;
    for (const auto &entry : fs::directory_iterator(path)) {
      check(++entries <= 2048, VXCORE_ERR_UNSUPPORTED);
      const auto name = entry.path().filename().u8string();
      if (name.rfind("export-", 0) == 0 && name.size() == 44 && name.substr(39) == ".json")
        export_record(*this, name.substr(7, 32));
    }
    if (trim && log.size() != offset) {
      disk::Truncate(path / log_name, offset, &log_identity); log_identity = disk::Info(path / log_name);
    }
    // A prior caller may have lost the directory barrier after atomic rename.
    // Re-establish it before reporting a recovered prefix as durable.
    disk::FlushDirectory(path);
  }
  Json summary() const {
    const auto saved = receipt();
    const bool clean = !saved.is_null() && saved.at("sourceHash") == body.at("sourceHash") && body.at("intent").is_null();
    return {{"documentKey", key}, {"token", token}, {"descriptor", body.at("descriptor")},
            {"revision", body.at("revision")}, {"sourceHash", body.at("sourceHash")},
            {"baseSourceHash", body.at("opening").at("sha256")},
            {"savedRevision", saved.is_null() ? Json(nullptr) : saved.at("revision")},
            {"savedSourceHash", saved.is_null() ? Json(nullptr) : saved.at("sourceHash")},
            {"savedDiskHash", saved.is_null() ? Json(nullptr) : saved.at("diskHash")},
            {"candidateId", body.at("intent").is_null() ? Json(nullptr) : intent(text(body.at("intent"))).at("candidateId")},
            {"supersededBy", body.at("supersededBy")},
            {"savedCandidateId", saved.is_null() ? Json(nullptr) : saved.at("candidateId")},
            {"savedRequestId", saved.is_null() ? Json(nullptr) : saved.at("requestId")},
            {"status", !body.at("supersededBy").is_null() ? "superseded" : body.at("intent").is_null() ? (clean ? "saved" : "draft") : "pending"}};
  }
  void compact() {
    if (body.at("frames") == 0) return;
    reserve(root, key, source.size() + 2 * kManifest);
    auto next = body; next["base"] = save_source(source); next["baseRevision"] = body.at("revision");
    const auto log = "log-" + random_id() + ".bin"; disk::Bytes(path / log, {});
    next["log"] = log; next["offset"] = 0; next["frames"] = 0; publish(std::move(next));
    log_identity = disk::Info(path / log);
    collect();
  }
  void collect() const {
    // Validate every durable reference BEFORE deleting even an orphan. Unknown
    // files and damaged references are preserved for explicit raw export.
    std::set<std::string> live{"manifest.json", text(body.at("opening").at("file")),
                               text(body.at("base").at("file")), text(body.at("log"))};
    if (!body.at("intent").is_null()) {
      const auto name = text(body.at("intent")); const auto value = intent(name);
      live.insert(name); live.insert(text(value.at("source").at("file")));
    }
    if (!body.at("saved").is_null()) {
      const auto value = receipt(); live.insert(text(body.at("saved"))); live.insert(text(value.at("source").at("file")));
    }
    for (const auto &entry : fs::directory_iterator(path)) {
      const auto name = entry.path().filename().u8string();
      if (name.rfind("export-", 0) == 0 && name.size() == 44 && name.substr(39) == ".json") {
        const auto value = export_record(*this, name.substr(7, 32));
        live.insert(name); live.insert(text(value.at("source").at("file")));
      }
    }
    for (const auto &entry : fs::directory_iterator(path)) {
      const auto name = entry.path().filename().u8string();
      if (live.count(name)) continue;
      const bool source_file = name.size() == 44 && name.rfind("source-", 0) == 0 && hex(name.substr(7, 32), 32) && name.substr(39) == ".utf8";
      const bool log_file = name.size() == 40 && name.rfind("log-", 0) == 0 && hex(name.substr(4, 32), 32) && name.substr(36) == ".bin";
      const bool intent_file = name.size() == 44 && name.rfind("intent-", 0) == 0 && hex(name.substr(7, 32), 32) && name.substr(39) == ".json";
      const bool receipt_file = name.size() == 45 && name.rfind("receipt-", 0) == 0 && hex(name.substr(8, 32), 32) && name.substr(40) == ".json";
      if (source_file || log_file || intent_file || receipt_file) disk::RemovePrivate(entry.path());
    }
  }
};
Json begin(Journal &journal, const Json &desc, std::string_view source, std::string_view opening) {
  descriptor(desc, journal.key); units(source); units(opening);
  if (disk::Exists(journal.path / "manifest.json")) {
    journal.load(); check(journal.body.at("descriptor") == desc && journal.body.at("revision") == 0 && journal.source == source,
                          VXCORE_ERR_INVALID_STATE); return journal.summary();
  }
  reserve(journal.root, journal.key, source.size() + (source == opening ? 0 : opening.size()) + 3 * kManifest, true);
  if (!disk::Exists(journal.root / journal.key)) disk::MakeDirectory(journal.root / journal.key);
  if (!disk::Exists(journal.path)) disk::MakeDirectory(journal.path);
  journal.save_record("descriptor.json", {{"documentKey", journal.key}, {"token", journal.token}, {"descriptor", desc}});
  const auto base = journal.save_source(source);
  const auto original = source == opening ? base : journal.save_source(opening);
  const auto log = "log-" + random_id() + ".bin"; disk::Bytes(journal.path / log, {});
  journal.body = {{"documentKey", journal.key}, {"token", journal.token}, {"descriptor", desc}, {"opening", original},
                  {"base", base}, {"baseRevision", 0}, {"log", log}, {"offset", 0}, {"frames", 0}, {"revision", 0},
                  {"sourceHash", base.at("sha256")}, {"intent", nullptr}, {"saved", nullptr}, {"created", now()},
                  {"supersededBy", nullptr}, {"reconciledDiskHash", nullptr}};
  journal.envelope = journal.save_record("manifest.json", journal.body);
  journal.source.assign(source); journal.opening.assign(opening); return journal.summary();
}
Json candidate_summary(const Json &candidate) {
  Json out;
  for (const auto *key : {"documentKey", "token", "candidateId", "revision", "sourceHash", "expectedDiskHash", "intendedDiskHash", "eol"})
    out[key] = candidate.at(key);
  return out;
}
Json prepare(Journal &journal, uint64_t revision, const std::string &request_id) {
  check(journal.body.at("supersededBy").is_null(), VXCORE_ERR_INVALID_STATE);
  if (!journal.body.at("intent").is_null()) {
    const auto previous = journal.intent(text(journal.body.at("intent")));
    check(previous.at("revision") == revision && previous.at("requestId") == request_id, VXCORE_ERR_INVALID_STATE);
    return candidate_summary(previous);
  }
  check(revision == number(journal.body.at("revision")), VXCORE_ERR_INVALID_STATE);
  journal.compact(); reserve(journal.root, journal.key, 3 * kManifest);
  const auto saved = journal.receipt(); const auto &desc = journal.body.at("descriptor");
  const std::string expected = saved.is_null() ? text(desc.at("openingDiskHash")) : text(saved.at("diskHash"));
  std::string converted; std::string intended;
  if (journal.body.at("sourceHash") == expected) intended = expected;
  else if (!saved.is_null() && saved.at("sourceHash") == journal.body.at("sourceHash")) intended = text(saved.at("diskHash"));
  else {
    // Compare against the actual expected disk representation, not the saved
    // original CRLF/LF checkpoint that later UTF-16 edits must continue to use.
    std::string previous_disk, previous_conversion;
    std::string_view previous = journal.opening;
    if (!saved.is_null()) {
      previous_disk = journal.read_source(saved.at("source"));
      previous = saved.at("sourceHash") == saved.at("diskHash") ? std::string_view(previous_disk) :
          ProjectDisk(previous_disk, {}, static_cast<int32_t>(number(desc.at("eol"), 3)), previous_conversion);
      check(disk::Hash(previous) == saved.at("diskHash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    intended = disk::Hash(ProjectDisk(journal.source, previous, static_cast<int32_t>(number(desc.at("eol"), 3)), converted));
  }
  const auto id = random_id();
  Json value{{"documentKey", journal.key}, {"token", journal.token}, {"candidateId", id}, {"revision", revision},
             {"requestId", request_id}, {"source", journal.body.at("base")}, {"sourceHash", journal.body.at("sourceHash")},
             {"expectedDiskHash", expected}, {"intendedDiskHash", intended}, {"eol", desc.at("eol")}, {"descriptor", desc}};
  const auto name = "intent-" + id + ".json"; journal.save_record(name, value);
  auto next = journal.body; next["intent"] = name; journal.publish(std::move(next));
  return candidate_summary(value);
}
bool policy(const Journal &journal, const OwnerFacts &facts) {
  const auto &desc = journal.body.at("descriptor");
  return facts.exists && facts.ordinary && facts.notebook_id == desc.at("notebookId") && facts.node_id == desc.at("nodeId") &&
      facts.notebook_relative == desc.at("notebookRelative") && facts.editor_type == desc.at("editorType") &&
      facts.eol == desc.at("eol") && hex(facts.disk_hash, 64);
}
void saved(Journal &journal, const Json &source, uint64_t revision, const std::string &hash, const Json &candidate = nullptr) {
  reserve(journal.root, journal.key, 3 * kManifest);
  const auto name = "receipt-" + random_id() + ".json";
  journal.save_record(name, {{"documentKey", journal.key}, {"token", journal.token}, {"revision", revision},
      {"source", source}, {"sourceHash", source.at("sha256")}, {"diskHash", hash},
      {"eol", journal.body.at("descriptor").at("eol")}, {"savedAt", now()},
      {"candidateId", candidate.is_null() ? Json(nullptr) : candidate.at("candidateId")},
      {"requestId", candidate.is_null() ? Json(nullptr) : candidate.at("requestId")}});
  auto next = journal.body; next["saved"] = name; next["intent"] = nullptr; next["reconciledDiskHash"] = hash;
  journal.publish(std::move(next));
  journal.collect();
}
Json reconcile(Journal &journal, const OwnerFacts &facts, const std::string *commit_candidate = nullptr) {
  std::string outcome = "conflict"; bool retry = false;
  if (policy(journal, facts)) {
    const auto receipt = journal.receipt();
    const auto pending = journal.body.at("intent").is_null() ? Json(nullptr) : journal.intent(text(journal.body.at("intent")));
    if (commit_candidate) check(!pending.is_null() && pending.at("candidateId") == *commit_candidate, VXCORE_ERR_INVALID_STATE);
    if (!pending.is_null() && pending.at("intendedDiskHash") == facts.disk_hash) {
      saved(journal, pending.at("source"), number(pending.at("revision")), facts.disk_hash, pending); outcome = "saved";
    } else if (commit_candidate) check(false, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    else if (!receipt.is_null() && receipt.at("diskHash") == facts.disk_hash) {
      outcome = "saved"; retry = !pending.is_null() && pending.at("expectedDiskHash") == facts.disk_hash;
    }
    else if (receipt.is_null() && journal.body.at("descriptor").at("openingDiskHash") == facts.disk_hash) {
      outcome = "base"; retry = !pending.is_null() && pending.at("expectedDiskHash") == facts.disk_hash;
      // A new epoch is saved0 only upon exact actual disk equality. An arbitrary
      // chosen/recovered source never inherits an old epoch's revision integer.
      std::string projected;
      if (journal.body.at("revision") == 0 && pending.is_null() &&
          disk::Hash(ProjectDisk(journal.source, journal.opening, facts.eol, projected)) == facts.disk_hash) {
        saved(journal, journal.body.at("base"), 0, facts.disk_hash); outcome = "saved";
      }
    } else if (receipt.is_null() && !pending.is_null() && pending.at("expectedDiskHash") == facts.disk_hash) { outcome = "base"; retry = true; }
  } else if (commit_candidate) check(false, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const Json observed = policy(journal, facts) ? Json(facts.disk_hash) : Json(nullptr);
  if (journal.body.at("reconciledDiskHash") != observed) {
    reserve(journal.root, journal.key, 2 * kManifest);
    auto next = journal.body; next["reconciledDiskHash"] = observed; journal.publish(std::move(next));
  }
  auto out = journal.summary(); out["outcome"] = outcome; out["canRetry"] = retry; out["observedDiskHash"] = facts.disk_hash;
  out["completedCandidateId"] = out.at("savedCandidateId"); out["completedRequestId"] = out.at("savedRequestId");
  return out;
}
Json export_record(const Journal &journal, const std::string &id) {
  check(hex(id, 32)); auto record = journal.read_record("export-" + id + ".json");
  keys(record, {"binding", "source"}); const auto &binding = record.at("binding");
  keys(binding, {"documentKey", "token", "revision", "candidateId", "sha256", "format"});
  check(binding.at("documentKey") == journal.key && binding.at("token") == journal.token && binding.at("candidateId") == id);
  number(binding.at("revision")); check(binding.at("format") == "text" || binding.at("format") == "raw-archive");
  reference(record.at("source")); check(binding.at("sha256") == record.at("source").at("sha256"));
  const auto info = disk::Info(journal.path / text(record.at("source").at("file")), true, nullptr, kDocument);
  check(info.at("sha256") == binding.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE); return record;
}
void release_export(Journal &journal, const std::string &id, bool remove) {
  check(hex(id, 32));
  if (!disk::Exists(journal.path / ("export-" + id + ".json"))) return;
  const auto record = export_record(journal, id);
  const auto resources = journal.root.parent_path() / "resources";
  if (disk::Exists(resources)) {
    size_t count = 0;
    for (const auto &entry : fs::directory_iterator(resources)) {
      check(++count <= kRecords, VXCORE_ERR_UNSUPPORTED);
      const auto desired_path = entry.path() / "resource.json";
      if (!disk::Exists(desired_path)) continue;
      const auto desired = disk::ReadJson(desired_path, 16384);
      if (desired.value("origin", std::string()) != "draft" || desired.value("binding", Json()) != record.at("binding")) continue;
      const auto result = disk::Command(entry.path().u8string(), "resource", "verifyExport"); Json ready;
      const auto code = vxm_import::TransferRun(result, nullptr, ready); check(code == VXCORE_OK, code);
    }
  }
  if (remove) {
    disk::RemovePrivate(journal.path / ("export-" + id + ".json"));
    disk::FlushDirectory(journal.path);
    // A source can coincide with a checkpoint; leave reclamation to reference GC.
  }
}
void no_exports(Journal &journal) {
  for (const auto &entry : fs::directory_iterator(journal.path)) {
    const auto name = entry.path().filename().u8string();
    check(!(name.rfind("export-", 0) == 0 && name.size() == 44 && name.substr(39) == ".json"), VXCORE_ERR_INVALID_STATE);
  }
}
void retire(Journal &journal) {
  const auto retired = journal.path.parent_path() / ("discarded-" + journal.token);
  disk::Move(journal.path, retired); disk::RemovePrivate(retired);
  disk::FlushDirectory(journal.path.parent_path());
  if (fs::is_empty(journal.path.parent_path())) {
    disk::RemovePrivate(journal.path.parent_path()); disk::FlushDirectory(journal.root);
  }
}
Json run(const Json &request, std::string_view payload, const std::atomic<bool> *cancel) {
  const auto op = text(request.at("op"), 32); cancelled(cancel);
  if (op == "key") {
    keys(request, {"op", "notebookId", "nodeId"}); check(payload.empty());
    return {{"documentKey", document_key(text(request.at("notebookId"), 127), text(request.at("nodeId"), 127))}};
  }
  if (op == "scan" || op == "prune") {
    if (op == "scan") keys(request, {"op", "draftsRoot", "offset"}); else keys(request, {"op", "draftsRoot"});
    check(payload.empty()); const auto root = root_path(text(request.at("draftsRoot"), 4096));
    const auto entries = records(root, cancel); Json result = Json::array(); size_t bytes = 32, removed = 0;
    struct Retirement { std::string key, token; bool head; };
    std::vector<Retirement> retirements; std::set<std::string> keep_heads;
    const auto offset = op == "scan" ? number(request.at("offset"), kRecords) : 0;
    size_t index = static_cast<size_t>(offset);
    for (; index < entries.size(); ++index) {
      cancelled(cancel); const auto &entry = entries[index]; Json summary;
      try {
        Journal journal(root.u8string(), entry.key, entry.token); journal.load(); summary = journal.summary();
        if (op == "prune") {
          const auto receipt = journal.receipt();
          bool eligible = summary.at("status") == "saved" && !receipt.is_null() &&
              now() > number(receipt.at("savedAt"), UINT64_MAX) + 7 * 24 * 60 * 60;
          if (summary.at("status") == "superseded") {
            std::set<std::string> seen{entry.token}; auto successor = text(journal.body.at("supersededBy"), 32);
            for (;;) {
              check(seen.insert(successor).second && seen.size() <= kRecords);
              Journal replacement(root.u8string(), entry.key, successor); replacement.load();
              if (!replacement.body.at("supersededBy").is_null()) { successor = text(replacement.body.at("supersededBy"), 32); continue; }
              // A newer exact owner disk comparison permits superseded base
              // reclamation; unresolved replacements retain every older prefix.
              eligible = !replacement.receipt().is_null(); break;
            }
          }
          if (eligible) {
            no_exports(journal); retirements.push_back({entry.key, entry.token, summary.at("status") == "saved"});
          }
          else if (summary.at("status") != "saved") keep_heads.insert(entry.key);
        }
      } catch (...) {
        if (op == "prune") { keep_heads.insert(entry.key); continue; }
        summary = {{"documentKey", entry.key}, {"token", entry.token}, {"status", "quarantined"}, {"errorCode", disk::ErrorCode()}};
        try {
          const auto owned = unseal(disk::ReadJson(entry.path / "descriptor.json", kManifest));
          keys(owned, {"documentKey", "token", "descriptor"});
          check(owned.at("documentKey") == entry.key && owned.at("token") == entry.token);
          descriptor(owned.at("descriptor"), entry.key); summary["descriptor"] = owned.at("descriptor");
        } catch (...) { /* Raw owned bytes remain exportable without invented source. */ }
      }
      if (op == "scan") {
        const auto size = summary.dump().size() + 1; if (bytes + size > kManifest - 64) break;
        bytes += size; result.push_back(std::move(summary));
      }
    }
    if (op == "prune") {
      std::stable_sort(retirements.begin(), retirements.end(), [](const Retirement &a, const Retirement &b) { return a.head < b.head; });
      for (const auto &entry : retirements) {
        if (entry.head && keep_heads.count(entry.key)) continue;
        Journal journal(root.u8string(), entry.key, entry.token); retire(journal); ++removed;
      }
      return {{"removed", removed}};
    }
    return {{"entries", std::move(result)}, {"nextOffset", index < entries.size() ? Json(index) : Json(nullptr)}};
  }
  std::set<std::string> expected{"op", "draftsRoot", "documentKey", "token"};
  if (op == "begin") expected.insert("descriptor");
  else if (op == "append") expected.insert("expectedRevision");
  else if (op == "checkpoint") expected.insert("revision");
  else if (op == "prepareSave") expected.insert({"revision", "requestId"});
  else if (op == "prepareExport") expected.insert({"revision", "format"});
  else if (op == "export") expected.insert({"resourceRoot", "binding"});
  else if (op == "releaseExport") expected.insert("candidateId");
  else if (op == "rebase" || op == "rebaseSource") expected.insert("newToken");
  else check(op == "inspect" || op == "read" || op == "readBase" || op == "discard");
  check(request.is_object() && request.size() == expected.size());
  for (const auto &name : expected) check(request.contains(name));
  if (op != "begin" && op != "append" && op != "rebaseSource") check(payload.empty());
  Journal journal(text(request.at("draftsRoot"), 4096), text(request.at("documentKey"), 64), text(request.at("token"), 32));
  if (op == "begin") {
    check(payload.size() <= kSource && disk::Hash(payload) == request.at("descriptor").at("openingDiskHash"));
    return begin(journal, request.at("descriptor"), payload, payload);
  }
  if (op == "discard") {
    check(disk::Info(journal.path).at("directory") == true); no_exports(journal);
    retire(journal); return {{"discarded", true}};
  }
  if (op == "releaseExport") {
    release_export(journal, text(request.at("candidateId"), 32), true);
    return {{"released", true}};
  }
  if (op == "prepareExport" && request.at("format") == "raw-archive") {
    const auto revision = number(request.at("revision"));
    check(disk::Info(journal.path).at("directory") == true);
    std::vector<fs::path> files; uint64_t size = 8;
    for (const auto &entry : fs::directory_iterator(journal.path)) {
      check(files.size() < 2048); const auto name = entry.path().filename().u8string(); disk::Name(name);
      const auto info = disk::Info(entry.path()); check(info.at("directory") == false);
      size += 12 + name.size() + number(info.at("bytes"), kDocument); check(size <= kDocument, VXCORE_ERR_UNSUPPORTED);
      files.push_back(entry.path());
    }
    reserve(journal.root, journal.key, size + 2 * kManifest); std::sort(files.begin(), files.end());
    std::string archive("VXDRAFT1", 8); archive.reserve(size);
    for (const auto &file : files) {
      cancelled(cancel); const auto name = file.filename().u8string(), bytes = disk::Read(file, kDocument);
      for (unsigned i = 0; i < 4; ++i) archive.push_back(static_cast<char>((name.size() >> (i * 8)) & 255));
      for (unsigned i = 0; i < 8; ++i) archive.push_back(static_cast<char>((uint64_t(bytes.size()) >> (i * 8)) & 255));
      archive.append(name); archive.append(bytes);
    }
    const auto ref = journal.save_source(archive);
    const auto id = random_id();
    Json binding{{"documentKey", journal.key}, {"token", journal.token}, {"revision", revision}, {"candidateId", id},
                 {"sha256", ref.at("sha256")}, {"format", "raw-archive"}};
    journal.save_record("export-" + id + ".json", {{"binding", binding}, {"source", ref}}); return binding;
  }
  if (op == "export") {
    const auto &binding = request.at("binding"); const auto record = export_record(journal, text(binding.at("candidateId"), 32));
    check(record.at("binding") == binding, VXCORE_ERR_INVALID_STATE);
    const auto resource_root = disk::Absolute(text(request.at("resourceRoot"), 4096));
    check(resource_root.parent_path() == journal.root.parent_path() / "resources", VXCORE_ERR_UNSUPPORTED);
    const auto state = disk::Transaction(resource_root.u8string(), "resource");
    const auto desired = disk::ReadJson(resource_root / "resource.json", 16384);
    check(desired.at("version") == 2 && desired.at("origin") == "draft" && desired.at("operation") == "export" &&
          desired.at("binding") == binding, VXCORE_ERR_INVALID_STATE);
    const auto &target = state.at("target");
    const bool archive_target = binding.at("format") == "raw-archive" && target.at("notebookId") == "private-draft" &&
        target.at("nodeId") == journal.key && target.at("notebookRelative") == "private-draft";
    check(archive_target || document_key(text(target.at("notebookId")), text(target.at("nodeId"))) == journal.key);
    if (disk::Exists(resource_root / "ready.json")) {
      Json out; const auto code = vxm_import::TransferRun(disk::Command(resource_root.u8string(), "resource", "verifyExport"), cancel, out);
      check(code == VXCORE_OK, code); return out;
    }
    const auto name = text(desired.at("name"), 255); disk::Name(name);
    const auto output = resource_root / "output";
    if (disk::Exists(output)) disk::RemovePrivate(output);
    disk::MakeDirectory(output);
    const auto info = disk::Copy(journal.path / text(record.at("source").at("file")), output / fs::u8path(name), kDocument, cancel);
    check(info.at("sha256") == binding.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    disk::Marker(resource_root, "ready.json", {{"version", 1}, {"id", state.at("id")}, {"scope", "resource"},
        {"name", name}, {"bytes", info.at("bytes")}, {"sha256", info.at("sha256")}});
    return {{"name", name}, {"path", (output / fs::u8path(name)).u8string()}, {"bytes", info.at("bytes")}, {"sha256", info.at("sha256")}};
  }
  journal.load();
  if (op == "inspect") return journal.summary();
  if (op == "read" || op == "readBase") {
    auto result = journal.summary();
    if (op == "read") result["source"] = std::move(journal.source);
    else result["baseSource"] = std::move(journal.opening);
    return result;
  }
  if (op == "rebase" || op == "rebaseSource") {
    const auto new_token = text(request.at("newToken"), 32); check(new_token != journal.token && hex(new_token, 32));
    check(journal.body.at("supersededBy").is_null() || journal.body.at("supersededBy") == new_token, VXCORE_ERR_INVALID_STATE);
    if (!journal.body.at("intent").is_null()) {
      const auto pending = journal.intent(text(journal.body.at("intent")));
      check(journal.body.at("reconciledDiskHash") == pending.at("expectedDiskHash"), VXCORE_ERR_INVALID_STATE);
    }
    auto desc = journal.body.at("descriptor"); const auto receipt = journal.receipt();
    std::string previous_source, conversion;
    std::string_view previous_disk = journal.opening;
    if (!receipt.is_null()) {
      desc["openingDiskHash"] = receipt.at("diskHash"); previous_source = journal.read_source(receipt.at("source"));
      previous_disk = receipt.at("sourceHash") == receipt.at("diskHash") ? std::string_view(previous_source) :
          ProjectDisk(previous_source, {}, static_cast<int32_t>(number(desc.at("eol"), 3)), conversion);
      check(disk::Hash(previous_disk) == receipt.at("diskHash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    Journal next(journal.root.u8string(), journal.key, new_token);
    auto result = begin(next, desc, op == "rebaseSource" ? payload : std::string_view(journal.source), previous_disk);
    auto retired = journal.body; retired["supersededBy"] = new_token; journal.publish(std::move(retired));
    return result;
  }
  if (op == "checkpoint") {
    check(number(request.at("revision")) == number(journal.body.at("revision")), VXCORE_ERR_INVALID_STATE);
    journal.compact(); return journal.summary();
  }
  if (op == "prepareSave") return prepare(journal, number(request.at("revision")), text(request.at("requestId"), 128));
  if (op == "prepareExport") {
    check(request.at("format") == "text" && number(request.at("revision")) == number(journal.body.at("revision")), VXCORE_ERR_INVALID_STATE);
    journal.compact(); reserve(journal.root, journal.key, 2 * kManifest);
    const auto id = random_id();
    Json binding{{"documentKey", journal.key}, {"token", journal.token}, {"revision", journal.body.at("revision")},
                 {"candidateId", id}, {"sha256", journal.body.at("sourceHash")}, {"format", "text"}};
    journal.save_record("export-" + id + ".json", {{"binding", binding}, {"source", journal.body.at("base")}}); return binding;
  }
  check(op == "append" && payload.size() <= kBatch && !payload.empty());
  check(journal.body.at("supersededBy").is_null(), VXCORE_ERR_INVALID_STATE);
  if (number(journal.body.at("offset"), kDocument) >= 65536 || number(journal.body.at("frames"), 287) >= 256) journal.compact();
  check(number(request.at("expectedRevision")) == number(journal.body.at("revision")), VXCORE_ERR_INVALID_STATE);
  const auto batch = disk::Parse(payload, kBatch); keys(batch, {"frames"});
  check(batch.at("frames").is_array() && !batch.at("frames").empty() && batch.at("frames").size() <= 32);
  std::string framed; framed.reserve(payload.size() + 32 * 68); uint64_t revision = number(journal.body.at("revision"));
  for (const auto &frame : batch.at("frames")) {
    cancelled(cancel); const auto encoded = frame.dump(); check(encoded.size() <= kFrame, VXCORE_ERR_UNSUPPORTED);
    apply(journal.source, frame, journal.token, revision++);
    for (unsigned i = 0; i < 4; ++i) framed.push_back(static_cast<char>((encoded.size() >> (8 * i)) & 255));
    framed.append(disk::Hash(encoded)); framed.append(encoded);
  }
  reserve(journal.root, journal.key, framed.size() + 2 * kManifest, true);
  const auto offset = number(journal.body.at("offset"), kDocument); cancelled(cancel);
  disk::Append(journal.path / text(journal.body.at("log")), offset, framed, &journal.log_identity);
  auto next = journal.body; next["offset"] = offset + framed.size(); next["revision"] = revision;
  next["frames"] = number(journal.body.at("frames"), 287) + batch.at("frames").size(); next["sourceHash"] = disk::Hash(journal.source);
  journal.publish(std::move(next));
  if (number(journal.body.at("offset"), kDocument) >= 65536 || number(journal.body.at("frames"), 287) >= 256) journal.compact();
  return journal.summary();
}
}  // namespace
int32_t Run(const Json &request, std::string_view payload, const std::atomic<bool> *cancel, Json &out) noexcept {
  try { std::lock_guard<std::mutex> guard(journal_mutex); out = run(request, payload, cancel); return VXCORE_OK; }
  catch (...) { return disk::ErrorCode(); }
}
int32_t Describe(const std::string &root, const std::string &key, const std::string &token, Json &out) noexcept {
  try { std::lock_guard<std::mutex> guard(journal_mutex); Journal journal(root, key, token); journal.load(); out = journal.summary(); return VXCORE_OK; }
  catch (...) { return disk::ErrorCode(); }
}
int32_t LoadCandidate(const std::string &root, const std::string &key, const std::string &token,
                      const std::string &id, PreparedSave &out) noexcept {
  try {
    std::lock_guard<std::mutex> guard(journal_mutex); Journal journal(root, key, token); journal.load();
    check(journal.body.at("supersededBy").is_null() && hex(id, 32) && journal.body.at("intent") == "intent-" + id + ".json",
          VXCORE_ERR_INVALID_STATE);
    const auto value = journal.intent("intent-" + id + ".json"), desc = value.at("descriptor");
    out.document_key = key; out.token = token; out.candidate_id = id; out.revision = number(value.at("revision"));
    out.notebook_id = text(desc.at("notebookId")); out.node_id = text(desc.at("nodeId"));
    out.notebook_relative = text(desc.at("notebookRelative")); out.path_hint = text(desc.at("pathHint"));
    out.editor_type = text(desc.at("editorType")); out.eol = static_cast<int32_t>(number(desc.at("eol"), 3));
    out.source = journal.read_source(value.at("source")); out.source_hash = text(value.at("sourceHash"));
    out.expected_disk_hash = text(value.at("expectedDiskHash")); out.intended_disk_hash = text(value.at("intendedDiskHash")); return VXCORE_OK;
  } catch (...) { return disk::ErrorCode(); }
}
int32_t Reconcile(const std::string &root, const std::string &key, const std::string &token,
                  const OwnerFacts &facts, Json &out) noexcept {
  try { std::lock_guard<std::mutex> guard(journal_mutex); Journal journal(root, key, token); journal.load(); out = reconcile(journal, facts); return VXCORE_OK; }
  catch (...) { return disk::ErrorCode(); }
}
int32_t CommitSaved(const std::string &root, const std::string &key, const std::string &token,
                    const std::string &id, const OwnerFacts &facts, Json &out) noexcept {
  try { std::lock_guard<std::mutex> guard(journal_mutex); Journal journal(root, key, token); journal.load(); out = reconcile(journal, facts, &id); return VXCORE_OK; }
  catch (...) { return disk::ErrorCode(); }
}
}  // namespace vxm_drafts

extern "C" int32_t vxm_draft_run(const char *request_json, const uint8_t *payload, uint64_t payload_size,
                                 VxmImportCancel *cancel, char **out_json) {
  if (out_json) *out_json = nullptr;
  try {
    namespace disk = vxm_import::storage;
    disk::Check(request_json && out_json && (payload || !payload_size), VXCORE_ERR_NULL_POINTER);
    size_t size = 0; while (size <= 16384 && request_json[size]) ++size;
    disk::Check(size <= 16384 && payload_size <= 8 * 1024 * 1024, VXCORE_ERR_INVALID_PARAM);
    const auto request = disk::Parse(std::string_view(request_json, size), 16384);
    const auto op = request.value("op", std::string());
    const bool source = op == "read" || op == "readBase";
    const size_t maximum = source ? 32 * 1024 * 1024 : 65536;
    std::unique_ptr<char[]> result(new char[maximum + 1]); nlohmann::json out;
    const auto code = vxm_drafts::Run(request, std::string_view(payload_size ? reinterpret_cast<const char *>(payload) : "", payload_size),
                                    disk::Cancellation(cancel), out);
    if (code != VXCORE_OK) return code;
    const auto encoded = out.dump(); disk::Check(encoded.size() <= maximum, VXCORE_ERR_OUT_OF_MEMORY);
    std::memcpy(result.get(), encoded.c_str(), encoded.size() + 1); *out_json = result.release(); return VXCORE_OK;
  } catch (...) { return vxm_import::storage::ErrorCode(); }
}
