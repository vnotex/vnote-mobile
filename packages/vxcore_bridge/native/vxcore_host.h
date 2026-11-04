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
  VXM_EVENT_COHORT_OPEN = 11,
  VXM_EVENT_RESOURCE_OPEN = 12,
  VXM_EVENT_COHORT = 13,
  VXM_EVENT_RESOURCE = 14,
  VXM_EVENT_DRAFT = 15,
  VXM_EVENT_PREVIEW = 16,
  VXM_EVENT_SYNC = 17,
  VXM_EVENT_SYNC_CLONE_OPEN = 18,
  VXM_MODE_NOTE = 1,
  VXM_MODE_CATALOG = 2,
  VXM_MODE_COHORT_BUILDER = 3,
  VXM_MODE_RESOURCES = 4,
  VXM_MODE_SYNC_CLONE = 5,
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
  // source-rewriting notebook recovery/migrations before core initialization.
  // Explicit-root contexts never restore legacy core sessions; ordinary notebook
  // owners retain core's normal selected-notebook recovery behavior.
  int32_t export_only;
  // Builder/clone-only owned cohorts/<id> or imports/<id>. Native preflight
  // derives workbook/unpacked and isolated runtime paths before context creation.
  // Other modes require null/empty.
  const char *transaction_root;
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

// Copies bounded input and starts an owner thread. The mode-specific OPEN event
// is request1, revision0. Only one host may own a storage root until teardown.
// create_notebook=0 requires an existing notebook except COHORT_BUILDER and
// SYNC_CLONE, whose transaction_root preflight derives private target/runtime roots.
// create_notebook=1 remains catalog-only, with a display name and no expected UUID.
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
// 3 GiB - 128 KiB marker allowance; 64 MiB free-space headroom is separate.
// EXPORT data is <=1024 bytes: {format,bytes,files,directories,archiveLimit}; format
// is "notebook" or "filesAndAssets". Empty content snapshots are valid. Notebook
// identity/name use event metadata. Caller owns any private partial destination and
// must wait for the terminal/close before removing it; publish only on success.
// Never modifies the live tree. Invalid formats do not consume request IDs.
VXM_API int32_t vxm_host_catalog_export(VxmHost *host, uint64_t request_id,
                                       uint64_t generation, int32_t format, const char *destination,
                                       uint64_t staging_budget_bytes);
// Closed JSON <=16 KiB. Cohort: {op:"build"} on COHORT_BUILDER;
// {op:"apply"|"recover",transactionRoot} on normal CATALOG (never export-only).
// Resource: {op:"list"}, {op:"apply"|"recover",transactionRoot}, or
// {op:"export",name,transactionRoot}, admitted on NOTE and RESOURCES only.
// Resource-open is metadata-only: no source read/reload/decryption. List owns
// an 8 MiB reservation; all transfer summaries own 16 KiB until event release.
// Apply/recover drain after dispatch; only build/list/export are cancellable.
VXM_API int32_t vxm_host_cohort(VxmHost *host, uint64_t request_id,
                               uint64_t generation, const char *json);
VXM_API int32_t vxm_host_resource(VxmHost *host, uint64_t request_id,
                                 uint64_t generation, const char *json);
// Draft owner command <=16 KiB, immutable response <=64 KiB. Closed operations:
// {op:"write"|"inspect"|"reconcile",draftsRoot,documentKey,token,candidateId?}.
// token is the source capturing session, NOT the native generation guard.
// Write requires NOTE and a durable prepared candidate; inspect/reconcile also
// accept RESOURCES. Active commands drain; saved success requires a receipt.
VXM_API int32_t vxm_host_draft(VxmHost *host, uint64_t request_id,
                              uint64_t generation, const char *json);
// NOTE-only current source capture. JSON <=16 KiB, source <=4 MiB, response
// <=64 KiB; {op:"prepare",previewRoot,previewId,renderId,sourceRevision}.
// No source token enters this command. No note mutation; join cancellation
// before reclaiming the caller's known previewId/renderId staging namespace.
VXM_API int32_t vxm_host_preview(VxmHost *host, uint64_t request_id,
                                uint64_t generation, const char *json,
                                const uint8_t *source, uint64_t size);
// NOTE/CATALOG owner synchronization, or clone on its private clone owner.
// Closed command <=16 KiB, separate transient credentials <=16 KiB. Every
// admitted phase owns a terminal including actual partial failure data. Network
// runs outside the owner gate; cancellation never depends on queue capacity.
VXM_API int32_t vxm_host_sync(VxmHost *host, uint64_t request_id,
                             uint64_t generation, const char *command_json,
                             const char *credentials_json);
VXM_API int32_t vxm_host_sync_cancel(VxmHost *host, uint64_t generation,
                                    const char *operation_id);
// Desktop integration helper is not compiled/exported by Android or iOS. The
// implementation rejects calls after the first native context in the process.
#if !defined(__ANDROID__) && !defined(VXM_PLATFORM_TLS)
VXM_API int32_t vxm_host_test_enable_sync_fixture(void);
#endif
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
// Managed clone only: inspectClone/prepareClone/finishCloneCredentials add
// operationId. prepareClone seals actual sibling-receipt-proved unpacked bytes;
// finishCloneCredentials requires committed publication and the trusted caller's
// completed vault promotion. Unsettled committed clones refuse generic discard.
// Committed inspectClone returns original pinned receipt without rehashing live edits.
// Clone summaries also expose origin,operationId,cloneComplete,credentialsSettled,
// endpoint,autoSyncEnabled,cloneReceipt. Ordinary imports cannot mint these permits.
// writeMarker: +marker(request|captured|prepared),data -> durable phase.
// checkSpace: +requiredBytes (additional bytes, not headroom) -> {availableBytes};
// no-follow imports+exports+cohorts+resources and moved-attempt charges plus
// requiredBytes <=4GiB; free space includes an additional 64MiB headroom.
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
// Distinct cohort/resource staging schema, same bounded transport and borrowed
// cancellation lifetime. Result is released with vxm_import_result_free.
VXM_API int32_t vxm_transfer_run(const char *request_json, VxmImportCancel *cancel,
                                char **out_json);
// Worker-only durable journal and immutable preview commands. Borrowed cancel
// tokens and result ownership are identical to the import transport. Draft
// payload <=8 MiB (source/checkpoint <=4 MiB); requested source result <=32 MiB,
// summaries <=64 KiB. Preview request <=16 KiB and result <=16 MiB.
VXM_API int32_t vxm_draft_run(const char *request_json, const uint8_t *payload,
                             uint64_t size, VxmImportCancel *cancel, char **out_json);
VXM_API int32_t vxm_preview_run(const char *request_json, VxmImportCancel *cancel,
                               char **out_json);
VXM_API void vxm_import_result_free(char *result);

#ifdef __cplusplus
}
#endif
#endif
