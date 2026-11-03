#include "sync_tls.h"

#include <jni.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>

namespace {
constexpr uint64_t kMaxCertificates = 16;
constexpr uint64_t kMaxChainBytes = 1024 * 1024;
constexpr size_t kMaxHostBytes = 253;

// A strong reference pins the defining ClassLoader and its loaded vnote_host.
// This is process-lifetime state, deliberately not Flutter-engine state: old
// contexts and their network workers can outlive an engine detach/re-attach.
JavaVM* g_vm = nullptr;
jobject g_bridge = nullptr;
jclass g_bridge_class = nullptr;
jclass g_byte_array_class = nullptr;
jmethodID g_verify = nullptr;
std::mutex g_registration_mutex;
std::atomic<bool> g_available{false};

bool ClearException(JNIEnv* env) noexcept {
  if (!env->ExceptionCheck()) return false;
  env->ExceptionClear();  // Never emit certificate/host details to logcat.
  return true;
}

class ThreadEnvironment {
 public:
  explicit ThreadEnvironment(JavaVM* vm) noexcept : vm_(vm) {
    const jint state = vm_->GetEnv(reinterpret_cast<void**>(&env_), JNI_VERSION_1_6);
    if (state == JNI_EDETACHED) {
      if (vm_->AttachCurrentThread(&env_, nullptr) == JNI_OK) attached_ = true;
      else env_ = nullptr;
    } else if (state != JNI_OK) {
      env_ = nullptr;
    }
  }
  ~ThreadEnvironment() {
    if (attached_) vm_->DetachCurrentThread();
  }
  JNIEnv* get() const noexcept { return env_; }
 private:
  JavaVM* vm_;
  JNIEnv* env_ = nullptr;
  bool attached_ = false;
};

VxCoreError Verify(const char* host, const uint8_t* const* der,
                   const uint64_t* lengths, uint64_t count, void*) noexcept {
  if (!g_available.load(std::memory_order_acquire) || !host || !der || !lengths ||
      count == 0 || count > kMaxCertificates) return VXCORE_ERR_SYNC_NETWORK;
  const size_t host_size = strnlen(host, kMaxHostBytes + 1);
  if (host_size == 0 || host_size > kMaxHostBytes) return VXCORE_ERR_SYNC_NETWORK;
  // curl supplies its canonical ASCII DNS name (or IP literal), not a URL.
  for (size_t i = 0; i < host_size; ++i) {
    if (static_cast<unsigned char>(host[i]) <= 0x20 ||
        static_cast<unsigned char>(host[i]) >= 0x7f) return VXCORE_ERR_SYNC_NETWORK;
  }
  uint64_t total = 0;
  for (uint64_t i = 0; i < count; ++i) {
    if (!der[i] || lengths[i] == 0 || lengths[i] > kMaxChainBytes - total)
      return VXCORE_ERR_SYNC_NETWORK;
    total += lengths[i];
  }

  ThreadEnvironment thread(g_vm);
  JNIEnv* env = thread.get();
  if (!env) return VXCORE_ERR_SYNC_NETWORK;
  if (env->PushLocalFrame(static_cast<jint>(count + 4)) < 0) {
    ClearException(env);
    return VXCORE_ERR_SYNC_NETWORK;
  }
  VxCoreError result = VXCORE_ERR_SYNC_NETWORK;
  do {
    jstring java_host = env->NewStringUTF(host);
    if (ClearException(env) || !java_host) break;
    jobjectArray chain = env->NewObjectArray(static_cast<jsize>(count), g_byte_array_class, nullptr);
    if (ClearException(env) || !chain) break;
    bool encoded = true;
    for (uint64_t i = 0; i < count; ++i) {
      jbyteArray certificate = env->NewByteArray(static_cast<jsize>(lengths[i]));
      if (ClearException(env) || !certificate) { encoded = false; break; }
      env->SetByteArrayRegion(certificate, 0, static_cast<jsize>(lengths[i]),
                             reinterpret_cast<const jbyte*>(der[i]));
      if (ClearException(env)) { encoded = false; break; }
      env->SetObjectArrayElement(chain, static_cast<jsize>(i), certificate);
      if (ClearException(env)) { encoded = false; break; }
      env->DeleteLocalRef(certificate);
    }
    if (!encoded) break;
    const jboolean trusted = env->CallBooleanMethod(g_bridge, g_verify, java_host, chain);
    if (!ClearException(env) && trusted == JNI_TRUE) result = VXCORE_OK;
  } while (false);
  env->PopLocalFrame(nullptr);
  return result;
}
}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_vnote_1mobile_SyncTlsBridge_nativeRegister(JNIEnv* env, jobject bridge) {
  try {
    std::lock_guard<std::mutex> lock(g_registration_mutex);
    if (g_available.load(std::memory_order_acquire)) return JNI_TRUE;
    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK || !vm) return JNI_FALSE;
    jclass local_class = env->GetObjectClass(bridge);
    if (ClearException(env) || !local_class) return JNI_FALSE;
    jmethodID verify = env->GetMethodID(local_class, "verifyServerChain", "(Ljava/lang/String;[[B)Z");
    if (ClearException(env) || !verify) { env->DeleteLocalRef(local_class); return JNI_FALSE; }
    jclass local_bytes = env->FindClass("[B");
    if (ClearException(env) || !local_bytes) { env->DeleteLocalRef(local_class); return JNI_FALSE; }
    auto clazz = static_cast<jclass>(env->NewGlobalRef(local_class));
    const bool class_failed = ClearException(env) || !clazz;
    auto bytes = class_failed ? nullptr : static_cast<jclass>(env->NewGlobalRef(local_bytes));
    const bool bytes_failed = ClearException(env) || !bytes;
    jobject object = bytes_failed ? nullptr : env->NewGlobalRef(bridge);
    const bool object_failed = ClearException(env) || !object;
    env->DeleteLocalRef(local_class);
    env->DeleteLocalRef(local_bytes);
    if (class_failed || bytes_failed || object_failed) {
      if (clazz) env->DeleteGlobalRef(clazz);
      if (bytes) env->DeleteGlobalRef(bytes);
      if (object) env->DeleteGlobalRef(object);
      return JNI_FALSE;
    }
    g_vm = vm;
    g_bridge_class = clazz;
    g_byte_array_class = bytes;
    g_bridge = object;
    g_verify = verify;
    g_available.store(true, std::memory_order_release);
    return JNI_TRUE;
  } catch (...) {
    ClearException(env);
    return JNI_FALSE;
  }
}

namespace vxm_sync_tls {
bool Available() noexcept { return g_available.load(std::memory_order_acquire); }

VxCoreError Configure(VxCoreContextHandle context) noexcept {
  if (!context) return VXCORE_ERR_INVALID_PARAM;
  if (!Available()) return VXCORE_ERR_UNSUPPORTED;
  return vxcore_sync_set_tls_verifier(context, Verify, nullptr);
}
}  // namespace vxm_sync_tls
