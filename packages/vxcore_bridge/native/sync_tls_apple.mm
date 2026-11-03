#include "sync_tls.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <cstdint>
#include <cstring>

namespace {
constexpr uint64_t kMaxCertificates = 16;
constexpr uint64_t kMaxChainBytes = 1024 * 1024;
constexpr size_t kMaxHostBytes = 253;

template <typename T>
class OwnedCF {
 public:
  explicit OwnedCF(T value = nullptr) noexcept : value_(value) {}
  ~OwnedCF() { if (value_) CFRelease(value_); }
  OwnedCF(const OwnedCF&) = delete;
  OwnedCF& operator=(const OwnedCF&) = delete;
  T get() const noexcept { return value_; }
 private:
  T value_;
};

VxCoreError Verify(const char* host, const uint8_t* const* der,
                   const uint64_t* lengths, uint64_t count, void*) noexcept {
  if (!host || !der || !lengths ||
      count == 0 || count > kMaxCertificates || [NSThread isMainThread])
    return VXCORE_ERR_SYNC_NETWORK;
  const size_t host_size = strnlen(host, kMaxHostBytes + 1);
  if (host_size == 0 || host_size > kMaxHostBytes) return VXCORE_ERR_SYNC_NETWORK;
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
  @autoreleasepool {
    @try {
      OwnedCF<CFStringRef> hostname(CFStringCreateWithBytes(
          kCFAllocatorDefault, reinterpret_cast<const UInt8*>(host),
          static_cast<CFIndex>(host_size), kCFStringEncodingASCII, false));
      if (!hostname.get()) return VXCORE_ERR_SYNC_NETWORK;
      OwnedCF<SecPolicyRef> policy(SecPolicyCreateSSL(true, hostname.get()));
      OwnedCF<CFMutableArrayRef> certificates(CFArrayCreateMutable(
          kCFAllocatorDefault, static_cast<CFIndex>(count), &kCFTypeArrayCallBacks));
      if (!policy.get() || !certificates.get()) return VXCORE_ERR_SYNC_NETWORK;
      for (uint64_t i = 0; i < count; ++i) {
        // The DER belongs to the core callback and remains live through evaluation.
        OwnedCF<CFDataRef> data(CFDataCreateWithBytesNoCopy(
            kCFAllocatorDefault, der[i], static_cast<CFIndex>(lengths[i]), kCFAllocatorNull));
        if (!data.get()) return VXCORE_ERR_SYNC_NETWORK;
        OwnedCF<SecCertificateRef> certificate(SecCertificateCreateWithData(kCFAllocatorDefault, data.get()));
        if (!certificate.get()) return VXCORE_ERR_SYNC_NETWORK;
        CFArrayAppendValue(certificates.get(), certificate.get());
      }
      SecTrustRef raw_trust = nullptr;
      const OSStatus created = SecTrustCreateWithCertificates(certificates.get(), policy.get(), &raw_trust);
      OwnedCF<SecTrustRef> trust(raw_trust);
      if (created != errSecSuccess || !trust.get()) return VXCORE_ERR_SYNC_NETWORK;
      // AIA/OCSP fetches must not escape the core's cancellation/network budget.
      if (SecTrustSetNetworkFetchAllowed(trust.get(), false) != errSecSuccess)
        return VXCORE_ERR_SYNC_NETWORK;
      if (@available(iOS 12.0, *)) {
        CFErrorRef raw_error = nullptr;
        const bool trusted = SecTrustEvaluateWithError(trust.get(), &raw_error);
        OwnedCF<CFErrorRef> error(raw_error);
        return trusted ? VXCORE_OK : VXCORE_ERR_SYNC_NETWORK;
      }
      return VXCORE_ERR_UNSUPPORTED;
    } @catch (NSException* exception) {
      (void)exception;
      return VXCORE_ERR_SYNC_NETWORK;
    }
  }
}
}  // namespace

namespace vxm_sync_tls {
bool Available() noexcept {
  if (@available(iOS 12.0, *)) {
    OwnedCF<SecPolicyRef> policy(SecPolicyCreateSSL(true, nullptr));
    return policy.get() != nullptr;
  }
  return false;
}

VxCoreError Configure(VxCoreContextHandle context) noexcept {
  if (!context) return VXCORE_ERR_INVALID_PARAM;
  if (!Available()) return VXCORE_ERR_UNSUPPORTED;
  return vxcore_sync_set_tls_verifier(context, Verify, nullptr);
}
}  // namespace vxm_sync_tls
