#include <assert.h>
#include "shared_dma.h"
int main(void) {
    uint32_t regs[0x124 / 4] = {0};
    uintptr_t base = (uintptr_t)regs;
    shared_dma_job_t job = {.src=0x80001000,.dst=0x80002000,.length=16,.reps=1};
    uint32_t id = 0xdeadbeef;
    assert(shared_dma_try_submit(base,&job,0x80000000,0x100000000,32,&id)==-1);
    assert(id==0xdeadbeef);
    regs[SHDMA_QUEUE_STATUS/4]=1;
    regs[SHDMA_LAST_JOB_ID/4]=17;
    regs[SHDMA_SUBMIT_STATUS/4]=4;
    assert(shared_dma_try_submit(base,&job,0x80000000,0x100000000,32,&id)==-1);
    assert(id==0xdeadbeef);
    regs[SHDMA_SUBMIT_STATUS/4]=3;
    assert(shared_dma_try_submit(base,&job,0x80000000,0x100000000,32,&id)==-2);
    regs[SHDMA_SUBMIT_STATUS/4]=0;
    assert(shared_dma_try_submit(base,&job,0x80000000,0x100000000,32,&id)==0 && id==17);
    job.src=0x100001000; job.dst=0x100002000;
    assert(shared_dma_try_submit(base,&job,0x100000000,0x200000000,32,&id)==-2);
    assert(shared_dma_try_submit(base,&job,0x100000000,0x200000000,48,&id)==0);
    job.src=UINT64_MAX-1; job.dst=0x80000000; job.length=4;
    assert(shared_dma_try_submit(base,&job,0x80000000,UINT64_MAX,64,&id)==-2);
    job.src=job.dst=0x80000000;
    assert(shared_dma_try_submit(base,&job,0x80000000,0x100000000,32,&id)==-2);
    return 0;
}
