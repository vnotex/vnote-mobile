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

enum {
  VXM_EVENT_OPEN = 1,
  VXM_EVENT_READ = 2,
  VXM_EVENT_WRITE = 3,
  VXM_EVENT_CLOSED = 4,
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
  const char *note_path;
  const uint8_t *initial_data;
  uint64_t initial_size;
} VxmOpenOptions;

// Immutable terminal event. Pointers are borrowed until vxm_event_free(), which
// is required exactly once even for errors. Taken events may outlive their host.
// No borrowed core handles, JSON, or unredacted last-error strings cross this ABI.
typedef struct VxmEvent {
  uint64_t request_id;
  uint64_t generation;
  uint64_t revision;
  int32_t kind;
  int32_t code;
  int32_t line_ending;
  const char *message;
  const char *notebook_id;
  const char *node_id;
  const char *base_hash;
  const char *core_version;
  const uint8_t *data;
  uint64_t size;
} VxmEvent;

// Copies bounded input and starts an owner thread. OPEN is request 1, revision 0.
// Create a bundled notebook/first note only when notebook_path is absent. An
// existing malformed notebook or missing indexed note is an error, never repair.
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
// Request IDs strictly increase per host. Rejected IDs do not consume a number.
// Cancel only affects pending requests; an active operation returns its real
// outcome. INVALID_STATE means no pending matching request (not false cancel).
VXM_API int32_t vxm_host_cancel(VxmHost *host, uint64_t request_id, uint64_t generation);
// Idempotent; stops admission, cancels pending work, finishes active work, then
// emits the separately reserved CLOSED terminal (request 0) after owner teardown.
VXM_API void vxm_host_request_close(VxmHost *host);
VXM_API VxmEvent *vxm_host_take_event(VxmHost *host);
VXM_API void vxm_event_free(VxmEvent *event);
// Joins; never call on a UI isolate or from notify. No concurrent host access is
// permitted during destroy. Undelivered events are freed; taken events survive.
VXM_API void vxm_host_destroy(VxmHost *host);
// Borrowed process-lifetime UTF-8 text generated from actual dependency licenses.
VXM_API const char *vxm_native_notices(void);

#ifdef __cplusplus
}
#endif
#endif
