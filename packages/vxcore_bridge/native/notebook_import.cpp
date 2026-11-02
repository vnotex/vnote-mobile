// SPDX-License-Identifier: LGPL-3.0-only
#include "notebook_import.h"
#include "vxcore_host.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <new>
#include <set>
#include <string>
#include <string_view>
#include <vector>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif
#if defined(__APPLE__)
#include <stdio.h>
#endif
#endif
#include <nlohmann/json.hpp>
#include <sodium.h>
#include <utf8proc.h>

struct VxmImportCancel {
  std::atomic<bool> requested{false};
  const std::atomic<bool> *borrowed = nullptr;
};
static_assert(std::atomic<bool>::is_always_lock_free, "Cancellation must be lock-free");

namespace {
namespace fs = std::filesystem;
using Json = nlohmann::json;
constexpr size_t kRequest = 16384, kResponse = 8 * 1024 * 1024;
constexpr size_t kEntries = 100000, kChunk = 256 * 1024, kLine = 8192;
constexpr uint64_t kFile = 256ULL * 1024 * 1024, kTree = 2ULL * 1024 * 1024 * 1024;
using Failure = vxm_import::StorageFailure;
void require(bool condition, int32_t code = VXCORE_ERR_INVALID_PARAM) {
  if (!condition) throw Failure{code};
}
void cancelled(const VxmImportCancel *cancel) {
  require(!cancel || (!cancel->requested.load(std::memory_order_relaxed) &&
          (!cancel->borrowed || !cancel->borrowed->load(std::memory_order_relaxed))), VXCORE_ERR_CANCELLED);
}
bool hex(const std::string &text, size_t length) {
  return text.size() == length && std::all_of(text.begin(), text.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
const std::string &text(const Json &value, size_t limit = kRequest, bool empty = false) {
  require(value.is_string(), VXCORE_ERR_JSON_PARSE);
  const auto &result = value.get_ref<const std::string &>();
  require((empty || !result.empty()) && result.size() <= limit && result.find('\0') == std::string::npos,
          VXCORE_ERR_JSON_PARSE);
  return result;
}
uint64_t number(const Json &value, uint64_t limit) {
  require(value.is_number_integer() && (!value.is_number_unsigned() ? value.get<int64_t>() >= 0 : true), VXCORE_ERR_JSON_PARSE);
  const auto result = value.get<uint64_t>();
  require(result <= limit, VXCORE_ERR_JSON_PARSE);
  return result;
}
void keys(const Json &value, std::initializer_list<const char *> expected) {
  require(value.is_object() && value.size() == expected.size(), VXCORE_ERR_JSON_PARSE);
  for (const auto *key : expected) require(value.contains(key), VXCORE_ERR_JSON_PARSE);
}
// Check depth before DOM parsing and reject duplicate keys (JSON's normal last-
// value-wins rule is unsafe for metadata, identity, and durable intent records).
Json parse(std::string_view raw, size_t limit) {
  require(!raw.empty() && raw.size() <= limit, VXCORE_ERR_JSON_PARSE);
  std::vector<std::set<std::string>> objects;
  auto callback = [&](int depth, Json::parse_event_t event, Json &parsed) {
    require(depth <= 32, VXCORE_ERR_JSON_PARSE);
    if (event == Json::parse_event_t::object_start) objects.emplace_back();
    else if (event == Json::parse_event_t::key) {
      require(!objects.empty() && objects.back().insert(parsed.get<std::string>()).second, VXCORE_ERR_JSON_PARSE);
    } else if (event == Json::parse_event_t::object_end) objects.pop_back();
    return true;
  };
  auto result = Json::parse(raw.begin(), raw.end(), callback);
  require(result.is_object(), VXCORE_ERR_JSON_PARSE);
  return result;
}
std::string fold(std::string_view input, bool compose) {
  require(input.size() <= 1024 && input.find('\0') == std::string_view::npos);
  utf8proc_uint8_t *raw = nullptr;
  const auto options = static_cast<utf8proc_option_t>(UTF8PROC_STABLE | UTF8PROC_CASEFOLD |
      (compose ? UTF8PROC_COMPOSE : UTF8PROC_DECOMPOSE));
  const auto length = utf8proc_map(reinterpret_cast<const utf8proc_uint8_t *>(input.data()),
                                 static_cast<utf8proc_ssize_t>(input.size()), &raw, options);
  std::unique_ptr<utf8proc_uint8_t, decltype(&std::free)> owned(raw, std::free);
  require(length >= 0, VXCORE_ERR_UNSUPPORTED);
  require(length <= 16384, VXCORE_ERR_UNSUPPORTED);
  return std::string(reinterpret_cast<const char *>(raw), static_cast<size_t>(length));
}
void basename(const std::string &name) {
  require(!name.empty() && name.size() <= 255 && name != "." && name != ".." && name.back() != '.' && name.back() != ' ', VXCORE_ERR_UNSUPPORTED);
  for (size_t i = 0; i < name.size();) {
    utf8proc_int32_t point = 0;
    const auto count = utf8proc_iterate(reinterpret_cast<const uint8_t *>(name.data() + i),
                                      static_cast<utf8proc_ssize_t>(name.size() - i), &point);
    require(count > 0 && point >= 32 && !(point >= 0x7f && point <= 0x9f), VXCORE_ERR_UNSUPPORTED);
    require(point > 127 || std::strchr("<>:\"/\\|?*", static_cast<char>(point)) == nullptr, VXCORE_ERR_UNSUPPORTED);
    i += static_cast<size_t>(count);
  }
  auto stem = fold(name.substr(0, name.find('.')), true);
  while (!stem.empty() && stem.back() == ' ') stem.pop_back();
  require(stem != "con" && stem != "prn" && stem != "aux" && stem != "nul" && stem != "conin$" && stem != "conout$", VXCORE_ERR_UNSUPPORTED);
  require(!(stem.size() == 4 && (stem.compare(0, 3, "com") == 0 || stem.compare(0, 3, "lpt") == 0) && stem[3] >= '0' && stem[3] <= '9'), VXCORE_ERR_UNSUPPORTED);
  for (const auto *digit : {u8"¹", u8"²", u8"³"})
    require(stem != std::string("com") + digit && stem != std::string("lpt") + digit, VXCORE_ERR_UNSUPPORTED);
}
void relative(const std::string &path) {
  require(!path.empty() && path.size() <= 1024 && path.front() != '/' && path.back() != '/', VXCORE_ERR_UNSUPPORTED);
  size_t start = 0, depth = 0;
  for (;;) {
    const auto end = path.find('/', start);
    basename(path.substr(start, end == std::string::npos ? end : end - start));
    require(++depth <= 32, VXCORE_ERR_UNSUPPORTED);
    if (end == std::string::npos) break;
    start = end + 1;
  }
}
void no_link(const fs::path &path) {
  require(!fs::is_symlink(fs::symlink_status(path)), VXCORE_ERR_UNSUPPORTED);
#if defined(_WIN32)
  const auto attributes = GetFileAttributesW(path.c_str());
  require(attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_REPARSE_POINT), VXCORE_ERR_UNSUPPORTED);
#endif
}
void confined(const fs::path &root, const std::string &path = "") {
  no_link(root);
  auto current = root;
  if (path.empty()) return;
  relative(path);
  for (const auto &part : fs::u8path(path)) { current /= part; no_link(current); }
}
fs::path absolute(const std::string &value) {
  auto result = fs::u8path(value);
  require(result.is_absolute() && result == result.lexically_normal());
  auto current = result.root_path();
  for (const auto &part : result.relative_path()) { current /= part; no_link(current); }
  return result;
}
bool present(const fs::path &path) { return fs::exists(fs::symlink_status(path)); }

struct Identity {
  uint64_t device = 0, low = 0, high = 0, size = 0, links = 0;
  int64_t seconds = 0, nanos = 0;
  bool directory = false;
  bool object(const Identity &other) const {
    return device == other.device && low == other.low && high == other.high && directory == other.directory;
  }
  bool operator==(const Identity &other) const {
    return object(other) && size == other.size && links == other.links && seconds == other.seconds && nanos == other.nanos;
  }
  Json journal() const { return {{"device", device}, {"low", low}, {"high", high}}; }
  bool matches(const Json &value) const {
    keys(value, {"device", "low", "high"});
    return directory && device == number(value.at("device"), UINT64_MAX) &&
        low == number(value.at("low"), UINT64_MAX) && high == number(value.at("high"), UINT64_MAX);
  }
};
// Same no-follow handle + before/after identity pattern as host export. These
// checks catch outside changes, not malicious writers with private-root access.
struct File {
#if defined(_WIN32)
  HANDLE handle = INVALID_HANDLE_VALUE;
#else
  int handle = -1;
#endif
  File(const fs::path &path, bool output = false, bool directory = false, bool flushable = false) {
#if defined(_WIN32)
    handle = CreateFileW(path.c_str(), output ? GENERIC_WRITE : directory ? FILE_READ_ATTRIBUTES :
                         GENERIC_READ | (flushable ? GENERIC_WRITE : 0),
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                         output ? CREATE_NEW : OPEN_EXISTING,
                         FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), nullptr);
    require(handle != INVALID_HANDLE_VALUE, VXCORE_ERR_IO);
#else
    const int flags = output ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY | O_NONBLOCK;
    (void)flushable;
    handle = ::open(path.c_str(), flags | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0), 0600);
    require(handle >= 0, VXCORE_ERR_IO);
#endif
  }
  File(const File &) = delete;
  File &operator=(const File &) = delete;
  ~File() {
#if defined(_WIN32)
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
#else
    if (handle >= 0) ::close(handle);
#endif
  }
  Identity identity() const {
    Identity result;
#if defined(_WIN32)
    BY_HANDLE_FILE_INFORMATION info{};
    FILE_ID_INFO id{};
    require(GetFileInformationByHandle(handle, &info) &&
            GetFileInformationByHandleEx(handle, FileIdInfo, &id, sizeof(id)), VXCORE_ERR_IO);
    require(!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && GetFileType(handle) == FILE_TYPE_DISK, VXCORE_ERR_UNSUPPORTED);
    result.device = id.VolumeSerialNumber;
    std::memcpy(&result.low, id.FileId.Identifier, 8);
    std::memcpy(&result.high, id.FileId.Identifier + 8, 8);
    result.size = (uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    result.links = info.nNumberOfLinks;
    result.seconds = static_cast<int64_t>((uint64_t(info.ftLastWriteTime.dwHighDateTime) << 32) | info.ftLastWriteTime.dwLowDateTime);
    result.directory = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
    struct stat info{};
    require(::fstat(handle, &info) == 0, VXCORE_ERR_IO);
    require(S_ISDIR(info.st_mode) || S_ISREG(info.st_mode), VXCORE_ERR_UNSUPPORTED);
    result.device = info.st_dev;
    result.low = info.st_ino;
    result.size = info.st_size;
    result.links = info.st_nlink;
    result.directory = S_ISDIR(info.st_mode);
#if defined(__APPLE__)
    result.seconds = info.st_mtimespec.tv_sec;
    result.nanos = info.st_mtimespec.tv_nsec;
#else
    result.seconds = info.st_mtim.tv_sec;
    result.nanos = info.st_mtim.tv_nsec;
#endif
#endif
    require(result.directory || result.links == 1, VXCORE_ERR_UNSUPPORTED);
    return result;
  }
  size_t read(uint8_t *buffer, size_t count) {
#if defined(_WIN32)
    DWORD received = 0;
    require(ReadFile(handle, buffer, static_cast<DWORD>(count), &received, nullptr), VXCORE_ERR_IO);
    return received;
#else
    ssize_t received;
    do { received = ::read(handle, buffer, count); } while (received < 0 && errno == EINTR);
    require(received >= 0, VXCORE_ERR_IO);
    return static_cast<size_t>(received);
#endif
  }
  void write(std::string_view data) {
    while (!data.empty()) {
#if defined(_WIN32)
      DWORD count = 0;
      require(WriteFile(handle, data.data(), static_cast<DWORD>(data.size()), &count, nullptr) && count, VXCORE_ERR_IO);
#else
      ssize_t count;
      do { count = ::write(handle, data.data(), data.size()); } while (count < 0 && errno == EINTR);
      require(count > 0, VXCORE_ERR_IO);
#endif
      data.remove_prefix(static_cast<size_t>(count));
    }
  }
  void flush() {
#if defined(_WIN32)
    require(FlushFileBuffers(handle), VXCORE_ERR_IO);
#else
    int result;
    do { result = ::fsync(handle); } while (result < 0 && errno == EINTR);
    require(result == 0, VXCORE_ERR_IO);
#endif
  }
};
Identity identity(const fs::path &path) {
#if defined(_WIN32)
  File file(path, false, true);
#else
  const auto status = fs::symlink_status(path);
  require(fs::is_regular_file(status) || fs::is_directory(status), VXCORE_ERR_UNSUPPORTED);
  File file(path, false, fs::is_directory(status));
#endif
  return file.identity();
}
void directory_flush(const fs::path &path) {
  require(identity(path).directory, VXCORE_ERR_IO);
#if !defined(_WIN32)
  File directory(path, false, true);
  directory.flush();
#endif
  // Windows directory-entry barriers are the WRITE_THROUGH renames below.
  // Win32 has no portable unprivileged fsync(directory) guarantee; do not claim
  // POSIX-equivalent power-loss durability or swallow failed file flushes.
}
void rename_new(const fs::path &source, const fs::path &target) {
  no_link(source);
  no_link(target.parent_path());
#if defined(_WIN32)
  require(MoveFileExW(source.c_str(), target.c_str(), MOVEFILE_WRITE_THROUGH), VXCORE_ERR_IO);
#elif defined(__APPLE__)
  require(::renameatx_np(AT_FDCWD, source.c_str(), AT_FDCWD, target.c_str(), RENAME_EXCL) == 0, VXCORE_ERR_IO);
#elif defined(__linux__)
  // Android API 28 must not link the libc wrapper first exposed at API 30.
  require(::syscall(SYS_renameat2, AT_FDCWD, source.c_str(), AT_FDCWD, target.c_str(), 1 /* RENAME_NOREPLACE */) == 0, VXCORE_ERR_IO);
#else
  (void)target;
  throw Failure{VXCORE_ERR_UNSUPPORTED};
#endif
  directory_flush(source.parent_path());
  if (target.parent_path() != source.parent_path()) directory_flush(target.parent_path());
}
std::string read_bytes(const fs::path &path, size_t maximum, const VxmImportCancel *cancel = nullptr) {
  File file(path);
  const auto before = file.identity();
  require(!before.directory && before.size <= maximum, VXCORE_ERR_UNSUPPORTED);
  std::string result(static_cast<size_t>(before.size), '\0');
  size_t offset = 0;
  while (offset != result.size()) {
    cancelled(cancel);
    const auto count = file.read(reinterpret_cast<uint8_t *>(result.data() + offset), std::min(kChunk, result.size() - offset));
    require(count != 0, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    offset += count;
  }
  uint8_t extra;
  require(file.read(&extra, 1) == 0 && file.identity() == before && identity(path) == before, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  return result;
}
Json read_json(const fs::path &path, size_t maximum = kRequest, const VxmImportCancel *cancel = nullptr) {
  return parse(read_bytes(path, maximum, cancel), maximum);
}
struct Hash {
  crypto_hash_sha256_state state{};
  Hash() {
    static const int initialized = sodium_init();
    require(initialized >= 0, VXCORE_ERR_NOT_INITIALIZED);
    crypto_hash_sha256_init(&state);
  }
  void add(const uint8_t *bytes, size_t size) { crypto_hash_sha256_update(&state, bytes, size); }
  std::string finish() {
    uint8_t digest[crypto_hash_sha256_BYTES];
    char hex_digest[65];
    crypto_hash_sha256_final(&state, digest);
    sodium_bin2hex(hex_digest, sizeof(hex_digest), digest, sizeof(digest));
    return hex_digest;
  }
};
std::string hash_file(const fs::path &path, uint64_t expected, const VxmImportCancel *cancel, bool flush,
                      uint64_t limit = kFile) {
  File file(path, false, false, flush);
  const auto before = file.identity();
  require(!before.directory && before.size == expected && expected <= limit, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  Hash hash;
  std::array<uint8_t, kChunk> buffer;
  uint64_t total = 0;
  for (;;) {
    cancelled(cancel);
    const auto count = file.read(buffer.data(), buffer.size());
    if (!count) break;
    require(count <= expected - total, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    total += count;
    hash.add(buffer.data(), count);
  }
  require(total == expected && file.identity() == before && identity(path) == before, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  if (flush) { cancelled(cancel); file.flush(); }
  return hash.finish();
}
void durable_json(const fs::path &directory, const std::string &name, const Json &value,
                  size_t limit = kRequest) {
  const auto destination = directory / name;
  if (present(destination)) {
    require(read_json(destination, limit) == value, VXCORE_ERR_INVALID_STATE);
    return;
  }
  const auto temporary = directory / (name + ".tmp");
  const auto encoded = value.dump();
  require(encoded.size() <= limit, VXCORE_ERR_INVALID_PARAM);
  if (present(temporary)) {
    require(read_json(temporary, limit) == value, VXCORE_ERR_INVALID_STATE);
    File file(temporary, false, false, true);
    file.flush();
  } else {
    File file(temporary, true);
    file.write(encoded);
    file.flush();
  }
  rename_new(temporary, destination);
}
void replace_json(const fs::path &directory, const std::string &name, const Json &expected, const Json &value) {
  const auto target = directory / name;
  require(read_json(target) == expected, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto before = identity(target);
  const auto temporary = directory / (name + ".next");
  const auto encoded = value.dump();
  require(encoded.size() <= kRequest, VXCORE_ERR_INVALID_PARAM);
  if (present(temporary)) {
    require(read_json(temporary) == value, VXCORE_ERR_INVALID_STATE);
    File output(temporary, false, false, true); output.flush();
  } else {
    File output(temporary, true); output.write(encoded); output.flush();
  }
  require(identity(target) == before, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
#if defined(_WIN32)
  require(MoveFileExW(temporary.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH), VXCORE_ERR_IO);
#else
  require(::rename(temporary.c_str(), target.c_str()) == 0, VXCORE_ERR_IO);
#endif
  directory_flush(directory);
}

// Track every physical spelling, including prefixes, in both full-fold forms.
struct Names {
  std::set<std::string> nfc, nfd;
  void add(const std::string &path) {
    relative(path);
    require(nfc.insert(fold(path, true)).second && nfd.insert(fold(path, false)).second, VXCORE_ERR_UNSUPPORTED);
  }
};
struct InventoryResult {
  uint64_t bytes = 0, entries = 0;
  std::string prefix;
  std::map<std::string, bool> paths;
  void contains(const std::string &path, bool directory) const {
    const auto found = paths.find(prefix + path);
    require(found != paths.end() && found->second == directory, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  }
};
InventoryResult inventory(const fs::path &transaction, const fs::path &tree,
                          const std::string &tree_relative, const std::string &expected_hash,
                          const VxmImportCancel *cancel, bool flush) {
  require(hex(expected_hash, 64));
  const auto wrapper = tree_relative == "unpacked" ? std::string() : tree_relative.substr(9);
  File manifest(transaction / "inventory.jsonl");
  const auto before = manifest.identity();
  require(!before.directory && before.size <= uint64_t(kEntries) * kLine, VXCORE_ERR_UNSUPPORTED);
  Hash digest;
  InventoryResult result;
  Names names;
  std::map<std::string, bool> listed;
  std::string previous, line;
  line.reserve(kLine);
  std::array<uint8_t, kChunk> buffer;
  uint64_t read = 0;
  auto record = [&] {
    cancelled(cancel);
    auto item = parse(line, kLine);
    keys(item, {"path", "type", "size", "sha256"});
    const auto &path = text(item.at("path"), 1024);
    require(previous.empty() || previous < path, VXCORE_ERR_UNSUPPORTED);
    previous = path;
    names.add(path);
    const auto &type = text(item.at("type"));
    require(type == "file" || type == "directory", VXCORE_ERR_UNSUPPORTED);
    const bool directory = type == "directory";
    const auto size = number(item.at("size"), directory ? 0 : kFile);
    const auto &hash = text(item.at("sha256"), 64, directory);
    require(directory ? hash.empty() : hex(hash, 64), VXCORE_ERR_JSON_PARSE);
    const auto slash = path.rfind('/');
    if (slash != std::string::npos) {
      const auto parent = listed.find(path.substr(0, slash));
      require(parent != listed.end() && parent->second, VXCORE_ERR_UNSUPPORTED);
    }
    require(listed.emplace(path, directory).second && ++result.entries <= kEntries, VXCORE_ERR_UNSUPPORTED);
    require(size <= kTree - result.bytes, VXCORE_ERR_UNSUPPORTED);
    result.bytes += size;
    std::string mapped = path;
    if (!wrapper.empty()) {
      if (path == wrapper) { require(directory, VXCORE_ERR_UNSUPPORTED); mapped.clear(); }
      else {
        require(path.compare(0, wrapper.size() + 1, wrapper + "/") == 0, VXCORE_ERR_UNSUPPORTED);
        mapped = path.substr(wrapper.size() + 1);
      }
    }
    confined(tree, mapped);
    const auto target = mapped.empty() ? tree : tree / fs::u8path(mapped);
    const auto current = identity(target);
    require(current.directory == directory, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    if (!directory) require(hash_file(target, size, cancel, flush) == hash, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    line.clear();
  };
  for (;;) {
    cancelled(cancel);
    const auto count = manifest.read(buffer.data(), buffer.size());
    if (!count) break;
    require(count <= before.size - read, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    read += count;
    digest.add(buffer.data(), count);
    for (size_t i = 0; i < count; ++i) {
      if (buffer[i] == '\n') record();
      else { require(line.size() < kLine, VXCORE_ERR_UNSUPPORTED); line.push_back(static_cast<char>(buffer[i])); }
    }
  }
  require(line.empty() && read == before.size && result.entries && digest.finish() == expected_hash &&
          manifest.identity() == before && identity(transaction / "inventory.jsonl") == before, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  require(identity(tree).directory, VXCORE_ERR_UNSUPPORTED);
  size_t physical = wrapper.empty() ? 0 : 1;
  for (fs::recursive_directory_iterator it(tree), end; it != end; ++it) {
    cancelled(cancel);
    const auto path = it->path().lexically_relative(tree).generic_u8string();
    relative(path);
    confined(tree, path);
    const auto key = wrapper.empty() ? path : wrapper + "/" + path;
    const auto found = listed.find(key);
    require(found != listed.end() && identity(it->path()).directory == found->second && ++physical <= kEntries, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  }
  require(physical == result.entries, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  if (flush) {
    // Children before parents; map order also puts a child after its own parent.
    for (auto it = listed.rbegin(); it != listed.rend(); ++it) if (it->second) {
      cancelled(cancel);
      auto mapped = wrapper.empty() ? it->first : it->first == wrapper ? "" : it->first.substr(wrapper.size() + 1);
      directory_flush(mapped.empty() ? tree : tree / fs::u8path(mapped));
    }
    if (wrapper.empty()) directory_flush(tree);
    File file(transaction / "inventory.jsonl", false, false, true);
    file.flush();
  }
  result.prefix = wrapper.empty() ? "" : wrapper + "/";
  result.paths = std::move(listed);
  return result;
}

void credentials(const Json &value) {
  if (value.is_array()) { for (const auto &child : value) credentials(child); return; }
  if (!value.is_object()) return;
  for (auto it = value.begin(); it != value.end(); ++it) {
    const auto &key = it.key();
    require(key != "credentials" && key != "syncCredentials" && key != "personalAccessToken" &&
            key != "pat" && key != "password", VXCORE_ERR_UNSUPPORTED);
    if (key == "syncRemoteUrl") {
      const auto &url = text(it.value(), kRequest, true);
      require(url.find('@') == std::string::npos && url.find('?') == std::string::npos && url.find('#') == std::string::npos,
              VXCORE_ERR_UNSUPPORTED);
    }
    credentials(it.value());
  }
}
void common_metadata(const Json &config) {
  if (config.contains("metadata")) require(config.at("metadata").is_object(), VXCORE_ERR_JSON_PARSE);
  for (const auto *key : {"createdUtc", "modifiedUtc"})
    if (config.contains(key)) require(config.at(key).is_number_integer(), VXCORE_ERR_JSON_PARSE);
  credentials(config);
}
std::string resource(const fs::path &root, const Json &config, const char *key, const char *fallback) {
  auto path = config.contains(key) ? text(config.at(key), 1024, true) : std::string(fallback);
  if (path.empty() && std::string(key) == "recycleBinFolder") path = fallback;
  relative(path);
  const auto folded = fold(path, true);
  for (const auto *reserved : {"vx_notebook/contents", "vx_notebook/vx_sync", "vx_notebook/vx_import", "vx_notebook/vx_transfer"}) {
    const std::string prefix(reserved);
    require(folded != prefix && folded.compare(0, prefix.size() + 1, prefix + "/") != 0 &&
            prefix.compare(0, folded.size() + 1, folded + "/") != 0, VXCORE_ERR_UNSUPPORTED);
  }
  confined(root, path);
  if (present(root / fs::u8path(path))) require(identity(root / fs::u8path(path)).directory, VXCORE_ERR_UNSUPPORTED);
  return path;
}
void exact_child(const fs::path &parent, const std::string &name, const VxmImportCancel *cancel) {
  for (const auto &entry : fs::directory_iterator(parent)) {
    cancelled(cancel);
    if (entry.path().filename().u8string() == name) return;
  }
  throw Failure{VXCORE_ERR_FILE_CHANGED_OUTSIDE};
}
vxm_import::Inspection inspect_metadata(const fs::path &root, bool incoming, const VxmImportCancel *cancel,
                                       const InventoryResult *physical = nullptr, bool pending_import = false) {
  absolute(root.u8string());
  require(identity(root).directory, VXCORE_ERR_UNSUPPORTED);
  confined(root, "vx_notebook/config.json");
  if (physical) physical->contains("vx_notebook/config.json", false);
  else {
    exact_child(root, "vx_notebook", cancel);
    exact_child(root / "vx_notebook", "config.json", cancel);
    exact_child(root / "vx_notebook", "contents", cancel);
  }
  const auto config = read_json(root / "vx_notebook/config.json", kResponse, cancel);
  common_metadata(config);
  vxm_import::Inspection result;
  result.notebook_id = text(config.at("id"), 127);
  basename(result.notebook_id);
  result.notebook_name = text(config.at("name"));
  bool nonblank = false;
  for (size_t i = 0; i < result.notebook_name.size();) {
    utf8proc_int32_t point = 0;
    const auto count = utf8proc_iterate(reinterpret_cast<const uint8_t *>(result.notebook_name.data() + i),
                                      static_cast<utf8proc_ssize_t>(result.notebook_name.size() - i), &point);
    require(count > 0 && point >= 32 && !(point >= 0x7f && point <= 0x9f), VXCORE_ERR_UNSUPPORTED);
    const bool space = point == 0x20 || point == 0xa0 || point == 0x1680 ||
        (point >= 0x2000 && point <= 0x200a) || point == 0x2028 || point == 0x2029 ||
        point == 0x202f || point == 0x205f || point == 0x3000 || point == 0xfeff;
    nonblank |= !space;
    i += static_cast<size_t>(count);
  }
  require(nonblank, VXCORE_ERR_JSON_PARSE);
  if (config.contains("encryptionInitialized")) require(config.at("encryptionInitialized").is_boolean(), VXCORE_ERR_JSON_PARSE);
  // These are portable routing/preferences, not permission to start sync.
  // Read-only validation does not register a backend or execute network work.
  for (const auto *key : {"syncEnabled", "autoSyncEnabled"})
    if (config.contains(key)) require(config.at(key).is_boolean(), VXCORE_ERR_JSON_PARSE);
  for (const auto *key : {"syncBackend", "syncRemoteUrl", "description"})
    if (config.contains(key)) text(config.at(key), kRequest, true);
  if (config.contains("attachmentsFolder")) {
    const auto &legacy = text(config.at("attachmentsFolder"), 1024, true);
    require(legacy.empty(), VXCORE_ERR_UNSUPPORTED);
  }
  const auto assets = resource(root, config, "assetsFolder", "vx_assets");
  resource(root, config, "recycleBinFolder", "vx_notebook/recycle_bin");
  if (config.contains("tags")) {
    const auto &tags = config.at("tags");
    require(tags.is_array() && tags.size() <= kEntries, VXCORE_ERR_JSON_PARSE);
    require(tags.empty() || (config.contains("tagsModifiedUtc") && config.at("tagsModifiedUtc").is_number_integer() &&
                            config.at("tagsModifiedUtc").get<int64_t>() != 0), VXCORE_ERR_UNSUPPORTED);
    std::set<std::string> names;
    for (const auto &tag : tags) {
      require(tag.is_object(), VXCORE_ERR_JSON_PARSE);
      require(names.insert(text(tag.at("name"))).second, VXCORE_ERR_JSON_PARSE);
      if (tag.contains("parent")) text(tag.at("parent"), kRequest, true);
      common_metadata(tag);
    }
  }
  if (config.contains("ignored")) {
    require(config.at("ignored").is_array(), VXCORE_ERR_JSON_PARSE);
    for (const auto &item : config.at("ignored")) text(item);
  }
  // Empty import/transfer parents are harmless; any recovery material is not.
  for (const auto *runtime : {"vx_sync", "vx_import", "vx_transfer"}) {
    const auto relative_runtime = std::string("vx_notebook/") + runtime;
    confined(root, relative_runtime);
    const auto path = root / relative_runtime;
    if (!present(path)) continue;
    require(identity(path).directory, VXCORE_ERR_UNSUPPORTED);
    if (pending_import && std::string(runtime) == "vx_import") continue;
    for (const auto &entry : fs::directory_iterator(path)) {
      require(std::string(runtime) == "vx_transfer" && entry.path().filename() == "encryption" &&
              identity(entry.path()).directory && fs::is_empty(entry.path()), VXCORE_ERR_UNSUPPORTED);
    }
  }
  std::set<std::string> ids, metadata_paths;
  size_t id_bytes = 0;
  auto add_id = [&](const Json &value) {
    const auto &id = text(value, 127);
    basename(id);
    require(id != result.notebook_id && ids.insert(id).second && ids.size() <= kEntries, VXCORE_ERR_JSON_PARSE);
    id_bytes += id.size();
    require(id_bytes <= 4 * 1024 * 1024, VXCORE_ERR_UNSUPPORTED);
    result.node_ids.push_back(id);
    return id;
  };
  struct Folder { std::string path, expected_name; };
  std::vector<Folder> pending{{"", ""}};
  while (!pending.empty()) {
    cancelled(cancel);
    auto folder = std::move(pending.back());
    pending.pop_back();
    const auto folder_prefix = folder.path.empty() ? "" : folder.path + "/";
    const auto metadata = "vx_notebook/contents/" + folder_prefix + "vx.json";
    confined(root, metadata);
    require(metadata_paths.insert(metadata).second, VXCORE_ERR_JSON_PARSE);
    const auto node = read_json(root / fs::u8path(metadata), kResponse, cancel);
    common_metadata(node);
    add_id(node.at("id"));
    const auto &name = text(node.at("name"), kRequest, folder.path.empty());
    require(folder.path.empty() || name == folder.expected_name, VXCORE_ERR_JSON_PARSE);
    require(node.at("folders").is_array() && node.at("files").is_array(), VXCORE_ERR_JSON_PARSE);
    if (physical) physical->contains(metadata, false);
    else exact_child((root / fs::u8path(metadata)).parent_path(), "vx.json", cancel);
    require(node.at("folders").size() <= kEntries && node.at("files").size() <= kEntries, VXCORE_ERR_UNSUPPORTED);
    if (!folder.path.empty()) {
      confined(root, folder.path);
      require(present(root / fs::u8path(folder.path)) && identity(root / fs::u8path(folder.path)).directory, VXCORE_ERR_UNSUPPORTED);
    }
    std::map<std::string, bool> observed;
    if (!physical) {
      for (const auto &file : node.at("files")) observed.emplace(text(file.at("name"), 255), false);
      for (const auto &child : node.at("folders")) observed.emplace(text(child, 255), false);
      for (const auto &entry : fs::directory_iterator(folder.path.empty() ? root : root / fs::u8path(folder.path))) {
        cancelled(cancel);
        const auto found = observed.find(entry.path().filename().u8string());
        if (found != observed.end()) found->second = true;
      }
    }
    Names children;
    for (const auto &file : node.at("files")) {
      require(file.is_object(), VXCORE_ERR_JSON_PARSE);
      common_metadata(file);
      const auto id = add_id(file.at("id"));
      const auto &file_name = text(file.at("name"), 255);
      children.add(file_name);
      auto suffix = file_name.size() >= 4 ? file_name.substr(file_name.size() - 4) : std::string();
      for (auto &c : suffix) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
      bool encrypted = false;
      if (file.contains("metadata") && file.at("metadata").contains("encrypted")) {
        require(file.at("metadata").at("encrypted").is_boolean(), VXCORE_ERR_JSON_PARSE);
        encrypted = file.at("metadata").at("encrypted").get<bool>();
      }
      require(encrypted == (suffix == ".vne"), VXCORE_ERR_UNSUPPORTED);
      if (encrypted) {
        const auto &editor = text(file.at("metadata").at("editorType"));
        require(editor == "markdown" || editor == "text" || editor == "mindmap", VXCORE_ERR_UNSUPPORTED);
      }
      const auto path = folder_prefix + file_name;
      confined(root, path);
      if (physical) physical->contains(path, false);
      if (incoming || present(root / fs::u8path(path))) {
        require(physical || observed.at(file_name), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        require(!identity(root / fs::u8path(path)).directory, VXCORE_ERR_UNSUPPORTED);
      }
      if (file.contains("tags")) {
        require(file.at("tags").is_array(), VXCORE_ERR_JSON_PARSE);
        std::set<std::string> tags;
        for (const auto &tag : file.at("tags")) require(tags.insert(text(tag)).second, VXCORE_ERR_JSON_PARSE);
      }
      if (file.contains("attachments")) {
        require(file.at("attachments").is_array(), VXCORE_ERR_JSON_PARSE);
        std::set<std::string> attachments;
        for (const auto &attachment : file.at("attachments")) {
          const auto &reference = text(attachment, 1024);
          relative(reference);
          const auto slash = reference.rfind('/');
          const auto attachment_name = reference.substr(slash == std::string::npos ? 0 : slash + 1);
          const auto asset = assets + "/" + id + "/" + attachment_name;
          require(slash == std::string::npos || reference == asset, VXCORE_ERR_UNSUPPORTED);
          require(attachments.insert(attachment_name).second, VXCORE_ERR_JSON_PARSE);
          const auto target = folder_prefix + asset;
          confined(root, target);
          if (physical) physical->contains(target, false);
          if (incoming || present(root / fs::u8path(target))) require(!identity(root / fs::u8path(target)).directory, VXCORE_ERR_UNSUPPORTED);
        }
      }
    }
    for (const auto &child : node.at("folders")) {
      const auto &child_name = text(child, 255);
      children.add(child_name);
      if (physical) physical->contains(folder_prefix + child_name, true);
      else require(observed.at(child_name), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      const auto path = folder_prefix + child_name;
      relative(path);
      require(pending.size() + ids.size() < kEntries, VXCORE_ERR_UNSUPPORTED);
      pending.push_back({path, child_name});
    }
  }
  // No orphan vx.json can hide identities from the declared reachable graph.
  const auto metadata_root = root / "vx_notebook/contents";
  size_t count = 0;
  Names physical_names;
  for (fs::recursive_directory_iterator it(metadata_root), end; it != end; ++it) {
    cancelled(cancel);
    const auto path = it->path().lexically_relative(root).generic_u8string();
    require(++count <= kEntries, VXCORE_ERR_UNSUPPORTED);
    physical_names.add(path);
    confined(root, path);
    const auto actual = identity(it->path());
    if (it->path().filename() == "vx.json") require(!actual.directory && metadata_paths.count(path), VXCORE_ERR_JSON_PARSE);
    else if (fold(it->path().filename().u8string(), true) == "vx.json") throw Failure{VXCORE_ERR_UNSUPPORTED};
  }
  std::sort(result.node_ids.begin(), result.node_ids.end());
  return result;
}

struct Store {
  fs::path imports, notebooks, transaction;
  std::string id;
  VxmImportCancel *cancel;
  Store(const Json &request, VxmImportCancel *token) : cancel(token) {
    imports = absolute(text(request.at("importsRoot")));
    notebooks = absolute(text(request.at("notebooksRoot")));
    id = text(request.at("id"), 32);
    require(hex(id, 32) && imports.filename() == "imports" && notebooks.filename() == "notebooks" &&
            imports.parent_path() == notebooks.parent_path());
    require(identity(imports).directory && identity(notebooks).directory, VXCORE_ERR_UNSUPPORTED);
    transaction = imports / id;
  }
  void owned() const {
    confined(imports, id);
    require(identity(transaction).directory, VXCORE_ERR_UNSUPPORTED);
  }
  Json marker(const char *name, const std::string &kind = "") const {
    auto result = read_json(transaction / (std::string(name) + ".json"));
    require(number(result.at("version"), 1) == 1 && text(result.at("id"), 32) == id, VXCORE_ERR_JSON_PARSE);
    const auto &actual_kind = text(result.at("kind"));
    require((actual_kind == "zip" || actual_kind == "folder") && (kind.empty() || actual_kind == kind), VXCORE_ERR_JSON_PARSE);
    return result;
  }
  void validate_marker(const std::string &name, const Json &value, const std::string &kind) const {
    require(number(value.at("version"), 1) == 1 && text(value.at("id"), 32) == id && text(value.at("kind")) == kind, VXCORE_ERR_JSON_PARSE);
    if (name == "request") keys(value, {"version", "id", "kind"});
    else if (name == "captured") {
      keys(value, {"version", "id", "kind", "sourceName", "bytes", "entries"});
      text(value.at("sourceName"), 1024);
      number(value.at("bytes"), kind == "zip" ? kTree / 2 : kTree);
      number(value.at("entries"), kEntries);
    } else if (name == "prepared") {
      keys(value, {"version", "id", "kind", "treeRelative", "inventoryHash", "bytes", "entries"});
      tree_relative(text(value.at("treeRelative"), 1024));
      require(hex(text(value.at("inventoryHash"), 64), 64), VXCORE_ERR_JSON_PARSE);
      number(value.at("bytes"), kTree);
      require(number(value.at("entries"), kEntries) != 0, VXCORE_ERR_JSON_PARSE);
    } else throw Failure{VXCORE_ERR_INVALID_PARAM};
  }
  static void tree_relative(const std::string &tree) {
    relative(tree);
    require(tree == "unpacked" || (tree.compare(0, 9, "unpacked/") == 0 && tree.find('/', 9) == std::string::npos), VXCORE_ERR_UNSUPPORTED);
  }
  Json state(bool verify = true, bool committed_cleanup = false) const {
    owned();
    const auto request = marker("request");
    const auto kind = text(request.at("kind"));
    validate_marker("request", request, kind);
    Json result = {{"id", id}, {"kind", kind}, {"phase", "staged"}, {"captured", false}, {"prepared", false},
                   {"treeRelative", nullptr}, {"inventoryHash", nullptr}, {"notebookId", nullptr},
                   {"notebookName", nullptr}, {"destination", nullptr}, {"bytes", 0}, {"entries", 0}};
    if (present(transaction / "captured.json")) {
      const auto captured = marker("captured", kind);
      validate_marker("captured", captured, kind);
      result["captured"] = true;
      result["sourceName"] = captured.at("sourceName");
      result["bytes"] = captured.at("bytes");
      result["entries"] = captured.at("entries");
    }
    if (present(transaction / "prepared.json")) {
      require(result.at("captured").get<bool>(), VXCORE_ERR_INVALID_STATE);
      const auto prepared = marker("prepared", kind);
      validate_marker("prepared", prepared, kind);
      result["prepared"] = true;
      for (const auto *key : {"treeRelative", "inventoryHash", "bytes", "entries"}) result[key] = prepared.at(key);
    }
    if (!present(transaction / "publication.json")) {
      require(!present(transaction / "committed.json"), VXCORE_ERR_INVALID_STATE);
      return result;
    }
    require(result.at("prepared").get<bool>(), VXCORE_ERR_INVALID_STATE);
    const auto publication = marker("publication", kind);
    keys(publication, {"version", "id", "kind", "treeRelative", "inventoryHash", "notebookId", "notebookName", "destination", "sourceIdentity"});
    require(publication.at("treeRelative") == result.at("treeRelative") && publication.at("inventoryHash") == result.at("inventoryHash") &&
            text(publication.at("destination")) == "nb-" + id, VXCORE_ERR_JSON_PARSE);
    text(publication.at("notebookId"), 127);
    text(publication.at("notebookName"));
    // Validate identity shape even when a committed receipt authorizes only
    // private cleanup and the live notebook has legitimately disappeared.
    const auto &source_identity = publication.at("sourceIdentity");
    keys(source_identity, {"device", "low", "high"});
    for (const auto *key : {"device", "low", "high"}) number(source_identity.at(key), UINT64_MAX);
    for (const auto *key : {"notebookId", "notebookName"}) result[key] = publication.at(key);
    const auto destination = notebooks / ("nb-" + id);
    result["destination"] = destination.u8string();
    const auto tree = text(result.at("treeRelative"), 1024);
    const auto staged = transaction / fs::u8path(tree);
    if (present(transaction / "committed.json")) {
      const auto committed = marker("committed", kind);
      require(committed == publication, VXCORE_ERR_JSON_PARSE);
      result["phase"] = "committed";
      if (committed_cleanup) return result;
      confined(notebooks, "nb-" + id);
      require(present(destination) && identity(destination).matches(source_identity), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      confined(destination, "vx_notebook/config.json");
      require(read_json(destination / "vx_notebook/config.json", kResponse).at("id") == result.at("notebookId"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      return result; // Never compare a committed notebook with stale source bytes.
    }
    confined(transaction, tree);
    confined(notebooks, "nb-" + id);
    const bool source_exists = present(staged), target_exists = present(destination);
    require(source_exists != target_exists, VXCORE_ERR_INVALID_STATE);
    const auto actual = source_exists ? staged : destination;
    require(identity(actual).matches(source_identity), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    result["phase"] = source_exists ? "staged" : "published";
    if (verify) {
      const auto totals = inventory(transaction, actual, tree, text(result.at("inventoryHash"), 64), cancel, false);
      require(totals.bytes == number(result.at("bytes"), kTree) && totals.entries == number(result.at("entries"), kEntries), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      const auto inspected = inspect_metadata(actual, true, cancel, &totals);
      require(inspected.notebook_id == result.at("notebookId") && inspected.notebook_name == result.at("notebookName"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    return result;
  }
  fs::path candidate(const Json &request) const {
    const auto tree = text(request.at("treeRelative"), 1024);
    tree_relative(tree);
    confined(transaction, tree);
    // A wrapper is allowed only as the sole physical child, not as permission
    // to silently discard unrelated unpacked siblings.
    if (tree != "unpacked") {
      size_t children = 0;
      for (const auto &entry : fs::directory_iterator(transaction / "unpacked")) {
        require(entry.path().filename().u8string() == tree.substr(9) && ++children == 1, VXCORE_ERR_UNSUPPORTED);
      }
      require(children == 1, VXCORE_ERR_UNSUPPORTED);
    }
    return transaction / fs::u8path(tree);
  }
  Json inspect(const Json &request) const {
    const auto current = state(false);
    require(current.at("phase") == "staged" && current.at("prepared").get<bool>() &&
            request.at("treeRelative") == current.at("treeRelative") && request.at("inventoryHash") == current.at("inventoryHash"), VXCORE_ERR_INVALID_STATE);
    const auto root = candidate(request);
    const auto totals = inventory(transaction, root, text(request.at("treeRelative")), text(request.at("inventoryHash")), cancel, false);
    require(totals.bytes == number(current.at("bytes"), kTree) && totals.entries == number(current.at("entries"), kEntries), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    const auto result = inspect_metadata(root, true, cancel, &totals);
    return {{"notebookId", result.notebook_id}, {"notebookName", result.notebook_name}, {"nodeIds", result.node_ids}};
  }
  Json publish(const Json &request) const {
    auto current = state(false);
    require(current.at("prepared").get<bool>() && current.at("treeRelative") == request.at("treeRelative") &&
            current.at("inventoryHash") == request.at("inventoryHash"), VXCORE_ERR_INVALID_STATE);
    if (current.at("phase") != "staged") {
      require(current.at("notebookId") == request.at("notebookId") && current.at("notebookName") == request.at("notebookName"), VXCORE_ERR_INVALID_STATE);
      return current.at("phase") == "published" ? state() : current;
    }
    const auto inspected = inspect(request);
    require(inspected.at("notebookId") == request.at("notebookId") && inspected.at("notebookName") == request.at("notebookName"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    const auto source = candidate(request);
    const auto source_identity = identity(source);
    const auto target = notebooks / ("nb-" + id);
    require(!present(target), VXCORE_ERR_ALREADY_EXISTS);
    require(source_identity.device == identity(notebooks).device, VXCORE_ERR_UNSUPPORTED);
    const auto totals = inventory(transaction, source, text(request.at("treeRelative")), text(request.at("inventoryHash")), cancel, true);
    require(totals.bytes == number(current.at("bytes"), kTree) && totals.entries == number(current.at("entries"), kEntries), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    Json publication = {{"version", 1}, {"id", id}, {"kind", current.at("kind")},
                        {"treeRelative", current.at("treeRelative")}, {"inventoryHash", current.at("inventoryHash")},
                        {"notebookId", inspected.at("notebookId")}, {"notebookName", inspected.at("notebookName")},
                        {"destination", "nb-" + id}, {"sourceIdentity", source_identity.journal()}};
    cancelled(cancel);
    durable_json(transaction, "publication.json", publication);
    cancelled(cancel);
    absolute(imports.u8string());
    absolute(notebooks.u8string());
    confined(transaction, text(current.at("treeRelative")));
    require(identity(source).object(source_identity) && !present(target), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    // This rename is the commit point. From here onward cancellation cannot
    // claim rollback; a flush/response failure still requires actual-state recovery.
    rename_new(source, target);
    current["phase"] = "published";
    current["notebookId"] = inspected.at("notebookId");
    current["notebookName"] = inspected.at("notebookName");
    current["destination"] = target.u8string();
    return current;
  }
  Json write_marker(const Json &request) const {
    owned();
    const auto name = text(request.at("marker"));
    const auto &value = request.at("data");
    const auto kind = text(value.at("kind"));
    require(kind == "zip" || kind == "folder");
    validate_marker(name, value, kind);
    if (name != "request") {
      auto previous = state(false);
      require(previous.at("kind") == kind && previous.at("phase") == "staged" && !present(transaction / "publication.json"), VXCORE_ERR_INVALID_STATE);
      if (name == "prepared") {
        require(previous.at("captured").get<bool>(), VXCORE_ERR_INVALID_STATE);
        const auto root = candidate(value);
        const auto totals = inventory(transaction, root, text(value.at("treeRelative")), text(value.at("inventoryHash")), cancel, false);
        require(totals.bytes == number(value.at("bytes"), kTree) && totals.entries == number(value.at("entries"), kEntries), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      }
    } else if (!present(transaction / "request.json")) {
      for (const auto &entry : fs::directory_iterator(transaction)) require(entry.path().filename() == "request.json.tmp", VXCORE_ERR_INVALID_STATE);
    }
    cancelled(cancel);
    durable_json(transaction, name + ".json", value);
    return state(false);
  }
  Json commit() const {
    // The caller has already joined the guarded destination core owner. A
    // requested cancellation cannot interrupt admitted post-publication finish.
    Store uncancelled = *this;
    uncancelled.cancel = nullptr;
    auto current = uncancelled.state();
    require(current.at("phase") == "published" || current.at("phase") == "committed", VXCORE_ERR_INVALID_STATE);
    if (current.at("phase") == "committed") return current;
    const auto publication = marker("publication", text(current.at("kind")));
    durable_json(transaction, "committed.json", publication);
    current["phase"] = "committed";
    return current;
  }
  static void remove_private(const fs::path &path) {
    // remove_all is not used: a reparse point/link must be unlinked, never walked.
    const auto status = fs::symlink_status(path);
    bool directory = fs::is_directory(status) && !fs::is_symlink(status);
#if defined(_WIN32)
    const auto attributes = GetFileAttributesW(path.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) directory = false;
#endif
    if (directory) for (const auto &entry : fs::directory_iterator(path)) remove_private(entry.path());
    require(fs::remove(path), VXCORE_ERR_IO);
  }
  Json discard(bool allow_published) const {
    auto current = state(false, true);
    if (current.at("phase") == "published") {
      require(allow_published, VXCORE_ERR_INVALID_STATE);
      const auto publication = marker("publication", text(current.at("kind")));
      const auto target = notebooks / ("nb-" + id);
      require(identity(target).matches(publication.at("sourceIdentity")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      // Move the unregistered directory back under its original private name
      // before cleanup. A crash here recovers as staged; foreign targets are never
      // recursively deleted, and the same no-replace/identity truth table applies.
      const auto source = transaction / fs::u8path(text(current.at("treeRelative")));
      require(!present(source), VXCORE_ERR_INVALID_STATE);
      rename_new(target, source);
    }
    cancelled(cancel);
    const auto retired = imports / ("done-" + id);
    rename_new(transaction, retired);
    remove_private(retired);
    directory_flush(imports);
    return {{"discarded", true}};
  }
};
Json full_identity(const Identity &value) {
  auto out = value.journal();
  out["directory"] = value.directory;
  out["bytes"] = value.size;
  out["links"] = value.links;
  out["seconds"] = value.seconds;
  out["nanos"] = value.nanos;
  return out;
}
Json snapshot_file(const fs::path &path, uint64_t limit, const VxmImportCancel *cancel) {
  absolute(path.u8string());
  const auto before = identity(path);
  require(!before.directory && before.size <= limit, VXCORE_ERR_UNSUPPORTED);
  auto result = full_identity(before);
  result["sha256"] = hash_file(path, before.size, cancel, false, limit);
  require(identity(path) == before, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  return result;
}
Json copy_file(const fs::path &source, const fs::path &destination, uint64_t limit,
               const VxmImportCancel *cancel) {
  absolute(source.u8string());
  absolute(destination.u8string());
  require(!present(destination), VXCORE_ERR_ALREADY_EXISTS);
  File input(source);
  const auto before = input.identity();
  require(!before.directory && before.size <= limit, VXCORE_ERR_UNSUPPORTED);
  File output(destination, true);
  Hash hash;
  std::array<uint8_t, kChunk> buffer;
  uint64_t total = 0;
  for (;;) {
    cancelled(cancel);
    const auto count = input.read(buffer.data(), buffer.size());
    if (!count) break;
    require(count <= before.size - total, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    output.write(std::string_view(reinterpret_cast<const char *>(buffer.data()), count));
    hash.add(buffer.data(), count);
    total += count;
  }
  require(total == before.size && input.identity() == before && identity(source) == before,
          VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  output.flush();
  auto result = full_identity(output.identity());
  result["sha256"] = hash.finish();
  directory_flush(destination.parent_path());
  return result;
}
Json snapshot_tree(const fs::path &root, const VxmImportCancel *cancel,
                   const fs::path *copy_to = nullptr) {
  absolute(root.u8string());
  require(identity(root).directory, VXCORE_ERR_UNSUPPORTED);
  if (copy_to) {
    absolute(copy_to->u8string());
    require(!present(*copy_to) && fs::create_directory(*copy_to), VXCORE_ERR_ALREADY_EXISTS);
  }
  std::map<std::string, bool> paths;
  Names names;
  uint64_t bytes = 0;
  size_t path_bytes = 0;
  for (fs::recursive_directory_iterator it(root), end; it != end; ++it) {
    cancelled(cancel);
    const auto path = it->path().lexically_relative(root).generic_u8string();
    names.add(path);
    confined(root, path);
    const auto current = identity(it->path());
    require(paths.size() < 3 * kEntries && path.size() <= 32 * 1024 * 1024 - path_bytes,
            VXCORE_ERR_UNSUPPORTED);
    path_bytes += path.size();
    paths.emplace(path, current.directory);
  }
  Hash digest;
  for (const auto &entry : paths) {
    cancelled(cancel);
    const auto path = root / fs::u8path(entry.first);
    Json row{{"path", entry.first}, {"type", entry.second ? "directory" : "file"},
             {"size", 0}, {"sha256", ""}};
    if (entry.second) {
      require(identity(path).directory, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      if (copy_to) require(fs::create_directory(*copy_to / fs::u8path(entry.first)), VXCORE_ERR_IO);
    } else {
      const auto item = copy_to ? copy_file(path, *copy_to / fs::u8path(entry.first), kFile, cancel) :
                                 snapshot_file(path, kFile, cancel);
      const auto size = number(item.at("bytes"), kFile);
      require(size <= kTree + 128ULL * 1024 * 1024 - bytes, VXCORE_ERR_UNSUPPORTED);
      bytes += size;
      row["size"] = size;
      row["sha256"] = item.at("sha256");
    }
    const auto encoded = row.dump() + "\n";
    digest.add(reinterpret_cast<const uint8_t *>(encoded.data()), encoded.size());
  }
  // Detect additions/removals during the snapshot, including empty directories.
  size_t seen = 0;
  for (fs::recursive_directory_iterator it(root), end; it != end; ++it) {
    cancelled(cancel);
    const auto key = it->path().lexically_relative(root).generic_u8string();
    const auto found = paths.find(key);
    require(found != paths.end() && identity(it->path()).directory == found->second,
            VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    ++seen;
  }
  require(seen == paths.size(), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  if (copy_to) directory_flush(*copy_to);
  return {{"bytes", bytes}, {"entries", paths.size()}, {"sha256", digest.finish()}};
}
Json quota(const fs::path &base, uint64_t required, const VxmImportCancel *cancel) {
  constexpr uint64_t maximum = 4ULL * 1024 * 1024 * 1024;
  constexpr uint64_t headroom = 64ULL * 1024 * 1024;
  absolute(base.u8string());
  uint64_t bytes = 0;
  size_t entries = 0;
  for (const auto *group : {"imports", "exports", "cohorts", "resources"}) {
    const auto root = base / group;
    no_link(root);
    if (!present(root)) continue;
    require(identity(root).directory, VXCORE_ERR_UNSUPPORTED);
    for (fs::recursive_directory_iterator it(root), end; it != end; ++it) {
      cancelled(cancel);
      require(it.depth() <= 40 && ++entries <= 12 * kEntries, VXCORE_ERR_UNSUPPORTED);
      no_link(it->path());
      const auto item = identity(it->path());
      if (!item.directory) {
        require(item.size <= maximum - bytes, VXCORE_ERR_UNSUPPORTED);
        bytes += item.size;
      }
    }
  }
  const auto cohorts = base / "cohorts";
  if (present(cohorts)) for (const auto &entry : fs::directory_iterator(cohorts)) {
    cancelled(cancel);
    if (!identity(entry.path()).directory) continue;
    const auto intent_path = entry.path() / "intent.json";
    if (!present(intent_path)) continue;
    const auto intent = read_json(intent_path);
    keys(intent, {"version", "id", "scope", "target", "cohortId", "preparedHash", "charge", "generation",
                  "attemptIdentity", "contentIdentity", "metadataIdentity", "movedRelative"});
    const auto id = entry.path().filename().u8string();
    require(hex(id, 32) && intent.at("id") == id && intent.at("scope") == "cohort" &&
            number(intent.at("version"), 1) == 1, VXCORE_ERR_JSON_PARSE);
    const auto &target = intent.at("target");
    keys(target, {"version", "id", "notebookId", "parentId", "notebookRelative", "folderName"});
    require(target.at("id") == id && number(target.at("version"), 1) == 1, VXCORE_ERR_JSON_PARSE);
    const auto notebook_name = text(target.at("notebookRelative"), 255);
    basename(notebook_name);
    const auto notebook = base / "notebooks" / fs::u8path(notebook_name);
    const auto moved = "vx_notebook/vx_import/vnote-" + id;
    require(intent.at("movedRelative") == moved && hex(text(intent.at("preparedHash"), 64), 64),
            VXCORE_ERR_JSON_PARSE);
    const auto charge = number(intent.at("charge"), maximum);
    require(number(intent.at("generation"), 10000) != 0, VXCORE_ERR_JSON_PARSE);
    for (const auto *key : {"attemptIdentity", "contentIdentity", "metadataIdentity"}) {
      keys(intent.at(key), {"device", "low", "high"});
      for (const auto *part : {"device", "low", "high"}) number(intent.at(key).at(part), UINT64_MAX);
    }
    if (present(entry.path() / "committed.json")) {
      const auto receipt = read_json(entry.path() / "committed.json");
      require(receipt == read_json(entry.path() / "outcome.json") && receipt.at("status") == "committed" &&
              receipt.at("id") == id && receipt.at("cohortId") == intent.at("cohortId") &&
              receipt.at("preparedHash") == intent.at("preparedHash"), VXCORE_ERR_INVALID_STATE);
      continue;
    }
    const auto rollback_path = entry.path() / ("rollback-" + std::to_string(number(intent.at("generation"), 10000)) + ".json");
    if (present(rollback_path)) {
      const auto rollback = read_json(rollback_path);
      keys(rollback, {"version", "id", "scope", "intent", "status"});
      require(rollback.at("version") == 1 && rollback.at("id") == id && rollback.at("scope") == "cohort" &&
              rollback.at("intent") == intent && rollback.at("status") == "absent", VXCORE_ERR_INVALID_STATE);
      confined(notebook, moved);
      require(!present(notebook / moved), VXCORE_ERR_INVALID_STATE);
      continue; // Owner proved rollback; retained/rebuilt private bytes were scanned.
    }
    const auto attempt = entry.path() / "attempt";
    if (present(attempt)) {
      require(identity(attempt).matches(intent.at("attemptIdentity")) &&
              identity(attempt / "content").matches(intent.at("contentIdentity")) &&
              identity(attempt / "metadata").matches(intent.at("metadataIdentity")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      continue; // This complete private copy has already been counted by the scan.
    }
    absolute(notebook.u8string());
    require(read_json(notebook / "vx_notebook/config.json", kResponse).at("id") == target.at("notebookId"),
            VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    confined(notebook, moved);
    if (present(notebook / moved))
      require(identity(notebook / moved).matches(intent.at("attemptIdentity")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    // Missing wrapper is NOT rollback/commit proof: children may be in live paths.
    require(charge <= maximum - bytes, VXCORE_ERR_UNSUPPORTED);
    bytes += charge;
  }
  require(required <= maximum - bytes, VXCORE_ERR_UNSUPPORTED);
  const auto available = fs::space(base).available;
  require(required <= UINT64_MAX - headroom && available >= required + headroom, VXCORE_ERR_IO);
  return {{"availableBytes", available}, {"stagedBytes", bytes}, {"remainingBytes", maximum - bytes}};
}
Json check_space(const Store &store, uint64_t required) {
  return quota(store.imports.parent_path(), required, store.cancel);
}
struct TransferStore {
  fs::path root, notebooks, transaction;
  std::string id, scope;
  const VxmImportCancel *cancel;
  TransferStore(const Json &request, const VxmImportCancel *token) : cancel(token) {
    scope = text(request.at("scope"));
    require(scope == "cohort" || scope == "resource");
    root = absolute(text(request.at("root")));
    notebooks = absolute(text(request.at("notebooksRoot")));
    id = text(request.at("id"), 32);
    require(hex(id, 32) && root.filename() == (scope == "cohort" ? "cohorts" : "resources") &&
            notebooks.filename() == "notebooks" && root.parent_path() == notebooks.parent_path());
    require(identity(root).directory && identity(notebooks).directory, VXCORE_ERR_UNSUPPORTED);
    transaction = root / id;
  }
  void owned() const {
    confined(root, id);
    require(identity(transaction).directory, VXCORE_ERR_UNSUPPORTED);
  }
  void target(const Json &value) const {
    if (scope == "cohort") keys(value, {"version", "id", "notebookId", "parentId", "notebookRelative", "folderName"});
    else keys(value, {"version", "id", "notebookId", "nodeId", "notebookRelative"});
    require(number(value.at("version"), 1) == 1 && value.at("id") == id, VXCORE_ERR_JSON_PARSE);
    basename(text(value.at("notebookId"), 127));
    basename(text(value.at(scope == "cohort" ? "parentId" : "nodeId"), 127));
    basename(text(value.at("notebookRelative"), 255));
    if (scope == "cohort") basename(text(value.at("folderName"), 255));
  }
  Json marker(const char *name) const {
    auto value = read_json(transaction / (std::string(name) + ".json"));
    require(number(value.at("version"), 2) == (std::string(name) == "request" ? 2 : 1) &&
            value.at("id") == id && value.at("scope") == scope, VXCORE_ERR_JSON_PARSE);
    return value;
  }
  Json state() const {
    owned();
    const auto request = marker("request");
    keys(request, {"version", "id", "scope", "kind"});
    const auto kind = text(request.at("kind"));
    require(scope == "cohort" ? (kind == "file" || kind == "folder" || kind == "zip") :
            (kind == "file" || kind == "image"), VXCORE_ERR_JSON_PARSE);
    const auto pinned = read_json(transaction / "target.json");
    target(pinned);
    Json out{{"id", id}, {"scope", scope}, {"kind", kind}, {"phase", "allocated"}, {"target", pinned},
             {"captured", false}, {"source", false}, {"prepared", false}, {"intent", false},
             {"committed", false}, {"canApply", false}, {"bytes", 0}, {"entries", 0}};
    if (present(transaction / "captured.json")) {
      const auto capture = marker("captured");
      keys(capture, {"version", "id", "scope", "kind", "sourceName", "bytes", "entries"});
      require(capture.at("kind") == kind, VXCORE_ERR_JSON_PARSE);
      text(capture.at("sourceName"), 1024);
      number(capture.at("bytes"), (kind == "file" || kind == "image") ? kFile : kind == "zip" ? kTree / 2 : kTree);
      const auto count = number(capture.at("entries"), kEntries);
      require((kind != "file" && kind != "image") || count == 1, VXCORE_ERR_JSON_PARSE);
      for (const auto *key : {"sourceName", "bytes", "entries"}) out[key] = capture.at(key);
      out["captured"] = true;
      out["phase"] = "captured";
    }
    if (present(transaction / "source.json")) {
      const auto source = marker("source");
      keys(source, {"version", "id", "scope", "kind", "sourceName", "treeRelative", "inventoryHash", "bytes", "entries"});
      require(out.at("captured") == true && source.at("kind") == kind && source.at("treeRelative") == "unpacked" &&
              source.at("sourceName") == out.at("sourceName") && hex(text(source.at("inventoryHash"), 64), 64), VXCORE_ERR_JSON_PARSE);
      number(source.at("bytes"), scope == "resource" ? kFile : kTree);
      number(source.at("entries"), kEntries);
      for (const auto *key : {"bytes", "entries", "inventoryHash", "treeRelative"}) out[key] = source.at(key);
      out["source"] = true;
      out["phase"] = "source";
    }
    for (const auto *stage : {"build", "prepared"}) if (present(transaction / (std::string(stage) + ".json"))) {
      require(scope == "cohort" && out.at("source") == true, VXCORE_ERR_INVALID_STATE);
      const auto value = marker(stage);
      keys(value, {"version", "id", "scope", "target", "privateNotebookId", "cohortId", "contentRelative", "metadataRelative",
                   "contentHash", "metadataHash", "idsHash", "assetLayout", "bytes", "entries"});
      basename(text(value.at("privateNotebookId"), 127));
      basename(text(value.at("cohortId"), 127));
      relative(text(value.at("assetLayout"), 1024));
      for (const auto *key : {"contentHash", "metadataHash", "idsHash"}) require(hex(text(value.at(key), 64), 64), VXCORE_ERR_JSON_PARSE);
      number(value.at("bytes"), kTree + 128ULL * 1024 * 1024);
      number(value.at("entries"), 3 * kEntries);
      const auto folder_name = text(pinned.at("folderName"), 255);
      require(value.at("contentRelative") == (std::string(stage) == "build" ? "workbook/" + folder_name : "prepared/content") &&
              value.at("metadataRelative") == (std::string(stage) == "build" ? "workbook/vx_notebook/contents/" + folder_name : "prepared/metadata"),
              VXCORE_ERR_JSON_PARSE);
      require(value.at("target") == pinned, VXCORE_ERR_INVALID_STATE);
      text(value.at("cohortId"), 127);
      out["cohortId"] = value.at("cohortId");
      out["phase"] = std::string(stage) == "build" ? "built" : "prepared";
      if (std::string(stage) == "prepared") { out["prepared"] = true; out["canApply"] = true; }
    }
    if (present(transaction / "resource.json")) {
      require(scope == "resource", VXCORE_ERR_INVALID_STATE);
      const auto desired = marker("resource");
      keys(desired, {"version", "id", "scope", "target", "operation", "name", "newName"});
      require(desired.at("target") == pinned, VXCORE_ERR_INVALID_STATE);
      for (const auto *key : {"operation", "name", "newName"}) out[key] = desired.at(key);
      const auto operation = text(desired.at("operation"));
      basename(text(desired.at("name"), 255));
      require(operation == "add" || operation == "image" || operation == "track" || operation == "untrack" ||
              operation == "rename" || operation == "remove" || operation == "export", VXCORE_ERR_JSON_PARSE);
      if (operation == "rename") basename(text(desired.at("newName"), 255));
      else require(desired.at("newName").is_null(), VXCORE_ERR_JSON_PARSE);
      if (operation != "add" && operation != "image" && operation != "export") out["phase"] = "prepared";
      if (present(transaction / "dispatch.json")) {
        const auto dispatch = marker("dispatch");
        keys(dispatch, {"version", "id", "scope", "desired", "notePath", "assetRelative", "old", "source", "wasMember"});
        require(dispatch.at("desired") == desired && dispatch.at("wasMember").is_boolean(), VXCORE_ERR_INVALID_STATE);
        relative(text(dispatch.at("notePath"), 1024));
        relative(text(dispatch.at("assetRelative"), 1024));
        out["intent"] = true; out["phase"] = "pending";
      }
    }
    if (present(transaction / "intent.json")) {
      require(scope == "cohort" && out.at("prepared") == true, VXCORE_ERR_INVALID_STATE);
      const auto intent = marker("intent");
      keys(intent, {"version", "id", "scope", "target", "cohortId", "preparedHash", "charge", "generation",
                    "attemptIdentity", "contentIdentity", "metadataIdentity", "movedRelative"});
      require(hex(text(intent.at("preparedHash"), 64), 64) && intent.at("movedRelative") == "vx_notebook/vx_import/vnote-" + id,
              VXCORE_ERR_JSON_PARSE);
      number(intent.at("charge"), 4ULL * 1024 * 1024 * 1024);
      for (const auto *key : {"attemptIdentity", "contentIdentity", "metadataIdentity"}) {
        keys(intent.at(key), {"device", "low", "high"});
        for (const auto *part : {"device", "low", "high"}) number(intent.at(key).at(part), UINT64_MAX);
      }
      require(intent.at("target") == pinned && intent.at("cohortId") == out.at("cohortId"), VXCORE_ERR_INVALID_STATE);
      out["intent"] = true;
      out["phase"] = "pending";
      out["canApply"] = false;
      const auto generation = number(intent.at("generation"), 10000);
      require(generation != 0, VXCORE_ERR_JSON_PARSE);
      const auto rollback_path = transaction / ("rollback-" + std::to_string(generation) + ".json");
      const auto absent_path = transaction / ("absent-" + std::to_string(generation) + ".json");
      if (present(rollback_path) && present(absent_path)) {
        const auto rollback = read_json(rollback_path), absent = read_json(absent_path);
        keys(rollback, {"version", "id", "scope", "intent", "status"});
        keys(absent, {"version", "id", "scope", "status", "cohortId", "preparedHash"});
        require(rollback.at("version") == 1 && rollback.at("id") == id && rollback.at("scope") == scope &&
                absent.at("version") == 1 && absent.at("id") == id && absent.at("scope") == scope &&
                absent.at("cohortId") == out.at("cohortId"), VXCORE_ERR_JSON_PARSE);
        require(rollback.at("intent") == intent && rollback.at("status") == "absent" &&
                absent.at("status") == "absent" && absent.at("preparedHash") == intent.at("preparedHash"), VXCORE_ERR_INVALID_STATE);
        const auto moved = notebooks / fs::u8path(text(pinned.at("notebookRelative"))) / fs::u8path(text(intent.at("movedRelative")));
        absolute(moved.u8string());
        require(!present(moved), VXCORE_ERR_INVALID_STATE);
        out["canApply"] = true;
        out["phase"] = "prepared";
      }
    }
    if (present(transaction / "committed.json")) {
      const auto receipt = marker("committed");
      require(receipt == marker("outcome"), VXCORE_ERR_INVALID_STATE);
      require(scope == "cohort" ? (receipt.at("status") == "committed" && receipt.at("cohortId") == out.at("cohortId")) :
              receipt.at("committed") == true, VXCORE_ERR_INVALID_STATE);
      out["committed"] = true;
      out["phase"] = "committed";
      out["canApply"] = false;
      for (const auto *key : {"name", "relativeUrl", "path"}) if (receipt.contains(key)) out[key] = receipt.at(key);
    }
    if (present(transaction / "ready.json")) {
      require(scope == "resource", VXCORE_ERR_INVALID_STATE);
      const auto ready = marker("ready");
      keys(ready, {"version", "id", "scope", "name", "bytes", "sha256"});
      basename(text(ready.at("name"), 255));
      number(ready.at("bytes"), kTree / 2);
      require(hex(text(ready.at("sha256"), 64), 64), VXCORE_ERR_JSON_PARSE);
      for (const auto *key : {"name", "bytes", "sha256"}) out[key] = ready.at(key);
      out["operation"] = "export";
      out["phase"] = "exportReady";
    }
    return out;
  }
  Json source() const {
    const auto current = state();
    require(current.at("source") == true && current.at("prepared") == false, VXCORE_ERR_INVALID_STATE);
    const auto value = marker("source");
    const auto totals = inventory(transaction, transaction / "unpacked", "unpacked", text(value.at("inventoryHash")), cancel, false);
    require(totals.bytes == number(value.at("bytes"), kTree) && totals.entries == number(value.at("entries"), kEntries),
            VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    return value;
  }
  Json resource_source() const {
    require(scope == "resource");
    source();
    fs::path file;
    size_t count = 0;
    for (const auto &entry : fs::directory_iterator(transaction / "unpacked")) {
      require(++count == 1 && !identity(entry.path()).directory, VXCORE_ERR_UNSUPPORTED);
      file = entry.path();
    }
    require(count == 1, VXCORE_ERR_UNSUPPORTED);
    auto info = snapshot_file(file, kFile, cancel);
    return {{"name", file.filename().u8string()}, {"path", file.u8string()},
            {"bytes", info.at("bytes")}, {"sha256", info.at("sha256")}};
  }
  Json seal() const {
    require(scope == "cohort");
    auto current = state();
    if (current.at("prepared") == true) return current;
    require(current.at("phase") == "built" && !present(transaction / "intent.json"), VXCORE_ERR_INVALID_STATE);
    const auto build = marker("build");
    require(build.at("contentRelative") == "workbook/" + text(current.at("target").at("folderName")) &&
            build.at("metadataRelative") == "workbook/vx_notebook/contents/" + text(current.at("target").at("folderName")),
            VXCORE_ERR_INVALID_STATE);
    const auto ids = snapshot_file(transaction / "ids.json", kResponse, cancel);
    require(ids.at("sha256") == build.at("idsHash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    const auto prepared = transaction / "prepared";
    if (!present(prepared)) require(fs::create_directory(prepared), VXCORE_ERR_IO);
    require(identity(prepared).directory, VXCORE_ERR_UNSUPPORTED);
    for (const auto *part : {"content", "metadata"}) {
      const auto src = transaction / fs::u8path(text(build.at(std::string(part) + "Relative")));
      const auto dst = prepared / part;
      require(present(src) != present(dst), VXCORE_ERR_INVALID_STATE);
      const auto actual = snapshot_tree(present(src) ? src : dst, cancel);
      require(actual.at("sha256") == build.at(std::string(part) + "Hash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      if (present(src)) rename_new(src, dst);
    }
    auto sealed = build;
    sealed["contentRelative"] = "prepared/content";
    sealed["metadataRelative"] = "prepared/metadata";
    durable_json(transaction, "prepared.json", sealed);
    // Only the durable seal permits reclamation of redundant complete input.
    for (const auto *part : {"workbook", "engine", "unpacked", "input.zip"})
      if (present(transaction / part)) Store::remove_private(transaction / part);
    return state();
  }
  Json attempt() const {
    require(scope == "cohort");
    auto current = state();
    require(current.at("prepared") == true, VXCORE_ERR_INVALID_STATE);
    if (present(transaction / "intent.json")) return current;
    const auto prepared = marker("prepared");
    const auto charge = number(prepared.at("bytes"), kTree + 128ULL * 1024 * 1024) + 64ULL * 1024 * 1024;
    const auto path = transaction / "attempt";
    if (present(path)) Store::remove_private(path); // No intent: this is only an incomplete private derivation.
    quota(root.parent_path(), charge, cancel);
    require(fs::create_directory(path), VXCORE_ERR_IO);
    for (const auto *part : {"content", "metadata"}) {
      const auto destination = path / part;
      const auto result = snapshot_tree(transaction / "prepared" / part, cancel, &destination);
      require(result.at("sha256") == prepared.at(std::string(part) + "Hash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    const auto prepared_hash = snapshot_file(transaction / "prepared.json", kRequest, cancel).at("sha256");
    Json intent{{"version", 1}, {"id", id}, {"scope", scope}, {"target", current.at("target")},
                {"cohortId", prepared.at("cohortId")}, {"preparedHash", prepared_hash}, {"charge", charge}, {"generation", 1},
                {"attemptIdentity", identity(path).journal()}, {"contentIdentity", identity(path / "content").journal()},
                {"metadataIdentity", identity(path / "metadata").journal()},
                {"movedRelative", "vx_notebook/vx_import/vnote-" + id}};
    cancelled(cancel);
    durable_json(transaction, "intent.json", intent);
    return state();
  }
  Json receipt() const {
    auto current = state();
    if (current.at("committed") == true) return current;
    const auto outcome = marker("outcome");
    require(scope == "cohort" ? outcome.at("status") == "committed" : outcome.at("committed") == true,
            VXCORE_ERR_INVALID_STATE);
    if (scope == "cohort") require(outcome.at("cohortId") == current.at("cohortId") &&
            outcome.at("preparedHash") == marker("intent").at("preparedHash"), VXCORE_ERR_INVALID_STATE);
    durable_json(transaction, "committed.json", outcome);
    return state();
  }
  Json export_ready() const {
    require(scope == "resource");
    state();
    const auto ready = marker("ready");
    const auto name = text(ready.at("name"), 255);
    basename(name);
    const auto file = transaction / "output" / fs::u8path(name);
    const auto info = snapshot_file(file, kTree / 2, cancel);
    require(info.at("bytes") == ready.at("bytes") && info.at("sha256") == ready.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    return {{"name", name}, {"path", file.u8string()}, {"bytes", ready.at("bytes")}, {"sha256", ready.at("sha256")}};
  }
};
Json transfer_run(const Json &request, const VxmImportCancel *cancel) {
  const auto op = text(request.at("op"));
  std::set<std::string> required{"scope", "root", "notebooksRoot", "id", "op"}, optional;
  if (op == "allocate") required.insert({"kind", "target"});
  else if (op == "capture") required.insert({"sourceName", "bytes", "entries"});
  else if (op == "source") required.insert({"treeRelative", "inventoryHash", "bytes", "entries"});
  else if (op == "resetWork") optional.insert("folderName");
  else if (op == "writeResourceIntent") required.insert({"operation", "name", "newName"});
  else if (op == "checkSpace") required.insert("requiredBytes");
  else if (op == "discard") optional.insert("abandon");
  else require(op == "scan" || op == "sealCohort" || op == "prepareAttempt" || op == "recoverAttempt" ||
               op == "writeReceipt" || op == "inspectResource" || op == "finishResource" ||
               op == "exportReady" || op == "verifyExport" || op == "discardExport");
  require(request.is_object(), VXCORE_ERR_JSON_PARSE);
  for (const auto &key : required) require(request.contains(key), VXCORE_ERR_JSON_PARSE);
  for (auto it = request.begin(); it != request.end(); ++it) require(required.count(it.key()) || optional.count(it.key()), VXCORE_ERR_JSON_PARSE);
  TransferStore store(request, cancel);
  cancelled(cancel);
  if (op == "checkSpace") return quota(store.root.parent_path(), number(request.at("requiredBytes"), 4ULL * 1024 * 1024 * 1024), cancel);
  if (op == "scan") {
    Json entries = Json::array();
    size_t output_bytes = 0;
    for (const auto &entry : fs::directory_iterator(store.root)) {
      cancelled(cancel);
      const auto id = entry.path().filename().u8string();
      Json state;
      try {
        require(hex(id, 32), VXCORE_ERR_INVALID_STATE);
        auto args = request;
        args["id"] = id;
        state = TransferStore(args, cancel).state();
      } catch (const Failure &error) {
        if (error.code == VXCORE_ERR_CANCELLED) throw;
        state = {{"id", id}, {"scope", store.scope}, {"phase", "quarantined"}, {"errorCode", error.code}};
      } catch (...) {
        state = {{"id", id}, {"scope", store.scope}, {"phase", "quarantined"}, {"errorCode", VXCORE_ERR_JSON_PARSE}};
      }
      output_bytes += state.dump().size() + 1;
      require(entries.size() < 10000 && output_bytes < kResponse - 64, VXCORE_ERR_UNSUPPORTED);
      entries.push_back(std::move(state));
    }
    return {{"entries", std::move(entries)}};
  }
  if (op == "allocate") {
    const auto kind = text(request.at("kind"));
    require(store.scope == "cohort" ? (kind == "file" || kind == "zip" || kind == "folder") :
            (kind == "file" || kind == "image"));
    store.target(request.at("target"));
    quota(store.root.parent_path(), 128 * 1024, cancel);
    require(!present(store.transaction) && fs::create_directory(store.transaction), VXCORE_ERR_ALREADY_EXISTS);
    durable_json(store.transaction, "request.json", {{"version", 2}, {"id", store.id}, {"scope", store.scope}, {"kind", kind}});
    durable_json(store.transaction, "target.json", request.at("target"));
    return store.state();
  }
  auto current = store.state();
  if (op == "recoverAttempt") return current;
  if (op == "capture") {
    require(current.at("prepared") == false && current.at("intent") == false, VXCORE_ERR_INVALID_STATE);
    const auto kind = text(current.at("kind"));
    const auto bytes = number(request.at("bytes"), (kind == "file" || kind == "image") ? kFile : kind == "zip" ? kTree / 2 : kTree);
    const auto entries = number(request.at("entries"), kEntries);
    require((kind != "file" && kind != "image") || entries == 1, VXCORE_ERR_UNSUPPORTED);
    const auto name = text(request.at("sourceName"), 1024);
    if (kind == "zip") require(!identity(store.transaction / "input.zip").directory && identity(store.transaction / "input.zip").size == bytes,
                               VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    else require(identity(store.transaction / "unpacked").directory && !identity(store.transaction / "accepted.jsonl").directory,
                 VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    durable_json(store.transaction, "captured.json", {{"version", 1}, {"id", store.id}, {"scope", store.scope}, {"kind", kind},
                 {"sourceName", name}, {"bytes", bytes}, {"entries", entries}});
    return store.state();
  }
  if (op == "source") {
    require(current.at("captured") == true && current.at("prepared") == false && current.at("intent") == false &&
            request.at("treeRelative") == "unpacked", VXCORE_ERR_INVALID_STATE);
    const auto hash = text(request.at("inventoryHash"), 64);
    const auto totals = inventory(store.transaction, store.transaction / "unpacked", "unpacked", hash, cancel, true);
    require(totals.bytes == number(request.at("bytes"), store.scope == "resource" ? kFile : kTree) &&
            totals.entries == number(request.at("entries"), kEntries), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    if (current.at("kind") != "zip") {
      const auto captured = store.marker("captured");
      require(captured.at("bytes") == totals.bytes && captured.at("entries") == totals.entries, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    durable_json(store.transaction, "source.json", {{"version", 1}, {"id", store.id}, {"scope", store.scope},
                 {"kind", current.at("kind")}, {"sourceName", current.at("sourceName")}, {"treeRelative", "unpacked"},
                 {"inventoryHash", hash}, {"bytes", totals.bytes}, {"entries", totals.entries}});
    return store.state();
  }
  if (op == "resetWork") {
    require(current.at("prepared") == false && current.at("intent") == false && !present(store.transaction / "dispatch.json"), VXCORE_ERR_INVALID_STATE);
    for (const auto *name : {"workbook", "engine", "prepared", "build.json", "build.json.tmp", "ids.json", "ids.json.tmp", "preflight.json", "preflight.json.tmp"})
      if (present(store.transaction / name)) Store::remove_private(store.transaction / name);
    if (current.at("source") == false) {
      for (const auto *name : {"inventory.jsonl", "inventory.jsonl.tmp"})
        if (present(store.transaction / name)) Store::remove_private(store.transaction / name);
      if (current.at("captured") == false) {
        for (const auto *name : {"input.zip", "unpacked", "accepted.jsonl"})
          if (present(store.transaction / name)) Store::remove_private(store.transaction / name);
      } else if (current.at("kind") == "zip" && present(store.transaction / "unpacked")) Store::remove_private(store.transaction / "unpacked");
    }
    if (request.contains("folderName")) {
      require(store.scope == "cohort");
      basename(text(request.at("folderName"), 255));
      auto target = current.at("target");
      target["folderName"] = request.at("folderName");
      replace_json(store.transaction, "target.json", current.at("target"), target);
    }
    return store.state();
  }
  if (op == "sealCohort") return store.seal();
  if (op == "prepareAttempt") return store.attempt();
  if (op == "writeReceipt" || op == "finishResource") return store.receipt();
  if (op == "inspectResource") return store.resource_source();
  if (op == "writeResourceIntent") {
    require(store.scope == "resource" && !present(store.transaction / "ready.json"));
    const auto operation = text(request.at("operation"));
    require(operation == "add" || operation == "image" || operation == "track" || operation == "untrack" ||
            operation == "rename" || operation == "remove" || operation == "export");
    const auto name = text(request.at("name"), 255);
    basename(name);
    if (operation == "rename") { basename(text(request.at("newName"), 255)); require(request.at("newName") != name); }
    else require(request.at("newName").is_null());
    durable_json(store.transaction, "resource.json", {{"version", 1}, {"id", store.id}, {"scope", store.scope},
                 {"target", current.at("target")}, {"operation", operation}, {"name", name}, {"newName", request.at("newName")}});
    return store.state();
  }
  if (op == "exportReady" || op == "verifyExport") return store.export_ready();
  require(op == "discard" || op == "discardExport");
  if (request.contains("abandon")) require(request.at("abandon").is_boolean());
  const bool abandon = request.value("abandon", false);
  require(!abandon || store.scope == "resource");
  if (store.scope == "cohort" && current.at("intent") == true && current.at("committed") == false) {
    const auto intent = store.marker("intent");
    const auto generation = number(intent.at("generation"), 10000);
    const auto outcome = read_json(store.transaction / ("absent-" + std::to_string(generation) + ".json"));
    const auto rollback = read_json(store.transaction / ("rollback-" + std::to_string(generation) + ".json"));
    require(outcome.at("status") == "absent" && outcome.at("preparedHash") == intent.at("preparedHash") &&
            rollback.at("intent") == intent && rollback.at("status") == "absent", VXCORE_ERR_INVALID_STATE);
    const auto moved = store.notebooks / fs::u8path(text(intent.at("target").at("notebookRelative"))) /
                       fs::u8path(text(intent.at("movedRelative")));
    absolute(moved.u8string());
    require(!present(moved), VXCORE_ERR_INVALID_STATE);
  }
  if (store.scope == "resource" && present(store.transaction / "dispatch.json") && current.at("committed") == false)
    require(abandon, VXCORE_ERR_INVALID_STATE);
  if (op == "discardExport") require(store.scope == "resource" && !present(store.transaction / "dispatch.json") &&
      (!present(store.transaction / "resource.json") || store.marker("resource").at("operation") == "export"));
  const auto retired = store.root / ("done-" + store.id);
  rename_new(store.transaction, retired);
  Store::remove_private(retired);
  directory_flush(store.root);
  return {{"discarded", true}};
}
Json run(const Json &request, VxmImportCancel *cancel) {
  const auto op = text(request.at("op"));
  const std::set<std::string> base{"op", "importsRoot", "notebooksRoot", "id"};
  std::set<std::string> allowed = base;
  if (op == "inspect") allowed.insert({"treeRelative", "inventoryHash"});
  else if (op == "inspectManaged") allowed.insert({"location", "expectedNotebookId"});
  else if (op == "publish") allowed.insert({"treeRelative", "inventoryHash", "notebookId", "notebookName"});
  else if (op == "writeMarker") allowed.insert({"marker", "data"});
  else if (op == "discard") allowed.insert("allowPublished");
  else if (op == "checkSpace") allowed.insert("requiredBytes");
  else require(op == "recover" || op == "commit");
  for (auto it = request.begin(); it != request.end(); ++it) require(allowed.count(it.key()));
  Store store(request, cancel);
  if (op == "commit") return store.commit();
  cancelled(cancel);
  if (op == "checkSpace") return check_space(store, number(request.at("requiredBytes"), 4ULL * 1024 * 1024 * 1024));
  if (op == "inspectManaged") {
    const auto root = absolute(text(request.at("location")));
    require(root.parent_path() == store.notebooks);
    const auto result = inspect_metadata(root, false, cancel);
    if (request.contains("expectedNotebookId"))
      require(result.notebook_id == text(request.at("expectedNotebookId"), 127), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    return {{"notebookId", result.notebook_id}, {"notebookName", result.notebook_name}, {"nodeIds", result.node_ids}};
  }
  if (op == "inspect") return store.inspect(request);
  if (op == "publish") return store.publish(request);
  if (op == "recover") return store.state();
  if (op == "writeMarker") return store.write_marker(request);
  if (request.contains("allowPublished")) require(request.at("allowPublished").is_boolean());
  return store.discard(request.value("allowPublished", false));
}
int32_t import_exception_code() noexcept {
  try { throw; }
  catch (const Failure &error) { return error.code; }
  catch (const std::bad_alloc &) { return VXCORE_ERR_OUT_OF_MEMORY; }
  catch (const Json::exception &) { return VXCORE_ERR_JSON_PARSE; }
  catch (const fs::filesystem_error &) { return VXCORE_ERR_IO; }
  catch (...) { return VXCORE_ERR_UNKNOWN; }
}
}  // namespace

namespace vxm_import {
int32_t inspect_managed(const fs::path &root, const std::string &expected_id, Inspection &out) noexcept {
  try {
    auto result = inspect_metadata(root, false, nullptr);
    require(result.notebook_id == expected_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    out = std::move(result);
    return VXCORE_OK;
  } catch (...) { return import_exception_code(); }
}
int32_t TransferRun(const Json &request, const std::atomic<bool> *cancel, Json &out) noexcept {
  try {
    VxmImportCancel token;
    token.borrowed = cancel;
    require(request.dump().size() <= kRequest);
    out = transfer_run(request, &token);
    require(out.dump().size() <= kResponse, VXCORE_ERR_OUT_OF_MEMORY);
    return VXCORE_OK;
  } catch (...) { return import_exception_code(); }
}
namespace storage {
void Check(bool condition, int32_t code) { require(condition, code); }
void Name(const std::string &name) { basename(name); }
void Relative(const std::string &path) { relative(path); }
std::string Fold(const std::string &name) { return fold(name, true); }
fs::path Absolute(const std::string &path) {
  auto validated = absolute(path);
  // Directory APIs may retain a trailing separator; it is not another node.
  if (validated.has_relative_path() && validated.filename().empty()) validated = validated.parent_path();
  return validated;
}
bool Exists(const fs::path &path) { absolute(path.u8string()); return present(path); }
Json Info(const fs::path &path, bool hash, const std::atomic<bool> *cancel, uint64_t limit) {
  VxmImportCancel token;
  token.borrowed = cancel;
  absolute(path.u8string());
  return hash ? snapshot_file(path, limit, &token) : full_identity(identity(path));
}
Json ReadJson(const fs::path &path, size_t limit) { absolute(path.u8string()); return read_json(path, limit); }
std::string Read(const fs::path &path, size_t limit) { absolute(path.u8string()); return read_bytes(path, limit); }
std::string Header(const fs::path &path, size_t count) {
  require(count <= 4096);
  absolute(path.u8string());
  File input(path);
  const auto before = input.identity();
  require(!before.directory, VXCORE_ERR_UNSUPPORTED);
  std::string result(static_cast<size_t>(std::min<uint64_t>(count, before.size)), '\0');
  size_t offset = 0;
  while (offset != result.size()) {
    const auto read = input.read(reinterpret_cast<uint8_t *>(&result[offset]), result.size() - offset);
    require(read != 0, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    offset += read;
  }
  require(input.identity() == before && identity(path) == before, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  return result;
}
void Marker(const fs::path &directory, const std::string &name, const Json &value, size_t limit) {
  absolute(directory.u8string());
  basename(name);
  durable_json(directory, name, value, limit);
}
void ReplaceMarker(const fs::path &directory, const std::string &name, const Json &expected, const Json &value) {
  absolute(directory.u8string()); basename(name); replace_json(directory, name, expected, value);
}
void MakeDirectory(const fs::path &path) {
  absolute(path.u8string());
  require(!present(path) && fs::create_directory(path), VXCORE_ERR_ALREADY_EXISTS);
  directory_flush(path.parent_path());
}
void Move(const fs::path &source, const fs::path &target) {
  absolute(source.u8string()); absolute(target.u8string()); rename_new(source, target);
}
void RemovePrivate(const fs::path &path) { absolute(path.u8string()); Store::remove_private(path); }
Json Copy(const fs::path &source, const fs::path &target, uint64_t limit, const std::atomic<bool> *cancel) {
  VxmImportCancel token;
  token.borrowed = cancel;
  return copy_file(source, target, limit, &token);
}
Json Tree(const fs::path &root, const std::atomic<bool> *cancel) {
  VxmImportCancel token;
  token.borrowed = cancel;
  return snapshot_tree(root, &token);
}
Json CopyTree(const fs::path &source, const fs::path &target, const std::atomic<bool> *cancel) {
  VxmImportCancel token;
  token.borrowed = cancel;
  return snapshot_tree(source, &token, &target);
}
Json Command(const std::string &root, const std::string &scope, const std::string &op) {
  const auto path = absolute(root);
  return {{"scope", scope}, {"root", path.parent_path().u8string()},
          {"notebooksRoot", (path.parent_path().parent_path() / "notebooks").u8string()},
          {"id", path.filename().u8string()}, {"op", op}};
}
Json Transaction(const std::string &root, const std::string &scope) {
  return TransferStore(Command(root, scope, "recoverAttempt"), nullptr).state();
}
Inspection Inspect(const fs::path &root, const std::string &expected_id, bool pending) {
  auto out = inspect_metadata(root, false, nullptr, nullptr, pending);
  require(out.notebook_id == expected_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  return out;
}
int32_t ErrorCode() noexcept { return import_exception_code(); }
}  // namespace storage
}  // namespace vxm_import

extern "C" {
VxmImportCancel *vxm_import_cancel_create(void) {
  return new (std::nothrow) VxmImportCancel;
}
void vxm_import_cancel_request(VxmImportCancel *cancel) {
  if (cancel) cancel->requested.store(true, std::memory_order_relaxed);
}
int32_t vxm_import_cancel_query(const VxmImportCancel *cancel) {
  return cancel && cancel->requested.load(std::memory_order_relaxed) ? 1 : 0;
}
void vxm_import_cancel_free(VxmImportCancel *cancel) { delete cancel; }
int32_t vxm_import_path_keys(const uint8_t *input, uint64_t size,
                            uint8_t *nfc, uint64_t nfc_capacity, uint64_t *nfc_size,
                            uint8_t *nfd, uint64_t nfd_capacity, uint64_t *nfd_size) {
  if (nfc_size) *nfc_size = 0;
  if (nfd_size) *nfd_size = 0;
  try {
    require(nfc_size && nfd_size && (input || !size), VXCORE_ERR_NULL_POINTER);
    require(size <= 1024);
    const std::string_view value(size ? reinterpret_cast<const char *>(input) : "", static_cast<size_t>(size));
    const auto composed = fold(value, true), decomposed = fold(value, false);
    *nfc_size = composed.size();
    *nfd_size = decomposed.size();
    require(nfc_capacity >= composed.size() && nfd_capacity >= decomposed.size());
    require((nfc || composed.empty()) && (nfd || decomposed.empty()), VXCORE_ERR_NULL_POINTER);
    if (!composed.empty()) std::memcpy(nfc, composed.data(), composed.size());
    if (!decomposed.empty()) std::memcpy(nfd, decomposed.data(), decomposed.size());
    return VXCORE_OK;
  } catch (...) { return import_exception_code(); }
}
int32_t vxm_import_run(const char *request_json, VxmImportCancel *cancel, char **out_json) {
  if (out_json) *out_json = nullptr;
  try {
    require(request_json && out_json, VXCORE_ERR_NULL_POINTER);
    size_t size = 0;
    while (size <= kRequest && request_json[size]) ++size;
    require(size <= kRequest);
    const auto request = parse(std::string_view(request_json, size), kRequest);
    // Reserve terminal storage before any mutation. Serialization allocations
    // can still fail after rename: callers must recover, never infer rollback.
    std::unique_ptr<char[]> result(new char[kResponse + 1]);
    const auto encoded = run(request, cancel).dump();
    require(encoded.size() <= kResponse, VXCORE_ERR_OUT_OF_MEMORY);
    std::memcpy(result.get(), encoded.c_str(), encoded.size() + 1);
    *out_json = result.release();
    return VXCORE_OK;
  } catch (...) { return import_exception_code(); }
}
int32_t vxm_transfer_run(const char *request_json, VxmImportCancel *cancel, char **out_json) {
  if (out_json) *out_json = nullptr;
  try {
    require(request_json && out_json, VXCORE_ERR_NULL_POINTER);
    size_t size = 0;
    while (size <= kRequest && request_json[size]) ++size;
    require(size <= kRequest);
    const auto request = parse(std::string_view(request_json, size), kRequest);
    std::unique_ptr<char[]> result(new char[kResponse + 1]);
    const auto encoded = transfer_run(request, cancel).dump();
    require(encoded.size() <= kResponse, VXCORE_ERR_OUT_OF_MEMORY);
    std::memcpy(result.get(), encoded.c_str(), encoded.size() + 1);
    *out_json = result.release();
    return VXCORE_OK;
  } catch (...) { return import_exception_code(); }
}
void vxm_import_result_free(char *result) { delete[] result; }
}  // extern "C"
