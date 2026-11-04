// SPDX-License-Identifier: LGPL-3.0-only
#ifndef VNOTE_MOBILE_SHARE_INBOX_ACTIVATION_H
#define VNOTE_MOBILE_SHARE_INBOX_ACTIVATION_H

#include "vxcore_host.h"

#ifdef __cplusplus
extern "C" {
#endif
// Caller holds the platform inbox ledger process lock and library reservation.
// These filesystem-only calls take the common native admission mutex, never a
// second ledger lock, and never open or mutate a live notebook. Return VxCoreError.
// Activation writes inbox/activation.json only after native zero-byte quota proof.
VXM_API int32_t vxm_share_inbox_activate(const char *support_root, const char *inbox_root);
// claim_json: {id,operationId,target:{notebookId,parentId,notebookRelative,folderName},cohortId?}.
// disposition: "consume" or "discard". Caller retains the ledger lock through
// durable tombstoning, then may use normal private cohort discard for reclamation.
VXM_API int32_t vxm_share_inbox_prove(const char *support_root, const char *claim_json,
                                    const char *disposition);
// App-private outgoing snapshots (also available without an iOS App Group).
// Positive preflight only: caller holds its library reservation through copying.
// All retained outgoing-shares bytes count against the common 3 GiB ledger.
VXM_API int32_t vxm_share_export_check(const char *support_root, uint64_t required_bytes);
#ifdef __cplusplus
}
#endif
#endif
