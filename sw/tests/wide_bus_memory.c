// SPDX-License-Identifier: Apache-2.0
#include <stddef.h>
#include <stdint.h>
#include "shared_dma.h"
#include "shared_dma_cva6_wb.h"

static const volatile uint64_t guard = UINT64_C(0x123456789abcdef0);

#define VECTOR_CASE(bits, type) \
static __attribute__((optimize("no-tree-vectorize"))) int vector_##bits(void) { \
    static type source[139] __attribute__((aligned(16))); \
    static volatile type destination[139] __attribute__((aligned(16))); \
    for (unsigned i=0;i<139;i++) { source[i]=(type)(17*i+5); destination[i]=(type)0xa5; } \
    __asm__ volatile("fence iorw,iorw" ::: "memory"); \
    for (size_t i=1;i<138;) { \
        size_t vl; \
        __asm__ volatile("vsetvli %0,%1,e" #bits ",m1,ta,ma\n" \
          "vle" #bits ".v v8,(%2)\n" \
          "vadd.vi v8,v8,3\n" \
          "vse" #bits ".v v8,(%3)" \
          : "=&r"(vl) : "r"((size_t)138-i),"r"(source+i),"r"(destination+i) \
          : "v8","memory"); \
        i+=vl; \
    } \
    __asm__ volatile("fence iorw,iorw" ::: "memory"); \
    if(destination[0]!=(type)0xa5 || destination[138]!=(type)0xa5) return 1; \
    for(unsigned i=1;i<138;i++) if(destination[i]!=(type)(17*i+8)) return 2; \
    return 0; \
}

VECTOR_CASE(8,uint8_t)
VECTOR_CASE(16,uint16_t)
VECTOR_CASE(32,uint32_t)
VECTOR_CASE(64,uint64_t)

static __attribute__((optimize("no-tree-vectorize"))) int vector_stride(void) {
    static uint64_t source[146] __attribute__((aligned(16)));
    static volatile uint64_t destination[146] __attribute__((aligned(16)));
    for(unsigned i=0;i<146;i++) { source[i]=100+i; destination[i]=0xa5; }
    for(size_t i=0;i<73;) {
        size_t vl;
        __asm__ volatile("vsetvli %0,%1,e64,m1,ta,ma\n"
          "vlse64.v v8,(%2),%4\n"
          "vadd.vi v8,v8,3\n"
          "vsse64.v v8,(%3),%4"
          : "=&r"(vl) : "r"((size_t)73-i),"r"(source+2*i),
            "r"(destination+2*i),"r"((uintptr_t)16) : "v8","memory");
        i+=vl;
    }
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    for(unsigned i=0;i<146;i++)
        if(destination[i] != (i&1 ? 0xa5 : 103+i)) return 1;
    return 0;
}

static int atomics(void) {
    volatile uint32_t *spm=(volatile uint32_t *)UINT64_C(0x1000f000);
    for(unsigned lane=0;lane<4;lane++) {
        uintptr_t alias=UINT64_C(0x1400f000)+4*lane;
        uintptr_t old;
        spm[lane]=0x81230000u+lane;
        __asm__ volatile("amoadd.w %0,%1,(%2)" : "=r"(old)
                         : "r"((uintptr_t)3),"r"(alias) : "memory");
        if((uint32_t)old != 0x81230000u+lane || spm[lane] != 0x81230003u+lane) return 1;
    }
    for(unsigned lane=0;lane<2;lane++) {
        volatile uint64_t *word=(volatile uint64_t *)(UINT64_C(0x1000f020)+8*lane);
        uintptr_t old,next,status;
        *word=0x123400+lane;
        __asm__ volatile("lr.d %0,(%3)\naddi %1,%0,1\nsc.d %2,%1,(%4)"
          : "=&r"(old),"=&r"(next),"=&r"(status)
          : "r"(word),"r"((uintptr_t)word+0x04000000) : "memory");
        if(status || old != 0x123400+lane || *word != old+1) return 2;
    }
    return 0;
}

static __attribute__((optimize("no-tree-vectorize"))) int dma_irq(void) {
    const uintptr_t dma=0x01000000;
    volatile uint8_t *source=(volatile uint8_t *)UINT64_C(0x84000ff8);
    volatile uint8_t *destination=(volatile uint8_t *)UINT64_C(0x84003008);
    for(unsigned i=0;i<1024;i++) { source[i]=(uint8_t)(i*13+7); destination[i]=0xa5; }
    *(volatile uint32_t *)UINT64_C(0x040000e8)=1;
    *(volatile uint32_t *)UINT64_C(0x04002004)=1u<<26;
    *(volatile uint32_t *)UINT64_C(0x04200000)=0;
    shared_dma_write(dma,SHDMA_IRQ_ENABLE,1);
    shared_dma_job_t job={.src=(uintptr_t)source,.dst=(uintptr_t)destination,
        .length=257,.reps=2,.src_stride=512,.dst_stride=512};
    uint32_t id;
    if(shared_dma_try_submit(dma,&job,0x80000000,UINT64_C(0x100000000),48,&id)) return 1;
    uint32_t claim=0;
    for(unsigned attempt=0;attempt<200000 && claim==0;attempt++)
        claim=*(volatile uint32_t *)UINT64_C(0x04200004);
    if(claim!=58) return 2;
    if(*(volatile uint32_t *)UINT64_C(0x04200004)!=0) return 3;
    shared_dma_completion_t completion;
    if(!shared_dma_poll(dma,&completion) || completion.job_id!=id || completion.error_code) return 4;
    *(volatile uint32_t *)UINT64_C(0x04200004)=58;
    shared_dma_fence();
    for(unsigned i=0;i<1024;i++) {
        uint8_t expected=i<257 || (i>=512 && i<769) ? (uint8_t)(i*13+7) : 0xa5;
        if(destination[i]!=expected) return 5;
    }
    return 0;
}

int main(void) {
    shared_dma_machine_irq_off();
    shared_dma_cva6_wb_disable(&guard);
    __asm__ volatile("li t0,0x600\ncsrs mstatus,t0" ::: "t0","memory");
    if(vector_8()) return 8;
    if(vector_16()) return 16;
    if(vector_32()) return 32;
    if(vector_64()) return 64;
    if(vector_stride()) return 65;
    if(atomics()) return 66;
    int dma_status=dma_irq();
    return dma_status ? 80+dma_status : 0;
}
