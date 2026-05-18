#if defined(__arm64__)

.text
.globl _OBObservationTrackingCancel
.p2align 2
_OBObservationTrackingCancel:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    str x20, [sp, #-16]!
    mov x20, x1
    blr x0
    ldr x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

#else

.text
.globl _OBObservationTrackingCancel
.p2align 2
_OBObservationTrackingCancel:
    ret

#endif
