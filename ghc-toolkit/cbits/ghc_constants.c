#include <Rts.h>
#include <Capability.h>

HsInt sizeof_bdescr() { return sizeof(bdescr); }

HsInt offset_bdescr_start() { return offsetof(bdescr, start); }

HsInt offset_bdescr_free() { return offsetof(bdescr, free); }

HsInt offset_bdescr_flags() { return offsetof(bdescr, flags); }

HsInt offset_bdescr_blocks() { return offsetof(bdescr, blocks); }

HsInt sizeof_Capability() { return sizeof(Capability); }

HsInt offset_Capability_r() { return offsetof(Capability, r); }

HsInt sizeof_StgInd() { return sizeof(StgInd); }

HsInt offset_StgInd_indirectee() { return offsetof(StgInd, indirectee); }

HsInt sizeof_StgRegTable() { return sizeof(StgRegTable); }

HsInt offset_StgRegTable_rCurrentTSO() {
  return offsetof(StgRegTable, rCurrentTSO);
}

HsInt offset_StgRegTable_rCurrentNursery() {
  return offsetof(StgRegTable, rCurrentNursery);
}

HsInt offset_StgRegTable_rRet() { return offsetof(StgRegTable, rRet); }

HsInt sizeof_StgStack() { return sizeof(StgStack); }

HsInt offset_StgStack_stack_size() { return offsetof(StgStack, stack_size); }

HsInt offset_StgStack_sp() { return offsetof(StgStack, sp); }

HsInt offset_StgStack_stack() { return offsetof(StgStack, stack); }

HsInt sizeof_StgTSO() { return sizeof(StgTSO); }

HsInt offset_StgTSO_stackobj() { return offsetof(StgTSO, stackobj); }

HsInt offset_StgTSO_alloc_limit() { return offsetof(StgTSO, alloc_limit); }