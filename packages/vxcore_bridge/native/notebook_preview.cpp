// SPDX-License-Identifier: LGPL-3.0-only
#include "notebook_preview.h"
#include "notebook_import.h"
#include "notebook_transfers.h"
#include "vxcore_host.h"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string_view>
#include <vector>
#include <cmark.h>
#include <sodium.h>
#include <utf8proc.h>

namespace {
namespace fs = std::filesystem;
namespace disk = vxm_import::storage;
using Json = nlohmann::json;
constexpr size_t kSource = 4 * 1024 * 1024, kManifest = 16 * 1024 * 1024;
constexpr uint64_t kFile = 16ULL * 1024 * 1024, kTotal = 64ULL * 1024 * 1024;
constexpr uint64_t kPixels = 16000000, kRevision = 9007199254740991ULL;
constexpr size_t kHandles = 200, kNodes = 100000, kHeader = 256 * 1024;
std::mutex preview_mutex;
void require(bool value, int32_t code = VXCORE_ERR_INVALID_PARAM) { disk::Check(value, code); }
void check(int32_t code) { require(code == VXCORE_OK, code); }
void cancelled(const std::atomic<bool> *cancel) {
  require(!cancel || !cancel->load(std::memory_order_relaxed), VXCORE_ERR_CANCELLED);
}
void keys(const Json &value, std::initializer_list<const char *> expected) {
  require(value.is_object() && value.size() == expected.size(), VXCORE_ERR_JSON_PARSE);
  for (const auto *key : expected) require(value.contains(key), VXCORE_ERR_JSON_PARSE);
}
const std::string &text(const Json &value, size_t limit = 16384, bool empty = false) {
  require(value.is_string(), VXCORE_ERR_JSON_PARSE);
  const auto &result = value.get_ref<const std::string &>();
  require((empty || !result.empty()) && result.size() <= limit && result.find('\0') == std::string::npos, VXCORE_ERR_JSON_PARSE);
  return result;
}
uint64_t number(const Json &value, uint64_t maximum) {
  require(value.is_number_unsigned() || (value.is_number_integer() && value.get<int64_t>() >= 0), VXCORE_ERR_JSON_PARSE);
  const auto result = value.get<uint64_t>();
  require(result <= maximum, VXCORE_ERR_UNSUPPORTED);
  return result;
}
const std::string &hex(const Json &value, size_t length = 32) {
  const auto &result = text(value, length);
  require(result.size() == length && std::all_of(result.begin(), result.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  }), VXCORE_ERR_JSON_PARSE);
  return result;
}
void utf8(std::string_view value, bool uri = false) {
  for (size_t i = 0; i < value.size();) {
    utf8proc_int32_t point = 0;
    const auto count = utf8proc_iterate(reinterpret_cast<const uint8_t *>(value.data() + i), value.size() - i, &point);
    require(count > 0 && point != 0, VXCORE_ERR_UNSUPPORTED);
    if (uri) require(point >= 32 && point != 127 && !(point >= 128 && point <= 159) && point != '\\', VXCORE_ERR_UNSUPPORTED);
    i += static_cast<size_t>(count);
  }
}
std::string random_id() {
  require(sodium_init() >= 0, VXCORE_ERR_NOT_INITIALIZED);
  unsigned char bytes[16]; char result[33];
  randombytes_buf(bytes, sizeof(bytes));
  sodium_bin2hex(result, sizeof(result), bytes, sizeof(bytes));
  return result;
}
const std::string &process_token() {
  static const std::string value = random_id();
  return value;
}
Json consumer_lease(const std::string &id, const Json &preview, const Json &render) {
  return {{"version", 2}, {"kind", "consumer"}, {"id", id}, {"process", process_token()},
          {"previewId", preview}, {"renderId", render}};
}
std::string lower(std::string value) {
  for (auto &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
  return value;
}
std::string parent(const std::string &path) {
  const auto slash = path.rfind('/');
  return slash == std::string::npos ? std::string() : path.substr(0, slash);
}
bool beneath(const std::string &path, const std::string &prefix) {
  return path == prefix || (path.size() > prefix.size() && path.compare(0, prefix.size() + 1, prefix + "/") == 0);
}
int digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}
std::string decode(std::string_view value, bool path) {
  std::string out; out.reserve(value.size());
  for (size_t i = 0; i < value.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(value[i]);
    if (c == '%') {
      require(i + 2 < value.size(), VXCORE_ERR_UNSUPPORTED);
      const auto a = digit(value[i + 1]), b = digit(value[i + 2]);
      require(a >= 0 && b >= 0, VXCORE_ERR_UNSUPPORTED);
      c = static_cast<unsigned char>((a << 4) | b); i += 2;
      // A second decoding pass must never turn a literal filename into traversal.
      require(c != '%' && (!path || (c != '/' && c != '\\')), VXCORE_ERR_UNSUPPORTED);
    }
    require(c >= 32 && c != 127 && c != '\\', VXCORE_ERR_UNSUPPORTED);
    out.push_back(static_cast<char>(c));
  }
  utf8(out, true);
  return out;
}
std::string confined_path(const std::string &note, std::string_view destination,
                          const std::string &recycle) {
  const auto decoded = decode(destination, true);
  require(!decoded.empty() && decoded.front() != '/' && decoded.find(':') == std::string::npos &&
          decoded.find('?') == std::string::npos, VXCORE_ERR_UNSUPPORTED);
  std::vector<std::string> components;
  for (const auto &part : fs::u8path(parent(note))) components.push_back(part.u8string());
  size_t start = 0;
  for (;;) {
    const auto end = decoded.find('/', start);
    const auto component = decoded.substr(start, end == std::string::npos ? end : end - start);
    require(!component.empty(), VXCORE_ERR_UNSUPPORTED);
    if (component == "..") {
      require(!components.empty(), VXCORE_ERR_UNSUPPORTED); components.pop_back();
    } else if (component != ".") {
      disk::Name(component);
      const auto folded = disk::Fold(component);
      require(component.front() != '.' && folded != "vx_notebook", VXCORE_ERR_UNSUPPORTED);
      components.push_back(component);
    }
    require(components.size() <= 64, VXCORE_ERR_UNSUPPORTED);
    if (end == std::string::npos) break;
    start = end + 1;
  }
  std::string out;
  for (const auto &part : components) { if (!out.empty()) out += '/'; out += part; }
  disk::Relative(out);
  require(!beneath(disk::Fold(out), disk::Fold(recycle)), VXCORE_ERR_UNSUPPORTED);
  return out;
}
void exact_path(const fs::path &root, const std::string &relative) {
  auto current = root;
  for (const auto &part : fs::u8path(relative)) {
    require(disk::Info(current).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
    bool found = false; size_t count = 0;
    const auto name = part.u8string(), folded = disk::Fold(name);
    for (const auto &entry : fs::directory_iterator(current)) {
      require(++count <= kNodes, VXCORE_ERR_UNSUPPORTED);
      const auto actual = entry.path().filename().u8string();
      if (disk::Fold(actual) != folded) continue;
      require(actual == name && !found, VXCORE_ERR_UNSUPPORTED);
      disk::Info(entry.path()); found = true;
    }
    require(found, VXCORE_ERR_NOT_FOUND);
    current /= part;
  }
}
struct CoreString {
  char *value = nullptr;
  ~CoreString() { if (value) vxcore_string_free(value); }
  std::string str() const {
    require(value != nullptr, VXCORE_ERR_INVALID_STATE);
    size_t size = 0; while (size <= kManifest && value[size]) ++size;
    require(size <= kManifest, VXCORE_ERR_UNSUPPORTED);
    return std::string(value, size);
  }
};
void ipv4(std::string_view address) {
  size_t start = 0, groups = 0;
  for (;;) {
    const auto end = address.find('.', start);
    const auto part = address.substr(start, end == std::string_view::npos ? end : end - start);
    require(!part.empty() && part.size() <= 3 && (part.size() == 1 || part.front() != '0'), VXCORE_ERR_UNSUPPORTED);
    unsigned value = 0;
    for (char c : part) { require(c >= '0' && c <= '9', VXCORE_ERR_UNSUPPORTED); value = value * 10 + c - '0'; }
    require(value <= 255 && ++groups <= 4, VXCORE_ERR_UNSUPPORTED);
    if (end == std::string_view::npos) break;
    start = end + 1;
  }
  require(groups == 4, VXCORE_ERR_UNSUPPORTED);
}
void ipv6(std::string_view address) {
  size_t start = 0, groups = 0; bool compressed = false;
  if (!address.empty() && address.front() == ':') {
    require(address.size() >= 2 && address[1] == ':', VXCORE_ERR_UNSUPPORTED);
    compressed = true; start = 2;
  }
  while (start < address.size()) {
    const auto end = address.find(':', start);
    const auto part = address.substr(start, end == std::string_view::npos ? end : end - start);
    if (part.find('.') != std::string_view::npos) {
      require(end == std::string_view::npos, VXCORE_ERR_UNSUPPORTED);
      ipv4(part); groups += 2; break;
    }
    require(!part.empty() && part.size() <= 4, VXCORE_ERR_UNSUPPORTED);
    for (char c : part) require(digit(c) >= 0, VXCORE_ERR_UNSUPPORTED);
    require(++groups <= 8, VXCORE_ERR_UNSUPPORTED);
    if (end == std::string_view::npos) break;
    start = end + 1;
    require(start < address.size(), VXCORE_ERR_UNSUPPORTED);
    if (address[start] == ':') {
      require(!compressed, VXCORE_ERR_UNSUPPORTED); compressed = true; ++start;
    }
  }
  require(compressed ? groups < 8 : groups == 8, VXCORE_ERR_UNSUPPORTED);
}
Json external(const std::string &url) {
  utf8(url, true);
  require(url.find(' ') == std::string::npos, VXCORE_ERR_UNSUPPORTED);
  decode(url, false); // Validate percent escapes and encoded controls, without rewriting URL.
  const auto scheme_end = url.find("://");
  require(scheme_end != std::string::npos, VXCORE_ERR_UNSUPPORTED);
  const auto scheme = lower(url.substr(0, scheme_end));
  require(scheme == "http" || scheme == "https", VXCORE_ERR_UNSUPPORTED);
  const auto start = scheme_end + 3, end = url.find_first_of("/?#", start);
  const auto authority = url.substr(start, end == std::string::npos ? end : end - start);
  require(!authority.empty() && authority.size() <= 253 && authority.find('@') == std::string::npos &&
          authority.find('%') == std::string::npos, VXCORE_ERR_UNSUPPORTED);
  std::string host, port;
  if (authority.front() == '[') {
    const auto close = authority.find(']');
    require(close != std::string::npos && close > 1, VXCORE_ERR_UNSUPPORTED);
    host = authority.substr(0, close + 1);
    ipv6(std::string_view(host).substr(1, host.size() - 2));
    if (close + 1 != authority.size()) {
      require(authority[close + 1] == ':', VXCORE_ERR_UNSUPPORTED); port = authority.substr(close + 2);
      require(!port.empty(), VXCORE_ERR_UNSUPPORTED);
    }
  } else {
    const auto colon = authority.find(':');
    host = authority.substr(0, colon);
    if (colon != std::string::npos) { port = authority.substr(colon + 1); require(!port.empty(), VXCORE_ERR_UNSUPPORTED); }
    require(!host.empty() && host.front() != '.' && host.back() != '.', VXCORE_ERR_UNSUPPORTED);
    size_t label = 0;
    for (size_t i = 0; i < host.size(); ++i) {
      const auto c = host[i];
      require((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.', VXCORE_ERR_UNSUPPORTED);
      if (c == '.') { require(label > 0 && host[i - 1] != '-', VXCORE_ERR_UNSUPPORTED); label = 0; }
      else { require((label || c != '-') && ++label <= 63, VXCORE_ERR_UNSUPPORTED); }
    }
    require(label && host.back() != '-', VXCORE_ERR_UNSUPPORTED);
    const auto last_dot = host.rfind('.');
    const auto last_label = std::string_view(host).substr(last_dot == std::string::npos ? 0 : last_dot + 1);
    if (std::all_of(last_label.begin(), last_label.end(), [](char c) { return c >= '0' && c <= '9'; })) ipv4(host);
    // WHATWG URLs accept noncanonical hexadecimal IPv4 spellings. Refuse them
    // rather than showing an origin different from the system browser's host.
    require(!(last_label.size() > 2 && last_label[0] == '0' && (last_label[1] == 'x' || last_label[1] == 'X') &&
              std::all_of(last_label.begin() + 2, last_label.end(), [](char c) { return digit(c) >= 0; })), VXCORE_ERR_UNSUPPORTED);
  }
  if (!port.empty()) {
    require(port.size() <= 5, VXCORE_ERR_UNSUPPORTED); unsigned value = 0;
    for (char c : port) { require(c >= '0' && c <= '9', VXCORE_ERR_UNSUPPORTED); value = value * 10 + c - '0'; }
    require(value > 0 && value <= 65535, VXCORE_ERR_UNSUPPORTED);
  }
  return {{"kind", "external"}, {"url", url}, {"origin", scheme + "://" + lower(authority)}, {"insecure", scheme == "http"}};
}
uint32_t be32(const uint8_t *p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }
uint32_t le32(const uint8_t *p) { return uint32_t(p[3]) << 24 | uint32_t(p[2]) << 16 | uint32_t(p[1]) << 8 | p[0]; }
uint32_t le24(const uint8_t *p) { return uint32_t(p[2]) << 16 | uint32_t(p[1]) << 8 | p[0]; }
struct Image { std::string mime; uint32_t width = 0, height = 0; };
Image image_header(const fs::path &path, const std::string &name, uint64_t bytes) {
  const auto extension = lower(fs::u8path(name).extension().u8string());
  require(bytes > 0 && bytes <= kFile, VXCORE_ERR_UNSUPPORTED);
  const auto header = disk::Header(path, kHeader);
  const auto *p = reinterpret_cast<const uint8_t *>(header.data());
  const auto n = header.size(); Image out;
  if (extension == ".png") {
    const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    require(n >= 33 && !std::memcmp(p, signature, 8) && be32(p + 8) == 13 && !std::memcmp(p + 12, "IHDR", 4), VXCORE_ERR_UNSUPPORTED);
    out = {"image/png", be32(p + 16), be32(p + 20)};
    const auto depth = p[24], color = p[25];
    require((color == 0 && (depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16)) ||
            (color == 3 && (depth == 1 || depth == 2 || depth == 4 || depth == 8)) ||
            ((color == 2 || color == 4 || color == 6) && (depth == 8 || depth == 16)), VXCORE_ERR_UNSUPPORTED);
    require(p[26] == 0 && p[27] == 0 && p[28] <= 1, VXCORE_ERR_UNSUPPORTED);
    uint32_t crc = 0xffffffffU;
    for (size_t i = 12; i < 29; ++i) {
      crc ^= p[i]; for (unsigned bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320U : 0);
    }
    require((crc ^ 0xffffffffU) == be32(p + 29), VXCORE_ERR_UNSUPPORTED);
    size_t offset = 33; bool pixels = false;
    while (offset + 8 <= n) {
      const auto length = be32(p + offset);
      const auto *type = p + offset + 4;
      require(uint64_t(offset) + 12 + length <= bytes && std::memcmp(type, "acTL", 4) &&
              std::memcmp(type, "fcTL", 4) && std::memcmp(type, "fdAT", 4) &&
              std::memcmp(type, "IHDR", 4), VXCORE_ERR_UNSUPPORTED);
      if (!std::memcmp(type, "IDAT", 4)) { pixels = true; break; }
      require(std::memcmp(type, "IEND", 4) && ((type[0] & 32) || !std::memcmp(type, "PLTE", 4)) &&
              uint64_t(offset) + 12 + length <= n, VXCORE_ERR_UNSUPPORTED);
      offset += 12 + length;
    }
    require(pixels, VXCORE_ERR_UNSUPPORTED);
  } else if (extension == ".jpg" || extension == ".jpeg") {
    require(n >= 4 && p[0] == 0xff && p[1] == 0xd8, VXCORE_ERR_UNSUPPORTED);
    size_t offset = 2;
    while (offset < n) {
      require(p[offset++] == 0xff, VXCORE_ERR_UNSUPPORTED);
      while (offset < n && p[offset] == 0xff) ++offset;
      require(offset < n, VXCORE_ERR_UNSUPPORTED); const auto marker = p[offset++];
      require(marker != 0 && marker != 0xd8 && marker != 0xd9 && marker != 0xda && !(marker >= 0xd0 && marker <= 0xd7), VXCORE_ERR_UNSUPPORTED);
      require(offset + 2 <= n, VXCORE_ERR_UNSUPPORTED);
      const auto length = (uint32_t(p[offset]) << 8) | p[offset + 1];
      require(length >= 2 && length <= n - offset, VXCORE_ERR_UNSUPPORTED);
      if (marker == 0xc0 || marker == 0xc1 || marker == 0xc2) {
        require(length >= 8 && p[offset + 2] == 8, VXCORE_ERR_UNSUPPORTED);
        const auto components = p[offset + 7];
        require((components == 1 || components == 3 || components == 4) && length == 8U + components * 3U, VXCORE_ERR_UNSUPPORTED);
        out = {"image/jpeg", uint32_t(p[offset + 5]) << 8 | p[offset + 6], uint32_t(p[offset + 3]) << 8 | p[offset + 4]};
        break;
      }
      require(!(marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc), VXCORE_ERR_UNSUPPORTED);
      offset += length;
    }
  } else if (extension == ".webp") {
    require(n >= 25 && !std::memcmp(p, "RIFF", 4) && !std::memcmp(p + 8, "WEBP", 4) &&
            uint64_t(le32(p + 4)) + 8 == bytes, VXCORE_ERR_UNSUPPORTED);
    const auto chunk = le32(p + 16);
    require(uint64_t(chunk) + 20 + (chunk & 1U) <= bytes, VXCORE_ERR_UNSUPPORTED);
    if (!std::memcmp(p + 12, "VP8 ", 4)) {
      require(n >= 30 && chunk >= 10 && !(p[20] & 1) && !std::memcmp(p + 23, "\x9d\x01\x2a", 3), VXCORE_ERR_UNSUPPORTED);
      out = {"image/webp", (uint32_t(p[26]) | uint32_t(p[27]) << 8) & 0x3fff,
                              (uint32_t(p[28]) | uint32_t(p[29]) << 8) & 0x3fff};
    } else if (!std::memcmp(p + 12, "VP8L", 4)) {
      require(chunk >= 5 && p[20] == 0x2f && !(p[24] & 0xe0), VXCORE_ERR_UNSUPPORTED);
      const auto bits = le32(p + 21);
      out = {"image/webp", (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1};
    } else {
      require(n >= 30 && !std::memcmp(p + 12, "VP8X", 4) && chunk == 10 && !(p[20] & 0xc3) &&
              p[21] == 0 && p[22] == 0 && p[23] == 0, VXCORE_ERR_UNSUPPORTED); // Reject animation.
      out = {"image/webp", le24(p + 24) + 1, le24(p + 27) + 1};
      // Extended files must contain an actual still-image bitstream in the
      // bounded header; animation/chunk ambiguity cannot bypass admission.
      size_t offset = 30; bool bitstream = false;
      while (offset + 8 <= n) {
        const auto length = le32(p + offset + 4);
        require(uint64_t(offset) + 8 + length <= bytes && std::memcmp(p + offset, "ANIM", 4) &&
                std::memcmp(p + offset, "ANMF", 4), VXCORE_ERR_UNSUPPORTED);
        if (!std::memcmp(p + offset, "VP8 ", 4)) {
          require(length >= 10 && offset + 18 <= n && !(p[offset + 8] & 1) &&
                  !std::memcmp(p + offset + 11, "\x9d\x01\x2a", 3), VXCORE_ERR_UNSUPPORTED);
          const auto width = (uint32_t(p[offset + 14]) | uint32_t(p[offset + 15]) << 8) & 0x3fff;
          const auto height = (uint32_t(p[offset + 16]) | uint32_t(p[offset + 17]) << 8) & 0x3fff;
          require(width == out.width && height == out.height, VXCORE_ERR_UNSUPPORTED);
          bitstream = true; break;
        }
        if (!std::memcmp(p + offset, "VP8L", 4)) {
          require(length >= 5 && offset + 13 <= n && p[offset + 8] == 0x2f && !(p[offset + 12] & 0xe0), VXCORE_ERR_UNSUPPORTED);
          const auto bits = le32(p + offset + 9);
          require((bits & 0x3fff) + 1 == out.width && ((bits >> 14) & 0x3fff) + 1 == out.height, VXCORE_ERR_UNSUPPORTED);
          bitstream = true; break;
        }
        require(uint64_t(offset) + 8 + length + (length & 1U) <= n, VXCORE_ERR_UNSUPPORTED);
        offset += 8 + length + (length & 1U);
      }
      require(bitstream, VXCORE_ERR_UNSUPPORTED);
    }
  }
  require(!out.mime.empty() && out.width && out.height && uint64_t(out.width) * out.height <= kPixels, VXCORE_ERR_UNSUPPORTED);
  return out;
}

fs::path preview_root(const Json &request) {
  const auto root = disk::Absolute(text(request.at("previewRoot")));
  require(disk::Info(root).at("directory") == true && root.filename() == "previews", VXCORE_ERR_UNSUPPORTED);
  return root;
}
fs::path snapshot_path(const Json &request) {
  return preview_root(request) / hex(request.at("previewId")) / hex(request.at("renderId"));
}
Json summary(const Json &manifest, const std::string &hash) {
  return {{"version", 1}, {"previewId", manifest.at("previewId")}, {"renderId", manifest.at("renderId")},
          {"sourceRevision", manifest.at("sourceRevision")}, {"sourceHash", manifest.at("sourceHash")},
          {"manifestHash", hash}, {"imageCount", manifest.at("images").size()}, {"fileCount", manifest.at("files").size()},
          {"navigationCount", manifest.at("navigation").size()}, {"encodedBytes", manifest.at("encodedBytes")}};
}
struct Snapshot { fs::path path; Json manifest; std::string hash; };
Snapshot load(const Json &request, bool revoked, const std::atomic<bool> *cancel, bool verify_content) {
  Snapshot out; out.path = snapshot_path(request);
  require(disk::Info(out.path).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
  require(revoked || !disk::Exists(out.path / "revoked.json"), VXCORE_ERR_INVALID_STATE);
  const auto bytes = disk::Read(out.path / "manifest.json", kManifest);
  out.hash = disk::Hash(bytes);
  require(disk::Read(out.path / "manifest.sha256", 64) == out.hash, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  out.manifest = disk::Parse(bytes, kManifest);
  const auto &m = out.manifest;
  keys(m, {"version", "previewId", "renderId", "sourceRevision", "sourceHash", "sourceBytes", "notebookId", "nodeId", "images", "files", "navigation", "encodedBytes"});
  require(m.at("version") == 1 && hex(m.at("previewId")) == request.at("previewId") &&
          hex(m.at("renderId")) == request.at("renderId"), VXCORE_ERR_INVALID_STATE);
  number(m.at("sourceRevision"), kRevision); number(m.at("sourceBytes"), kSource); hex(m.at("sourceHash"), 64);
  text(m.at("notebookId"), 127); text(m.at("nodeId"), 127);
  if (verify_content) {
    const auto source = disk::Info(out.path / "source.md", true, cancel, kSource);
    require(source.at("bytes") == m.at("sourceBytes") && source.at("sha256") == m.at("sourceHash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  }
  for (const auto *key : {"images", "files"}) require(m.at(key).is_array() && m.at(key).size() <= kHandles, VXCORE_ERR_UNSUPPORTED);
  require(m.at("navigation").is_array() && m.at("navigation").size() <= kNodes, VXCORE_ERR_UNSUPPORTED);
  std::map<std::string, const Json *> files;
  uint64_t total = 0;
  for (const auto &file : m.at("files")) {
    cancelled(cancel); keys(file, {"handle", "name", "mime", "bytes", "sha256"});
    const auto handle = hex(file.at("handle")); disk::Name(text(file.at("name"), 255)); hex(file.at("sha256"), 64);
    const auto size = number(file.at("bytes"), kFile);
    require(total <= kTotal - size && files.emplace(handle, &file).second, VXCORE_ERR_UNSUPPORTED); total += size;
    const auto mime = text(file.at("mime"), 32);
    require(mime == "application/octet-stream" || mime == "image/png" || mime == "image/jpeg" || mime == "image/webp", VXCORE_ERR_UNSUPPORTED);
    if (verify_content) {
      const auto info = disk::Info(out.path / "files" / handle, true, cancel, kFile);
      require(info.at("bytes") == file.at("bytes") && info.at("sha256") == file.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
  }
  require(total == number(m.at("encodedBytes"), kTotal), VXCORE_ERR_INVALID_STATE);
  std::set<std::string> image_sources, nav_sources, nav_handles;
  for (const auto &image : m.at("images")) {
    keys(image, {"source", "handle", "mime", "width", "height", "bytes", "sha256"});
    require(image_sources.insert(text(image.at("source"))).second, VXCORE_ERR_JSON_PARSE);
    const auto found = files.find(hex(image.at("handle")));
    require(found != files.end(), VXCORE_ERR_INVALID_STATE);
    const auto &file = *found->second;
    for (const auto *key : {"mime", "bytes", "sha256"}) require(file.at(key) == image.at(key), VXCORE_ERR_INVALID_STATE);
    const auto width = number(image.at("width"), kPixels), height = number(image.at("height"), kPixels);
    require(width && height && width * height <= kPixels && file.at("mime") != "application/octet-stream", VXCORE_ERR_UNSUPPORTED);
    if (verify_content) {
      const auto dimensions = image_header(out.path / "files" / text(file.at("handle")), text(file.at("name")), number(file.at("bytes"), kFile));
      require(dimensions.mime == image.at("mime") && dimensions.width == width && dimensions.height == height, VXCORE_ERR_INVALID_STATE);
    }
  }
  for (const auto &nav : m.at("navigation")) {
    require(nav_sources.insert(text(nav.at("source"))).second && nav_handles.insert(hex(nav.at("handle"))).second, VXCORE_ERR_JSON_PARSE);
    const auto kind = text(nav.at("kind"));
    if (kind == "note") {
      keys(nav, {"source", "handle", "kind", "notebookId", "nodeId", "fragment"});
      require(nav.at("notebookId") == m.at("notebookId"), VXCORE_ERR_INVALID_STATE);
      text(nav.at("nodeId"), 127); utf8(text(nav.at("fragment"), 16384, true), true);
    } else if (kind == "external") {
      keys(nav, {"source", "handle", "kind", "url", "origin", "insecure"});
      const auto checked = external(text(nav.at("url")));
      for (const auto *key : {"url", "origin", "insecure"}) require(nav.at(key) == checked.at(key), VXCORE_ERR_INVALID_STATE);
    } else {
      keys(nav, {"source", "handle", "kind", "fileHandle"});
      require(kind == "export" && files.count(hex(nav.at("fileHandle"))), VXCORE_ERR_UNSUPPORTED);
    }
  }
  return out;
}
const Json &find_handle(const Json &entries, const std::string &handle) {
  for (const auto &entry : entries) if (entry.at("handle") == handle) return entry;
  throw vxm_import::StorageFailure{VXCORE_ERR_NOT_FOUND};
}
Json binding(const Snapshot &snapshot, const std::string &handle) {
  return {{"previewId", snapshot.manifest.at("previewId")}, {"renderId", snapshot.manifest.at("renderId")},
          {"handle", handle}, {"sourceHash", snapshot.manifest.at("sourceHash")}, {"manifestHash", snapshot.hash}};
}
bool consumer_current(const Json &pin, const std::string &id, const Json &preview, const Json &render) {
  require(id == "owner" || hex(Json(id)) == id, VXCORE_ERR_INVALID_STATE);
  if (pin.at("version") == 1) keys(pin, {"version", "kind", "id"});
  else {
    keys(pin, {"version", "kind", "id", "process", "previewId", "renderId"});
    require(pin.at("version") == 2 && hex(pin.at("previewId")) == preview &&
            hex(pin.at("renderId")) == render, VXCORE_ERR_INVALID_STATE);
    hex(pin.at("process"));
  }
  require(pin.at("kind") == "consumer" && pin.at("id") == id, VXCORE_ERR_INVALID_STATE);
  return pin.at("version") == 2 && pin.at("process") == process_token();
}
bool export_current(const Snapshot &snapshot, const Json &pin, const std::string &id) {
  hex(Json(id));
  if (pin.at("version") == 1) keys(pin, {"version", "kind", "id", "binding"});
  else {
    keys(pin, {"version", "kind", "id", "binding", "process"});
    require(pin.at("version") == 2, VXCORE_ERR_INVALID_STATE); hex(pin.at("process"));
  }
  require(pin.at("kind") == "export" && pin.at("id") == id, VXCORE_ERR_INVALID_STATE);
  const auto handle = hex(pin.at("binding").at("handle"));
  require(pin.at("binding") == binding(snapshot, handle), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  find_handle(snapshot.manifest.at("files"), handle);
  return pin.at("version") == 2 && pin.at("process") == process_token();
}
std::string lease_id(const Json &request, bool owner = false) {
  const auto id = text(request.at("leaseId"), 32);
  if (owner && id == "owner") return id;
  return hex(request.at("leaseId"));
}
void lease(const Snapshot &snapshot, const std::string &id, const Json &value) {
  size_t count = 0;
  for (const auto &entry : fs::directory_iterator(snapshot.path / "leases")) {
    disk::Info(entry.path()); require(++count <= 10000, VXCORE_ERR_UNSUPPORTED);
  }
  disk::Marker(snapshot.path / "leases", id + ".json", value);
}
bool reclaim(const Snapshot &snapshot) {
  if (!disk::Exists(snapshot.path / "revoked.json")) return false;
  if (fs::directory_iterator(snapshot.path / "leases") != fs::directory_iterator()) return false;
  disk::RemovePrivate(snapshot.path);
  // The preview parent may hold another live/pinned generation. Never recurse it.
  if (fs::directory_iterator(snapshot.path.parent_path()) == fs::directory_iterator()) disk::RemovePrivate(snapshot.path.parent_path());
  return true;
}
void release(const Snapshot &snapshot, const std::string &id) {
  const auto path = snapshot.path / "leases" / (id + ".json");
  if (disk::Exists(path)) disk::RemovePrivate(path);
}
void check_consumer_release(const Snapshot &snapshot, const std::string &id) {
  const auto path = snapshot.path / "leases" / (id + ".json");
  if (disk::Exists(path)) {
    const auto pin = disk::ReadJson(path);
    const bool current = consumer_current(pin, id, snapshot.manifest.at("previewId"), snapshot.manifest.at("renderId"));
    require(pin.at("version") == 1 || current, VXCORE_ERR_INVALID_STATE);
  }
}
Json transfer(const fs::path &root, const std::string &op, const std::atomic<bool> *cancel) {
  Json result; check(vxm_import::TransferRun(disk::Command(root.u8string(), "resource", op), cancel, result)); return result;
}
fs::path export_transaction(const Json &request) {
  const auto transaction = disk::Absolute(text(request.at("transactionRoot")));
  const auto root = disk::Absolute(text(request.at("previewRoot")));
  require(transaction.parent_path() == root.parent_path() / "resources" &&
          disk::Info(transaction.parent_path()).at("directory") == true, VXCORE_ERR_INVALID_STATE);
  hex(Json(transaction.filename().u8string()));
  return transaction;
}
Json release_export(const Json &request, const std::atomic<bool> *cancel) {
  const auto path = snapshot_path(request), transaction = export_transaction(request);
  const auto id = transaction.filename().u8string();
  Json state, desired;
  if (disk::Exists(transaction)) {
    state = disk::Transaction(transaction.u8string(), "resource");
    require(state.at("id") == id && !disk::Exists(transaction / "dispatch.json"), VXCORE_ERR_INVALID_STATE);
    if (disk::Exists(transaction / "resource.json")) {
      desired = disk::ReadJson(transaction / "resource.json");
      keys(desired, {"version", "id", "scope", "target", "operation", "name", "newName", "origin", "binding"});
      require(desired.at("version") == 2 && desired.at("origin") == "preview-file" &&
              desired.at("operation") == "export" && desired.at("newName").is_null() &&
              desired.at("scope") == "resource" && desired.at("id") == id &&
              desired.at("target") == state.at("target"), VXCORE_ERR_INVALID_STATE);
      const auto &bound = desired.at("binding");
      keys(bound, {"previewId", "renderId", "handle", "sourceHash", "manifestHash"});
      require(bound.at("previewId") == request.at("previewId") && bound.at("renderId") == request.at("renderId"), VXCORE_ERR_INVALID_STATE);
      hex(bound.at("handle")); hex(bound.at("sourceHash"), 64); hex(bound.at("manifestHash"), 64);
      // An existing unresolved desired record still needs its immutable source.
      const auto ready = transfer(transaction, "verifyExport", cancel);
      require(ready.at("name") == desired.at("name"), VXCORE_ERR_INVALID_STATE);
    } else {
      // prepareExport precedes desired publication. A failed publication may
      // release only an allocated owned request without mutation/ready markers.
      require(!disk::Exists(transaction / "ready.json"), VXCORE_ERR_INVALID_STATE);
    }
  }
  // Missing fixed resources/<id> is a completed/retired private discard; never
  // recreate either the request or the generation on repeated release calls.
  if (!disk::Exists(path)) return {{"released", true}, {"retained", false}};
  const auto snapshot = load(request, true, cancel, false);
  if (!state.is_null()) {
    const auto &target = state.at("target");
    require(target.at("notebookId") == snapshot.manifest.at("notebookId") &&
            target.at("nodeId") == snapshot.manifest.at("nodeId"), VXCORE_ERR_INVALID_STATE);
  }
  const auto pin_path = snapshot.path / "leases" / (id + ".json");
  if (disk::Exists(pin_path)) {
    const auto pin = disk::ReadJson(pin_path);
    export_current(snapshot, pin, id); // Old-process pins remain valid export authority.
    if (!desired.is_null()) require(desired.at("binding") == pin.at("binding"), VXCORE_ERR_INVALID_STATE);
    release(snapshot, id);
  }
  return {{"released", true}, {"retained", !reclaim(snapshot)}};
}
Json export_file(const Snapshot &snapshot, const fs::path &transaction, const std::atomic<bool> *cancel) {
  const auto state = disk::Transaction(transaction.u8string(), "resource");
  const auto desired = disk::ReadJson(transaction / "resource.json");
  keys(desired, {"version", "id", "scope", "target", "operation", "name", "newName", "origin", "binding"});
  require(desired.at("version") == 2 && desired.at("origin") == "preview-file" && desired.at("operation") == "export" &&
          desired.at("newName").is_null() && desired.at("id") == state.at("id") && desired.at("scope") == "resource" &&
          desired.at("target") == state.at("target"), VXCORE_ERR_INVALID_STATE);
  const auto &target = state.at("target");
  require(target.at("notebookId") == snapshot.manifest.at("notebookId") && target.at("nodeId") == snapshot.manifest.at("nodeId"), VXCORE_ERR_INVALID_STATE);
  const auto &bound = desired.at("binding");
  keys(bound, {"previewId", "renderId", "handle", "sourceHash", "manifestHash"});
  const auto handle = hex(bound.at("handle")), id = hex(state.at("id"));
  require(bound == binding(snapshot, handle), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto &file = find_handle(snapshot.manifest.at("files"), handle);
  require(desired.at("name") == file.at("name") && !disk::Exists(transaction / "dispatch.json"), VXCORE_ERR_INVALID_STATE);
  if (disk::Exists(transaction / "ready.json")) {
    auto ready = transfer(transaction, "verifyExport", cancel);
    require(ready.at("name") == file.at("name") && ready.at("bytes") == file.at("bytes") && ready.at("sha256") == file.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    release(snapshot, id); reclaim(snapshot); return ready;
  }
  const auto pin = disk::ReadJson(snapshot.path / "leases" / (id + ".json"));
  export_current(snapshot, pin, id);
  auto reserve = disk::Command(transaction.u8string(), "resource", "checkSpace");
  reserve["requiredBytes"] = number(file.at("bytes"), kFile) + 128 * 1024;
  Json ignored; check(vxm_import::TransferRun(reserve, cancel, ignored));
  const auto output = transaction / "output";
  if (disk::Exists(output)) disk::RemovePrivate(output);
  disk::MakeDirectory(output);
  const auto source = snapshot.path / "files" / handle;
  const auto identity = disk::Info(source);
  const auto copied = disk::CopyChecked(source, output / fs::u8path(text(file.at("name"))), kFile, identity, cancel);
  require(copied.at("bytes") == file.at("bytes") && copied.at("sha256") == file.at("sha256"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  cancelled(cancel);
  disk::Marker(transaction, "ready.json", {{"version", 1}, {"id", state.at("id")}, {"scope", "resource"},
               {"name", file.at("name")}, {"bytes", file.at("bytes")}, {"sha256", file.at("sha256")}});
  auto ready = transfer(transaction, "verifyExport", cancel);
  release(snapshot, id); reclaim(snapshot); return ready;
}

struct RetirePath { fs::path path; Json identity; };
struct RetireGeneration {
  fs::path path;
  Json identity;
  std::string preview, render;
  std::vector<RetirePath> members;
  std::vector<std::string> leases;
  bool valid = true, empty = true;
};
bool opaque_name(std::string_view name) {
  return name.size() == 32 && std::all_of(name.begin(), name.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
void retire_failure(size_t inspected) {
  const auto code = disk::ErrorCode();
  if (inspected > 10000 || code == VXCORE_ERR_CANCELLED || code == VXCORE_ERR_OUT_OF_MEMORY) throw;
}
bool same_object(const Json &first, const Json &second) {
  return first.at("directory") == second.at("directory") && first.at("device") == second.at("device") &&
      first.at("low") == second.at("low") && first.at("high") == second.at("high");
}
Json retire_previous(const Json &request, const std::atomic<bool> *cancel) {
  keys(request, {"op", "previewRoot"});
  const auto root = preview_root(request);
  std::vector<RetirePath> parents;
  std::vector<RetireGeneration> generations;
  size_t inspected = 0, removed = 0, retained = 0, unrecognized = 0;
  const auto visit = [&] { cancelled(cancel); require(++inspected <= 10000, VXCORE_ERR_UNSUPPORTED); };
  const std::set<std::string> metadata = {"source.md", "manifest.json", "manifest.sha256", "revoked.json",
                                         "renderer-request.json", "output.html"};
  // Finish all bounded enumeration before any mutation. Reclaim can remove an
  // empty parent, so no directory iterator may remain live while it runs.
  for (const auto &parent : fs::directory_iterator(root)) {
    visit();
    const auto preview = parent.path().filename().u8string();
    try {
      require(opaque_name(preview), VXCORE_ERR_UNSUPPORTED);
      auto info = disk::Info(parent.path()); require(info.at("directory") == true, VXCORE_ERR_UNSUPPORTED);
      parents.push_back({parent.path(), std::move(info)});
    } catch (...) { retire_failure(inspected); ++unrecognized; continue; }
    for (const auto &entry : fs::directory_iterator(parent.path())) {
      visit();
      RetireGeneration generation;
      generation.path = entry.path(); generation.preview = preview;
      generation.render = entry.path().filename().u8string();
      try {
        require(opaque_name(generation.render), VXCORE_ERR_UNSUPPORTED);
        generation.identity = disk::Info(generation.path);
        require(generation.identity.at("directory") == true, VXCORE_ERR_UNSUPPORTED);
        for (const auto &child : fs::directory_iterator(generation.path)) {
          visit();
          const auto name = child.path().filename().u8string();
          auto info = disk::Info(child.path());
          const bool directory = info.at("directory").get<bool>();
          require(directory ? (name == "files" || name == "leases") : metadata.count(name) != 0, VXCORE_ERR_UNSUPPORTED);
          generation.members.push_back({child.path(), std::move(info)});
          if (!directory) { generation.empty = false; continue; }
          for (const auto &leaf : fs::directory_iterator(child.path())) {
            visit();
            const auto leaf_name = leaf.path().filename().u8string();
            auto identity = disk::Info(leaf.path());
            require(identity.at("directory") == false, VXCORE_ERR_UNSUPPORTED);
            if (name == "files") require(opaque_name(leaf_name), VXCORE_ERR_UNSUPPORTED);
            else {
              require(leaf_name == "owner.json" || (leaf_name.size() == 37 &&
                  leaf_name.substr(32) == ".json" && opaque_name(std::string_view(leaf_name).substr(0, 32))), VXCORE_ERR_UNSUPPORTED);
              generation.leases.push_back(leaf_name.substr(0, leaf_name.size() - 5));
            }
            generation.empty = false;
            generation.members.push_back({leaf.path(), std::move(identity)});
          }
        }
      } catch (...) { retire_failure(inspected); generation.valid = false; }
      generations.push_back(std::move(generation));
    }
  }
  for (const auto &generation : generations) {
    cancelled(cancel);
    if (!generation.valid) { ++unrecognized; continue; }
    try {
      require(same_object(disk::Info(generation.path), generation.identity), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      const Json command = {{"previewRoot", root.u8string()}, {"previewId", generation.preview}, {"renderId", generation.render}};
      Snapshot snapshot;
      bool sealed = false;
      try { snapshot = load(command, true, cancel, false); sealed = true; }
      catch (...) { retire_failure(inspected); }
      struct Pin { std::string id; bool consumer; bool current; };
      std::vector<Pin> pins;
      bool current = false;
      for (const auto &id : generation.leases) {
        const auto pin = disk::ReadJson(generation.path / "leases" / (id + ".json"), 16384);
        const auto kind = text(pin.at("kind"), 16);
        bool live = false;
        if (kind == "consumer") {
          live = consumer_current(pin, id, generation.preview, generation.render);
          require(sealed || (pin.at("version") == 2 && id == "owner" && generation.leases.size() == 1), VXCORE_ERR_INVALID_STATE);
        } else {
          require(sealed && kind == "export", VXCORE_ERR_INVALID_STATE);
          live = export_current(snapshot, pin, id);
        }
        current |= live; pins.push_back({id, kind == "consumer", live});
      }
      // A current producer may still be between pin creation and publication.
      // Do not probe transaction absence or volatile output files in that case.
      if (current) { ++retained; continue; }
      require(disk::Info(generation.path) == generation.identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      for (const auto &member : generation.members)
        require(disk::Info(member.path) == member.identity, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      if (!sealed) {
        require(generation.empty || (pins.size() == 1 && pins.front().consumer && pins.front().id == "owner"), VXCORE_ERR_INVALID_STATE);
        disk::RemovePrivate(generation.path); ++removed; continue;
      }
      bool keep = false;
      for (const auto &pin : pins) {
        if (pin.consumer) continue;
        auto release_request = command;
        release_request["transactionRoot"] = (root.parent_path() / "resources" / pin.id).u8string();
        try { release_export(release_request, cancel); }
        catch (...) { retire_failure(inspected); keep = true; break; }
      }
      if (keep) { ++retained; continue; }
      if (!disk::Exists(generation.path)) { ++removed; continue; }
      require(same_object(disk::Info(generation.path), generation.identity), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      disk::Marker(snapshot.path, "revoked.json", {{"version", 1}, {"manifestHash", snapshot.hash}});
      for (const auto &pin : pins) if (pin.consumer) release(snapshot, pin.id);
      if (reclaim(snapshot)) ++removed; else ++retained;
    } catch (...) { retire_failure(inspected); ++unrecognized; }
  }
  for (const auto &parent : parents) {
    cancelled(cancel);
    try {
      if (!disk::Exists(parent.path)) continue;
      require(same_object(disk::Info(parent.path), parent.identity), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      const bool empty = fs::directory_iterator(parent.path) == fs::directory_iterator();
      if (empty) disk::RemovePrivate(parent.path);
    } catch (...) { retire_failure(inspected); ++unrecognized; }
  }
  return {{"removed", removed}, {"retained", retained}, {"unrecognized", unrecognized}};
}

Json prepare(VxCoreContextHandle context, const std::string &notebook_id, const std::string &node_id,
             const std::string &note_path, const std::string &notebook_root, const Json &request,
             std::string_view source, const std::atomic<bool> *cancel) {
  keys(request, {"op", "previewRoot", "previewId", "renderId", "sourceRevision"});
  cancelled(cancel);
  require(request.at("op") == "prepare" && context && source.size() <= kSource, VXCORE_ERR_UNSUPPORTED);
  number(request.at("sourceRevision"), kRevision); utf8(source);
  const auto root = disk::Absolute(notebook_root);
  Json policy; check(vxm_transfer::PreflightResource(context, notebook_id, node_id, notebook_root, policy));
  require(policy.at("notePath") == note_path && policy.at("editorType") == "markdown", VXCORE_ERR_UNSUPPORTED);
  exact_path(root, note_path);
  CoreString selected;
  check(vxcore_node_get_path_by_id(context, notebook_id.c_str(), node_id.c_str(), &selected.value));
  require(selected.str() == note_path, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  std::map<std::string, vxm_transfer::PreviewNode> note_index;
  check(vxm_transfer::PreviewIndex(context, notebook_id, notebook_root, cancel, note_index));
  const auto config = disk::ReadJson(root / "vx_notebook/config.json");
  const auto recycle = config.value("recycleBinFolder", std::string("vx_notebook/recycle_bin"));
  disk::Relative(recycle);
  const auto path = snapshot_path(request);
  require(!disk::Exists(path), VXCORE_ERR_ALREADY_EXISTS);
  if (!disk::Exists(path.parent_path())) disk::MakeDirectory(path.parent_path());
  else require(disk::Info(path.parent_path()).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
  disk::MakeDirectory(path);
  try {
    disk::MakeDirectory(path / "files"); disk::MakeDirectory(path / "leases");
    disk::Marker(path / "leases", "owner.json", consumer_lease("owner", request.at("previewId"), request.at("renderId")));
    disk::Bytes(path / "source.md", source);
    Json manifest = {{"version", 1}, {"previewId", request.at("previewId")}, {"renderId", request.at("renderId")},
                     {"sourceRevision", request.at("sourceRevision")}, {"sourceHash", disk::Hash(source)}, {"sourceBytes", source.size()},
                     {"notebookId", notebook_id}, {"nodeId", node_id}, {"images", Json::array()}, {"files", Json::array()},
                     {"navigation", Json::array()}, {"encodedBytes", 0}};
    using Document = std::unique_ptr<cmark_node, decltype(&cmark_node_free)>;
    using Iterator = std::unique_ptr<cmark_iter, decltype(&cmark_iter_free)>;
    Document document(cmark_parse_document(source.data(), source.size(), CMARK_OPT_DEFAULT), cmark_node_free);
    require(document != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
    Iterator iterator(cmark_iter_new(document.get()), cmark_iter_free);
    require(iterator != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
    std::set<std::pair<std::string, bool>> seen;
    std::map<std::string, Json> captured;
    std::set<std::string> validated_nodes;
    uint64_t total = 0; size_t nodes = 0, depth = 0;
    for (auto event = cmark_iter_next(iterator.get()); event != CMARK_EVENT_DONE; event = cmark_iter_next(iterator.get())) {
      cancelled(cancel);
      auto *node = cmark_iter_get_node(iterator.get());
      if (event != CMARK_EVENT_ENTER) { if (cmark_node_first_child(node)) --depth; continue; }
      require(++nodes <= kNodes, VXCORE_ERR_UNSUPPORTED);
      if (cmark_node_first_child(node)) require(++depth <= 64, VXCORE_ERR_UNSUPPORTED);
      const auto type = cmark_node_get_type(node);
      if (type != CMARK_NODE_LINK && type != CMARK_NODE_IMAGE) continue;
      const bool image = type == CMARK_NODE_IMAGE;
      const auto *raw = cmark_node_get_url(node); if (!raw || !*raw) continue;
      const std::string url(raw);
      require(url.size() <= 16384, VXCORE_ERR_UNSUPPORTED);
      if (!seen.emplace(url, image).second) continue;
      require(seen.size() <= kNodes, VXCORE_ERR_UNSUPPORTED);
      // Unsupported syntax has no capability. Only policy failures local to one
      // reference become a placeholder; cancellation/IO/quota failures abort.
      try {
        utf8(url, true);
        if (url.front() == '#') { decode(std::string_view(url).substr(1), false); continue; }
        const auto colon = url.find(':'); const auto slash = url.find('/');
        if (colon != std::string::npos && (slash == std::string::npos || colon < slash)) {
          require(!image, VXCORE_ERR_UNSUPPORTED);
          auto nav = external(url); nav["source"] = url; nav["handle"] = random_id();
          require(manifest.at("navigation").size() < kNodes, VXCORE_ERR_OUT_OF_MEMORY);
          manifest["navigation"].push_back(std::move(nav)); continue;
        }
        const auto fragment_at = url.find('#');
        const auto fragment = fragment_at == std::string::npos ? std::string() : decode(std::string_view(url).substr(fragment_at + 1), false);
        const auto relative = confined_path(note_path, std::string_view(url).substr(0, fragment_at), recycle);
        const auto physical = root / fs::u8path(relative);
        const auto indexed = note_index.find(relative);
        if (indexed != note_index.end()) {
          require(!indexed->second.protected_content, VXCORE_ERR_ENCRYPTION_LOCKED);
          if (!validated_nodes.count(relative)) {
            exact_path(root, relative);
            require(disk::Info(physical).at("directory") == false, VXCORE_ERR_UNSUPPORTED);
            CoreString target_config;
            check(vxcore_node_get_config(context, notebook_id.c_str(), relative.c_str(), &target_config.value));
            const auto target = disk::Parse(target_config.str(), kManifest);
            require(target.at("id") == indexed->second.id, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
            const auto prefix = disk::Header(physical, 8);
            require(prefix.size() < 8 || (std::memcmp(prefix.data(), "VNOTEE1", 8) &&
                    std::memcmp(prefix.data(), "VNEKEY1", 8)), VXCORE_ERR_ENCRYPTION_LOCKED);
            validated_nodes.insert(relative);
          }
          if (indexed->second.ordinary) {
            require(!image, VXCORE_ERR_UNSUPPORTED);
            require(manifest.at("navigation").size() < kNodes, VXCORE_ERR_OUT_OF_MEMORY);
            manifest["navigation"].push_back({{"source", url}, {"handle", random_id()}, {"kind", "note"},
                        {"notebookId", notebook_id}, {"nodeId", indexed->second.id}, {"fragment", fragment}});
            continue;
          }
        }
        require(fragment.empty(), VXCORE_ERR_UNSUPPORTED);
        auto existing = captured.find(relative);
        if (existing == captured.end()) {
          if (indexed == note_index.end()) exact_path(root, relative);
          const auto identity = disk::Info(physical);
          require(identity.at("directory") == false, VXCORE_ERR_UNSUPPORTED);
          const auto size = number(identity.at("bytes"), kFile);
          Image dimensions;
          if (image) dimensions = image_header(physical, fs::u8path(relative).filename().u8string(), size);
          require(captured.size() < kHandles && total <= kTotal - size, VXCORE_ERR_OUT_OF_MEMORY);
          const auto handle = random_id();
          const auto copied = disk::CopyChecked(physical, path / "files" / handle, kFile, identity, cancel);
          Json file = {{"handle", handle}, {"name", fs::u8path(relative).filename().u8string()},
                       {"mime", image ? dimensions.mime : "application/octet-stream"}, {"bytes", copied.at("bytes")}, {"sha256", copied.at("sha256")}};
          total += size; existing = captured.emplace(relative, std::move(file)).first;
        }
        auto &file = existing->second;
        if (image) {
          const auto dimensions = image_header(path / "files" / text(file.at("handle")), text(file.at("name")), number(file.at("bytes"), kFile));
          file["mime"] = dimensions.mime;
          require(manifest.at("images").size() < kHandles, VXCORE_ERR_OUT_OF_MEMORY);
          manifest["images"].push_back({{"source", url}, {"handle", file.at("handle")}, {"mime", dimensions.mime},
                      {"width", dimensions.width}, {"height", dimensions.height}, {"bytes", file.at("bytes")}, {"sha256", file.at("sha256")}});
        } else {
          require(manifest.at("navigation").size() < kNodes, VXCORE_ERR_OUT_OF_MEMORY);
          manifest["navigation"].push_back({{"source", url}, {"handle", random_id()}, {"kind", "export"}, {"fileHandle", file.at("handle")}});
        }
      } catch (const vxm_import::StorageFailure &failure) {
        if (failure.code != VXCORE_ERR_UNSUPPORTED && failure.code != VXCORE_ERR_NOT_FOUND && failure.code != VXCORE_ERR_ENCRYPTION_LOCKED) throw;
      }
    }
    for (auto &entry : captured) manifest["files"].push_back(std::move(entry.second));
    manifest["encodedBytes"] = total;
    const auto encoded = manifest.dump(); require(encoded.size() <= kManifest, VXCORE_ERR_UNSUPPORTED);
    cancelled(cancel);
    disk::Bytes(path / "manifest.json", encoded);
    const auto hash = disk::Hash(encoded); disk::Bytes(path / "manifest.sha256", hash);
    return summary(manifest, hash);
  } catch (...) {
    disk::RemovePrivate(path);
    if (fs::directory_iterator(path.parent_path()) == fs::directory_iterator()) disk::RemovePrivate(path.parent_path());
    throw;
  }
}
Json run(const Json &request, const std::atomic<bool> *cancel) {
  const auto op = text(request.at("op"), 32);
  cancelled(cancel);
  if (op == "retirePreviousProcess") return retire_previous(request, cancel);
  if (op == "inspect" || op == "revoke") keys(request, {"op", "previewRoot", "previewId", "renderId"});
  else if (op == "navigation") keys(request, {"op", "previewRoot", "previewId", "renderId", "handle"});
  else if (op == "lease" || op == "release") keys(request, {"op", "previewRoot", "previewId", "renderId", "leaseId"});
  else if (op == "prepareExport") keys(request, {"op", "previewRoot", "previewId", "renderId", "handle", "leaseId"});
  else {
    require(op == "export" || op == "releaseExport", VXCORE_ERR_INVALID_PARAM);
    keys(request, {"op", "previewRoot", "previewId", "renderId", "transactionRoot"});
  }
  cancelled(cancel);
  if (op == "releaseExport") return release_export(request, cancel);
  if (op == "revoke" && !disk::Exists(snapshot_path(request))) return {{"revoked", true}, {"retained", false}};
  if (op == "release") {
    lease_id(request, true);
    if (!disk::Exists(snapshot_path(request))) return {{"released", true}, {"retained", false}};
  }
  const auto snapshot = load(request, op == "release" || op == "revoke" || op == "export", cancel,
                             op == "inspect" || op == "prepareExport" || op == "export");
  if (op == "inspect") {
    auto out = summary(snapshot.manifest, snapshot.hash);
    for (const auto *key : {"images", "files", "navigation"}) out[key] = snapshot.manifest.at(key);
    return out;
  }
  if (op == "navigation") return find_handle(snapshot.manifest.at("navigation"), hex(request.at("handle")));
  if (op == "lease") {
    const auto id = lease_id(request);
    lease(snapshot, id, consumer_lease(id, snapshot.manifest.at("previewId"), snapshot.manifest.at("renderId")));
    return {{"leased", true}};
  }
  if (op == "release") {
    const auto id = lease_id(request, true);
    check_consumer_release(snapshot, id);
    release(snapshot, id); const auto removed = reclaim(snapshot);
    return {{"released", true}, {"retained", !removed}};
  }
  if (op == "revoke") {
    check_consumer_release(snapshot, "owner");
    disk::Marker(snapshot.path, "revoked.json", {{"version", 1}, {"manifestHash", snapshot.hash}});
    release(snapshot, "owner"); const auto removed = reclaim(snapshot);
    return {{"revoked", true}, {"retained", !removed}};
  }
  if (op == "prepareExport") {
    const auto handle = hex(request.at("handle")), id = lease_id(request);
    const auto &file = find_handle(snapshot.manifest.at("files"), handle);
    const auto bound = binding(snapshot, handle);
    lease(snapshot, id, {{"version", 2}, {"kind", "export"}, {"id", id}, {"binding", bound}, {"process", process_token()}});
    return {{"name", file.at("name")}, {"origin", "preview-file"}, {"binding", bound}};
  }
  return export_file(snapshot, export_transaction(request), cancel);
}
}  // namespace

namespace vxm_preview {
int32_t Prepare(VxCoreContextHandle context, const std::string &notebook_id,
                const std::string &node_id, const std::string &note_path,
                const std::string &notebook_root, const Json &request,
                const uint8_t *source, size_t source_size,
                const std::atomic<bool> *cancel, Json &out) noexcept {
  try {
    require(source || source_size == 0, VXCORE_ERR_NULL_POINTER);
    require(source_size <= kSource && request.dump().size() <= 16384, VXCORE_ERR_UNSUPPORTED);
    std::lock_guard<std::mutex> lock(preview_mutex);
    out = prepare(context, notebook_id, node_id, note_path, notebook_root, request,
                  std::string_view(source ? reinterpret_cast<const char *>(source) : "", source_size), cancel);
    return VXCORE_OK;
  } catch (...) { return disk::ErrorCode(); }
}
int32_t Run(const Json &request, const std::atomic<bool> *cancel, Json &out) noexcept {
  try {
    require(request.dump().size() <= 16384, VXCORE_ERR_UNSUPPORTED);
    std::lock_guard<std::mutex> lock(preview_mutex);
    out = run(request, cancel);
    require(out.dump().size() <= kManifest, VXCORE_ERR_OUT_OF_MEMORY);
    return VXCORE_OK;
  } catch (...) { return disk::ErrorCode(); }
}
}  // namespace vxm_preview

extern "C" int32_t vxm_preview_run(const char *command_json, VxmImportCancel *cancel, char **result_json) {
  if (result_json) *result_json = nullptr;
  try {
    require(command_json && result_json, VXCORE_ERR_NULL_POINTER);
    size_t size = 0; while (size <= 16384 && command_json[size]) ++size;
    require(size <= 16384, VXCORE_ERR_UNSUPPORTED);
    const auto request = disk::Parse(std::string_view(command_json, size), 16384);
    const size_t capacity = request.at("op") == "inspect" ? kManifest : 64 * 1024;
    std::unique_ptr<char[]> result(new char[capacity + 1]);
    Json out; check(vxm_preview::Run(request, disk::Cancellation(cancel), out));
    const auto encoded = out.dump(); require(encoded.size() <= capacity, VXCORE_ERR_OUT_OF_MEMORY);
    std::memcpy(result.get(), encoded.c_str(), encoded.size() + 1);
    *result_json = result.release(); return VXCORE_OK;
  } catch (...) { return disk::ErrorCode(); }
}
