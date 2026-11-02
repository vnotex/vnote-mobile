// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_VXCORE_HOST_H
#define VNOTE_MOBILE_VXCORE_HOST_H

#include <stdint.h>
#include <vxcore/vxcore_types.h>

#if defined(_WIN32)
#if defined(VXM_HOST_BUILD)
#define VXM_API __declspec(dllexport)
#else
#define VXM_API __declspec(dllimport)
#endif
#else
#define VXM_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VxmHost VxmHost;
typedef void (*VxmNotify)(int64_t token);
typedef struct VxmImportCancel VxmImportCancel;

enum {
  VXM_EVENT_OPEN = 1,
  VXM_EVENT_READ = 2,
  VXM_EVENT_WRITE = 3,
  VXM_EVENT_CLOSED = 4,
  VXM_EVENT_CATALOG_OPEN = 5,
  VXM_EVENT_LIST = 6,
  VXM_EVENT_MUTATE = 7,
  VXM_EVENT_QUERY = 8,
  VXM_EVENT_TAG = 9,
  VXM_EVENT_EXPORT = 10,
  VXM_MODE_NOTE = 1,
  VXM_MODE_CATALOG = 2,
  VXM_EXPORT_NOTEBOOK = 0,
  VXM_EXPORT_FILES_AND_ASSETS = 1,
  VXM_EDITOR_MARKDOWN = 1,
  VXM_EDITOR_TEXT = 2,
  VXM_CREATE_NOTE = 1,
  VXM_CREATE_FOLDER = 2,
  VXM_RENAME = 3,
  VXM_MOVE = 4,
  VXM_DELETE = 5,
  VXM_RENAME_NOTEBOOK = 6,
  VXM_MAX_CATALOG_BYTES = 8388608,
  VXM_MAX_SOURCE_BYTES = 4194304,
  VXM_MAX_OPERATIONS = 64,
  VXM_MAX_INPUT_BYTES = 33554432,
  VXM_MAX_OUTPUT_BYTES = 16777216
};

typedef struct VxmOpenOptions {
  const char *app_data_path;
  const char *local_data_path;
  const char *notebook_path;
  const char *notebook_name;
  const char *expected_notebook_id;
  const char *node_id;
  int32_t mode;
  int32_t create_notebook;
  // Export-only catalog admission: existing pinned UUID, no mutations. Checks
  // source-rewriting recovery/migrations and persisted session restoration before
  // core initialization. Ordinary owners retain core's normal recovery behavior.
  int32_t export_only;
} VxmOpenOptions;

// Immutable terminal event. Pointers are borrowed until vxm_event_free(), which
// is required exactly once even for errors. Taken events may outlive their host.
// Metadata and listing JSON belong to the event, never to its host. No core
// handles or unredacted last-error strings cross this ABI.
typedef struct VxmEvent {
  uint64_t request_id;
  uint64_t generation;
  uint64_t revision;
  int32_t kind;
  int32_t code;
  int32_t line_ending;
  int32_t editor_type;
  const char *message;
  const char *notebook_id;
  const char *node_id;
  const char *base_hash;
  const char *core_version;
  const char *path;
  const char *parent_id;
  const char *notebook_name;
  const uint8_t *data;
  uint64_t size;
} VxmEvent;

// Copies bounded input and starts an owner thread. OPEN/CATALOG_OPEN is request
// 1, revision 0. Only one host may own a given storage root until teardown.
// create_notebook=0 requires an existing notebook, even without an expected UUID.
// create_notebook=1 is catalog-only, requires a valid display name and no expected
// UUID, and rejects every existing root entry. Note mode never creates.
// All returns are actual VxCoreError values. Admission failure produces no event.
// Success reserves terminal storage before work starts. Notify runs outside the
// queue mutex and carries only a caller-owned integer token; it must not block.
VXM_API int32_t vxm_host_create(const VxmOpenOptions *options, VxmNotify notify,
                              int64_t token, VxmHost **out_host);
VXM_API uint64_t vxm_host_generation(const VxmHost *host);
VXM_API int32_t vxm_host_read(VxmHost *host, uint64_t request_id, uint64_t generation);
VXM_API int32_t vxm_host_write(VxmHost *host, uint64_t request_id, uint64_t generation,
                             uint64_t revision, const char *base_hash,
                             const uint8_t *data, uint64_t size);
// Catalog-only. A null/empty folder ID lists root; mutations require node IDs.
// RENAME_NOTEBOOK requires the root node ID and changes display metadata only.
// MUTATE returns the affected/new ID, including any known partial failure ID.
// Refresh separately after every attempted mutation; failure is not rollback.
VXM_API int32_t vxm_host_catalog_list(VxmHost *host, uint64_t request_id,
                                    uint64_t generation, const char *folder_id);
VXM_API int32_t vxm_host_catalog_mutate(VxmHost *host, uint64_t request_id,
                                      uint64_t generation, int32_t operation,
                                      const char *node_id, const char *name,
                                      const char *destination_folder_id);
// Catalog-only bounded JSON requests (at most 16 KiB, UTF-8, no embedded NUL).
// QUERY: {op:"search",text,tag?,caseSensitive} or {op:"tags",nodeId?}.
// QUERY: {op:"collectNodeIds"} returns {notebookId,nodeIds:[string]}; strict
// disk graph and core collector must agree exactly, without duplicate IDs.
// Search returns {notebookId,matches:[{id,path,line,snippet}],limited,skipped}.
// Tags returns complete {notebookId,tags:[{name,parent}],assigned:[string]}.
// TAG: {op:"createTag",name} or {op:"setTags",nodeId,tags:[string]}.
// TAG success describes only the mutation; refresh separately even after errors.
// QUERY owns a preallocated 8 MiB body until event release, including taken events.
VXM_API int32_t vxm_host_catalog_query(VxmHost *host, uint64_t request_id,
                                     uint64_t generation, const char *json);
VXM_API int32_t vxm_host_catalog_tag(VxmHost *host, uint64_t request_id,
                                   uint64_t generation, const char *json);
// Export-only catalog snapshot into an exclusively new absolute destination,
// outside notebook/app/local roots. Preserves original bytes, not regenerated
// metadata. FILES_AND_ASSETS omits the entire vx_notebook and configured recycle
// trees, and refuses protected data.
// Requires an owner created with export_only=1, mode=VXM_MODE_CATALOG,
// create_notebook=0, and a nonempty expected_notebook_id. Ordinary catalog
// owners reject export admission with VXCORE_ERR_INVALID_STATE.
// Limit: 1 GiB selected bytes, 100000 entries, depth 32, component 255/path 1024
// UTF-8 bytes. Content format charges excluded entries to the inspection cap too.
// staging_budget_bytes reserves snapshot + conservative ZIP bound, at most
// 4 GiB - 128 KiB marker allowance; 64 MiB free-space headroom is separate.
// EXPORT data is <=1024 bytes: {format,bytes,files,directories,archiveLimit}; format
// is "notebook" or "filesAndAssets". Empty content snapshots are valid. Notebook
// identity/name use event metadata. Caller owns any private partial destination and
// must wait for the terminal/close before removing it; publish only on success.
// Never modifies the live tree. Invalid formats do not consume request IDs.
VXM_API int32_t vxm_host_catalog_export(VxmHost *host, uint64_t request_id,
                                       uint64_t generation, int32_t format, const char *destination,
                                       uint64_t staging_budget_bytes);
// Request IDs strictly increase per host. Rejected IDs do not consume a number.
// Cancel affects pending requests and the matching active read-only search/export,
// checked between files/nodes and each 256 KiB export chunk. Active writes (including tags) are never cancelled. INVALID_STATE
// means no cancellable matching request. Search may finish one bounded file before cancellation.
VXM_API int32_t vxm_host_cancel(VxmHost *host, uint64_t request_id, uint64_t generation);
// Idempotent; stops admission, cancels pending work and active search/export, finishes
// active mutations, then emits the separately reserved CLOSED terminal (request 0)
// after owner teardown. Admitted terminals always precede CLOSED.
VXM_API void vxm_host_request_close(VxmHost *host);
VXM_API VxmEvent *vxm_host_take_event(VxmHost *host);
VXM_API void vxm_event_free(VxmEvent *event);
// Joins; never call on a UI isolate or from notify. No concurrent host access is
// permitted during destroy. Undelivered events are freed; taken events survive.
VXM_API void vxm_host_destroy(VxmHost *host);
// Borrowed process-lifetime UTF-8 text generated from actual dependency licenses.
VXM_API const char *vxm_native_notices(void);

// Pure cancellation/Unicode helpers: no filesystem access and no core context.
// Cancellation is borrowed by workers; free ONLY after every borrower has joined.
VXM_API VxmImportCancel *vxm_import_cancel_create(void);
VXM_API void vxm_import_cancel_request(VxmImportCancel *cancel);
VXM_API int32_t vxm_import_cancel_query(const VxmImportCancel *cancel);
VXM_API void vxm_import_cancel_free(VxmImportCancel *cancel);
// Input <=1024 UTF-8 bytes; output <=16384 bytes per key, no NUL terminator.
// Both sizes are set before checking capacity. Buffers are untouched on error.
VXM_API int32_t vxm_import_path_keys(const uint8_t *input, uint64_t size,
                                    uint8_t *nfc, uint64_t nfc_capacity, uint64_t *nfc_size,
                                    uint8_t *nfd, uint64_t nfd_capacity, uint64_t *nfd_size);
// Synchronous worker-only filesystem commands. Request <=16 KiB, response <=8 MiB.
// No core context is created or transferred. Errors may follow publication;
// ALWAYS recover actual journal/path state rather than guessing from an error.
// Every command has {op,importsRoot,notebooksRoot,id}; roots are absolute
// sibling imports/ and notebooks/ directories, id is exactly 32 lowercase hex.
// inspect: +treeRelative,inventoryHash -> {notebookId,notebookName,nodeIds}.
// inspectManaged: +location,expectedNotebookId? -> same strict result, read-only.
// publish: +treeRelative,inventoryHash,notebookId,notebookName -> durable phase.
// recover,commit: no extra fields -> durable phase; commit ignores cancellation
// after its caller's guarded destination owner has closed successfully.
// discard: +allowPublished? (default false) -> {discarded:true}. A valid committed
// receipt permits PRIVATE cleanup only, even after legitimate live edits/removal.
// writeMarker: +marker(request|captured|prepared),data -> durable phase.
// checkSpace: +requiredBytes (additional bytes, not headroom) -> {availableBytes};
// no-follow imports+exports bytes + requiredBytes <=4GiB, free space includes
// an additional 64MiB headroom. It also rejects hardlinks/reparse/special files.
// Durable phase fields: id,kind,phase(staged|published|committed),captured,prepared,
// treeRelative,inventoryHash,notebookId,notebookName,destination,bytes,entries;
// sourceName is included once captured. Unknown identity/path states are errors,
// never invented phases. destination is absolute, journal destination relative.
// A publication intent with matching source only is staged; matching target only
// is published. Both/neither or foreign identity fails closed. Committed data is
// never rehashed against its old inventory, and missing committed data never replays.
// Results are NUL-terminated UTF-8. On any failure *out_json is null; messages
// are redacted by the Dart facade. The borrowed token may be null (no cancellation).
VXM_API int32_t vxm_import_run(const char *request_json, VxmImportCancel *cancel,
                              char **out_json);
VXM_API void vxm_import_result_free(char *result);

#ifdef __cplusplus
}
#endif
#endif
