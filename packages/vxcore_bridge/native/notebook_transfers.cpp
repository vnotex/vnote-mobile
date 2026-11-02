// SPDX-License-Identifier: LGPL-3.0-only
#include "notebook_transfers.h"
#include "notebook_import.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <set>
#include <string_view>
#include <vector>
#include <cmark.h>
#include <utf8proc.h>

namespace {
namespace fs = std::filesystem;
namespace disk = vxm_import::storage;
using Json = nlohmann::json;
constexpr uint64_t kImage = 8ULL * 1024 * 1024, kJournal = 64ULL * 1024 * 1024 - 5;
constexpr uint64_t kFile = 256ULL * 1024 * 1024, kExport = 1024ULL * 1024 * 1024;
constexpr size_t kIds = 100000, kRows = 10000;
void require(bool condition, int32_t code = VXCORE_ERR_INVALID_STATE) { disk::Check(condition, code); }
void check(int32_t code) { require(code == VXCORE_OK, code); }
void cancelled(const std::atomic<bool> *cancel) {
  require(!cancel || !cancel->load(std::memory_order_relaxed), VXCORE_ERR_CANCELLED);
}
const std::string &text(const Json &value, size_t limit = 16384, bool empty = false) {
  require(value.is_string(), VXCORE_ERR_JSON_PARSE);
  const auto &out = value.get_ref<const std::string &>();
  require((empty || !out.empty()) && out.size() <= limit && out.find('\0') == std::string::npos, VXCORE_ERR_JSON_PARSE);
  return out;
}
void keys(const Json &value, std::initializer_list<const char *> expected) {
  require(value.is_object() && value.size() == expected.size(), VXCORE_ERR_JSON_PARSE);
  for (const auto *key : expected) require(value.contains(key), VXCORE_ERR_JSON_PARSE);
}
struct CoreString {
  char *value = nullptr;
  ~CoreString() { if (value) vxcore_string_free(value); }
  std::string str() const {
    require(value != nullptr, VXCORE_ERR_INVALID_STATE);
    const auto length = std::char_traits<char>::length(value);
    require(length <= kImage, VXCORE_ERR_UNSUPPORTED);
    return std::string(value, length);
  }
  Json json() const { return Json::parse(str()); }
};
Json command(const fs::path &transaction, const std::string &scope, const std::string &op,
             const std::atomic<bool> *cancel = nullptr) {
  Json out;
  check(vxm_import::TransferRun(disk::Command(transaction.u8string(), scope, op), cancel, out));
  return out;
}
void reserve(const fs::path &transaction, const std::string &scope, uint64_t bytes,
             const std::atomic<bool> *cancel = nullptr) {
  auto request = disk::Command(transaction.u8string(), scope, "checkSpace");
  request["requiredBytes"] = bytes;
  Json out;
  check(vxm_import::TransferRun(request, cancel, out));
}
std::string lower(std::string value) {
  for (auto &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
  return value;
}
std::string parent(const std::string &path) {
  const auto slash = path.rfind('/');
  return slash == std::string::npos ? std::string() : path.substr(0, slash);
}
std::string child(const std::string &path, const std::string &name) { return path.empty() ? name : path + "/" + name; }
bool same_object(const Json &a, const Json &b) {
  for (const auto *key : {"device", "low", "high"}) if (a.at(key) != b.at(key)) return false;
  return true;
}
bool same_bytes(const Json &a, const Json &b) { return a.at("bytes") == b.at("bytes") && a.at("sha256") == b.at("sha256"); }
void unprotected(const Json &value) {
  require(value.is_object(), VXCORE_ERR_JSON_PARSE);
  if (value.contains("encrypted")) {
    require(value.at("encrypted").is_boolean(), VXCORE_ERR_JSON_PARSE);
    require(value.at("encrypted") == false, VXCORE_ERR_ENCRYPTION_LOCKED);
  }
  if (value.contains("metadata")) {
    require(value.at("metadata").is_object(), VXCORE_ERR_JSON_PARSE);
    const auto &metadata = value.at("metadata");
    if (metadata.contains("encrypted")) {
      require(metadata.at("encrypted").is_boolean(), VXCORE_ERR_JSON_PARSE);
      require(metadata.at("encrypted") == false, VXCORE_ERR_ENCRYPTION_LOCKED);
    }
  }
}
void plain_header(const fs::path &path) {
  require(lower(path.extension().u8string()) != ".vne", VXCORE_ERR_ENCRYPTION_LOCKED);
  const auto prefix = disk::Header(path, 8);
  require(prefix.size() < 8 || (std::memcmp(prefix.data(), "VNOTEE1", 8) != 0 &&
          std::memcmp(prefix.data(), "VNEKEY1", 8) != 0), VXCORE_ERR_ENCRYPTION_LOCKED);
}
struct Node { std::string path; bool folder; };
struct Graph {
  fs::path root;
  Json config;
  std::map<std::string, Node> nodes;
  Graph(const fs::path &path, const std::string &id, bool pending = false) : root(path) {
    const auto inspected = disk::Inspect(root, id, pending);
    config = disk::ReadJson(root / "vx_notebook/config.json");
    std::vector<std::string> folders{std::string()};
    while (!folders.empty()) {
      auto path = std::move(folders.back()); folders.pop_back();
      const auto image = disk::ReadJson(root / "vx_notebook/contents" / fs::u8path(path) / "vx.json");
      require(nodes.emplace(text(image.at("id"), 127), Node{path, true}).second, VXCORE_ERR_JSON_PARSE);
      for (const auto &file : image.at("files"))
        require(nodes.emplace(text(file.at("id"), 127), Node{child(path, text(file.at("name"), 255)), false}).second,
                VXCORE_ERR_JSON_PARSE);
      for (const auto &name : image.at("folders")) folders.push_back(child(path, text(name, 255)));
    }
    require(nodes.size() == inspected.node_ids.size(), VXCORE_ERR_JSON_PARSE);
  }
  const Node &node(const std::string &id, bool folder) const {
    const auto found = nodes.find(id);
    require(found != nodes.end(), VXCORE_ERR_NOT_FOUND);
    require(found->second.folder == folder, VXCORE_ERR_UNSUPPORTED);
    return found->second;
  }
  Json record(const Node &node) const {
    if (node.folder) return disk::ReadJson(root / "vx_notebook/contents" / fs::u8path(node.path) / "vx.json");
    const auto image = disk::ReadJson(root / "vx_notebook/contents" / fs::u8path(parent(node.path)) / "vx.json");
    const auto name = fs::u8path(node.path).filename().u8string();
    for (const auto &file : image.at("files")) if (file.at("name") == name) return file;
    throw vxm_import::StorageFailure{VXCORE_ERR_NOT_FOUND};
  }
};
std::string asset_layout(const Graph &graph) {
  const auto assets = graph.config.value("assetsFolder", std::string("vx_assets"));
  disk::Relative(assets);
  require(disk::Fold(fs::u8path(assets).begin()->u8string()) != "vx_notebook", VXCORE_ERR_UNSUPPORTED);
  require(!graph.config.contains("attachmentsFolder") || graph.config.at("attachmentsFolder") == "", VXCORE_ERR_UNSUPPORTED);
  return assets;
}
void absent_name(const fs::path &directory, const std::string &name) {
  disk::Name(name);
  if (!disk::Exists(directory)) return;
  require(disk::Info(directory).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
  const auto key = disk::Fold(name);
  for (const auto &entry : fs::directory_iterator(directory)) {
    disk::Info(entry.path());
    require(disk::Fold(entry.path().filename().u8string()) != key, VXCORE_ERR_ALREADY_EXISTS);
  }
}
struct Destination {
  fs::path root, content, metadata;
  std::string path, layout;
  Json parent_image;
  std::string before, after;
};
Destination destination(const fs::path &transaction, const Json &target, uint64_t incoming_ids,
                        VxCoreContextHandle context = nullptr, bool pending = false) {
  Destination out;
  const auto notebooks = transaction.parent_path().parent_path() / "notebooks";
  out.root = disk::Absolute((notebooks / fs::u8path(text(target.at("notebookRelative"), 255))).u8string());
  Graph graph(out.root, text(target.at("notebookId"), 127), pending);
  const auto &node = graph.node(text(target.at("parentId"), 127), true);
  out.path = node.path;
  out.layout = asset_layout(graph);
  const auto &name = text(target.at("folderName"), 255);
  require(disk::Fold(name) != disk::Fold(fs::u8path(out.layout).begin()->u8string()) &&
          disk::Fold(name) != "vx_notebook", VXCORE_ERR_UNSUPPORTED);
  out.content = out.root;
  out.metadata = out.root / "vx_notebook/contents";
  if (!node.path.empty()) {
    out.content /= fs::u8path(node.path);
    out.metadata /= fs::u8path(node.path);
  }
  if (context) {
    CoreString notebook, content, metadata;
    check(vxcore_folder_get_import_paths(context, text(target.at("notebookId")).c_str(), node.path.c_str(),
                                        &notebook.value, &content.value, &metadata.value));
    require(disk::Absolute(notebook.str()) == out.root && disk::Absolute(content.str()) == out.content &&
            disk::Absolute(metadata.str()) == out.metadata, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  }
  absent_name(out.content, name);
  absent_name(out.metadata, name);
  out.before = disk::Read(out.metadata / "vx.json", kImage);
  out.parent_image = disk::ReadJson(out.metadata / "vx.json");
  for (const auto &folder : out.parent_image.at("folders"))
    require(disk::Fold(text(folder, 255)) != disk::Fold(name), VXCORE_ERR_ALREADY_EXISTS);
  for (const auto &file : out.parent_image.at("files"))
    require(disk::Fold(text(file.at("name"), 255)) != disk::Fold(name), VXCORE_ERR_ALREADY_EXISTS);
  auto after = out.parent_image;
  after["folders"].push_back(name);
  after["modifiedUtc"] = INT64_MAX;
  out.after = after.dump(2);
  require(out.after.size() <= kImage, VXCORE_ERR_UNSUPPORTED);
  // Match schema-2's escaped binary before/after strings. Generated UUIDs are
  // bounded conservatively at 127 bytes; fixed fields/identities fit 16 KiB.
  const auto bound = Json(out.before).dump().size() + Json(out.after).dump().size() + incoming_ids * 130 + 16384;
  require(incoming_ids <= kIds && bound <= kJournal, VXCORE_ERR_UNSUPPORTED);
  return out;
}
struct Classification {
  std::map<std::string, bool> physical;
  std::map<std::string, std::vector<std::string>> batches;
  std::set<std::string> indexed;
  uint64_t metadata_bound = 0;
};
bool beneath(const std::string &path, const std::string &prefix) {
  return path == prefix || (path.size() > prefix.size() && path.compare(0, prefix.size() + 1, prefix + "/") == 0);
}
void markdown_links(const fs::path &root, const std::string &path, const Classification &classification) {
  const auto source = disk::Read(root / fs::u8path(path), 4 * 1024 * 1024);
  for (size_t i = 0; i < source.size();) {
    utf8proc_int32_t point = 0;
    const auto n = utf8proc_iterate(reinterpret_cast<const uint8_t *>(source.data() + i), source.size() - i, &point);
    require(n > 0 && point != 0, VXCORE_ERR_UNSUPPORTED);
    i += static_cast<size_t>(n);
  }
  using Document = std::unique_ptr<cmark_node, decltype(&cmark_node_free)>;
  using Iterator = std::unique_ptr<cmark_iter, decltype(&cmark_iter_free)>;
  Document document(cmark_parse_document(source.data(), source.size(), CMARK_OPT_DEFAULT), cmark_node_free);
  require(document != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
  Iterator iterator(cmark_iter_new(document.get()), cmark_iter_free);
  require(iterator != nullptr, VXCORE_ERR_OUT_OF_MEMORY);
  for (auto event = cmark_iter_next(iterator.get()); event != CMARK_EVENT_DONE; event = cmark_iter_next(iterator.get())) {
    if (event != CMARK_EVENT_ENTER) continue;
    auto *node = cmark_iter_get_node(iterator.get());
    const auto type = cmark_node_get_type(node);
    if (type != CMARK_NODE_LINK && type != CMARK_NODE_IMAGE) continue;
    const auto *raw = cmark_node_get_url(node);
    if (!raw || !*raw) continue;
    std::string url(raw);
    require(url.size() <= 16384, VXCORE_ERR_UNSUPPORTED);
    for (unsigned char c : url) require(c >= 32 && c != 127 && c != '\\', VXCORE_ERR_UNSUPPORTED);
    if (url.front() == '#' || url.front() == '?') continue;
    require(url.front() != '/', VXCORE_ERR_UNSUPPORTED);
    const auto colon = url.find(':');
    const auto slash = url.find('/');
    if (colon != std::string::npos && (slash == std::string::npos || colon < slash)) {
      require(colon > 1, VXCORE_ERR_UNSUPPORTED); // Drive-relative and drive-rooted paths.
      const auto scheme = lower(url.substr(0, colon));
      require(scheme != "file", VXCORE_ERR_UNSUPPORTED);
      bool valid = std::isalpha(static_cast<unsigned char>(scheme.front())) != 0;
      for (unsigned char c : scheme) valid &= std::isalnum(c) != 0 || c == '+' || c == '-' || c == '.';
      require(valid, VXCORE_ERR_UNSUPPORTED);
      continue; // Remote and VNote-ID links remain opaque, never fetched/rewritten.
    }
    url.resize(url.find_first_of("?#") == std::string::npos ? url.size() : url.find_first_of("?#"));
    std::string decoded;
    decoded.reserve(url.size());
    const auto digit = [](char c) -> int {
      if (c >= '0' && c <= '9') return c - '0';
      if (c >= 'a' && c <= 'f') return c - 'a' + 10;
      if (c >= 'A' && c <= 'F') return c - 'A' + 10;
      return -1;
    };
    for (size_t i = 0; i < url.size(); ++i) {
      unsigned char c = static_cast<unsigned char>(url[i]);
      if (c == '%') {
        require(i + 2 < url.size(), VXCORE_ERR_UNSUPPORTED);
        const auto a = digit(url[i + 1]), b = digit(url[i + 2]);
        require(a >= 0 && b >= 0, VXCORE_ERR_UNSUPPORTED);
        c = static_cast<unsigned char>((a << 4) | b); i += 2;
        require(c != '/' && c != '\\', VXCORE_ERR_UNSUPPORTED);
      }
      require(c >= 32 && c != 127 && c != '\\' && c != ':', VXCORE_ERR_UNSUPPORTED);
      decoded.push_back(static_cast<char>(c));
    }
    if (decoded.empty()) continue;
    require(decoded.front() != '/', VXCORE_ERR_UNSUPPORTED);
    std::vector<std::string> components;
    for (const auto &part : fs::u8path(parent(path))) components.push_back(part.u8string());
    for (const auto &part : fs::u8path(decoded)) {
      const auto name = part.u8string();
      if (name.empty() || name == ".") continue;
      if (name == "..") { require(!components.empty(), VXCORE_ERR_UNSUPPORTED); components.pop_back(); }
      else { disk::Name(name); components.push_back(name); }
    }
    std::string resolved;
    for (const auto &part : components) resolved = child(resolved, part);
    require(resolved.empty() || classification.physical.count(resolved), VXCORE_ERR_NOT_FOUND);
  }
}
Classification classify_source(const fs::path &source, const std::string &assets,
                               const std::atomic<bool> *cancel = nullptr) {
  Classification out;
  std::set<std::string> aliases;
  for (fs::recursive_directory_iterator it(source), end; it != end; ++it) {
    cancelled(cancel);
    const auto path = it->path().lexically_relative(source).generic_u8string();
    disk::Relative(path);
    require(out.physical.size() < kIds && aliases.insert(disk::Fold(path)).second, VXCORE_ERR_UNSUPPORTED);
    const auto info = disk::Info(it->path());
    const bool directory = info.at("directory").get<bool>();
    const auto name = disk::Fold(it->path().filename().u8string());
    require(name != ".git" && name != "vx_notebook" && name != "vx.json" && name != "vx_sync" &&
            name != "vx_import" && name != "vx_transfer" && lower(it->path().extension().u8string()) != ".vswp",
            VXCORE_ERR_UNSUPPORTED);
    if (!directory) {
      require(info.at("bytes").get<uint64_t>() <= kFile, VXCORE_ERR_UNSUPPORTED);
      plain_header(it->path());
    }
    out.physical.emplace(path, directory);
  }
  const auto asset_component = fs::u8path(assets).begin()->u8string();
  std::set<std::string> opaque;
  out.batches.emplace("", std::vector<std::string>());
  for (const auto &entry : out.physical) {
    const auto name = fs::u8path(entry.first).filename().u8string();
    const auto parent_path = parent(entry.first);
    const bool inherited = !parent_path.empty() && opaque.count(parent_path);
    const bool asset = disk::Fold(name) == disk::Fold(asset_component) || disk::Fold(name) == "vx_assets";
    if (inherited || asset) {
      require(inherited || entry.second, VXCORE_ERR_UNSUPPORTED);
      opaque.insert(entry.first);
      continue;
    }
    out.indexed.insert(entry.first);
    out.batches[parent_path].push_back(name);
    if (entry.second) out.batches.emplace(entry.first, std::vector<std::string>());
  }
  require(out.indexed.size() + 1 <= kIds, VXCORE_ERR_UNSUPPORTED);
  for (const auto &batch : out.batches) {
    // FileRecord::ToJson has id/name/two int64 timestamps/metadata/tags.
    // 512 covers their pretty-printed fixed keys, 127-byte ID and timestamp
    // maxima; names use actual JSON escaping. Folders add only a name edge.
    uint64_t bound = 1024 + Json(fs::u8path(batch.first).filename().u8string()).dump().size();
    for (const auto &name : batch.second) {
      const bool folder = out.physical.at(child(batch.first, name));
      bound += Json(name).dump().size() + (folder ? 16 : 512);
    }
    require(bound <= kImage, VXCORE_ERR_UNSUPPORTED);
    out.metadata_bound += bound;
    require(out.metadata_bound <= 128ULL * 1024 * 1024, VXCORE_ERR_UNSUPPORTED);
  }
  for (const auto &entry : out.physical) if (!entry.second) {
    cancelled(cancel);
    const auto suffix = lower(fs::u8path(entry.first).extension().u8string());
    if (suffix == ".md" || suffix == ".markdown" || suffix == ".mkd" || suffix == ".rmd")
      markdown_links(source, entry.first, out);
  }
  return out;
}
Json preflight(const fs::path &transaction) {
  const auto state = disk::Transaction(transaction.u8string(), "cohort");
  require(state.at("source") == true && state.at("prepared") == false && state.at("intent") == false,
          VXCORE_ERR_INVALID_STATE);
  require(!disk::Exists(transaction / "workbook") && !disk::Exists(transaction / "build.json"), VXCORE_ERR_ALREADY_EXISTS);
  const auto source = disk::ReadJson(transaction / "source.json");
  auto verify = disk::Command(transaction.u8string(), "cohort", "source");
  for (const auto *key : {"treeRelative", "inventoryHash", "bytes", "entries"}) verify[key] = source.at(key);
  Json ignored;
  check(vxm_import::TransferRun(verify, nullptr, ignored));
  auto dest = destination(transaction, state.at("target"), 0);
  const auto classification = classify_source(transaction / "unpacked", dest.layout);
  dest = destination(transaction, state.at("target"), classification.indexed.size() + 1);
  reserve(transaction, "cohort", source.at("bytes").get<uint64_t>() + classification.metadata_bound + 64ULL * 1024 * 1024);
  Json proof{{"version", 1}, {"id", state.at("id")}, {"scope", "cohort"}, {"target", state.at("target")},
             {"inventoryHash", source.at("inventoryHash")}, {"assetLayout", dest.layout},
             {"indexed", classification.indexed.size() + 1}, {"metadataBound", classification.metadata_bound}};
  disk::Marker(transaction, "preflight.json", proof);
  if (!disk::Exists(transaction / "engine")) disk::MakeDirectory(transaction / "engine");
  for (const auto *part : {"app", "local"}) {
    const auto path = transaction / "engine" / part;
    require(!disk::Exists(path), VXCORE_ERR_ALREADY_EXISTS);
    disk::MakeDirectory(path);
  }
  return {{"notebookPath", (transaction / "workbook").u8string()},
          {"appDataPath", (transaction / "engine/app").u8string()},
          {"localDataPath", (transaction / "engine/local").u8string()}, {"notebookName", "Private cohort import"}};
}
Json build(VxCoreContextHandle context, const std::string &notebook_id, const fs::path &root,
           const fs::path &transaction, const std::atomic<bool> *cancel) {
  const auto state = disk::Transaction(transaction.u8string(), "cohort");
  require(root == transaction / "workbook" && state.at("prepared") == false && state.at("intent") == false,
          VXCORE_ERR_INVALID_STATE);
  const auto proof = disk::ReadJson(transaction / "preflight.json");
  require(proof.at("target") == state.at("target") && proof.at("inventoryHash") == state.at("inventoryHash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto source_marker = disk::ReadJson(transaction / "source.json");
  auto verify = disk::Command(transaction.u8string(), "cohort", "source");
  for (const auto *key : {"treeRelative", "inventoryHash", "bytes", "entries"}) verify[key] = source_marker.at(key);
  Json ignored;
  check(vxm_import::TransferRun(verify, cancel, ignored));
  const auto layout = text(proof.at("assetLayout"), 1024);
  const auto classification = classify_source(transaction / "unpacked", layout, cancel);
  require(classification.indexed.size() + 1 == proof.at("indexed").get<size_t>(), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto dest = destination(transaction, state.at("target"), classification.indexed.size() + 1);
  require(dest.layout == layout, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  Graph initial(root, notebook_id);
  require(initial.nodes.size() == 1, VXCORE_ERR_INVALID_STATE);
  auto notebook_config = initial.config;
  notebook_config["assetsFolder"] = layout;
  check(vxcore_notebook_update_config(context, notebook_id.c_str(), notebook_config.dump().c_str()));
  const auto name = text(state.at("target").at("folderName"), 255);
  absent_name(root, name);
  reserve(transaction, "cohort", state.at("bytes").get<uint64_t>() + classification.metadata_bound + 64ULL * 1024 * 1024, cancel);
  disk::CopyTree(transaction / "unpacked", root / fs::u8path(name), cancel);
  cancelled(cancel);
  const auto wrapper = Json::array({name}).dump();
  check(vxcore_folder_index_children(context, notebook_id.c_str(), "", wrapper.c_str()));
  for (const auto &batch : classification.batches) {
    const auto path = batch.first.empty() ? name : child(name, batch.first);
    for (size_t offset = 0; offset < batch.second.size(); offset += 10000) {
      cancelled(cancel);
      const auto end = std::min(batch.second.size(), offset + 10000);
      Json names = Json::array();
      for (size_t i = offset; i < end; ++i) names.push_back(batch.second[i]);
      check(vxcore_folder_index_children(context, notebook_id.c_str(), path.c_str(), names.dump().c_str()));
    }
  }
  Graph generated(root, notebook_id);
  std::set<std::string> actual;
  std::vector<std::string> ids;
  std::string cohort_id;
  for (const auto &entry : generated.nodes) {
    if (entry.second.path.empty()) continue;
    require(beneath(entry.second.path, name), VXCORE_ERR_INVALID_STATE);
    ids.push_back(entry.first);
    if (entry.second.path == name) { cohort_id = entry.first; require(entry.second.folder); }
    else actual.insert(entry.second.path.substr(name.size() + 1));
  }
  require(!cohort_id.empty() && actual == classification.indexed && ids.size() == classification.indexed.size() + 1,
          VXCORE_ERR_INVALID_STATE);
  CoreString notebook, content, metadata;
  check(vxcore_folder_get_share_paths(context, notebook_id.c_str(), name.c_str(), &notebook.value, &content.value, &metadata.value));
  require(disk::Absolute(notebook.str()) == root && disk::Absolute(content.str()) == root / fs::u8path(name) &&
          disk::Absolute(metadata.str()) == root / "vx_notebook/contents" / fs::u8path(name), VXCORE_ERR_INVALID_STATE);
  const auto content_snapshot = disk::Tree(fs::u8path(content.str()), cancel);
  require(content_snapshot == disk::Tree(transaction / "unpacked", cancel), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto metadata_snapshot = disk::Tree(fs::u8path(metadata.str()), cancel);
  destination(transaction, state.at("target"), ids.size());
  disk::Marker(transaction, "ids.json", {{"ids", ids}}, kImage);
  const auto ids_hash = disk::Info(transaction / "ids.json", true, cancel, kImage).at("sha256");
  Json result{{"version", 1}, {"id", state.at("id")}, {"scope", "cohort"}, {"target", state.at("target")},
              {"privateNotebookId", notebook_id}, {"cohortId", cohort_id}, {"contentRelative", "workbook/" + name},
              {"metadataRelative", "workbook/vx_notebook/contents/" + name}, {"contentHash", content_snapshot.at("sha256")},
              {"metadataHash", metadata_snapshot.at("sha256")}, {"idsHash", ids_hash}, {"assetLayout", layout},
              {"bytes", content_snapshot.at("bytes").get<uint64_t>() + metadata_snapshot.at("bytes").get<uint64_t>()},
              {"entries", content_snapshot.at("entries").get<uint64_t>() + metadata_snapshot.at("entries").get<uint64_t>()}};
  cancelled(cancel);
  disk::Marker(transaction, "build.json", result);
  return {{"privateNotebookId", notebook_id}, {"cohortId", cohort_id}};
}

struct ResourceView {
  std::string notebook_id, node_id, path, editor, relative_directory;
  fs::path root, assets;
  Json record;
  std::set<std::string> members;
  std::map<std::string, Json> files;
};
void exact_optional_path(const fs::path &root, const std::string &relative) {
  auto current = root;
  for (const auto &part : fs::u8path(relative)) {
    if (!disk::Exists(current)) return;
    require(disk::Info(current).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
    const auto name = part.u8string(), folded = disk::Fold(name);
    bool found = false;
    for (const auto &entry : fs::directory_iterator(current)) {
      const auto actual = entry.path().filename().u8string();
      if (disk::Fold(actual) != folded) continue;
      require(actual == name && !found, VXCORE_ERR_UNSUPPORTED);
      disk::Info(entry.path()); found = true;
    }
    if (!found) return;
    current /= part;
  }
}
ResourceView resource_view(VxCoreContextHandle context, const std::string &notebook_id, const std::string &node_id,
                           const fs::path &root, const std::atomic<bool> *cancel = nullptr) {
  cancelled(cancel);
  Graph graph(root, notebook_id, true);
  const auto &node = graph.node(node_id, false);
  ResourceView out;
  out.notebook_id = notebook_id; out.node_id = node_id; out.path = node.path; out.root = root;
  out.record = graph.record(node);
  unprotected(out.record);
  const auto note = root / fs::u8path(node.path);
  require(disk::Info(note).at("directory") == false, VXCORE_ERR_UNSUPPORTED);
  plain_header(note); // Must precede any buffer_open, even with cached keys.
  auto suffix = fs::u8path(node.path).extension().u8string();
  if (!suffix.empty()) suffix.erase(0, 1);
  CoreString type;
  check(vxcore_filetype_get_by_suffix(context, suffix.c_str(), &type.value));
  const auto type_name = type.json().at("name");
  require(type_name == "Markdown" || type_name == "Text", VXCORE_ERR_UNSUPPORTED);
  out.editor = type_name == "Markdown" ? "markdown" : "text";
  const auto layout = asset_layout(graph);
  out.relative_directory = child(layout, node_id);
  disk::Relative(out.relative_directory);
  out.assets = root / fs::u8path(child(parent(node.path), out.relative_directory));
  exact_optional_path(root, child(parent(node.path), out.relative_directory));
  const auto asset_anchor = child(parent(node.path), layout);
  for (const auto &entry : graph.nodes)
    require(!beneath(entry.second.path, asset_anchor), VXCORE_ERR_UNSUPPORTED);
  std::set<std::string> aliases;
  if (out.record.contains("attachments")) {
    require(out.record.at("attachments").is_array() && out.record.at("attachments").size() <= kRows, VXCORE_ERR_UNSUPPORTED);
    for (const auto &member : out.record.at("attachments")) {
      const auto name = text(member, 255);
      disk::Name(name); // Raw metadata, never core's basename normalization.
      require(out.members.insert(name).second && aliases.insert(disk::Fold(name)).second, VXCORE_ERR_JSON_PARSE);
    }
  }
  if (disk::Exists(out.assets)) {
    require(disk::Info(out.assets).at("directory") == true, VXCORE_ERR_UNSUPPORTED);
    size_t entries = 0;
    std::set<std::string> physical_aliases;
    for (const auto &entry : fs::directory_iterator(out.assets)) {
      cancelled(cancel);
      require(++entries <= kRows, VXCORE_ERR_UNSUPPORTED);
      const auto name = entry.path().filename().u8string();
      disk::Name(name);
      const auto folded = disk::Fold(name);
      require(physical_aliases.insert(folded).second, VXCORE_ERR_UNSUPPORTED);
      const auto info = disk::Info(entry.path());
      if (aliases.count(folded)) require(out.members.count(name) != 0, VXCORE_ERR_UNSUPPORTED);
      if (info.at("directory") == true) { require(out.members.count(name) == 0, VXCORE_ERR_UNSUPPORTED); continue; }
      out.files.emplace(name, info);
    }
  }
  require(out.members.size() + out.files.size() <= 2 * kRows, VXCORE_ERR_UNSUPPORTED);
  return out;
}
Json listing(const ResourceView &view) {
  std::set<std::string> names = view.members;
  for (const auto &entry : view.files) names.insert(entry.first);
  require(names.size() <= kRows, VXCORE_ERR_UNSUPPORTED);
  Json entries = Json::array();
  size_t bytes = 0;
  for (const auto &name : names) {
    const auto file = view.files.find(name);
    Json entry{{"name", name}, {"tracked", view.members.count(name) != 0}, {"exists", file != view.files.end()},
               {"bytes", file == view.files.end() ? uint64_t(0) : file->second.at("bytes").get<uint64_t>()},
               {"relativeUrl", child(view.relative_directory, name)}};
    bytes += entry.dump().size() + 1;
    require(bytes <= kImage - 16384, VXCORE_ERR_UNSUPPORTED);
    entries.push_back(std::move(entry));
  }
  return {{"notebookId", view.notebook_id}, {"nodeId", view.node_id}, {"notePath", view.path}, {"entries", std::move(entries)}};
}
void pin_resource(const fs::path &transaction, const Json &state, const ResourceView &view) {
  const auto &target = state.at("target");
  require(target.at("notebookId") == view.notebook_id && target.at("nodeId") == view.node_id &&
          view.root == transaction.parent_path().parent_path() / "notebooks" / fs::u8path(text(target.at("notebookRelative"))),
          VXCORE_ERR_FILE_CHANGED_OUTSIDE);
}
Json resource_result(const fs::path &transaction, const Json &state, const ResourceView &view,
                     const std::string &name, bool with_link) {
  Json result{{"committed", true}};
  if (!name.empty()) result["name"] = name;
  if (with_link) result["relativeUrl"] = child(view.relative_directory, name);
  auto receipt = result;
  receipt["version"] = 1; receipt["id"] = state.at("id"); receipt["scope"] = "resource";
  disk::Marker(transaction, "outcome.json", receipt);
  command(transaction, "resource", "finishResource");
  return result;
}
void resource_image_bound(const ResourceView &view, const std::string &operation,
                          const std::string &name, const std::string &new_name) {
  if (operation == "image") return;
  auto image = disk::ReadJson(view.root / "vx_notebook/contents" / fs::u8path(parent(view.path)) / "vx.json");
  auto members = view.members;
  if (operation == "add" || operation == "track") members.insert(name);
  else members.erase(name);
  if (operation == "rename") members.insert(new_name);
  bool found = false;
  for (auto &file : image.at("files")) if (file.at("id") == view.node_id) {
    file["attachments"] = members;
    file["modifiedUtc"] = INT64_MAX;
    found = true;
  }
  image["modifiedUtc"] = INT64_MAX;
  require(found && image.dump(2).size() <= kImage, VXCORE_ERR_UNSUPPORTED);
}
Json resource_apply(VxCoreContextHandle context, const std::string &buffer_id, ResourceView view,
                    const fs::path &transaction, bool recover, const std::atomic<bool> *cancel) {
  auto state = disk::Transaction(transaction.u8string(), "resource");
  pin_resource(transaction, state, view);
  if (state.at("committed") == true) {
    auto receipt = disk::ReadJson(transaction / "committed.json");
    receipt.erase("version"); receipt.erase("id"); receipt.erase("scope");
    return receipt; // Legitimate later edits/deletion never replay the source.
  }
  const auto desired = disk::ReadJson(transaction / "resource.json");
  const auto operation = text(desired.at("operation"));
  const auto name = text(desired.at("name"), 255);
  disk::Name(name);
  const auto new_name = operation == "rename" ? text(desired.at("newName"), 255) : std::string();
  const bool insertion = operation == "add" || operation == "image";
  require(operation != "export", VXCORE_ERR_INVALID_PARAM);
  resource_image_bound(view, operation, name, new_name);
  reserve(transaction, "resource", 2 * kImage + 128 * 1024, cancel);
  Json dispatch;
  bool newly_dispatched = false;
  if (disk::Exists(transaction / "dispatch.json")) {
    dispatch = disk::ReadJson(transaction / "dispatch.json");
    keys(dispatch, {"version", "id", "scope", "desired", "notePath", "assetRelative", "old", "source", "wasMember"});
    require(dispatch.at("version") == 1 && dispatch.at("id") == state.at("id") && dispatch.at("scope") == "resource" &&
            dispatch.at("desired") == desired && dispatch.at("wasMember").is_boolean(), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  } else {
    cancelled(cancel);
    require(!recover, VXCORE_ERR_INVALID_STATE);
    const bool exists = view.files.count(name) != 0, member = view.members.count(name) != 0;
    Json old = nullptr, source = nullptr;
    fs::path source_path;
    if (insertion) {
      require(!exists && !member, VXCORE_ERR_ALREADY_EXISTS);
      absent_name(view.assets, name);
      require(operation != "image" || view.editor == "markdown", VXCORE_ERR_UNSUPPORTED);
      source = command(transaction, "resource", "inspectResource", cancel);
      const auto named = transaction / "named";
      if (disk::Exists(named)) disk::RemovePrivate(named);
      reserve(transaction, "resource", 2 * source.at("bytes").get<uint64_t>() + 2 * kImage + 128 * 1024, cancel);
      disk::MakeDirectory(named);
      source_path = named / fs::u8path(name);
      disk::Copy(fs::u8path(text(source.at("path"))), source_path, kFile, cancel);
      require(same_bytes(disk::Info(source_path, true, cancel, kFile), source), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    } else {
      require(exists || (operation == "untrack" && member) || (operation == "remove" && member), VXCORE_ERR_NOT_FOUND);
      if (exists) old = disk::Info(view.assets / fs::u8path(name), true, cancel, UINT64_MAX);
      if (operation == "rename") {
        require(member && exists, VXCORE_ERR_NOT_FOUND);
        disk::Name(new_name);
        require(view.members.count(new_name) == 0, VXCORE_ERR_ALREADY_EXISTS);
        absent_name(view.assets, new_name);
      }
      if (operation == "track") require(!member, VXCORE_ERR_ALREADY_EXISTS);
      if (operation == "untrack") require(member, VXCORE_ERR_NOT_FOUND);
    }
    const auto immediate = resource_view(context, view.notebook_id, view.node_id, view.root, cancel);
    require(immediate.path == view.path && immediate.relative_directory == view.relative_directory &&
            (immediate.members.count(name) != 0) == member, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    if (insertion) absent_name(immediate.assets, name);
    else if (!old.is_null()) {
      const auto now = disk::Info(immediate.assets / fs::u8path(name), true, cancel, UINT64_MAX);
      require(same_object(now, old) && same_bytes(now, old), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    }
    if (operation == "rename") absent_name(immediate.assets, new_name);
    dispatch = {{"version", 1}, {"id", state.at("id")}, {"scope", "resource"}, {"desired", desired},
                {"notePath", view.path}, {"assetRelative", view.relative_directory}, {"old", old}, {"source", source},
                {"wasMember", member}};
    cancelled(cancel);
    disk::Marker(transaction, "dispatch.json", dispatch); // Irreversible no-replay barrier.
    newly_dispatched = true;
    CoreString actual;
    int32_t code = VXCORE_OK;
    if (insertion) code = vxcore_buffer_insert_asset(context, buffer_id.c_str(), source_path.u8string().c_str(), &actual.value);
    else if (operation == "rename") code = vxcore_buffer_rename_attachment(context, buffer_id.c_str(), name.c_str(), new_name.c_str(), &actual.value);
    else if (operation == "track") code = vxcore_file_add_attachment(context, view.notebook_id.c_str(), view.path.c_str(), name.c_str());
    else if (operation == "untrack") code = vxcore_file_delete_attachment(context, view.notebook_id.c_str(), view.path.c_str(), name.c_str());
    else if (operation == "remove") {
      // Membership failure must precede any byte removal, including an API error
      // reported after publication. Only a later recovery may finish the deletion.
      code = vxcore_file_delete_attachment(context, view.notebook_id.c_str(), view.path.c_str(), name.c_str());
      if (code == VXCORE_OK && exists) {
        const auto now = disk::Info(view.assets / fs::u8path(name), true, nullptr, UINT64_MAX);
        require(same_object(now, old) && same_bytes(now, old), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
        code = vxcore_buffer_delete_asset(context, buffer_id.c_str(), child(parent(view.path), child(view.relative_directory, name)).c_str());
      }
    } else throw vxm_import::StorageFailure{VXCORE_ERR_INVALID_PARAM};
    Json returned{{"version", 1}, {"id", state.at("id")}, {"scope", "resource"}, {"code", code},
                  {"actual", nullptr}, {"actualName", nullptr}, {"actualIdentity", nullptr}};
    if (actual.value) {
      returned["actual"] = actual.str();
      const auto actual_name = fs::u8path(actual.str()).filename().u8string();
      try {
        disk::Name(actual_name);
        require(!insertion || parent(actual.str()) == child(parent(view.path), view.relative_directory));
        returned["actualName"] = actual_name;
        returned["actualIdentity"] = disk::Info(view.assets / fs::u8path(actual_name), true, nullptr, UINT64_MAX);
      } catch (...) {
        // The returned name remains evidence even when its object changed or
        // cannot be read. Never replace that uncertainty with claimed success.
      }
    }
    disk::Marker(transaction, "returned.json", returned);
    // Core InsertAsset returns notebook-relative, not note-relative, paths.
    if (actual.value) {
      const auto expected = insertion ? child(parent(view.path), child(view.relative_directory, name)) : new_name;
      if (actual.str() != expected) {
        disk::Marker(transaction, "ambiguous.json", returned);
        throw vxm_import::StorageFailure{VXCORE_ERR_INVALID_STATE};
      }
    }
  }
  require(!disk::Exists(transaction / "ambiguous.json"), VXCORE_ERR_INVALID_STATE);
  if (disk::Exists(transaction / "returned.json")) {
    const auto returned = disk::ReadJson(transaction / "returned.json");
    keys(returned, {"version", "id", "scope", "code", "actual", "actualName", "actualIdentity"});
    require(returned.at("version") == 1 && returned.at("id") == state.at("id") && returned.at("scope") == "resource",
            VXCORE_ERR_JSON_PARSE);
    if (!returned.at("actual").is_null()) {
      const auto expected = insertion ? child(parent(text(dispatch.at("notePath"))), child(view.relative_directory, name)) : new_name;
      require(returned.at("actual") == expected, VXCORE_ERR_INVALID_STATE);
    }
  }
  require(dispatch.at("assetRelative") == view.relative_directory, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  // No cancellation after dispatch: always drain authoritative reconciliation.
  view = resource_view(context, view.notebook_id, view.node_id, view.root);
  const auto old_path = view.assets / fs::u8path(name);
  const bool exists = view.files.count(name) != 0;
  const bool member = view.members.count(name) != 0;
  if (insertion) {
    // Absence is never permission to invoke the suffix-generating API again.
    require(exists && !dispatch.at("source").is_null(), VXCORE_ERR_INVALID_STATE);
    require(same_bytes(disk::Info(old_path, true, nullptr, kFile), dispatch.at("source")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    if (operation == "add" && !member)
      check(vxcore_file_add_attachment(context, view.notebook_id.c_str(), view.path.c_str(), name.c_str()));
    view = resource_view(context, view.notebook_id, view.node_id, view.root);
    require(same_bytes(disk::Info(view.assets / fs::u8path(name), true, nullptr, kFile), dispatch.at("source")),
            VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    require(operation == "add" ? view.members.count(name) != 0 : view.members.count(name) == 0, VXCORE_ERR_INVALID_STATE);
    return resource_result(transaction, state, view, name, true);
  }
  if (operation == "rename") {
    require(!exists && view.files.count(new_name) != 0 && !dispatch.at("old").is_null(), VXCORE_ERR_INVALID_STATE);
    const auto actual = disk::Info(view.assets / fs::u8path(new_name), true, nullptr, UINT64_MAX);
    require(same_object(actual, dispatch.at("old")) && same_bytes(actual, dispatch.at("old")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    if (member || view.members.count(new_name) == 0) {
      auto members = view.members;
      members.erase(name); members.insert(new_name);
      check(vxcore_file_update_attachments(context, view.notebook_id.c_str(), view.path.c_str(), Json(members).dump().c_str()));
    }
    view = resource_view(context, view.notebook_id, view.node_id, view.root);
    require(view.members.count(name) == 0 && view.members.count(new_name) != 0, VXCORE_ERR_INVALID_STATE);
    return resource_result(transaction, state, view, new_name, true);
  }
  if (exists) {
    require(!dispatch.at("old").is_null(), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    const auto actual = disk::Info(old_path, true, nullptr, UINT64_MAX);
    require(same_object(actual, dispatch.at("old")) && same_bytes(actual, dispatch.at("old")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  } else if (operation == "track") require(false, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  if (operation == "track") {
    if (!member) check(vxcore_file_add_attachment(context, view.notebook_id.c_str(), view.path.c_str(), name.c_str()));
  } else {
    if (member) check(vxcore_file_delete_attachment(context, view.notebook_id.c_str(), view.path.c_str(), name.c_str()));
    if (operation == "remove" && exists) {
      // An error in the first metadata operation never causes deletion in that
      // same invocation. Recovery is an explicit new admission with identity proof.
      if (newly_dispatched) {
        const auto returned = disk::ReadJson(transaction / "returned.json");
        check(returned.at("code").get<int32_t>());
      }
      const auto now = disk::Info(old_path, true, nullptr, UINT64_MAX);
      require(same_object(now, dispatch.at("old")) && same_bytes(now, dispatch.at("old")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
      check(vxcore_buffer_delete_asset(context, buffer_id.c_str(), child(parent(view.path), child(view.relative_directory, name)).c_str()));
    }
  }
  view = resource_view(context, view.notebook_id, view.node_id, view.root);
  require(operation == "track" ? view.members.count(name) != 0 : view.members.count(name) == 0, VXCORE_ERR_INVALID_STATE);
  if (operation == "remove") require(view.files.count(name) == 0, VXCORE_ERR_INVALID_STATE);
  return resource_result(transaction, state, view, name, operation == "track");
}
Json resource_export(const ResourceView &view, const fs::path &transaction, const std::string &name,
                     const std::atomic<bool> *cancel) {
  const auto state = disk::Transaction(transaction.u8string(), "resource");
  pin_resource(transaction, state, view);
  disk::Name(name);
  require(!disk::Exists(transaction / "dispatch.json"), VXCORE_ERR_INVALID_STATE);
  if (disk::Exists(transaction / "ready.json")) {
    const auto ready = command(transaction, "resource", "verifyExport", cancel);
    require(ready.at("name") == name, VXCORE_ERR_INVALID_STATE);
    return ready;
  }
  require(view.files.count(name) != 0, VXCORE_ERR_NOT_FOUND);
  const auto desired = disk::ReadJson(transaction / "resource.json");
  require(desired.at("operation") == "export" && desired.at("name") == name, VXCORE_ERR_INVALID_STATE);
  const auto bytes = view.files.at(name).at("bytes").get<uint64_t>();
  require(bytes <= kExport, VXCORE_ERR_UNSUPPORTED);
  reserve(transaction, "resource", bytes + 128 * 1024, cancel);
  const auto output = transaction / "output";
  if (disk::Exists(output)) disk::RemovePrivate(output); // No ready receipt: only private failed derivation.
  disk::MakeDirectory(output);
  require(disk::Info(view.assets / fs::u8path(name)) == view.files.at(name), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto snapshot = disk::Copy(view.assets / fs::u8path(name), output / fs::u8path(name), kExport, cancel);
  cancelled(cancel);
  disk::Marker(transaction, "ready.json", {{"version", 1}, {"id", state.at("id")}, {"scope", "resource"},
               {"name", name}, {"bytes", snapshot.at("bytes")}, {"sha256", snapshot.at("sha256")}});
  return command(transaction, "resource", "verifyExport");
}

uint64_t attempt_generation(const Json &intent) {
  require(intent.at("generation").is_number_unsigned() || intent.at("generation").is_number_integer(), VXCORE_ERR_JSON_PARSE);
  const auto generation = intent.at("generation").get<uint64_t>();
  require(generation > 0 && generation <= 10000, VXCORE_ERR_UNSUPPORTED);
  return generation;
}
std::string attempt_marker(const char *kind, const Json &intent) {
  return std::string(kind) + "-" + std::to_string(attempt_generation(intent)) + ".json";
}
Json directory_identity(const fs::path &path) {
  const auto value = disk::Info(path);
  require(value.at("directory") == true, VXCORE_ERR_UNSUPPORTED);
  return {{"device", value.at("device")}, {"low", value.at("low")}, {"high", value.at("high")}};
}
Json cohort_outcome(const fs::path &transaction, const Json &state, const Json &intent,
                    const std::string &status, const std::string &path = "") {
  Json result{{"status", status}, {"cohortId", state.at("cohortId")}};
  if (status == "committed") result["path"] = path;
  auto receipt = result;
  receipt["version"] = 1; receipt["id"] = state.at("id"); receipt["scope"] = "cohort";
  receipt["preparedHash"] = intent.at("preparedHash");
  // Absence is a recoverable attempt state, not immutable final success. Its
  // proof is kept separately so a later exact-ID retry may commit once.
  disk::Marker(transaction, status == "committed" ? "outcome.json" : attempt_marker("absent", intent), receipt);
  if (status == "committed") command(transaction, "cohort", "writeReceipt");
  return result;
}
Json cohort_reconcile(VxCoreContextHandle context, const std::string &notebook_id, const fs::path &root,
                      const fs::path &transaction, const Json &state, const Json &intent) {
  int recovered = 0;
  check(vxcore_notebook_recover_imports(context, notebook_id.c_str(), &recovered));
  Graph graph(root, notebook_id, true);
  const auto prepared = disk::ReadJson(transaction / "prepared.json");
  require(disk::Info(transaction / "ids.json", true, nullptr, kImage).at("sha256") == prepared.at("idsHash"),
          VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto ids = disk::ReadJson(transaction / "ids.json").at("ids");
  require(ids.is_array() && !ids.empty() && ids.size() <= kIds, VXCORE_ERR_JSON_PARSE);
  const auto root_id = text(state.at("cohortId"), 127);
  const auto found = graph.nodes.find(root_id);
  if (found != graph.nodes.end()) {
    require(found->second.folder, VXCORE_ERR_INVALID_STATE);
    return cohort_outcome(transaction, state, intent, "committed", found->second.path);
  }
  for (const auto &id : ids) require(!graph.nodes.count(text(id, 127)), VXCORE_ERR_INVALID_STATE);
  const auto moved = root / fs::u8path(text(intent.at("movedRelative")));
  const auto private_attempt = transaction / "attempt";
  const auto rollback_path = transaction / attempt_marker("rollback", intent);
  const bool settled = disk::Exists(rollback_path);
  if (settled) require(disk::ReadJson(rollback_path).at("intent") == intent, VXCORE_ERR_INVALID_STATE);
  if (disk::Exists(moved)) {
    require(!settled && same_object(disk::Info(moved), intent.at("attemptIdentity")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    require(!disk::Exists(moved / "journal.json"), VXCORE_ERR_INVALID_STATE);
    size_t count = 0;
    for (const auto &entry : fs::directory_iterator(moved)) {
      require(entry.path().filename() == "content" || entry.path().filename() == "metadata", VXCORE_ERR_INVALID_STATE);
      ++count;
    }
    require(count == 2, VXCORE_ERR_INVALID_STATE);
    for (const auto *part : {"content", "metadata"})
      require(same_object(disk::Info(moved / part), intent.at(std::string(part) + "Identity")) &&
              disk::Tree(moved / part).at("sha256") == prepared.at(std::string(part) + "Hash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    require(!disk::Exists(private_attempt), VXCORE_ERR_INVALID_STATE);
    disk::Move(moved, private_attempt);
  }
  bool complete_private = false;
  if (disk::Exists(private_attempt) && same_object(disk::Info(private_attempt), intent.at("attemptIdentity"))) {
    for (const auto *part : {"content", "metadata"})
      require(same_object(disk::Info(private_attempt / part), intent.at(std::string(part) + "Identity")) &&
              disk::Tree(private_attempt / part).at("sha256") == prepared.at(std::string(part) + "Hash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    complete_private = true;
  }
  if (!complete_private && !settled) {
    // Missing wrapper alone proves nothing. Exact unchanged parent bytes,
    // absent destinations and a complete authoritative no-ID proof are needed.
    const auto dispatch = disk::ReadJson(transaction / attempt_marker("dispatch", intent));
    require(dispatch.at("generation") == intent.at("generation"), VXCORE_ERR_INVALID_STATE);
    const auto dest = destination(transaction, state.at("target"), ids.size(), context, true);
    const auto parent_now = disk::Info(dest.metadata / "vx.json", true, nullptr, kImage);
    require(same_bytes(parent_now, dispatch.at("parentBefore")) && !disk::Exists(private_attempt) && !disk::Exists(moved),
            VXCORE_ERR_INVALID_STATE);
  }
  require(!disk::Exists(moved), VXCORE_ERR_INVALID_STATE);
  // This durable native proof settles only this attempt generation. It never
  // authorizes a live deletion or success. Future retries retain every node ID.
  disk::Marker(transaction, attempt_marker("rollback", intent),
               {{"version", 1}, {"id", state.at("id")}, {"scope", "cohort"}, {"intent", intent}, {"status", "absent"}});
  return cohort_outcome(transaction, state, intent, "absent");
}
Json renew_attempt(const fs::path &transaction, const Json &intent, const Json &prepared,
                   const std::atomic<bool> *cancel) {
  const auto proof = disk::ReadJson(transaction / attempt_marker("rollback", intent));
  require(proof.at("intent") == intent && proof.at("status") == "absent", VXCORE_ERR_INVALID_STATE);
  const auto generation = attempt_generation(intent);
  require(generation < 10000, VXCORE_ERR_UNSUPPORTED);
  const auto attempt = transaction / "attempt";
  bool complete = disk::Exists(attempt) && same_object(disk::Info(attempt), intent.at("attemptIdentity"));
  if (complete) for (const auto *part : {"content", "metadata"})
    complete &= disk::Exists(attempt / part) && disk::Tree(attempt / part, cancel).at("sha256") == prepared.at(std::string(part) + "Hash");
  if (!complete) {
    // Only private derivation is removed after the durable rollback proof.
    if (disk::Exists(attempt)) disk::RemovePrivate(attempt);
    reserve(transaction, "cohort", prepared.at("bytes").get<uint64_t>() + 64ULL * 1024 * 1024, cancel);
    disk::MakeDirectory(attempt);
    for (const auto *part : {"content", "metadata"})
      require(disk::CopyTree(transaction / "prepared" / part, attempt / part, cancel).at("sha256") ==
              prepared.at(std::string(part) + "Hash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  }
  auto next = intent;
  next["generation"] = generation + 1;
  next["attemptIdentity"] = directory_identity(attempt);
  next["contentIdentity"] = directory_identity(attempt / "content");
  next["metadataIdentity"] = directory_identity(attempt / "metadata");
  disk::Marker(transaction, attempt_marker("intent", intent), intent);
  disk::ReplaceMarker(transaction, "intent.json", intent, next);
  return next;
}
Json cohort_apply(VxCoreContextHandle context, const std::string &notebook_id, const fs::path &root,
                  const fs::path &transaction, bool recover, const std::atomic<bool> *cancel) {
  auto state = disk::Transaction(transaction.u8string(), "cohort");
  const auto target = state.at("target");
  require(target.at("notebookId") == notebook_id && root == transaction.parent_path().parent_path() / "notebooks" /
          fs::u8path(text(target.at("notebookRelative"))), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  if (state.at("committed") == true) {
    auto out = disk::ReadJson(transaction / "committed.json");
    for (const auto *key : {"version", "id", "scope", "preparedHash"}) out.erase(key);
    return out;
  }
  require(state.at("prepared") == true, VXCORE_ERR_INVALID_STATE);
  if (state.at("intent") == false) {
    if (recover) return {{"status", "absent"}, {"cohortId", state.at("cohortId")}};
    state = command(transaction, "cohort", "prepareAttempt", cancel);
  }
  auto intent = disk::ReadJson(transaction / "intent.json");
  require(disk::Info(transaction / "prepared.json", true, nullptr, 16384).at("sha256") == intent.at("preparedHash"),
          VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto prepared = disk::ReadJson(transaction / "prepared.json");
  if (recover) return cohort_reconcile(context, notebook_id, root, transaction, state, intent);
  if (disk::Exists(transaction / attempt_marker("rollback", intent))) {
    const auto outcome = cohort_reconcile(context, notebook_id, root, transaction, state, intent);
    if (outcome.at("status") == "committed") return outcome;
    intent = renew_attempt(transaction, intent, prepared, cancel);
  } else if (disk::Exists(transaction / attempt_marker("dispatch", intent)))
    return cohort_reconcile(context, notebook_id, root, transaction, state, intent);
  require(disk::Info(transaction / "ids.json", true, cancel, kImage).at("sha256") == prepared.at("idsHash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto ids = disk::ReadJson(transaction / "ids.json").at("ids");
  auto dest = destination(transaction, target, ids.size(), context);
  require(dest.layout == prepared.at("assetLayout"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  Graph current(root, notebook_id);
  for (const auto &id : ids) require(!current.nodes.count(text(id, 127)), VXCORE_ERR_ALREADY_EXISTS);
  const auto attempt = transaction / "attempt";
  require(same_object(disk::Info(attempt), intent.at("attemptIdentity")), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  for (const auto *part : {"content", "metadata"})
    require(same_object(disk::Info(attempt / part), intent.at(std::string(part) + "Identity")) &&
            disk::Tree(attempt / part, cancel).at("sha256") == prepared.at(std::string(part) + "Hash"), VXCORE_ERR_FILE_CHANGED_OUTSIDE);
  const auto journal_root = root / "vx_notebook/vx_import";
  if (!disk::Exists(journal_root)) disk::MakeDirectory(journal_root);
  const auto moved = root / fs::u8path(text(intent.at("movedRelative")));
  require(!disk::Exists(moved) && disk::Info(journal_root).at("device") == disk::Info(attempt).at("device"), VXCORE_ERR_UNSUPPORTED);
  // Exact current schema-2 journal bound, including escaped binary images.
  auto after = dest.parent_image;
  after["folders"].push_back(target.at("folderName")); after["modifiedUtc"] = INT64_MAX;
  Json journal{{"schema", 2}, {"notebookId", notebook_id}, {"phase", "init"},
               {"destPath", dest.path.empty() ? "." : dest.path}, {"finalName", target.at("folderName")},
               {"parentId", target.at("parentId")}, {"rootFolderId", state.at("cohortId")}, {"ids", ids},
               {"parentConfigBytes", dest.before}, {"parentAfterBytes", after.dump(2)},
               {"stagingIdentity", intent.at("attemptIdentity")}, {"contentIdentity", intent.at("contentIdentity")},
               {"metadataIdentity", intent.at("metadataIdentity")}};
  require(after.dump(2).size() <= kImage && journal.dump().size() <= kJournal, VXCORE_ERR_UNSUPPORTED);
  cancelled(cancel);
  disk::Marker(transaction, attempt_marker("dispatch", intent), {{"version", 1}, {"id", state.at("id")}, {"scope", "cohort"},
               {"generation", intent.at("generation")}, {"parentPath", dest.path},
               {"parentBefore", disk::Info(dest.metadata / "vx.json", true, nullptr, kImage)}});
  // From intent+move onward cancellation cannot make a rollback claim.
  try {
    disk::Move(attempt, moved);
    CoreString attached;
    const auto code = vxcore_folder_attach_imported(context, notebook_id.c_str(), dest.path.c_str(),
        text(target.at("folderName")).c_str(), moved.u8string().c_str(), &attached.value);
    (void)code; // Actual authoritative state, not the return code, decides commit.
  } catch (...) {
    // A rename/flush error can follow the move. Always drain core recovery;
    // never expose a guessed absence or retry the old source path.
    return cohort_reconcile(context, notebook_id, root, transaction, state, intent);
  }
  return cohort_reconcile(context, notebook_id, root, transaction, state, intent);
}
}  // namespace

namespace vxm_transfer {
int32_t PreflightCohortBuilder(const std::string &transaction_root, Json &options) noexcept {
  try { options = preflight(disk::Absolute(transaction_root)); return VXCORE_OK; }
  catch (...) { return disk::ErrorCode(); }
}
int32_t PreflightResource(VxCoreContextHandle context, const std::string &notebook_id,
                          const std::string &node_id, const std::string &notebook_root, Json &metadata) noexcept {
  try {
    const auto view = resource_view(context, notebook_id, node_id, disk::Absolute(notebook_root));
    metadata = {{"notebookId", notebook_id}, {"nodeId", node_id}, {"notePath", view.path}, {"editorType", view.editor}};
    return VXCORE_OK;
  } catch (...) { return disk::ErrorCode(); }
}
int32_t Cohort(VxCoreContextHandle context, const std::string &notebook_id, const std::string &notebook_root,
               const Json &request, const std::atomic<bool> *cancel, Json &out) noexcept {
  try {
    keys(request, {"op", "transactionRoot"});
    const auto operation = text(request.at("op"));
    const auto root = disk::Absolute(notebook_root), transaction = disk::Absolute(text(request.at("transactionRoot")));
    if (operation == "build") out = build(context, notebook_id, root, transaction, cancel);
    else {
      require(operation == "apply" || operation == "recover", VXCORE_ERR_INVALID_PARAM);
      out = cohort_apply(context, notebook_id, root, transaction, operation == "recover", cancel);
    }
    require(out.dump().size() <= 16384, VXCORE_ERR_OUT_OF_MEMORY);
    return VXCORE_OK;
  } catch (...) { return disk::ErrorCode(); }
}
int32_t Resource(VxCoreContextHandle context, const std::string &notebook_id, const std::string &node_id,
                 const std::string &note_path, const std::string &buffer_id, const std::string &notebook_root,
                 const Json &request, const std::atomic<bool> *cancel, Json &out) noexcept {
  try {
    const auto operation = text(request.at("op"));
    if (operation == "list") keys(request, {"op"});
    else if (operation == "export") keys(request, {"op", "name", "transactionRoot"});
    else { keys(request, {"op", "transactionRoot"}); require(operation == "apply" || operation == "recover", VXCORE_ERR_INVALID_PARAM); }
    auto view = resource_view(context, notebook_id, node_id, disk::Absolute(notebook_root), cancel);
    require(view.path == note_path, VXCORE_ERR_FILE_CHANGED_OUTSIDE);
    if (operation == "list") out = listing(view);
    else if (operation == "export") out = resource_export(view, disk::Absolute(text(request.at("transactionRoot"))), text(request.at("name"), 255), cancel);
    else out = resource_apply(context, buffer_id, std::move(view), disk::Absolute(text(request.at("transactionRoot"))), operation == "recover", cancel);
    require(out.dump().size() <= (operation == "list" ? kImage : 16384), VXCORE_ERR_OUT_OF_MEMORY);
    return VXCORE_OK;
  } catch (...) { return disk::ErrorCode(); }
}
}  // namespace vxm_transfer
