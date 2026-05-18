.text
.globl _OBObservationTrackingCancel

#if defined(__arm64__)

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

#elif defined(__x86_64__)

.p2align 4, 0x90
_OBObservationTrackingCancel:
    pushq %rbp
    movq %rsp, %rbp
    pushq %r13
    subq $8, %rsp
    movq %rsi, %r13
    callq *%rdi
    addq $8, %rsp
    popq %r13
    popq %rbp
    retq

#else

.p2align 2
_OBObservationTrackingCancel:
    ret

#endif
