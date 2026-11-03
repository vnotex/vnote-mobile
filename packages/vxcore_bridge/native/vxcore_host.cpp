// SPDX-License-Identifier: LGPL-3.0-only
#include "vxcore_host.h"
#include "notebook_import.h"
#include "notebook_transfers.h"
#include "editor_drafts.h"
#include "notebook_preview.h"
#include "notebook_sync.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <string>
#include <string_view>
#include <thread>
#include <vector>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
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
constexpr size_t kOwnerSummary = 64 * 1024;
constexpr size_t kCatalog = VXM_MAX_CATALOG_BYTES;
// Every terminal owns bounded metadata, including terminals taken past close.
constexpr size_t kMetadata = 2 * (kString + 1) + 3 * 128 + 65 + 64;
constexpr uint64_t kMaxRevision = 9007199254740991ULL;
// Core's UUID generator has process-global mutable state. Serialize owner jobs
// across hosts too; control/event delivery never acquires this disk-operation gate.
std::mutex core_owner_gate;
// Accessed only under core_owner_gate, never from control/cancellation calls.
std::set<fs::path> owned_notebooks;

struct Failure { int32_t code; const char *message = nullptr; };
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
// input_string has already validated UTF-8 and bounded this metadata string.
void display_name(const std::string &name) {
  bool nonblank = false;
  for (size_t i = 0; i < name.size();) {
    uint32_t value = static_cast<uint8_t>(name[i++]);
    unsigned continuation = 0;
    if (value >= 0xf0) { continuation = 3; value &= 7; }
    else if (value >= 0xe0) { continuation = 2; value &= 15; }
    else if (value >= 0xc0) { continuation = 1; value &= 31; }
    while (continuation--) value = (value << 6) | (static_cast<uint8_t>(name[i++]) & 63);
    require(value >= 32 && !(value >= 0x7f && value <= 0x9f));
    const bool space = value == 0x20 || value == 0xa0 || value == 0x1680 ||
        (value >= 0x2000 && value <= 0x200a) || value == 0x2028 || value == 0x2029 ||
        value == 0x202f || value == 0x205f || value == 0x3000 || value == 0xfeff;
    nonblank |= !space;
  }
  require(nonblank);
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
void safe_tree(const fs::path &path, const std::atomic<bool> *cancelled = nullptr) {
  require(!cancelled || !cancelled->load(std::memory_order_relaxed), VXCORE_ERR_CANCELLED);
  no_link(path);
  if (!fs::exists(path) || !fs::is_directory(path)) return;
  for (const auto &entry : fs::recursive_directory_iterator(path)) {
    require(!cancelled || !cancelled->load(std::memory_order_relaxed), VXCORE_ERR_CANCELLED);
    no_link(entry.path());
  }
}

constexpr uint64_t kExportSource = 1024ULL * 1024 * 1024;
constexpr uint64_t kExportStaging = 4ULL * 1024 * 1024 * 1024 - 128 * 1024;
constexpr uint64_t kExportHeadroom = 64ULL * 1024 * 1024;
constexpr size_t kExportSummary = 1024;
constexpr size_t kExportEntries = 100000;
constexpr size_t kExportChunk = 256 * 1024;
void export_require(bool condition, const char *reason, int32_t code = VXCORE_ERR_UNSUPPORTED) {
  if (!condition) throw Failure{code, reason};
}
void export_cancelled(const std::atomic<bool> *cancelled) {
  require(!cancelled || !cancelled->load(std::memory_order_relaxed), VXCORE_ERR_CANCELLED);
}
void export_name(const std::string &name) {
  export_require(!name.empty() && name.size() <= 255 && name != "." && name != ".." &&
                 utf8(reinterpret_cast<const uint8_t *>(name.data()), name.size()),
                 "Export refused an invalid or oversized filename");
  for (size_t i = 0; i < name.size(); ++i) {
    const auto c = static_cast<unsigned char>(name[i]);
    export_require(c >= 32 && c != 127 && c != '\\' && c != '/' && c != ':',
                   "Export refused an ambiguous or control-character filename");
    if (c == 0xc2 && i + 1 < name.size()) {
      const auto next = static_cast<unsigned char>(name[i + 1]);
      export_require(next < 0x80 || next > 0x9f, "Export refused a control-character filename");
    }
  }
}
void export_relative(const std::string &relative) {
  export_require(!relative.empty() && relative.size() <= 1024,
                 "Export exceeds the relative path limit");
  relative_path(relative);
  size_t depth = 0;
  for (const auto &part : fs::u8path(relative)) {
    export_name(part.u8string());
    export_require(++depth <= 32, "Export exceeds the directory depth limit");
  }
}
// The operation validates absolute ancestors at its phase boundaries. Recheck
// the anchored root and every relative component before each access, without
// restatting the same OS/application ancestors for every inventory entry.
void export_confined(const fs::path &root, const std::string &relative) {
  relative_path(relative);
  auto current = root;
  no_link(current);
  for (const auto &part : fs::u8path(relative)) { current /= part; no_link(current); }
}
void export_reserved_spelling(const fs::path &root, const std::string &relative) {
  // On case-insensitive filesystems, a differently spelled reserved directory
  // still belongs to core. Refuse that alias instead of copying runtime secrets.
  // Distinct spellings on a case-sensitive filesystem remain ordinary data.
  for (const auto *reserved : {"vx_notebook", "vx_notebook/vx_sync", "vx_notebook/vx_import", "vx_notebook/vx_transfer"}) {
    const std::string_view expected(reserved);
    if (relative.size() != expected.size() || std::string_view(relative) == expected) continue;
    bool matches = true;
    for (size_t i = 0; i < relative.size(); ++i) {
      auto c = relative[i];
      if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
      if (c != expected[i]) { matches = false; break; }
    }
    if (!matches) continue;
    std::error_code error;
    const bool alias = fs::equivalent(root / fs::u8path(relative), root / fs::u8path(reserved), error);
    export_require(!alias, "Export refuses ambiguous reserved runtime directory spelling");
    export_require(!error || error == std::errc::no_such_file_or_directory,
                   "Export could not classify a reserved runtime path", VXCORE_ERR_IO);
  }
}
// Deliberately no case folding or Unicode normalization of portable filenames.
// A native handle checks the final component without following it. Parent paths
// are checked immediately before access; this detects ordinary outside changes,
// not an adversarial filesystem snapshot.
struct ExportIdentity {
  uint64_t device = 0, inode = 0, size = 0, links = 0;
  int64_t seconds = 0, nanos = 0;
  bool directory = false;
  bool same_object(const ExportIdentity &other) const {
    return device == other.device && inode == other.inode && directory == other.directory;
  }
  bool operator==(const ExportIdentity &other) const {
    return same_object(other) && size == other.size && links == other.links &&
           seconds == other.seconds && nanos == other.nanos;
  }
};
struct ExportFile {
#if defined(_WIN32)
  HANDLE handle = INVALID_HANDLE_VALUE;
#else
  int handle = -1;
#endif
  ExportFile(const fs::path &path, bool output = false, bool directory = false) {
#if defined(_WIN32)
    handle = CreateFileW(path.c_str(), output ? GENERIC_WRITE : directory ? FILE_READ_ATTRIBUTES : GENERIC_READ,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                         output ? CREATE_NEW : OPEN_EXISTING,
                         FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), nullptr);
    export_require(handle != INVALID_HANDLE_VALUE, "Export could not safely open a file", VXCORE_ERR_IO);
#else
    const int flags = output ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY | O_NONBLOCK;
    handle = ::open(path.c_str(), flags | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0), 0600);
    export_require(handle >= 0, "Export could not safely open a file", VXCORE_ERR_IO);
#endif
  }
  ExportFile(const ExportFile &) = delete;
  ExportFile &operator=(const ExportFile &) = delete;
  ~ExportFile() {
#if defined(_WIN32)
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
#else
    if (handle >= 0) ::close(handle);
#endif
  }
  ExportIdentity identity() const {
    ExportIdentity result;
#if defined(_WIN32)
    BY_HANDLE_FILE_INFORMATION info{};
    export_require(GetFileInformationByHandle(handle, &info) != 0,
                   "Export could not inspect a file", VXCORE_ERR_IO);
    export_require(!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && GetFileType(handle) == FILE_TYPE_DISK,
                   "Export refuses links, reparse points, and special files");
    result.device = info.dwVolumeSerialNumber;
    result.inode = (uint64_t(info.nFileIndexHigh) << 32) | info.nFileIndexLow;
    result.size = (uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    result.links = info.nNumberOfLinks;
    result.seconds = (uint64_t(info.ftLastWriteTime.dwHighDateTime) << 32) | info.ftLastWriteTime.dwLowDateTime;
    result.directory = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
#else
    struct stat info{};
    export_require(::fstat(handle, &info) == 0, "Export could not inspect a file", VXCORE_ERR_IO);
    export_require(S_ISREG(info.st_mode) || S_ISDIR(info.st_mode), "Export refuses special files");
    result.device = info.st_dev;
    result.inode = info.st_ino;
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
    export_require(result.directory || result.links == 1, "Export refuses hard-linked files");
    return result;
  }
  size_t read(uint8_t *buffer, size_t count) {
#if defined(_WIN32)
    DWORD received = 0;
    export_require(ReadFile(handle, buffer, static_cast<DWORD>(count), &received, nullptr) != 0,
                   "Export could not read a source file", VXCORE_ERR_IO);
    return received;
#else
    ssize_t received;
    do { received = ::read(handle, buffer, count); } while (received < 0 && errno == EINTR);
    export_require(received >= 0, "Export could not read a source file", VXCORE_ERR_IO);
    return static_cast<size_t>(received);
#endif
  }
  void write(const uint8_t *buffer, size_t count) {
    while (count) {
#if defined(_WIN32)
      DWORD written = 0;
      export_require(WriteFile(handle, buffer, static_cast<DWORD>(count), &written, nullptr) != 0 && written,
                     "Export could not write staging storage", VXCORE_ERR_IO);
#else
      ssize_t written;
      do { written = ::write(handle, buffer, count); } while (written < 0 && errno == EINTR);
      export_require(written > 0, "Export could not write staging storage", VXCORE_ERR_IO);
#endif
      buffer += written;
      count -= written;
    }
  }
  // Transient snapshot data needs a checked close, not per-file durability sync.
  // The controller publishes and flushes the completed ZIP separately.
  void finish() {
#if defined(_WIN32)
    const auto old = handle;
    handle = INVALID_HANDLE_VALUE;
    export_require(CloseHandle(old) != 0, "Export could not close staging storage", VXCORE_ERR_IO);
#else
    const auto old = handle;
    handle = -1;
    export_require(::close(old) == 0, "Export could not close staging storage", VXCORE_ERR_IO);
#endif
  }
};
ExportIdentity export_identity(const fs::path &path) {
#if defined(_WIN32)
  // Attribute access with BACKUP_SEMANTICS works for both files and directories.
  // The no-follow handle supplies type, reparse, hardlink and identity checks in
  // one inspection; separate symlink_status/GetFileAttributes calls duplicate it.
  ExportFile file(path, false, true);
#else
  const auto status = fs::symlink_status(path);
  export_require(fs::is_regular_file(status) || fs::is_directory(status),
                 "Export refuses missing entries and special files");
  ExportFile file(path, false, fs::is_directory(status));
#endif
  return file.identity();
}

Json export_json(const fs::path &path, const ExportIdentity &expected,
                 const std::atomic<bool> *cancelled = nullptr) {
  export_require(!expected.directory && expected.size <= kJson,
                 "Export requires bounded regular JSON metadata");
  ExportFile input(path);
  require(input.identity() == expected, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  std::string raw(static_cast<size_t>(expected.size), '\0');
  size_t offset = 0;
  while (offset < raw.size()) {
    export_cancelled(cancelled);
    const auto count = input.read(reinterpret_cast<uint8_t *>(raw.data() + offset),
                                  std::min(kExportChunk, raw.size() - offset));
    require(count != 0, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    offset += count;
  }
  uint8_t extra;
  require(input.read(&extra, 1) == 0 && input.identity() == expected && export_identity(path) == expected,
          VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  auto json = Json::parse(raw, nullptr, false);
  require(json.is_object(), VXCORE_ERR_JSON_PARSE);
  return json;
}
struct ExportResources { std::string assets = "vx_assets", recycle = "vx_notebook/recycle_bin"; };
ExportResources export_resources(const fs::path &root, const Json &config) {
  ExportResources result;
  for (const auto *key : {vxcore::kJsonKeyAssetsFolder, vxcore::kJsonKeyRecycleBinFolder}) {
    const auto found = config.find(key);
    auto &resource = key == vxcore::kJsonKeyAssetsFolder ? result.assets : result.recycle;
    if (found != config.end()) {
      require(found->is_string(), VXCORE_ERR_JSON_PARSE);
      if (key == vxcore::kJsonKeyAssetsFolder || !found->get_ref<const std::string &>().empty())
        resource = found->get<std::string>();
    }
    export_relative(resource);
    confined(root, resource);
    for (const auto *excluded : {"vx_notebook/vx_sync", "vx_notebook/vx_import", "vx_notebook/vx_transfer"}) {
      const std::string prefix(excluded);
      export_require(resource != prefix && resource.compare(0, prefix.size() + 1, prefix + "/") != 0,
                     "Export refuses resources stored in excluded runtime directories");
    }
    const auto status = fs::symlink_status(root / fs::u8path(resource));
    export_require(!fs::exists(status) || fs::is_directory(status), "Export requires self-contained resource directories");
  }
  return result;
}

bool export_within(const fs::path &path, const fs::path &root) {
  auto p = path.begin();
  for (auto r = root.begin(); r != root.end(); ++r, ++p) {
    if (p == path.end()) return false;
#if defined(_WIN32)
    if (CompareStringOrdinal(p->c_str(), -1, r->c_str(), -1, TRUE) != CSTR_EQUAL) return false;
#else
    if (*p != *r) return false;
#endif
  }
  return true;
}
// Core automatically recovers these journals on open. Refuse before catalog open
// as well as before capture, so an export owner cannot trigger source recovery.
void export_journals(const fs::path &root, const std::atomic<bool> *cancelled = nullptr) {
  for (const auto *name : {"vx_import", "vx_transfer"}) {
    const auto path = root / "vx_notebook" / name;
    confined(root, std::string("vx_notebook/") + name);
    if (!fs::exists(fs::symlink_status(path))) continue;
    export_require(fs::is_directory(path), "Export requires import and transfer recovery to be resolved");
    size_t entries = 0;
    for (const auto &entry : fs::recursive_directory_iterator(path)) {
      export_cancelled(cancelled);
      no_link(entry.path());
      export_relative(entry.path().lexically_relative(root).generic_u8string());
      export_require(++entries <= kExportEntries && fs::is_directory(entry.symlink_status()),
                     "Export requires import and transfer recovery to be resolved");
    }
  }
}
void export_credentials(const Json &config) {
  const auto inspect = [](const Json &object) {
    if (!object.is_object()) return;
    for (const auto *key : {"credentials", "syncCredentials", "personalAccessToken", "pat", "password"})
      export_require(!object.contains(key), "Export refuses recognized credential fields in notebook configuration");
    const auto remote = object.find("syncRemoteUrl");
    if (remote == object.end()) return;
    export_require(remote->is_string(), "Export refuses malformed synchronization routing metadata");
    const auto &url = remote->get_ref<const std::string &>();
    const auto query = url.find('?');
    const auto fragment = url.find('#');
    export_require((query == std::string::npos || query + 1 == url.size() || query + 1 == fragment) &&
                   (fragment == std::string::npos || fragment + 1 == url.size()),
                   "Export refuses credential-bearing synchronization URLs");
    const auto scheme = url.find("://");
    const auto start = scheme == std::string::npos ? 0 : scheme + 3;
    const auto end = url.find_first_of("/?#", start);
    const auto at = url.rfind('@', end == std::string::npos ? url.size() : end);
    if (at == std::string::npos || at < start) return;
    for (size_t i = start; i < at; ++i) {
      unsigned char c = static_cast<unsigned char>(url[i]);
      if (c == '%' && i + 2 < at) {
        const auto digit = [](char value) -> int {
          if (value >= '0' && value <= '9') return value - '0';
          if (value >= 'a' && value <= 'f') return value - 'a' + 10;
          if (value >= 'A' && value <= 'F') return value - 'A' + 10;
          return -1;
        };
        const int hi = digit(url[i + 1]), lo = digit(url[i + 2]);
        if (hi >= 0 && lo >= 0) { c = static_cast<unsigned char>(hi * 16 + lo); i += 2; }
      }
      export_require(c != ':', "Export refuses password-bearing synchronization URLs");
    }
  };
  inspect(config);
  const auto metadata = config.find("metadata");
  if (metadata != config.end()) inspect(*metadata);
}
const char *export_redacted(int32_t code) {
  switch (code) {
    case VXCORE_OK: return "Notebook snapshot completed";
    case VXCORE_ERR_CANCELLED: return "Notebook export was cancelled; the original notebook was not changed";
    case VXCORE_ERR_FILE_CHANGED_OUTSIDE: return "Notebook export stopped because source files changed; retry after other writers stop";
    case VXCORE_ERR_UNSUPPORTED: return "Notebook export refused an unsafe link, filename, or unsupported layout";
    case VXCORE_ERR_JSON_PARSE: return "Notebook export refused malformed notebook configuration";
    case VXCORE_ERR_IO: return "Notebook export could not read source or write staging storage";
    default: return "Notebook export failed; the original notebook was not changed";
  }
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
    case VXCORE_ERR_CANCELLED: return "The operation was cancelled";
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

// JSON input has one bounded, validated shape before it can consume a request ID.
enum CatalogOperation { kSearch = 1, kTags, kCreateTag, kSetTags, kCollectNodeIds };
const std::string &json_string(const Json &value, bool empty = false,
                               int32_t code = VXCORE_ERR_JSON_PARSE) {
  require(value.is_string(), code);
  const auto &text = value.get_ref<const std::string &>();
  require((empty || !text.empty()) && text.size() <= kString &&
          text.find('\0') == std::string::npos &&
          utf8(reinterpret_cast<const uint8_t *>(text.data()), text.size()), code);
  return text;
}

bool export_under(std::string_view path, std::string_view prefix) {
  return path == prefix || (path.size() > prefix.size() &&
      path.compare(0, prefix.size(), prefix) == 0 && path[prefix.size()] == '/');
}
bool export_overlap(std::string_view path, std::string_view excluded) {
  return export_under(path, excluded) || export_under(excluded, path);
}
void export_unprotected(const Json &record) {
  require(record.is_object(), VXCORE_ERR_JSON_PARSE);
  const auto flag = [](const Json &object) {
    const auto value = object.find(vxcore::kJsonKeyEncrypted);
    if (value == object.end()) return;
    require(value->is_boolean(), VXCORE_ERR_JSON_PARSE);
    export_require(!value->get<bool>(), "Files and assets export refuses protected content; use a notebook backup");
  };
  flag(record);
  const auto metadata = record.find(vxcore::kJsonKeyMetadata);
  if (metadata != record.end()) {
    require(metadata->is_object(), VXCORE_ERR_JSON_PARSE);
    flag(*metadata);
  }
}
struct ExportEntry { std::string relative; ExportIdentity identity; bool selected; };
// Reuse the import boundary's pure Unicode keys, not a second folding policy.
// Buffers are reused for every path; only retained collision keys allocate.
struct ExportPathKeys {
  std::array<uint8_t, 16384> nfc, nfd;
  std::string_view composed, decomposed;
  void set(const std::string &path) {
    uint64_t nfc_size = 0, nfd_size = 0;
    check(static_cast<VxCoreError>(vxm_import_path_keys(
        reinterpret_cast<const uint8_t *>(path.data()), path.size(),
        nfc.data(), nfc.size(), &nfc_size, nfd.data(), nfd.size(), &nfd_size)));
    composed = {reinterpret_cast<const char *>(nfc.data()), static_cast<size_t>(nfc_size)};
    decomposed = {reinterpret_cast<const char *>(nfd.data()), static_cast<size_t>(nfd_size)};
  }
};
void export_content_metadata(const fs::path &root, const std::vector<ExportEntry> &entries,
                             const ExportResources &resources, const std::string &notebook_id,
                             const std::atomic<bool> *cancelled) {
  std::map<std::string_view, const ExportEntry *, std::less<>> inventory;
  for (const auto &entry : entries) inventory.emplace(entry.relative, &entry);
  // Missing lazy assets are allowed, but aliases and omitted ancestors are not.
  // The same classified inventory authorizes live files, folders and attachments.
  const auto selected = [&](const std::string &path, bool directory, bool optional = false,
                            bool resource_root = false) {
    export_relative(path);
    export_require(!export_overlap(path, "vx_notebook") && !export_under(path, resources.recycle) &&
                       (resource_root || !export_under(resources.recycle, path)),
                   "Files and assets export refuses live content overlapping omitted metadata or recycle data");
    size_t end = 0;
    for (;;) {
      export_cancelled(cancelled);
      end = path.find('/', end);
      const auto component = std::string_view(path).substr(0, end);
      const auto found = inventory.find(component);
      if (found == inventory.end()) {
        const auto relative = std::string(component);
        export_confined(root, relative);
        export_require(!fs::exists(fs::symlink_status(root / fs::u8path(relative))),
                       "Files and assets export refuses differently spelled live content or asset paths");
        export_require(optional, "Files and assets export requires every declared live file, folder and attachment");
      } else {
        export_require(found->second->selected && found->second->identity.directory ==
                           (end == std::string::npos ? directory : true),
                       "Files and assets export requires selected live content and asset ancestors");
      }
      if (end == std::string::npos) return;
      ++end;
    }
  };
  // Validate configured assets even for an empty notebook. Its root can contain
  // a separate recycle subtree, but cannot itself be omitted or alias metadata.
  selected(resources.assets, true, true, true);
  ExportPathKeys keys;
  std::set<std::string> metadata_nfc, metadata_nfd;
  std::set<std::string_view> physical_metadata;
  constexpr std::string_view contents = "vx_notebook/contents";
  for (const auto &entry : entries) {
    export_cancelled(cancelled);
    if (!export_under(entry.relative, "vx_notebook")) continue;
    keys.set(entry.relative);
    if (!export_under(keys.composed, contents)) continue;
    export_require(export_under(entry.relative, contents),
                   "Files and assets export refuses aliased notebook metadata paths");
    export_require(metadata_nfc.emplace(keys.composed).second && metadata_nfd.emplace(keys.decomposed).second,
                   "Files and assets export refuses case or Unicode aliases in notebook metadata");
    const auto name = fs::u8path(entry.relative).filename().u8string();
    keys.set(name);
    if (keys.composed != "vx.json" && keys.decomposed != "vx.json") continue;
    export_require(name == "vx.json" && !entry.identity.directory,
                   "Files and assets export refuses aliased or invalid vx.json metadata");
    physical_metadata.insert(entry.relative);
  }
  std::set<std::string> declared_metadata{"vx_notebook/contents/vx.json"};
  std::set<std::string> ids;
  size_t records = 0;
  const auto node_id = [&](const Json &record) -> const std::string & {
    const auto &id = json_string(record.at(vxcore::kJsonKeyId));
    basename(id);
    require(id.size() < 128 && id != notebook_id && ids.insert(id).second, VXCORE_ERR_JSON_PARSE);
    export_require(++records <= kExportEntries, "Files and assets export exceeds the metadata record limit");
    return id;
  };
  for (const auto &path : physical_metadata) {
    export_cancelled(cancelled);
    const auto &entry = *inventory.at(path);
    export_confined(root, entry.relative);
    const auto record = export_json(root / fs::u8path(path), entry.identity, cancelled);
    export_unprotected(record);
    node_id(record);
    // Every raw record is checked, including orphans. Safe child basenames make
    // edges strictly deeper; equality of incoming and physical records below
    // therefore proves the complete graph is reachable from its sole root.
    const auto folder_prefix = std::string(path.substr(contents.size() + 1,
        path.size() - contents.size() - 1 - std::string_view("vx.json").size()));
    const auto folder = folder_prefix.empty() ? std::string() : folder_prefix.substr(0, folder_prefix.size() - 1);
    const auto &name = json_string(record.at(vxcore::kJsonKeyName), folder.empty());
    if (!folder.empty()) {
      require(name == fs::u8path(folder).filename().u8string(), VXCORE_ERR_JSON_PARSE);
      selected(folder, true);
    }
    const auto &files = record.at(vxcore::kJsonKeyFiles);
    const auto &folders = record.at(vxcore::kJsonKeyFolders);
    require(files.is_array() && folders.is_array(), VXCORE_ERR_JSON_PARSE);
    export_require(files.size() <= kExportEntries && folders.size() <= kExportEntries,
                   "Files and assets export exceeds the metadata record limit");
    std::set<std::string> names_nfc, names_nfd;
    const auto child_name = [&](const Json &value) -> const std::string & {
      const auto &child = json_string(value);
      basename(child);
      keys.set(child);
      export_require(names_nfc.emplace(keys.composed).second && names_nfd.emplace(keys.decomposed).second,
                     "Files and assets export refuses case or Unicode aliases in declared content");
      return child;
    };
    for (const auto &file : files) {
      export_cancelled(cancelled);
      export_unprotected(file);
      const auto &id = node_id(file);
      const auto &file_name = child_name(file.at(vxcore::kJsonKeyName));
      selected(folder_prefix + file_name, false);
      const auto asset = resources.assets + "/" + id;
      const auto assets_path = folder_prefix + asset;
      const auto attachments = file.find(vxcore::kJsonKeyAttachments);
      if (attachments != file.end()) require(attachments->is_array(), VXCORE_ERR_JSON_PARSE);
      const bool required = attachments != file.end() && !attachments->empty();
      selected(assets_path, true, !required);
      if (!required) continue;
      std::set<std::string> attachment_names;
      for (const auto &attachment : *attachments) {
        export_cancelled(cancelled);
        const auto &reference = json_string(attachment);
        export_relative(reference);
        const auto slash = reference.rfind('/');
        const auto attachment_name = reference.substr(slash == std::string::npos ? 0 : slash + 1);
        basename(attachment_name);
        require(attachment_names.insert(attachment_name).second, VXCORE_ERR_JSON_PARSE);
        export_require(slash == std::string::npos || reference == asset + "/" + attachment_name,
                       "Files and assets export refuses attachments outside their note asset directory");
        selected(assets_path + "/" + attachment_name, false);
      }
    }
    for (const auto &child : folders) {
      export_cancelled(cancelled);
      const auto &child_value = child_name(child);
      const auto child_path = folder_prefix + child_value;
      selected(child_path, true);
      export_relative(child_path);
      export_require(declared_metadata.size() < kExportEntries,
                     "Files and assets export exceeds the metadata record limit");
      require(declared_metadata.insert(std::string(contents) + "/" + child_path + "/vx.json").second,
              VXCORE_ERR_JSON_PARSE);
    }
  }
  export_require(declared_metadata.size() == physical_metadata.size() &&
                 std::equal(declared_metadata.begin(), declared_metadata.end(), physical_metadata.begin()),
                 "Files and assets export refuses missing or orphan notebook metadata");
}
void tag_names(const Json &tags, int32_t code = VXCORE_ERR_JSON_PARSE) {
  require(tags.is_array() && tags.size() <= 10000, code);
  std::set<std::string_view> names;
  for (const auto &tag : tags)
    require(names.insert(json_string(tag, false, code)).second, code);
}
int32_t catalog_operation(const uint8_t *data, size_t size, int32_t kind) {
  require(size && size <= kString);
  const auto json = Json::parse(data, data + size, nullptr, false);
  require(json.is_object() && json.contains("op"));
  const auto &op = json_string(json.at("op"), false, VXCORE_ERR_INVALID_PARAM);
  int32_t operation = 0;
  if (kind == VXM_EVENT_QUERY && op == "search") {
    const auto &text = json_string(json.at("text"), true, VXCORE_ERR_INVALID_PARAM);
    require(json.contains("caseSensitive") && json.at("caseSensitive").is_boolean());
    const bool tagged = json.contains("tag");
    if (tagged) json_string(json.at("tag"), false, VXCORE_ERR_INVALID_PARAM);
    require(!text.empty() || tagged);
    operation = kSearch;
  } else if (kind == VXM_EVENT_QUERY && op == "tags") {
    operation = kTags;
  } else if (kind == VXM_EVENT_QUERY && op == "collectNodeIds") {
    operation = kCollectNodeIds;
  } else if (kind == VXM_EVENT_TAG && op == "createTag") {
    json_string(json.at("name"), false, VXCORE_ERR_INVALID_PARAM);
    operation = kCreateTag;
  } else if (kind == VXM_EVENT_TAG && op == "setTags") {
    tag_names(json.at("tags"), VXCORE_ERR_INVALID_PARAM);
    require(json.contains("nodeId"));
    operation = kSetTags;
  } else throw Failure{VXCORE_ERR_INVALID_PARAM};
  if ((operation == kTags || operation == kSetTags) && json.contains("nodeId"))
    require(json_string(json.at("nodeId"), false, VXCORE_ERR_INVALID_PARAM).size() < 128);
  for (auto it = json.begin(); it != json.end(); ++it) {
    const auto &key = it.key();
    require(key == "op" ||
            (operation == kSearch && (key == "text" || key == "tag" || key == "caseSensitive")) ||
            ((operation == kTags || operation == kSetTags) && key == "nodeId") ||
            (operation == kCreateTag && key == "name") || (operation == kSetTags && key == "tags"));
  }
  return operation;
}

enum DraftOperation { kDraftWrite = 1, kDraftInspect, kDraftReconcile };
bool lowercase_hex(const std::string &value, size_t size) {
  return value.size() == size && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
int32_t draft_operation(const uint8_t *data, size_t size, int32_t mode) {
  require(size && size <= kString);
  const auto json = Json::parse(data, data + size, nullptr, false);
  require(json.is_object() && json.contains("op"));
  const auto op = json_string(json.at("op"), false, VXCORE_ERR_INVALID_PARAM);
  const bool writing = op == "write";
  require(writing || op == "inspect" || op == "reconcile");
  require(!writing || mode == VXM_MODE_NOTE, VXCORE_ERR_INVALID_STATE);
  require(json.size() == (writing ? 5 : 4));
  require(fs::u8path(json_string(json.at("draftsRoot"), false, VXCORE_ERR_INVALID_PARAM)).is_absolute());
  require(lowercase_hex(json_string(json.at("documentKey"), false, VXCORE_ERR_INVALID_PARAM), 64));
  require(lowercase_hex(json_string(json.at("token"), false, VXCORE_ERR_INVALID_PARAM), 32));
  if (writing) require(lowercase_hex(json_string(json.at("candidateId"), false, VXCORE_ERR_INVALID_PARAM), 32));
  return writing ? kDraftWrite : op == "inspect" ? kDraftInspect : kDraftReconcile;
}
void preview_command(const std::string &command) {
  require(!command.empty() && command.size() <= kString);
  const auto json = Json::parse(command, nullptr, false);
  require(json.is_object() && json.size() == 5 && json.at("op") == "prepare");
  require(fs::u8path(json_string(json.at("previewRoot"), false, VXCORE_ERR_INVALID_PARAM)).is_absolute());
  require(lowercase_hex(json_string(json.at("previewId"), false, VXCORE_ERR_INVALID_PARAM), 32));
  require(lowercase_hex(json_string(json.at("renderId"), false, VXCORE_ERR_INVALID_PARAM), 32));
  require(json.at("sourceRevision").is_number_unsigned() && json.at("sourceRevision").get<uint64_t>() <= kMaxRevision);
}

enum TransferOperation { kBuild = 1, kApply, kRecover, kResourceList, kResourceExport };
int32_t transfer_operation(const uint8_t *data, size_t size, int32_t kind, int32_t mode) {
  require(size && size <= kString);
  const auto json = Json::parse(data, data + size, nullptr, false);
  require(json.is_object() && json.contains("op"));
  const auto &op = json_string(json.at("op"), false, VXCORE_ERR_INVALID_PARAM);
  int32_t operation = 0;
  if (kind == VXM_EVENT_COHORT && op == "build") {
    require(mode == VXM_MODE_COHORT_BUILDER, VXCORE_ERR_INVALID_STATE);
    operation = kBuild;
  } else if (op == "apply" || op == "recover") {
    require(kind != VXM_EVENT_COHORT || mode == VXM_MODE_CATALOG, VXCORE_ERR_INVALID_STATE);
    operation = op == "apply" ? kApply : kRecover;
  } else if (kind == VXM_EVENT_RESOURCE && op == "list") operation = kResourceList;
  else if (kind == VXM_EVENT_RESOURCE && op == "export") operation = kResourceExport;
  else throw Failure{VXCORE_ERR_INVALID_PARAM};
  if (operation == kApply || operation == kRecover || operation == kResourceExport) {
    const auto &root = json_string(json.at("transactionRoot"), false, VXCORE_ERR_INVALID_PARAM);
    require(fs::u8path(root).is_absolute());
  }
  if (operation == kResourceExport) basename(json_string(json.at("name"), false, VXCORE_ERR_INVALID_PARAM));
  for (auto item = json.begin(); item != json.end(); ++item) {
    require(item.key() == "op" ||
            ((operation == kApply || operation == kRecover || operation == kResourceExport) && item.key() == "transactionRoot") ||
            (operation == kResourceExport && item.key() == "name"));
  }
  return operation;
}
bool transfer_event(int32_t kind) {
  return kind == VXM_EVENT_COHORT || kind == VXM_EVENT_RESOURCE;
}
bool opening_event(int32_t kind) {
  return kind == VXM_EVENT_OPEN || kind == VXM_EVENT_CATALOG_OPEN ||
         kind == VXM_EVENT_COHORT_OPEN || kind == VXM_EVENT_RESOURCE_OPEN || kind == VXM_EVENT_SYNC_CLONE_OPEN;
}
const char *transfer_redacted(int32_t code) {
  switch (code) {
    case VXCORE_OK: return "Transfer completed";
    case VXCORE_ERR_CANCELLED: return "Transfer cancelled; retain private data until its owner has joined";
    case VXCORE_ERR_ALREADY_EXISTS: return "Transfer refused an existing destination; no replacement was authorized";
    case VXCORE_ERR_ENCRYPTION_LOCKED: return "Resource operations do not open or decrypt protected notes";
    case VXCORE_ERR_UNSUPPORTED: return "Transfer refused unsafe storage, protected content, or a size limit";
    case VXCORE_ERR_FILE_CHANGED_OUTSIDE: return "Transfer identity changed; retained work is quarantined";
    case VXCORE_ERR_JSON_PARSE: return "Transfer metadata or durable records are malformed";
    default: return "Transfer failed; recover its actual outcome before retrying or cleanup";
  }
}

// One explicit input file and batch_size=1 run inline on the owner. Never retain
// the core callback's borrowed JSON or expose its absolute path. Escaping a 4 MiB
// control-character line can require 24 MiB; concurrent outside writers can make
// core read more (its own ceiling is 50 MiB), so reject excessive callback JSON.
struct SearchMatch {
  const std::string &expected_id;
  bool received = false;
  bool matched = false;
  int32_t error = VXCORE_OK;
  int64_t line = 0;
  std::string snippet;
  explicit SearchMatch(const std::string &id) : expected_id(id) {}
  static void collect(int index, int total, const char *data, void *userdata) noexcept {
    auto &out = *static_cast<SearchMatch *>(userdata);
    try {
      require(!out.received && index == 0 && total == 1, VXCORE_ERR_INVALID_STATE);
      out.received = true;
      const auto size = bounded_length(data, 6 * kSource + 12 * kString + 4096);
      const auto batch = Json::parse(data, data + size, nullptr, false);
      require(batch.is_object(), VXCORE_ERR_JSON_PARSE);
      const auto &files = batch.at("matches");
      require(files.is_array() && files.size() <= 1, VXCORE_ERR_INVALID_STATE);
      if (files.empty()) return;
      const auto &file = files.front();
      require(identity(file) == out.expected_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      const auto &matches = file.at("matches");
      require(matches.is_array() && matches.size() == 1, VXCORE_ERR_INVALID_STATE);
      const auto &first = matches.front();
      require(first.at("lineNumber").is_number_integer(), VXCORE_ERR_JSON_PARSE);
      out.line = first.at("lineNumber").get<int64_t>();
      require(out.line > 0 && out.line <= INT32_MAX, VXCORE_ERR_JSON_PARSE);
      const auto &line = first.at("lineText").get_ref<const std::string &>();
      require(line.size() <= kSource && line.find('\0') == std::string::npos &&
              utf8(reinterpret_cast<const uint8_t *>(line.data()), line.size()), VXCORE_ERR_UNSUPPORTED);
      size_t length = line.size() < 512 ? line.size() : 512;
      while (length < line.size() && (static_cast<uint8_t>(line[length]) & 0xc0) == 0x80) --length;
      out.snippet.assign(line.data(), length);
      out.matched = true;
    } catch (const Failure &failure) { out.error = failure.code; }
    catch (const std::bad_alloc &) { out.error = VXCORE_ERR_OUT_OF_MEMORY; }
    catch (const Json::exception &) { out.error = VXCORE_ERR_JSON_PARSE; }
    catch (...) { out.error = VXCORE_ERR_UNKNOWN; }
  }
};

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
  std::string node, name, destination, command;
  int32_t operation = 0;
  int32_t export_format = VXM_EXPORT_NOTEBOOK;
  size_t input_cost = 0;
  uint64_t staging_budget = 0;
  std::atomic<bool> cancelled{false};
  bool sensitive = false;
  ~Request() { if (sensitive && !input.empty()) sodium_memzero(input.data(), input.size()); }
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

std::string_view vxm_drafts::ProjectDisk(std::string_view source,
                                       std::string_view opening_source,
                                       int32_t ending, std::string &storage) {
  vxm_import::storage::Check(source.size() <= kSource, VXCORE_ERR_INVALID_PARAM);
  vxm_import::storage::Check(ending >= VXCORE_LINE_ENDING_UNSPECIFIED && ending <= VXCORE_LINE_ENDING_CR,
                            VXCORE_ERR_UNSUPPORTED);
  if (source == opening_source || ending == VXCORE_LINE_ENDING_UNSPECIFIED) return source;
  size_t output_size = 0;
  bool conversion = false;
  for (size_t i = 0; i < source.size(); ++i) {
    if (source[i] != '\r' && source[i] != '\n') { ++output_size; continue; }
    const bool pair = source[i] == '\r' && i + 1 < source.size() && source[i + 1] == '\n';
    conversion |= ending == VXCORE_LINE_ENDING_CRLF ? !pair :
        pair || source[i] != (ending == VXCORE_LINE_ENDING_LF ? '\n' : '\r');
    if (pair) ++i;
    output_size += ending == VXCORE_LINE_ENDING_CRLF ? 2 : 1;
  }
  vxm_import::storage::Check(output_size <= kSource, VXCORE_ERR_INVALID_PARAM);
  if (!conversion) return source;
  storage.resize(output_size);
  size_t next = 0;
  for (size_t i = 0; i < source.size(); ++i) {
    if (source[i] != '\r' && source[i] != '\n') { storage[next++] = source[i]; continue; }
    if (source[i] == '\r' && i + 1 < source.size() && source[i + 1] == '\n') ++i;
    if (ending != VXCORE_LINE_ENDING_LF) storage[next++] = '\r';
    if (ending != VXCORE_LINE_ENDING_CR) storage[next++] = '\n';
  }
  return storage;
}

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
  uint64_t active_read_only = 0; // Protected by mutex, including completion handoff.
  std::atomic<bool> read_cancelled{false};
  uint64_t generation = new_generation();
  uint64_t last_request = 0;
  VxmNotify notify = nullptr;
  int64_t token = 0;
  std::thread owner;
  vxm_sync::Runtime sync;
  std::thread sync_worker;
  std::unique_ptr<Request> sync_request;
  std::unique_ptr<vxm_sync::Work> sync_work;
  bool sync_running = false, sync_ready = false;
  Request *active_sync_command = nullptr; // Protected by mutex; never owns storage.
  int32_t close_code = VXCORE_OK;
  std::string app_path, local_path, notebook_path, notebook_name, note_path;
  std::string expected_notebook_id;
  std::string transaction_root;
  int32_t mode = 0;
  bool create_notebook = false;
  bool export_only = false;
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
  Json notebook_config() {
    CoreString value;
    check(vxcore_notebook_get_config(context, notebook_id.c_str(), &value.value));
    auto config = value.json();
    require(identity(config) == notebook_id, VXCORE_ERR_INVALID_STATE);
    notebook_name = config.at(vxcore::kJsonKeyName).get<std::string>();
    require(notebook_name.size() <= kString, VXCORE_ERR_INVALID_STATE);
    assets = config.at(vxcore::kJsonKeyAssetsFolder).get<std::string>();
    recycle = config.at(vxcore::kJsonKeyRecycleBinFolder).get<std::string>();
    return config;
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
  void layout(const std::atomic<bool> *cancelled = nullptr) {
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
    safe_tree(root / "vx_notebook", cancelled);
    confined(root, recycle);
    safe_tree(root / fs::u8path(recycle), cancelled);
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
    notebook_config();
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
    const auto operation = request.operation;
    if (operation == VXM_RENAME_NOTEBOOK) require(request.node == root_id);
    const auto target = resolve(request.node, false, operation == VXM_DELETE);
    auto &out = *request.result;
    copy_field(out.node, target.id);
    if (operation == VXM_RENAME_NOTEBOOK) {
      require(target.path == ".");
      auto config = notebook_config();
      config[vxcore::kJsonKeyName] = request.name;
      const auto json = config.dump();
      require(json.size() <= kJson);
      const auto result = vxcore_notebook_update_config(context, notebook_id.c_str(), json.c_str());
      // Core can apply metadata before a later store fails. Reload even on error;
      // the mutation retains its original outcome and a separate list is fresh.
      try { notebook_config(); }
      catch (...) { check(result); throw; }
      check(result);
      return;
    }
    if (target.path != ".")
      for (const auto &part : fs::u8path(target.path)) basename(part.u8string());
    const auto root = fs::u8path(notebook_path);
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
  void check_read_cancelled() const {
    require(!read_cancelled.load(std::memory_order_relaxed), VXCORE_ERR_CANCELLED);
  }
  void append_query(EventStorage &out, const std::string &text) {
    require(text.size() <= kCatalog - out.event.size, VXCORE_ERR_UNSUPPORTED);
    std::memcpy(out.body.get() + out.event.size, text.data(), text.size());
    out.event.size += text.size();
  }
  void file_identity(const Node &node) {
    require(!node.folder, VXCORE_ERR_INVALID_PARAM);
    for (const auto &part : fs::u8path(node.path)) basename(part.u8string());
    ordinary(node.path);
    confined(fs::u8path(notebook_path), node.path);
    const auto path = fs::u8path(notebook_path) / fs::u8path(node.path);
    require(fs::exists(path), VXCORE_ERR_NODE_NOT_EXISTS);
    require(fs::is_regular_file(path), VXCORE_ERR_UNSUPPORTED);
  }
  void search_file_supported(const Node &node) {
    file_identity(node);
    if (node.config.value(vxcore::kJsonKeyEncrypted, false))
      throw Failure{VXCORE_ERR_ENCRYPTION_LOCKED};
    const auto metadata = node.config.find(vxcore::kJsonKeyMetadata);
    if (metadata != node.config.end()) {
      require(metadata->is_object(), VXCORE_ERR_JSON_PARSE);
      if (metadata->value(vxcore::kJsonKeyEncrypted, false))
        throw Failure{VXCORE_ERR_ENCRYPTION_LOCKED};
    }
    classify(node.path);
    uint64_t size = 0;
    check(vxcore_node_get_file_size(context, notebook_id.c_str(), node.path.c_str(), &size));
    require(size <= kSource, VXCORE_ERR_UNSUPPORTED);
    if (size) {
      CoreString source;
      check(vxcore_file_peek(context, notebook_id.c_str(), node.path.c_str(), static_cast<size_t>(size), &source.value));
      require(source.value != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
      const auto length = bounded_length(source.value, kSource);
      // Peek is a C string: unequal length also rejects any embedded NUL.
      require(length == size && utf8(reinterpret_cast<const uint8_t *>(source.value), length), VXCORE_ERR_UNSUPPORTED);
    }
  }
  static bool unsupported_candidate(int32_t code) {
    return code == VXCORE_ERR_UNSUPPORTED || code == VXCORE_ERR_NODE_NOT_EXISTS ||
           code == VXCORE_ERR_NOT_FOUND || code == VXCORE_ERR_ENCRYPTION_LOCKED ||
           code == VXCORE_ERR_ENCRYPTION_AUTH_FAILED || code == VXCORE_ERR_ENCRYPTION_FORMAT ||
           code == VXCORE_ERR_ENCRYPTION_RECOVERY_REQUIRED;
  }
  void search_catalog(Request &request, const Json &query) {
    check_read_cancelled();
    auto &out = *request.result;
    const auto &text = query.at("text").get_ref<const std::string &>();
    Json scope = {{"recursive", false}, {"filePatterns", Json::array({"*"})}};
    if (query.contains("tag")) scope["tags"] = Json::array({query.at("tag")});
    const auto core_query = text.empty()
        ? Json{{"tags", scope.at("tags")}, {"operator", "AND"}, {"scope", scope}}.dump()
        : Json{{"pattern", text}, {"caseSensitive", query.at("caseSensitive")},
               {"regex", false}, {"firstMatchPerFile", true}, {"scope", scope}}.dump();
    append_query(out, "{\"notebookId\":" + Json(notebook_id).dump() + ",\"matches\":[");
    std::vector<std::string> folders{"."};
    size_t queued_bytes = 1, inspected = 0, rows = 0, skipped = 0;
    bool limited = false;
    std::set<std::string> seen;
    seen.insert(root_id);
    while (!folders.empty() && !limited) {
      check_read_cancelled();
      auto path = std::move(folders.back());
      folders.pop_back();
      queued_bytes -= path.size();
      ordinary(path);
      confined(fs::u8path(notebook_path), path);
      CoreString listing;
      check(vxcore_folder_list_children(context, notebook_id.c_str(), path.c_str(), &listing.value));
      const auto children = listing.json(kCatalog);
      for (const bool folder : {false, true}) {
        const auto &entries = children.at(folder ? vxcore::kJsonKeyFolders : vxcore::kJsonKeyFiles);
        require(entries.is_array(), VXCORE_ERR_JSON_PARSE);
        for (const auto &child : entries) {
          check_read_cancelled();
          if (inspected == 100000) { limited = true; break; }
          ++inspected;
          const auto id = identity(child);
          require(seen.insert(id).second, VXCORE_ERR_JSON_PARSE);
          const auto &name = json_string(child.at(vxcore::kJsonKeyName));
          const auto exists = child.at(vxcore::kJsonKeyNodeExists).get<bool>();
          std::string next;
          try {
            // Nonportable names/links/layouts are visible skipped candidates,
            // never passed to core's recursive or permissive path handling.
            try { basename(name); }
            catch (const Failure &) { throw Failure{VXCORE_ERR_UNSUPPORTED}; }
            next = joined(path, name);
            ordinary(next);
            confined(fs::u8path(notebook_path), next);
            require(exists, VXCORE_ERR_NODE_NOT_EXISTS);
            const auto physical = fs::u8path(notebook_path) / fs::u8path(next);
            require(fs::exists(physical), VXCORE_ERR_NODE_NOT_EXISTS);
            if (folder) {
              require(fs::is_directory(physical), VXCORE_ERR_UNSUPPORTED);
            } else {
              auto node = load_node(next, id);
              require(!node.folder, VXCORE_ERR_JSON_PARSE);
              search_file_supported(node);
            }
          } catch (const Failure &failure) {
            if (!unsupported_candidate(failure.code)) throw;
            ++skipped;
            continue;
          }
          if (folder) {
            if (next.size() > kCatalog - queued_bytes) { limited = true; break; }
            queued_bytes += next.size();
            folders.push_back(std::move(next));
            continue;
          }
          check_read_cancelled();
          // Never send an empty input list: core treats that as whole-tree search.
          const auto inputs = Json{{"files", Json::array({next})}}.dump();
          SearchMatch match{id};
          if (text.empty()) {
            CoreString result;
            check(vxcore_search_by_tags(context, notebook_id.c_str(), core_query.c_str(), inputs.c_str(), &result.value));
            const auto body = result.json(kCatalog);
            const auto &matches = body.at("matches");
            require(matches.is_array() && matches.size() <= 1, VXCORE_ERR_INVALID_STATE);
            if (!matches.empty()) {
              require(identity(matches.front()) == id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
              match.matched = true;
            }
          } else {
            check(vxcore_search_content_streaming(context, notebook_id.c_str(), core_query.c_str(),
                                                  inputs.c_str(), 1, SearchMatch::collect, &match, nullptr));
            require(match.error == VXCORE_OK, match.error);
          }
          check_read_cancelled();
          if (!match.matched) continue;
          const auto row = Json{{"id", id}, {"path", next}, {"line", match.line}, {"snippet", match.snippet}}.dump();
          // Leave ample space for the fixed trailer and bounded skipped count.
          if (row.size() + (rows ? 1 : 0) > kCatalog - out.event.size - 128) {
            limited = true;
            break;
          }
          if (rows) append_query(out, ",");
          append_query(out, row);
          if (++rows == 10000) { limited = true; break; }
        }
        if (limited) break;
      }
    }
    check_read_cancelled();
    append_query(out, std::string("],\"limited\":") + (limited ? "true" : "false") +
                     ",\"skipped\":" + std::to_string(skipped) + "}");
  }
  void tags_catalog(Request &request, const Json &query) {
    auto &out = *request.result;
    CoreString raw;
    check(vxcore_tag_list(context, notebook_id.c_str(), &raw.value));
    const auto size = bounded_length(raw.value, kCatalog);
    const auto tags = Json::parse(raw.value, raw.value + size, nullptr, false);
    require(tags.is_array() && tags.size() <= 10000, VXCORE_ERR_UNSUPPORTED);
    append_query(out, "{\"notebookId\":" + Json(notebook_id).dump() + ",\"tags\":[");
    std::set<std::string_view> names;
    bool comma = false;
    for (const auto &tag : tags) {
      const auto &name = json_string(tag.at(vxcore::kJsonKeyName));
      const auto &parent = json_string(tag.at(vxcore::kJsonKeyParent), true);
      require(names.insert(name).second, VXCORE_ERR_JSON_PARSE);
      if (comma) append_query(out, ",");
      append_query(out, Json{{"name", name}, {"parent", parent}}.dump());
      comma = true;
    }
    append_query(out, "],\"assigned\":[");
    if (query.contains("nodeId")) {
      const auto node = resolve(query.at("nodeId").get<std::string>());
      file_identity(node);
      const auto &assigned = node.config.at(vxcore::kJsonKeyTags);
      tag_names(assigned);
      comma = false;
      for (const auto &tag : assigned) {
        if (comma) append_query(out, ",");
        append_query(out, tag.dump());
        comma = true;
      }
    }
    append_query(out, "]}");
  }
  void collect_node_ids(Request &request) {
    vxm_import::Inspection strict;
    check(static_cast<VxCoreError>(vxm_import::inspect_managed(fs::u8path(notebook_path), notebook_id, strict)));
    CoreString collected;
    check(vxcore_notebook_collect_node_ids(context, notebook_id.c_str(), &collected.value));
    const auto size = bounded_length(collected.value, kCatalog);
    const auto values = Json::parse(collected.value, collected.value + size, nullptr, false);
    require(values.is_array() && values.size() == strict.node_ids.size(), VXCORE_ERR_JSON_PARSE);
    std::set<std::string> unique;
    for (const auto &value : values) {
      const auto &id = json_string(value);
      require(id.size() < 128 && unique.insert(id).second, VXCORE_ERR_JSON_PARSE);
    }
    require(std::equal(unique.begin(), unique.end(), strict.node_ids.begin(), strict.node_ids.end()),
            VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    append_query(*request.result, "{\"notebookId\":" + Json(notebook_id).dump() + ",\"nodeIds\":[");
    bool comma = false;
    for (const auto &id : strict.node_ids) {
      if (comma) append_query(*request.result, ",");
      append_query(*request.result, Json(id).dump());
      comma = true;
    }
    append_query(*request.result, "]}");
  }
  void query_catalog(Request &request) {
    require(mode == VXM_MODE_CATALOG, VXCORE_ERR_INVALID_STATE);
    if (request.operation == kSearch) check_read_cancelled();
    layout(request.operation == kSearch ? &read_cancelled : nullptr);
    load_node(".", root_id);
    const auto query = Json::parse(request.input.begin(), request.input.end());
    auto &out = *request.result;
    copy_field(out.notebook, notebook_id);
    if (request.operation == kSearch) search_catalog(request, query);
    else if (request.operation == kCollectNodeIds) collect_node_ids(request);
    else tags_catalog(request, query);
    out.event.data = out.body.get();
    // Keep the full reservation while the preallocated body is retained. Charging
    // only serialized bytes here would hide up to 8 MiB per held terminal.
  }
  void tag_catalog(Request &request) {
    require(mode == VXM_MODE_CATALOG, VXCORE_ERR_INVALID_STATE);
    layout();
    load_node(".", root_id);
    const auto query = Json::parse(request.input.begin(), request.input.end());
    if (request.operation == kCreateTag) {
      check(vxcore_tag_create(context, notebook_id.c_str(), query.at("name").get_ref<const std::string &>().c_str()));
    } else {
      const auto node = resolve(query.at("nodeId").get<std::string>());
      file_identity(node);
      copy_field(request.result->node, node.id);
      const auto tags = query.at("tags").dump();
      // Core permits defined names OR this file's existing orphan assignments.
      // Do not tighten that validator, mutate disk directly, or refresh here.
      check(vxcore_file_update_tags(context, notebook_id.c_str(), node.path.c_str(), tags.c_str()));
    }
  }
  void export_catalog(Request &request) {
    require(mode == VXM_MODE_CATALOG, VXCORE_ERR_INVALID_STATE);
    check_read_cancelled();
    const auto source = fs::u8path(notebook_path);
    confined(source, ".");
    const auto source_identity = export_identity(source);
    export_require(source_identity.directory, "Export requires an existing notebook directory");
    const auto destination = fs::u8path(request.destination);
    export_require(destination.is_absolute() && !destination.filename().empty(),
                   "Export requires an absolute new staging directory", VXCORE_ERR_INVALID_PARAM);
    for (const auto &part : destination.relative_path())
      export_require(part != "." && part != "..", "Export refuses an ambiguous staging path");
    confined(destination.parent_path(), ".");
    export_require(fs::is_directory(destination.parent_path()), "Export staging parent is missing", VXCORE_ERR_IO);
    const auto canonical = fs::canonical(destination.parent_path()) / destination.filename();
    for (const auto *protected_path : {&notebook_path, &app_path, &local_path}) {
      const auto protected_root = fs::weakly_canonical(fs::u8path(*protected_path));
      export_require(!export_within(canonical, protected_root) && !export_within(protected_root, canonical),
                     "Export staging must be separate from notebook and core storage");
    }
    export_require(!fs::exists(fs::symlink_status(destination)), "Export staging already exists", VXCORE_ERR_ALREADY_EXISTS);
    export_journals(source, &read_cancelled);
    const bool content = request.export_format == VXM_EXPORT_FILES_AND_ASSETS;
    constexpr const char *config_relative = "vx_notebook/config.json";
    export_confined(source, config_relative);
    const auto config_identity = export_identity(source / config_relative);
    const auto config = export_json(source / config_relative, config_identity, &read_cancelled);
    require(identity(config) == notebook_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    export_credentials(config);
    notebook_name = json_string(config.at(vxcore::kJsonKeyName));
    const auto resources = export_resources(source, config);
    std::vector<std::pair<std::string, ExportIdentity>> excluded_roots;
    if (content) {
      export_unprotected(config);
      export_require(!export_under(resources.assets, "vx_notebook"),
                     "Files and assets export refuses assets stored in omitted notebook metadata");
      for (const auto &path : {std::string("vx_notebook"), resources.recycle}) {
        export_confined(source, path);
        if (fs::exists(fs::symlink_status(source / fs::u8path(path))))
          excluded_roots.emplace_back(path, export_identity(source / fs::u8path(path)));
      }
    }
    std::vector<ExportEntry> entries;
    std::array<bool, 32> excluded_ancestors{};
    uint64_t bytes = 0, files = 0, directories = 0, archive_limit = 1024;
    size_t runtime_entries = 0;
    bool found_config = false;
    // Inspect runtime paths for unsafe links before the public sync guard reads
    // them. Their bytes are never copied. Content exclusions retain identities
    // and consume the same inventory cap; no subtree is pruned in that profile.
    for (auto it = fs::recursive_directory_iterator(source); it != fs::recursive_directory_iterator(); ++it) {
      check_read_cancelled();
      auto relative = it->path().lexically_relative(source).generic_u8string();
      export_relative(relative);
      export_reserved_spelling(source, relative);
      export_confined(source, relative);
      const auto info = export_identity(it->path());
      bool selected = true;
      if (content) {
        bool excluded = export_under(relative, "vx_notebook") || export_under(relative, resources.recycle) ||
                        (it.depth() > 0 && excluded_ancestors[static_cast<size_t>(it.depth() - 1)]);
        for (const auto &root : excluded_roots) {
          if (info.same_object(root.second)) {
            export_require(relative == root.first,
                           "Files and assets export refuses differently spelled omitted directory aliases");
            excluded = true;
          }
          if (relative == root.first) require(info == root.second, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        }
        excluded_ancestors[static_cast<size_t>(it.depth())] = excluded;
        selected = !excluded;
      } else {
        if (relative == "vx_notebook/vx_import" || relative == "vx_notebook/vx_transfer") {
          it.disable_recursion_pending(); // Already proved directory-only residue.
          continue;
        }
        if (export_under(relative, "vx_notebook/vx_sync")) {
          export_require(++runtime_entries <= kExportEntries, "Export synchronization inspection exceeds the entry limit");
          continue;
        }
      }
      export_require(!selected || lower_ascii(it->path().filename().u8string()) != ".git",
                     "Export refuses unclassified Git working-copy data");
      export_require(entries.size() < kExportEntries, "Export exceeds the 100000-entry limit");
      if (relative == config_relative) {
        require(info == config_identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        found_config = true;
      }
      if (selected) {
        if (info.directory) ++directories;
        else {
          export_require(!content || lower_ascii(it->path().extension().u8string()) != ".vne",
                         "Files and assets export refuses protected content; use a notebook backup");
          export_require(info.size <= kExportSource - bytes, "Export exceeds the 1 GiB source limit");
          bytes += info.size;
          archive_limit += info.size + info.size / 64 + 4096;
          ++files;
        }
        archive_limit += 2 * relative.size() + 256;
      }
      entries.push_back({std::move(relative), info, selected});
    }
    export_require(found_config, "Export notebook configuration is missing or differently spelled");
    const auto check_sync = [&] {
      check_read_cancelled();
      const auto code = vxcore_sync_check_reconfiguration(context, notebook_id.c_str());
      export_require(code == VXCORE_OK, "Export requires synchronization conflicts and recovery to be resolved", code);
    };
    check_sync(); // Required before omitting the exact reserved runtime tree.
    export_require(bytes + archive_limit <= request.staging_budget,
                   "Export snapshot and ZIP exceed the staging budget");
    std::array<uint8_t, kExportChunk> buffer;
    if (content) export_content_metadata(source, entries, resources, notebook_id, &read_cancelled);
    export_confined(source, config_relative);
    require(export_identity(source / config_relative) == config_identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    const auto space = [&](uint64_t remaining) {
      check_read_cancelled();
      const auto available = fs::space(destination.parent_path()).available;
      export_require(available != static_cast<uintmax_t>(-1) && available >= remaining + archive_limit + kExportHeadroom,
                     "Export requires more free staging space including its safety headroom", VXCORE_ERR_IO);
    };
    space(bytes);
    confined(destination.parent_path(), ".");
    export_require(fs::create_directory(destination), "Export staging already exists", VXCORE_ERR_ALREADY_EXISTS);
    const auto destination_identity = export_identity(destination);
    uint64_t copied = 0;
    for (const auto &entry : entries) {
      check_read_cancelled();
      if (!entry.selected) continue;
      export_confined(source, entry.relative);
      export_confined(destination, entry.relative);
      require(export_identity(destination).same_object(destination_identity), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      const auto output_path = destination / fs::u8path(entry.relative);
      if (entry.identity.directory) {
        require(export_identity(source / fs::u8path(entry.relative)) == entry.identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        export_require(fs::create_directory(output_path), "Export staging entry already exists", VXCORE_ERR_ALREADY_EXISTS);
        continue;
      }
      space(bytes - copied);
      ExportFile input(source / fs::u8path(entry.relative));
      require(input.identity() == entry.identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      uint64_t remaining = entry.identity.size;
      size_t prefix = 0;
      if (content) {
        const auto prefix_size = static_cast<size_t>(std::min<uint64_t>(remaining, 8));
        while (prefix < prefix_size) {
          check_read_cancelled();
          const auto count = input.read(buffer.data() + prefix, prefix_size - prefix);
          require(count != 0, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
          prefix += count;
        }
        export_require(prefix < 8 || (std::memcmp(buffer.data(), "VNOTEE1", 8) != 0 &&
                                     std::memcmp(buffer.data(), "VNEKEY1", 8) != 0),
                       "Files and assets export refuses protected content; use a notebook backup");
      }
      ExportFile output(output_path, true);
      if (prefix) {
        output.write(buffer.data(), prefix);
        remaining -= prefix;
        copied += prefix;
      }
      while (remaining) {
        check_read_cancelled();
        const auto count = input.read(buffer.data(), static_cast<size_t>(std::min<uint64_t>(remaining, buffer.size())));
        require(count != 0, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        output.write(buffer.data(), count);
        remaining -= count;
        copied += count;
      }
      require(input.read(buffer.data(), 1) == 0 && input.identity() == entry.identity,
              VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      output.finish();
      export_confined(source, entry.relative);
      require(export_identity(source / fs::u8path(entry.relative)) == entry.identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    // Directory mtimes detect additions/removals too, not just changed files.
    for (const auto &entry : entries) {
      check_read_cancelled();
      export_confined(source, entry.relative);
      require(export_identity(source / fs::u8path(entry.relative)) == entry.identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    confined(source, ".");
    require(export_identity(source) == source_identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    require(export_identity(source / config_relative) == config_identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    export_journals(source, &read_cancelled);
    check_sync();
    space(0);
    auto &out = *request.result;
    copy_field(out.notebook, notebook_id);
    copy_field(out.title, notebook_name);
    const auto summary = Json{{"format", content ? "filesAndAssets" : "notebook"},
                              {"bytes", bytes}, {"files", files}, {"directories", directories},
                              {"archiveLimit", archive_limit}}.dump();
    require(summary.size() <= kExportSummary, VXCORE_ERR_INVALID_STATE);
    std::memcpy(out.body.get(), summary.data(), summary.size());
    out.event.data = out.body.get();
    out.event.size = summary.size();
    // Keep the actual 1 KiB allocation charged until terminal release.
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
  void preflight_isolated_context(const fs::path &root, const char *reason) {
    const auto canonical = fs::canonical(root);
    for (const auto *storage : {&app_path, &local_path}) {
      const auto path = fs::u8path(*storage);
      export_require(path.is_absolute(), reason);
      confined(path, ".");
      const auto core_root = fs::weakly_canonical(path);
      export_require(!export_within(canonical, core_root) && !export_within(core_root, canonical), reason);
    }
    // Explicit-root contexts ignore legacy session contents. Keep file identity
    // protection because later admitted operations/shutdown may write this path.
    try {
      const auto session_path = fs::u8path(local_path) / "vxsession.json";
      confined(fs::u8path(local_path), "vxsession.json");
      if (fs::exists(fs::symlink_status(session_path))) {
        export_require(!export_identity(session_path).directory, reason);
      }
    } catch (const Failure &failure) { throw Failure{failure.code, reason}; }
    catch (const fs::filesystem_error &) { throw Failure{VXCORE_ERR_IO, reason}; }
  }
  void preflight_export_open(const fs::path &root) {
    preflight_isolated_context(root, "Export requires isolated native state roots and safe session-file identity");
    size_t metadata_entries = 0;
    export_require(export_identity(root / "vx_notebook").directory, "Export requires existing notebook metadata");
    for (const auto &entry : fs::recursive_directory_iterator(root / "vx_notebook")) {
      export_require(++metadata_entries <= 2 * kExportEntries,
                     "Export metadata and runtime inspection exceeds the entry limit");
      const auto relative = entry.path().lexically_relative(root).generic_u8string();
      export_relative(relative);
      export_reserved_spelling(root, relative);
      confined(root, relative);
      export_identity(entry.path());
    }
    export_journals(root);
    const auto transfer = root / "vx_notebook/vx_transfer";
    if (fs::exists(fs::symlink_status(transfer))) {
      for (const auto &entry : fs::directory_iterator(transfer)) {
        // NodeTransfer removes even journal-less child directories; encryption
        // recovery likewise removes empty transaction children. The empty parent
        // named encryption is the only safe child to pass to core unchanged.
        export_require(entry.path().filename() == "encryption" && fs::is_empty(entry.path()),
                       "Export requires normal notebook recovery to clear transfer residue");
      }
    }
    const auto config_path = root / "vx_notebook/config.json";
    const auto config = export_json(config_path, export_identity(config_path));
    require(identity(config) == expected_notebook_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    json_string(config.at(vxcore::kJsonKeyName));
    export_credentials(config);
    export_resources(root, config);
    const auto tags = config.find(vxcore::kJsonKeyTags);
    if (tags != config.end()) {
      require(tags->is_array(), VXCORE_ERR_JSON_PARSE);
      const auto timestamp = config.find(vxcore::kJsonKeyTagsModifiedUtc);
      export_require(tags->empty() || (timestamp != config.end() && timestamp->is_number_integer() &&
                                     timestamp->get<int64_t>() != 0),
                     "Export requires normal notebook open to finish legacy tag migration");
    }
    confined(root, "vx_notebook/contents/vx.json");
    const auto root_path = root / "vx_notebook/contents/vx.json";
    const auto metadata = export_json(root_path, export_identity(root_path));
    identity(metadata);
    require(metadata.contains(vxcore::kJsonKeyFiles) && metadata.at(vxcore::kJsonKeyFiles).is_array() &&
            metadata.contains(vxcore::kJsonKeyFolders) && metadata.at(vxcore::kJsonKeyFolders).is_array(),
            VXCORE_ERR_JSON_PARSE);
  }
  void transfer(Request &request) {
    auto input = Json::parse(request.input.begin(), request.input.end());
    Json output;
    if (request.result->event.kind == VXM_EVENT_COHORT) {
      if (request.operation == kBuild) input["transactionRoot"] = transaction_root;
      check(static_cast<VxCoreError>(vxm_transfer::Cohort(context, notebook_id, notebook_path,
          input, request.operation == kBuild ? &read_cancelled : nullptr, output)));
    } else {
      check(static_cast<VxCoreError>(vxm_transfer::Resource(context, notebook_id, node_id,
          note_path, buffer_id, notebook_path, input,
          request.operation == kResourceList || request.operation == kResourceExport ? &read_cancelled : nullptr,
          output)));
    }
    const auto encoded = output.dump();
    const auto bound = request.operation == kResourceList ? kCatalog : kString;
    require(encoded.size() <= bound, VXCORE_ERR_UNSUPPORTED);
    auto &out = *request.result;
    if (!encoded.empty()) std::memcpy(out.body.get(), encoded.data(), encoded.size());
    out.event.data = out.body.get();
    out.event.size = encoded.size();
    copy_field(out.notebook, notebook_id);
    copy_field(out.node, node_id);
    // Keep the entire actual bounded body allocation charged until event free.
  }
  void initialize(Request &request) {
    check(vxcore_log_set_level(VXCORE_LOG_LEVEL_OFF));
    check(vxcore_log_enable_console(0));
    check(vxcore_log_set_file(""));
    require(sodium_init() >= 0, VXCORE_ERR_NOT_INITIALIZED);
    if (mode == VXM_MODE_SYNC_CLONE) {
      Json options;
      check(static_cast<VxCoreError>(vxm_import::PreflightClone(transaction_root, options)));
      notebook_path = json_string(options.at("notebookPath"));
      app_path = json_string(options.at("appDataPath"));
      local_path = json_string(options.at("localDataPath"));
      const auto canonical = fs::weakly_canonical(fs::u8path(notebook_path));
      for (const auto &active : owned_notebooks) {
        std::error_code error;
        require(canonical != active && !fs::equivalent(canonical, active, error), VXCORE_ERR_INVALID_STATE);
      }
      owned_root = canonical;
      owned_notebooks.insert(owned_root);
      owns_root = true;
      vxm_sync::ContextCreated();
      check(vxcore_context_create_with_paths(nullptr, app_path.c_str(), local_path.c_str(), &context));
      sync.Initialize(context, "", notebook_path, local_path, true);
      return;
    }
    if (mode == VXM_MODE_COHORT_BUILDER) {
      Json options;
      check(static_cast<VxCoreError>(vxm_transfer::PreflightCohortBuilder(transaction_root, options)));
      notebook_path = json_string(options.at("notebookPath"));
      app_path = json_string(options.at("appDataPath"));
      local_path = json_string(options.at("localDataPath"));
      notebook_name = json_string(options.at("notebookName"));
      create_notebook = true;
    }
    auto root = fs::u8path(notebook_path);
    require(root.is_absolute());
    // Directory URIs legitimately end in a separator. Keep the same location
    // while making its final component stable for draft/preview identities.
    if (root.has_relative_path() && root.filename().empty()) {
      root = root.parent_path();
      notebook_path = root.u8string();
    }
    const auto status = fs::symlink_status(root);
    const bool exists = fs::exists(status);
    require(create_notebook ? !exists : exists,
            create_notebook ? VXCORE_ERR_ALREADY_EXISTS : VXCORE_ERR_NOT_FOUND);
    confined(root, ".");
    confined(root, "vx_notebook/config.json");
    // Metadata-only recovery must not let notebook_open replay migrations or
    // pending body transfers before it can compare the actual durable state.
    if (export_only || mode == VXM_MODE_RESOURCES) preflight_export_open(root);
    else safe_tree(root / "vx_notebook");
    const auto canonical = fs::weakly_canonical(root);
    for (const auto &active : owned_notebooks) {
      std::error_code error;
      require(canonical != active && !fs::equivalent(canonical, active, error), VXCORE_ERR_INVALID_STATE);
    }
    owned_root = canonical;
    owned_notebooks.insert(owned_root);
    owns_root = true;
    vxm_sync::ContextCreated();
    check(vxcore_context_create_with_paths(nullptr, app_path.c_str(), local_path.c_str(), &context));
    check(vxcore_context_update_config(context, "{\"search\":{\"backends\":[\"simple\"]}}"));
    CoreString notebook;
    if (create_notebook) {
      const auto config = Json{{vxcore::kJsonKeyName, notebook_name}}.dump();
      check(vxcore_notebook_create(context, notebook_path.c_str(), config.c_str(), VXCORE_NOTEBOOK_BUNDLED, &notebook.value));
    } else {
      require(fs::is_directory(status), VXCORE_ERR_IO);
      check(vxcore_notebook_open(context, notebook_path.c_str(), &notebook.value));
    }
    notebook_id = notebook.take();
    require(expected_notebook_id.empty() || notebook_id == expected_notebook_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    if (!export_only && (mode == VXM_MODE_NOTE || mode == VXM_MODE_CATALOG))
      sync.Initialize(context, notebook_id, notebook_path, local_path, false);
    if (export_only) {
      const auto code = vxcore_sync_check_reconfiguration(context, notebook_id.c_str());
      export_require(code == VXCORE_OK, "Export requires synchronization conflicts and recovery to be resolved", code);
    }
    if (mode != VXM_MODE_CATALOG) notebook_config();
    root_id = load_node(".").id;
    if (mode == VXM_MODE_CATALOG) {
      list_catalog(request);
      return;
    }
    if (mode == VXM_MODE_COHORT_BUILDER) {
      fill_metadata(*request.result, load_node(".", root_id));
      return;
    }
    if (mode == VXM_MODE_RESOURCES) {
      Json resource_metadata;
      check(static_cast<VxCoreError>(vxm_transfer::PreflightResource(context, notebook_id,
          node_id, notebook_path, resource_metadata)));
      require(json_string(resource_metadata.at("notebookId")) == notebook_id &&
              json_string(resource_metadata.at("nodeId")) == node_id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      note_path = json_string(resource_metadata.at("notePath"));
    }
    note_metadata();
    if (mode == VXM_MODE_NOTE) check_disk_size();
    CoreString buffer;
    check(vxcore_buffer_open_by_node_id(context, node_id.c_str(), &buffer.value));
    buffer_id = buffer.take();
    buffer_metadata();
    if (mode == VXM_MODE_RESOURCES) {
      fill_metadata(*request.result, resolve(node_id));
      request.result->event.editor_type = editor_type;
      return;
    }
    require(mode == VXM_MODE_NOTE, VXCORE_ERR_INVALID_STATE);
    const uint8_t *data = nullptr;
    size_t size = 0;
    reload(data, size);
    fill_note(*request.result, data, size);
  }
  void read_note(Request &request) {
    if (sync.CanRefreshSource()) {
      const auto current = resolve(node_id);
      require(!current.folder, VXCORE_ERR_UNSUPPORTED);
      if (current.path != note_path) {
        // A clean source reload after metadata refresh follows its stable ID,
        // not an old path which may now identify a different incoming node.
        check(vxcore_buffer_close(context, buffer_id.c_str()));
        buffer_id.clear(); note_path.clear();
        note_metadata(); check_disk_size();
        CoreString buffer;
        check(vxcore_buffer_open_by_node_id(context, node_id.c_str(), &buffer.value));
        buffer_id = buffer.take();
      }
    }
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
      std::string normalized;
      const auto projected = vxm_drafts::ProjectDisk(
          std::string_view(reinterpret_cast<const char *>(source), size),
          std::string_view(reinterpret_cast<const char *>(disk), disk_size), ending, normalized);
      source = reinterpret_cast<const uint8_t *>(projected.data());
      size = projected.size();
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
  void owner_summary(EventStorage &out, const Json &value) {
    const auto encoded = value.dump();
    require(encoded.size() <= kOwnerSummary, VXCORE_ERR_UNSUPPORTED);
    std::memcpy(out.body.get(), encoded.data(), encoded.size());
    out.event.data = out.body.get();
    out.event.size = encoded.size();
    copy_field(out.notebook, notebook_id);
    copy_field(out.node, node_id);
  }
  vxm_drafts::OwnerFacts draft_facts(std::string &disk) {
    vxm_drafts::OwnerFacts facts;
    facts.notebook_id = notebook_id;
    facts.node_id = node_id;
    facts.notebook_relative = fs::u8path(notebook_path).filename().u8string();
    Json metadata;
    check(static_cast<VxCoreError>(vxm_transfer::PreflightResource(context, notebook_id,
        node_id, notebook_path, metadata)));
    require(metadata.at("notebookId") == notebook_id && metadata.at("nodeId") == node_id,
            VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    note_metadata();
    buffer_metadata();
    require(metadata.at("notePath") == note_path, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    VxCoreLineEnding ending;
    check(vxcore_buffer_get_line_ending_override(context, buffer_id.c_str(), &ending));
    facts.eol = ending;
    facts.editor_type = editor_type == VXM_EDITOR_MARKDOWN ? "markdown" : "text";
    facts.path_hint = note_path;
    confined(fs::u8path(notebook_path), note_path);
    disk = vxm_import::storage::Read(fs::u8path(notebook_path) / fs::u8path(note_path), kSource);
    source_valid(reinterpret_cast<const uint8_t *>(disk.data()), disk.size());
    facts.disk_hash = vxm_import::storage::Hash(disk);
    facts.exists = facts.ordinary = true;
    return facts;
  }
  void draft(Request &request) {
    const auto input = Json::parse(request.input.begin(), request.input.end());
    const auto root = input.at("draftsRoot").get<std::string>();
    const auto key = input.at("documentKey").get<std::string>();
    const auto token = input.at("token").get<std::string>();
    std::string disk;
    vxm_drafts::OwnerFacts facts;
    try { facts = draft_facts(disk); }
    catch (const Failure &failure) {
      if (request.operation == kDraftWrite || failure.code == VXCORE_ERR_OUT_OF_MEMORY) throw;
      facts.notebook_id = notebook_id;
      facts.node_id = node_id;
      facts.notebook_relative = fs::u8path(notebook_path).filename().u8string();
    } catch (const vxm_import::StorageFailure &failure) {
      if (request.operation == kDraftWrite || failure.code == VXCORE_ERR_OUT_OF_MEMORY) throw;
      facts.notebook_id = notebook_id;
      facts.node_id = node_id;
      facts.notebook_relative = fs::u8path(notebook_path).filename().u8string();
    }
    Json output;
    if (request.operation != kDraftWrite) {
      // Inspection uses the same actual-state matrix as explicit recovery; an
      // observed intended output becomes saved ONLY after the receipt commits.
      check(static_cast<VxCoreError>(vxm_drafts::Reconcile(root, key, token, facts, output)));
    } else {
      require(mode == VXM_MODE_NOTE, VXCORE_ERR_INVALID_STATE);
      const auto candidate_id = input.at("candidateId").get<std::string>();
      vxm_drafts::PreparedSave candidate;
      check(static_cast<VxCoreError>(vxm_drafts::LoadCandidate(root, key, token, candidate_id, candidate)));
      require(candidate.document_key == key && candidate.token == token && candidate.candidate_id == candidate_id &&
              candidate.notebook_id == notebook_id && candidate.node_id == node_id &&
              candidate.notebook_relative == fs::u8path(notebook_path).filename().u8string() &&
              facts.ordinary && facts.exists && candidate.editor_type == facts.editor_type && candidate.eol == facts.eol,
              VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      require(candidate.expected_disk_hash == facts.disk_hash, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      require(vxm_import::storage::Hash(candidate.source) == candidate.source_hash, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      if (candidate.intended_disk_hash != facts.disk_hash) {
        std::string converted;
        const auto intended = vxm_drafts::ProjectDisk(candidate.source, disk, facts.eol, converted);
        require(vxm_import::storage::Hash(intended) == candidate.intended_disk_hash, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        // Core reload verifies that its current raw view agrees with the guarded
        // file read, and clears any prior failed save's in-memory dirty buffer.
        const uint8_t *raw = nullptr;
        size_t size = 0;
        reload(raw, size);
        require(size == disk.size() && (!size || std::memcmp(raw, disk.data(), size) == 0), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        VxCoreLineEnding current_ending;
        check(vxcore_buffer_get_line_ending_override(context, buffer_id.c_str(), &current_ending));
        require(current_ending == candidate.eol &&
                candidate.editor_type == (editor_type == VXM_EDITOR_MARKDOWN ? "markdown" : "text"),
                VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        check(vxcore_buffer_set_content_raw(context, buffer_id.c_str(), intended.data(), intended.size()));
        check(vxcore_buffer_save(context, buffer_id.c_str()));
        reload(raw, size);
        require(size == intended.size() && (!size || std::memcmp(raw, intended.data(), size) == 0), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        facts = draft_facts(disk);
        require(facts.disk_hash == candidate.intended_disk_hash && facts.eol == candidate.eol &&
                facts.editor_type == candidate.editor_type, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      }
      // No source watermark changes until this durable publication succeeds.
      // On failure the candidate remains the reconciliation authority.
      check(static_cast<VxCoreError>(vxm_drafts::CommitSaved(root, key, token, candidate_id, facts, output)));
    }
    owner_summary(*request.result, output);
  }
  void preview(Request &request) {
    note_metadata();
    buffer_metadata();
    require(editor_type == VXM_EDITOR_MARKDOWN, VXCORE_ERR_UNSUPPORTED);
    Json output;
    check(static_cast<VxCoreError>(vxm_preview::Prepare(context, notebook_id, node_id,
        note_path, notebook_path, Json::parse(request.command), request.input.data(),
        request.input.size(), &read_cancelled, output)));
    owner_summary(*request.result, output);
  }
  int32_t teardown() noexcept {
    std::lock_guard<std::mutex> core_lock(core_owner_gate);
    int32_t result = VXCORE_OK;
    if (context) {
      result = sync.Shutdown();
      if (mode == VXM_MODE_SYNC_CLONE) notebook_id = sync.NotebookId();
      if (!buffer_id.empty()) {
        const auto code = vxcore_buffer_close(context, buffer_id.c_str());
        if (result == VXCORE_OK) result = code;
      }
      // Transient NOTE/CATALOG owners must retain the per-device metadata DB,
      // including last-success time. Context destruction closes its handles;
      // explicit notebook close deletes that DB and is only needed by a clone's
      // private registration before its publication receipt is issued.
      if (mode == VXM_MODE_SYNC_CLONE && !notebook_id.empty()) {
        const auto code = vxcore_notebook_close(context, notebook_id.c_str());
        if (result == VXCORE_OK) result = code;
      }
      const auto code = vxcore_prepare_shutdown(context);
      if (result == VXCORE_OK) result = code;
      vxcore_context_destroy(context);
      context = nullptr;
    }
    if (owns_root && mode != VXM_MODE_SYNC_CLONE) owned_notebooks.erase(owned_root);
    return result;
  }
  void run() noexcept {
    for (;;) {
      std::unique_ptr<Request> request;
      bool completing_sync = false;
      {
        std::unique_lock<std::mutex> lock(mutex);
        wake.wait(lock, [this] { return sync_ready || pending_size || (stopping && !sync_running); });
        if (sync_ready) {
          completing_sync = true;
          sync_ready = false;
          request = std::move(sync_request);
        } else {
          if (!pending_size) break;
          request.reset(pending[pending_start]);
          pending_start = (pending_start + 1) % pending.size();
          --pending_size;
          if (stopping) request->cancelled.store(true);
        }
        const auto kind = request->result->event.kind;
        if (kind == VXM_EVENT_SYNC) active_sync_command = request.get();
        if ((kind == VXM_EVENT_QUERY && request->operation == kSearch) ||
            kind == VXM_EVENT_EXPORT || kind == VXM_EVENT_PREVIEW ||
            (kind == VXM_EVENT_COHORT && request->operation == kBuild) ||
            (kind == VXM_EVENT_RESOURCE && (request->operation == kResourceList || request->operation == kResourceExport))) {
          active_read_only = request->result->event.request_id;
          read_cancelled.store(request->cancelled, std::memory_order_relaxed);
        }
      }
      // A completion has dedicated capacity: it never competes for admission.
      // Joining here, before taking G, also makes close safe during stage/apply.
      if (completing_sync && sync_worker.joinable()) sync_worker.join();
      auto &event = request->result->event;
      const char *failure_message = nullptr;
      try {
        require(completing_sync || !request->cancelled, VXCORE_ERR_CANCELLED);
        std::lock_guard<std::mutex> core_lock(core_owner_gate);
        if (completing_sync) {
          const auto output = sync.Complete(*sync_work);
          const auto encoded = output.dump();
          require(encoded.size() <= request->result->reserved_output - kMetadata, VXCORE_ERR_UNSUPPORTED);
          std::memcpy(request->result->body.get(), encoded.data(), encoded.size());
          event.data = request->result->body.get(); event.size = encoded.size();
          event.code = output.at("code").get<int32_t>();
        } else if (opening_event(event.kind)) initialize(*request);
        else {
          require(init_error == VXCORE_OK, init_error);
          if (event.kind == VXM_EVENT_SYNC) {
            require(!sync_running, VXCORE_ERR_SYNC_IN_PROGRESS);
            Json output;
            sync_work = sync.Prepare(vxm_import::storage::Parse(request->command, kString),
                request->input.empty() ? nullptr : reinterpret_cast<const char *>(request->input.data()), output);
            if (!request->input.empty()) sodium_memzero(request->input.data(), request->input.size());
            if (sync_work) {
              {
                std::lock_guard<std::mutex> lock(mutex);
                sync_running = true;
                if (request->cancelled.load() || stopping) sync.Cancel(sync_work->operation_id);
              }
              try {
                sync_worker = std::thread([this] {
                  if (sync_work->action == "stage" || sync_work->action == "apply") {
                    std::lock_guard<std::mutex> gate(core_owner_gate);
                    sync.Execute(*sync_work);
                  } else sync.Execute(*sync_work);
                  { std::lock_guard<std::mutex> lock(mutex); sync_ready = true; }
                  wake.notify_one();
                });
              } catch (...) {
                sync.Abort(*sync_work);
                sync_work.reset();
                { std::lock_guard<std::mutex> lock(mutex); sync_running = false; }
                throw;
              }
              sync_request = std::move(request);
              continue;
            }
            const auto encoded = output.dump();
            require(encoded.size() <= request->result->reserved_output - kMetadata, VXCORE_ERR_UNSUPPORTED);
            std::memcpy(request->result->body.get(), encoded.data(), encoded.size());
            event.data = request->result->body.get(); event.size = encoded.size();
            event.code = output.value("code", int32_t(VXCORE_OK));
          } else {
            require(sync.Allows(event.kind), VXCORE_ERR_SYNC_IN_PROGRESS);
            if (event.kind == VXM_EVENT_DRAFT && request->operation == kDraftWrite)
              require(sync.Allows(VXM_EVENT_WRITE), VXCORE_ERR_SYNC_IN_PROGRESS);
            if (event.kind == VXM_EVENT_READ) read_note(*request);
          else if (event.kind == VXM_EVENT_WRITE) write_note(*request);
          else if (event.kind == VXM_EVENT_DRAFT) draft(*request);
          else if (event.kind == VXM_EVENT_PREVIEW) preview(*request);
          else if (event.kind == VXM_EVENT_LIST) list_catalog(*request);
          else if (event.kind == VXM_EVENT_MUTATE) mutate_catalog(*request);
          else if (event.kind == VXM_EVENT_QUERY) query_catalog(*request);
          else if (event.kind == VXM_EVENT_TAG) tag_catalog(*request);
          else if (event.kind == VXM_EVENT_EXPORT) export_catalog(*request);
          else if (transfer_event(event.kind)) transfer(*request);
          else throw Failure{VXCORE_ERR_INVALID_STATE};
          }
        }
      } catch (const Failure &failure) { event.code = failure.code; failure_message = failure.message; }
      catch (const vxm_import::StorageFailure &failure) { event.code = failure.code; }
      catch (const std::bad_alloc &) { event.code = VXCORE_ERR_OUT_OF_MEMORY; }
      catch (const Json::exception &) { event.code = VXCORE_ERR_JSON_PARSE; }
      catch (const fs::filesystem_error &) { event.code = VXCORE_ERR_IO; }
      catch (...) { event.code = VXCORE_ERR_UNKNOWN; }
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (active_read_only == event.request_id) {
          // Cancel's accepted result and the terminal outcome linearize under
          // the same mutex: no accepted cancellation can turn into late success.
          if (read_cancelled.load(std::memory_order_relaxed)) event.code = VXCORE_ERR_CANCELLED;
          active_read_only = 0;
          read_cancelled.store(false, std::memory_order_relaxed);
        }
      }
      if (completing_sync) {
        if (event.size == 0) sync.Abort(*sync_work);
        sync_work.reset();
        std::lock_guard<std::mutex> lock(mutex);
        sync_running = false;
      }
      {
        std::lock_guard<std::mutex> lock(mutex);
        if (active_sync_command == request.get()) active_sync_command = nullptr;
      }
      if (event.kind == VXM_EVENT_SYNC && event.size == 0) {
        // Reserved terminal storage survives dispatch errors; never erase an
        // apply failure merely because the ordinary error path drops payloads.
        try {
          const auto command = Json::parse(request->command);
          if (command.at("action") != "inspect") {
            const auto body = Json{{"action", command.at("action")}, {"operationId", command.at("operationId")},
                {"code", event.code}, {"executed", completing_sync}, {"committed", false},
                {"cleanupRequired", completing_sync}, {"refreshRequired", sync.RefreshRequired()},
                {"changedPaths", nullptr}, {"refreshCode", nullptr}, {"didCommit", false},
                {"settled", false}, {"notebookId", notebook_id.empty() ? Json(nullptr) : Json(notebook_id)},
                {"cloneReceipt", nullptr}}.dump();
            std::memcpy(request->result->body.get(), body.data(), body.size());
            event.data = request->result->body.get(); event.size = body.size();
          }
        } catch (...) { /* The nonzero terminal code still reports allocation failure. */ }
      }
      if (opening_event(event.kind)) init_error = event.code;
      event.message = event.code != VXCORE_ERR_CANCELLED && failure_message ? failure_message :
          event.kind == VXM_EVENT_EXPORT ? export_redacted(event.code) :
          transfer_event(event.kind) || event.kind == VXM_EVENT_RESOURCE_OPEN || event.kind == VXM_EVENT_COHORT_OPEN
              ? transfer_redacted(event.code) : redacted(event.code);
      if (event.code != VXCORE_OK && event.kind != VXM_EVENT_SYNC) {
        event.size = 0;
        event.data = nullptr;
        if (event.kind == VXM_EVENT_QUERY || event.kind == VXM_EVENT_EXPORT || event.kind == VXM_EVENT_DRAFT || event.kind == VXM_EVENT_PREVIEW || transfer_event(event.kind)) request->result->body.reset();
        if (event.kind == VXM_EVENT_CATALOG_OPEN || event.kind == VXM_EVENT_LIST || event.kind == VXM_EVENT_QUERY || event.kind == VXM_EVENT_EXPORT || event.kind == VXM_EVENT_DRAFT || event.kind == VXM_EVENT_PREVIEW || transfer_event(event.kind))
          request->result->shrink(0);
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
    closed->event.code = close_code = teardown();
    closed->event.message = redacted(closed->event.code);
    publish(std::move(closed));
  }
};

namespace {
int32_t admit(VxmHost &host, int32_t kind, uint64_t id, uint64_t generation,
              uint64_t revision, const char *hash, const uint8_t *data, uint64_t size,
              size_t metadata_cost = 0, int32_t operation = 0,
              const char *node = nullptr, const char *name = nullptr, const char *destination = nullptr,
              uint64_t staging_budget = 0, int32_t export_format = VXM_EXPORT_NOTEBOOK,
              const char *command = nullptr) {
  try {
    require(revision <= kMaxRevision);
    source_valid(data, size);
    if (kind == VXM_EVENT_WRITE) require(valid_hash(hash));
    const bool exporting = kind == VXM_EVENT_EXPORT;
    require(!exporting || export_format == VXM_EXPORT_NOTEBOOK || export_format == VXM_EXPORT_FILES_AND_ASSETS);
    require(!exporting || host.export_only, VXCORE_ERR_INVALID_STATE);
    require(!host.export_only || (kind != VXM_EVENT_MUTATE && kind != VXM_EVENT_TAG && kind != VXM_EVENT_WRITE && kind != VXM_EVENT_DRAFT && kind != VXM_EVENT_PREVIEW && kind != VXM_EVENT_SYNC && !transfer_event(kind)),
            VXCORE_ERR_INVALID_STATE);
    const bool query = kind == VXM_EVENT_QUERY;
    const bool catalog = kind == VXM_EVENT_CATALOG_OPEN || kind == VXM_EVENT_LIST || query;
    const bool source = kind == VXM_EVENT_OPEN || kind == VXM_EVENT_READ;
    const bool transfer = transfer_event(kind);
    if (kind == VXM_EVENT_SYNC)
      require(host.mode == VXM_MODE_NOTE || host.mode == VXM_MODE_CATALOG || host.mode == VXM_MODE_SYNC_CLONE, VXCORE_ERR_INVALID_STATE);
    else if (kind == VXM_EVENT_SYNC_CLONE_OPEN)
      require(host.mode == VXM_MODE_SYNC_CLONE, VXCORE_ERR_INVALID_STATE);
    else if (kind == VXM_EVENT_RESOURCE || kind == VXM_EVENT_RESOURCE_OPEN || kind == VXM_EVENT_DRAFT)
      require(host.mode == VXM_MODE_NOTE || host.mode == VXM_MODE_RESOURCES, VXCORE_ERR_INVALID_STATE);
    else if (kind == VXM_EVENT_COHORT)
      require(host.mode == VXM_MODE_CATALOG || host.mode == VXM_MODE_COHORT_BUILDER, VXCORE_ERR_INVALID_STATE);
    else if (kind == VXM_EVENT_COHORT_OPEN)
      require(host.mode == VXM_MODE_COHORT_BUILDER, VXCORE_ERR_INVALID_STATE);
    else require((catalog || exporting || kind == VXM_EVENT_MUTATE || kind == VXM_EVENT_TAG) ? host.mode == VXM_MODE_CATALOG : host.mode == VXM_MODE_NOTE, VXCORE_ERR_INVALID_STATE);
    if (query || kind == VXM_EVENT_TAG) operation = catalog_operation(data, static_cast<size_t>(size), kind);
    if (transfer) operation = transfer_operation(data, static_cast<size_t>(size), kind, host.mode);
    if (kind == VXM_EVENT_DRAFT) operation = draft_operation(data, static_cast<size_t>(size), host.mode);
    auto command_value = optional_string(command);
    std::string sync_operation;
    if (kind == VXM_EVENT_PREVIEW) preview_command(command_value);
    if (kind == VXM_EVENT_SYNC) {
      const auto parsed = vxm_import::storage::Parse(command_value, kString);
      vxm_sync::ValidateCommand(parsed, host.mode == VXM_MODE_SYNC_CLONE);
      sync_operation = parsed.value("operationId", "");
      operation = parsed.at("action") == "inspect" || parsed.at("action") == "apply" ? 1 : 0;
      require(size <= kString);
      const auto action = parsed.at("action").get<std::string>();
      const bool needs_credentials = action == "enable" || action == "credentials" || action == "credentialRecovery" || action == "clone";
      require(needs_credentials == (size != 0));
      // Core prepare performs the closed credential-schema validation. The
      // bridge owns one transient copy, never another parsed password object.
      if (size) require(std::find(data, data + static_cast<size_t>(size), uint8_t(0)) == data + static_cast<size_t>(size));
    }
    auto node_value = optional_string(node);
    auto name_value = optional_string(name);
    auto destination_value = optional_string(destination);
    require(node_value.size() < 128 && (exporting || destination_value.size() < 128));
    if (exporting) require(!destination_value.empty() && staging_budget > 0 && staging_budget <= kExportStaging);
    if (kind == VXM_EVENT_MUTATE) {
      require(operation >= VXM_CREATE_NOTE && operation <= VXM_RENAME_NOTEBOOK && !node_value.empty());
      const bool named = operation == VXM_CREATE_NOTE || operation == VXM_CREATE_FOLDER || operation == VXM_RENAME || operation == VXM_RENAME_NOTEBOOK;
      require(named == !name_value.empty() && (operation == VXM_MOVE) == !destination_value.empty());
      if (operation == VXM_RENAME_NOTEBOOK) display_name(name_value);
    }
    std::lock_guard<std::mutex> lock(host.mutex);
    require(!host.stopping && generation == host.generation && id > host.last_request && id <= kMaxRevision, VXCORE_ERR_INVALID_STATE);
    std::lock_guard<std::mutex> capacity_lock(host.capacity->mutex);
    const size_t input_cost = static_cast<size_t>(size) + metadata_cost + node_value.size() + name_value.size() + destination_value.size() + command_value.size() + sync_operation.size() + (kind == VXM_EVENT_SYNC && size ? 1 : 0) + (hash ? 64 : 0);
    const bool owner_json = kind == VXM_EVENT_DRAFT || kind == VXM_EVENT_PREVIEW;
    const size_t body_cost = kind == VXM_EVENT_SYNC ? (operation ? kCatalog : kOwnerSummary) : owner_json ? kOwnerSummary : transfer ? (operation == kResourceList ? kCatalog : kString) :
        exporting ? kExportSummary : catalog ? kCatalog : source ? kSource : 0;
    const size_t output_cost = kMetadata + body_cost;
    auto &capacity = *host.capacity;
    require(capacity.operations < VXM_MAX_OPERATIONS && input_cost <= VXM_MAX_INPUT_BYTES - capacity.input && output_cost <= VXM_MAX_OUTPUT_BYTES - capacity.output, VXCORE_ERR_OUT_OF_MEMORY);
    auto request = std::make_unique<Request>();
    request->result = std::make_unique<EventStorage>();
    auto &result = *request->result;
    if (source || query || exporting || transfer || owner_json || kind == VXM_EVENT_SYNC) result.body.reset(new uint8_t[body_cost]);
    if (size) {
      request->input.reserve(static_cast<size_t>(size) + (kind == VXM_EVENT_SYNC ? 1 : 0));
      request->input.assign(data, data + static_cast<size_t>(size));
      if (kind == VXM_EVENT_SYNC) request->input.push_back(0);
    }
    if (hash) request->expected_hash = hash;
    request->node = std::move(node_value);
    request->name = kind == VXM_EVENT_SYNC ? std::move(sync_operation) : std::move(name_value);
    request->sensitive = kind == VXM_EVENT_SYNC;
    request->destination = std::move(destination_value);
    request->command = std::move(command_value);
    request->operation = operation;
    request->input_cost = input_cost;
    request->staging_budget = staging_budget;
    request->export_format = export_format;
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
  catch (const vxm_import::StorageFailure &failure) { return failure.code; }
  catch (const std::bad_alloc &) { return VXCORE_ERR_OUT_OF_MEMORY; }
  catch (const Json::exception &) { return VXCORE_ERR_INVALID_PARAM; }
  catch (...) { return VXCORE_ERR_UNKNOWN; }
}
int32_t admit_catalog_json(VxmHost *host, int32_t kind, uint64_t id,
                           uint64_t generation, const char *json) {
  if (!host) return VXCORE_ERR_NULL_POINTER;
  try {
    const auto size = bounded_length(json, kString);
    return admit(*host, kind, id, generation, 0, nullptr,
                 reinterpret_cast<const uint8_t *>(json), size);
  } catch (const Failure &failure) { return failure.code; }
}
}  // namespace

extern "C" {
int32_t vxm_host_create(const VxmOpenOptions *options, VxmNotify notify, int64_t token, VxmHost **out_host) {
  if (out_host) *out_host = nullptr;
  if (!options || !notify || !out_host || token <= 0) return VXCORE_ERR_INVALID_PARAM;
  std::unique_ptr<VxmHost> host;
  try {
    require(options->mode == VXM_MODE_NOTE || options->mode == VXM_MODE_CATALOG ||
            options->mode == VXM_MODE_COHORT_BUILDER || options->mode == VXM_MODE_RESOURCES || options->mode == VXM_MODE_SYNC_CLONE);
    require(options->create_notebook == 0 || options->create_notebook == 1);
    require(options->export_only == 0 || options->export_only == 1);
    host = std::make_unique<VxmHost>();
    host->notify = notify;
    host->token = token;
    const bool clone = options->mode == VXM_MODE_SYNC_CLONE;
    const bool builder = options->mode == VXM_MODE_COHORT_BUILDER || clone;
    host->app_path = builder ? optional_string(options->app_data_path) : input_string(options->app_data_path);
    host->local_path = builder ? optional_string(options->local_data_path) : input_string(options->local_data_path);
    host->notebook_path = builder ? optional_string(options->notebook_path) : input_string(options->notebook_path);
    host->transaction_root = optional_string(options->transaction_root);
    require(builder ? !host->transaction_root.empty() : host->transaction_root.empty());
    if (builder) require(host->app_path.empty() && host->local_path.empty() && host->notebook_path.empty() &&
                         options->create_notebook == 0 && options->export_only == 0 &&
                         fs::u8path(host->transaction_root).is_absolute());
    host->mode = options->mode;
    host->create_notebook = options->create_notebook == 1;
    host->export_only = options->export_only == 1;
    host->notebook_name = optional_string(options->notebook_name);
    host->expected_notebook_id = optional_string(options->expected_notebook_id);
    host->node_id = optional_string(options->node_id);
    require(host->expected_notebook_id.size() < 128 && host->node_id.size() < 128);
    if (host->export_only)
      require(host->mode == VXM_MODE_CATALOG && !host->create_notebook && !host->expected_notebook_id.empty());
    if (host->create_notebook) {
      require(host->mode == VXM_MODE_CATALOG && host->expected_notebook_id.empty());
      display_name(host->notebook_name);
    } else require(host->notebook_name.empty());
    if (host->mode == VXM_MODE_NOTE || host->mode == VXM_MODE_RESOURCES)
      require(!host->expected_notebook_id.empty() && !host->node_id.empty());
    else require(host->node_id.empty());
    if (builder) require(host->expected_notebook_id.empty());
    const auto cost = host->app_path.size() + host->local_path.size() + host->notebook_path.size() + host->notebook_name.size() + host->expected_notebook_id.size() + host->node_id.size() + host->transaction_root.size();
    const auto kind = host->mode == VXM_MODE_NOTE ? VXM_EVENT_OPEN :
        host->mode == VXM_MODE_RESOURCES ? VXM_EVENT_RESOURCE_OPEN :
        clone ? VXM_EVENT_SYNC_CLONE_OPEN : builder ? VXM_EVENT_COHORT_OPEN : VXM_EVENT_CATALOG_OPEN;
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
int32_t vxm_host_catalog_query(VxmHost *host, uint64_t id, uint64_t generation, const char *json) {
  return admit_catalog_json(host, VXM_EVENT_QUERY, id, generation, json);
}
int32_t vxm_host_catalog_tag(VxmHost *host, uint64_t id, uint64_t generation, const char *json) {
  return admit_catalog_json(host, VXM_EVENT_TAG, id, generation, json);
}
int32_t vxm_host_cohort(VxmHost *host, uint64_t id, uint64_t generation, const char *json) {
  return admit_catalog_json(host, VXM_EVENT_COHORT, id, generation, json);
}
int32_t vxm_host_resource(VxmHost *host, uint64_t id, uint64_t generation, const char *json) {
  return admit_catalog_json(host, VXM_EVENT_RESOURCE, id, generation, json);
}
int32_t vxm_host_draft(VxmHost *host, uint64_t id, uint64_t generation, const char *json) {
  return admit_catalog_json(host, VXM_EVENT_DRAFT, id, generation, json);
}
int32_t vxm_host_preview(VxmHost *host, uint64_t id, uint64_t generation,
                         const char *json, const uint8_t *source, uint64_t size) {
  return host ? admit(*host, VXM_EVENT_PREVIEW, id, generation, 0, nullptr, source, size,
                       0, 0, nullptr, nullptr, nullptr, 0, VXM_EXPORT_NOTEBOOK, json) : VXCORE_ERR_NULL_POINTER;
}
int32_t vxm_host_catalog_export(VxmHost *host, uint64_t id, uint64_t generation, int32_t format,
                                const char *destination, uint64_t staging_budget_bytes) {
  return host ? admit(*host, VXM_EVENT_EXPORT, id, generation, 0, nullptr, nullptr, 0,
                       0, 0, nullptr, nullptr, destination, staging_budget_bytes, format) : VXCORE_ERR_NULL_POINTER;
}
int32_t vxm_host_sync(VxmHost *host, uint64_t id, uint64_t generation,
                       const char *command, const char *credentials) {
  if (!host) return VXCORE_ERR_NULL_POINTER;
  try {
    const auto size = credentials ? bounded_length(credentials, kString) : 0;
    return admit(*host, VXM_EVENT_SYNC, id, generation, 0, nullptr,
        reinterpret_cast<const uint8_t *>(credentials), size, 0, 0, nullptr, nullptr, nullptr,
        0, VXM_EXPORT_NOTEBOOK, command);
  } catch (const Failure &failure) { return failure.code; }
  catch (...) { return VXCORE_ERR_INVALID_PARAM; }
}
int32_t vxm_host_sync_cancel(VxmHost *host, uint64_t generation, const char *operation) {
  if (!host || !operation) return VXCORE_ERR_NULL_POINTER;
  try {
    const auto value = input_string(operation);
    require(vxm_sync::Uuid(value));
    std::lock_guard<std::mutex> lock(host->mutex);
    require(generation == host->generation, VXCORE_ERR_INVALID_STATE);
    bool found = false;
    if (host->active_sync_command && host->active_sync_command->name == value) {
      host->active_sync_command->cancelled.store(true); found = true;
    }
    for (size_t i = 0; i < host->pending_size; ++i) {
      auto &request = *host->pending[(host->pending_start + i) % host->pending.size()];
      if (request.result->event.kind == VXM_EVENT_SYNC &&
          request.name == value) {
        request.cancelled = true; found = true;
      }
    }
    const auto code = host->sync.Cancel(value);
    return found ? VXCORE_OK : code;
  } catch (const Failure &failure) { return failure.code; }
  catch (...) { return VXCORE_ERR_INVALID_PARAM; }
}
int32_t vxm_host_cancel(VxmHost *host, uint64_t id, uint64_t generation) {
  if (!host) return VXCORE_ERR_NULL_POINTER;
  std::lock_guard<std::mutex> lock(host->mutex);
  if (generation != host->generation) return VXCORE_ERR_INVALID_STATE;
  if (id && host->active_read_only == id) {
    host->read_cancelled.store(true, std::memory_order_relaxed);
    return VXCORE_OK;
  }
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
  host->sync.Stop();
  if (host->active_read_only) host->read_cancelled.store(true, std::memory_order_relaxed);
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
  // Only a completed clone whose transaction-private owner has joined may mint
  // the sibling permit. Failure leaves an incomplete wrapper, never a cursor
  // reconstructed from state.json by a later filesystem command.
  if (host->mode == VXM_MODE_SYNC_CLONE && host->close_code == VXCORE_OK && host->sync.CloneCommitted())
    vxm_import::SealClone(host->transaction_root, host->sync.CloneOperation(), host->sync.NotebookId(), host->sync.CloneAutoSyncEnabled());
  if (host->mode == VXM_MODE_SYNC_CLONE && host->owns_root) {
    // Keep the unpacked root unavailable to every other owner through receipt
    // minting, not merely through private-context teardown.
    std::lock_guard<std::mutex> gate(core_owner_gate);
    owned_notebooks.erase(host->owned_root);
  }
  while (auto *event = vxm_host_take_event(host)) vxm_event_free(event);
  delete host;
}
}  // extern "C"
