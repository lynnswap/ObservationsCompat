#include "ObservationBridgePrivateABI.h"

#ifndef __has_attribute
#define __has_attribute(attribute) 0
#endif

#if (defined(__arm64__) || defined(__x86_64__)) && \
    __has_attribute(swiftcall) && __has_attribute(swift_context)
#define OB_HAS_SWIFT_CONTEXT_CALL 1
#else
#define OB_HAS_SWIFT_CONTEXT_CALL 0
#endif

#if OB_HAS_SWIFT_CONTEXT_CALL
typedef void (*OBObservationTrackingCancelFunction)(
    const void *tracking __attribute__((swift_context))
) __attribute__((swiftcall));
#endif

void OBObservationTrackingCancel(void *function, const void *tracking) {
#if OB_HAS_SWIFT_CONTEXT_CALL
    ((OBObservationTrackingCancelFunction)function)(tracking);
#else
    (void)function;
    (void)tracking;
#endif
}
