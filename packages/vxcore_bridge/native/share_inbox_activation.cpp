// SPDX-License-Identifier: LGPL-3.0-only
#include "share_inbox_activation.h"
#include "notebook_import.h"

extern "C" {
int32_t vxm_share_inbox_activate(const char *support_root, const char *inbox_root) {
  return vxm_import::ActivateInbox(support_root, inbox_root);
}
int32_t vxm_share_inbox_prove(const char *support_root, const char *claim_json, const char *disposition) {
  return vxm_import::ProveInbox(support_root, claim_json, disposition);
}
int32_t vxm_share_export_check(const char *support_root, uint64_t required_bytes) {
  return vxm_import::CheckShareExport(support_root, required_bytes);
}
}

#if defined(__ANDROID__)
#include <jni.h>
#include <new>
#include <string>

namespace {
// JNI modified UTF-8 is not filesystem/JSON UTF-8. Preserve supplementary names
// exactly and reject unpaired surrogates instead of changing the immutable claim.
std::string utf8(JNIEnv *env, jstring input) {
  if (!input) throw vxm_import::StorageFailure{VXCORE_ERR_NULL_POINTER};
  const auto length = env->GetStringLength(input);
  if (length <= 0 || length > 16384) throw vxm_import::StorageFailure{VXCORE_ERR_INVALID_PARAM};
  const jchar *chars = env->GetStringChars(input, nullptr);
  if (!chars) throw std::bad_alloc();
  struct Release {
    JNIEnv *env; jstring input; const jchar *chars;
    ~Release() { env->ReleaseStringChars(input, chars); }
  } release{env, input, chars};
  std::string result;
  result.reserve(static_cast<size_t>(length));
  for (jsize i = 0; i < length; ++i) {
    uint32_t cp = chars[i];
    if (cp >= 0xd800 && cp <= 0xdbff) {
      if (++i >= length || chars[i] < 0xdc00 || chars[i] > 0xdfff)
        throw vxm_import::StorageFailure{VXCORE_ERR_INVALID_PARAM};
      cp = 0x10000 + ((cp - 0xd800) << 10) + chars[i] - 0xdc00;
    } else if (cp == 0 || (cp >= 0xdc00 && cp <= 0xdfff)) {
      throw vxm_import::StorageFailure{VXCORE_ERR_INVALID_PARAM};
    }
    if (cp < 0x80) result.push_back(static_cast<char>(cp));
    else if (cp < 0x800) {
      result.push_back(static_cast<char>(0xc0 | (cp >> 6)));
      result.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    } else if (cp < 0x10000) {
      result.push_back(static_cast<char>(0xe0 | (cp >> 12)));
      result.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
      result.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    } else {
      result.push_back(static_cast<char>(0xf0 | (cp >> 18)));
      result.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
      result.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
      result.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    }
    if (result.size() > 16384) throw vxm_import::StorageFailure{VXCORE_ERR_INVALID_PARAM};
  }
  return result;
}
int32_t error(JNIEnv *env) noexcept {
  // Map JNI allocation failure to the same stable native status; no private logs.
  if (env->ExceptionCheck()) env->ExceptionClear();
  return vxm_import::storage::ErrorCode();
}
}
extern "C" JNIEXPORT jint JNICALL
Java_com_example_vnote_1mobile_ShareInboxPlugin_nativeActivate(JNIEnv *env, jclass, jstring support, jstring inbox) {
  try {
    const auto root = utf8(env, support), path = utf8(env, inbox);
    return vxm_share_inbox_activate(root.c_str(), path.c_str());
  } catch (...) { return error(env); }
}
extern "C" JNIEXPORT jint JNICALL
Java_com_example_vnote_1mobile_ShareInboxPlugin_nativeProve(JNIEnv *env, jclass, jstring support, jstring claim, jstring disposition) {
  try {
    const auto root = utf8(env, support), value = utf8(env, claim), action = utf8(env, disposition);
    return vxm_share_inbox_prove(root.c_str(), value.c_str(), action.c_str());
  } catch (...) { return error(env); }
}
extern "C" JNIEXPORT jint JNICALL
Java_com_example_vnote_1mobile_ShareInboxPlugin_nativeCheckExport(JNIEnv *env, jclass, jstring support, jlong required_bytes) {
  try {
    if (required_bytes <= 0) return VXCORE_ERR_INVALID_PARAM;
    const auto root = utf8(env, support);
    return vxm_share_export_check(root.c_str(), static_cast<uint64_t>(required_bytes));
  } catch (...) { return error(env); }
}
#endif
