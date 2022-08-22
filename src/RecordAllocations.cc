#include <sstream>
#include <memory>
#include <map>

#if !TFLMC_USE_INTERPRETER_HOOKS
#define private public
#endif
#include "tensorflow/lite/micro/micro_interpreter.h"
#if !TFLMC_USE_INTERPRETER_HOOKS
#undef private
#endif

#include "CustomOperators.h"
#include "RecordAllocations.h"
#include "MemMap.h"
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"

static std::vector<tflmc::Allocation> g_loggedAllocations;
static std::vector<uint8_t>   g_nodeScratchBufferAllocations;
static size_t g_currentNodeIndex = -1;
static uint8_t *g_arenaPtr = nullptr;

static ptrdiff_t g_arena_size = 0;


struct ScratchBufferInfo {
    	size_t node_id;
      size_t bytes;
};

static std::map<int, ScratchBufferInfo> g_logged_scratch_buffers;



#if TFLMC_USE_INTERPRETER_HOOKS


static  tflite::MicroInterpreter::TfLiteContextHooks *g_tflm_hooks;


static void *LoggingAllocatePersistentBuffer(struct TfLiteContext *ctx, size_t bytes) {
  auto ptr =  g_tflm_hooks->AllocatePersistentBuffer(ctx, bytes);
  assert(ptr != nullptr && "Alloc failure");
  ptrdiff_t offset = (uint8_t *)ptr - g_arenaPtr;

  g_loggedAllocations.push_back(
      {offset, bytes,
       g_currentNodeIndex, tflmc::AllocKind::Persistent, 0});
  return ptr;
}


static TfLiteStatus LoggingRequestScratchBufferInArena(TfLiteContext *ctx,
                                                       size_t bytes,
                                                       int *buffer_idx) {

  auto res = g_tflm_hooks->RequestScratchBufferInArena(ctx, bytes,  buffer_idx);
  if (res == kTfLiteOk) {
    g_logged_scratch_buffers[*buffer_idx] = {g_currentNodeIndex, bytes};
  }
  return res;                                         
}



static void* LoggingGetScratchBuffer(struct TfLiteContext* ctx, int buffer_idx) {
  return g_tflm_hooks->GetScratchBuffer (ctx, buffer_idx);
}

static void LoggingNotifyNodeIndex(const struct TfLiteContext* context,
                                size_t node) {
  g_currentNodeIndex = node;
  return g_tflm_hooks->NotifyNodeIndex(context, node);
}

static  tflite::MicroInterpreter::TfLiteContextHooks g_recording_hooks =
{
  LoggingAllocatePersistentBuffer,
  LoggingRequestScratchBufferInArena,
  LoggingGetScratchBuffer,
  LoggingNotifyNodeIndex
  
};

void tflmc::SetRecordAllocationhooks( tflite::MicroInterpreter *interpreter, 
                              uint8_t *arena_start,
                              size_t arena_size) {
  g_tflm_hooks = interpreter->getHooks();
  g_arenaPtr = arena_start;
  g_arena_size = arena_size;
  interpreter->setHooks(&g_recording_hooks);
}

void  tflmc::RecordScratchBufferAllocations(tflite::MicroInterpreter *interpreter)
{
  auto ctx = interpreter->getTFLContext();
  for( auto &sb_i : g_logged_scratch_buffers )
  {
      auto sb_idx = sb_i.first;
      void *sb_start = g_tflm_hooks->GetScratchBuffer(ctx, sb_idx );
      assert(sb_start != nullptr && "Unknown Scratch Buffer");
      ptrdiff_t offset = (uint8_t *)sb_start - g_arenaPtr;
      g_loggedAllocations.push_back(
        {offset, sb_i.second.bytes,
         sb_i.second.node_id, tflmc::AllocKind::Scratch, sb_i.first});

      size_t node_id = sb_i.second.node_id;
      if (g_nodeScratchBufferAllocations.size() <= node_id) {
        g_nodeScratchBufferAllocations.resize(node_id+1, 0);
      }
      g_nodeScratchBufferAllocations[node_id] += 1;
  }

}



TfLiteEvalTensor *tflmc::GetEvalTensor(tflite::MicroInterpreter *interpreter, int i) {
  auto ctx = interpreter->getTFLContext();
  return ctx->GetEvalTensor(ctx, i);
}

TfLiteTensor *tflmc::GetTensor(tflite::MicroInterpreter *interpreter, int i) {
  auto ctx = interpreter->getTFLContext();
  return ctx->GetTensor(ctx, i);
}

#else

static tflite::MicroAllocator *g_allocator;
static void *LoggingAllocatePersistentBuffer(struct TfLiteContext *ctx,
                                                    size_t bytes) {
  auto ptr = g_allocator->AllocatePersistentBuffer(bytes);
  assert(ptr != nullptr && "Alloc failure");
  ptrdiff_t offset = (uint8_t *)ptr - g_arenaPtr;

  g_loggedAllocations.push_back(
      {offset, bytes,
       g_currentNodeIndex, tflmc::AllocKind::Persistent, -1});
  return ptr;
}

static TfLiteStatus LoggingRequestScratchBufferInArena(TfLiteContext *ctx,
                                                       size_t bytes,
                                                       int *buffer_idx) {
  assert(false && "Not handling scratch buffers currently");
  return g_allocator->RequestScratchBufferInArena(bytes,
                                                  buffer_idx);
}


  // HACK: here in essence, we create a duplicate interpreter here and re-execute
  // Fragmnents of MicroInterpreter::AllocateTensors() with instrumented context
  // API calls.  

void tflmc::RecordAllocations(
    const tflite::Model *model, 
     size_t arena_size,  size_t arena_alignment) {

  tflmc::SufficientArena arena(arena_size, arena_alignment);
  g_arenaPtr = arena.alginedBufferStart();
  g_arena_size = arena_size;

  tflite::MicroErrorReporter error_reporter;

  // Resolver must be passed in  as otherwise pointers to its internal table
  // in the arena will be invalidated....

  
  tflite::AllOpsResolver resolver;
  tflmc::custom_operator_handle custom = tflmc::LoadCustom(&resolver);
  tflite::MicroInterpreter interpreter(model, resolver, g_arenaPtr,
                                       g_arena_size, &error_reporter);

  auto ctx = &interpreter.context_;
  auto allocator = &interpreter.allocator_;

  tflite::NodeAndRegistration *nodeAndRegs;
  TfLiteEvalTensor *eval_tensors=nullptr;
  tflite::ScratchBufferHandle* scratchhandle=nullptr;

  allocator->StartModelAllocation(model, resolver, &nodeAndRegs, &eval_tensors);
  allocator->FinishModelAllocation(model, eval_tensors, &scratchhandle);

  g_allocator = allocator;
  ctx->AllocatePersistentBuffer = &LoggingAllocatePersistentBuffer;
  ctx->RequestScratchBufferInArena = nullptr;
  auto ctx_GetScratchBuffer =  ctx->GetScratchBuffer;
  ctx->GetScratchBuffer = nullptr;


  auto subgraph = model->subgraphs()->Get(0);
  for (size_t i = 0; i < subgraph->operators()->size(); i++) {
    auto node = &nodeAndRegs[i].node;
    auto reg = nodeAndRegs[i].registration;
    if (reg->init) {
      g_currentNodeIndex = i;
      node->user_data = reg->init(ctx, (const char *)node->builtin_data, 0);
    }
  }


  ctx->RequestScratchBufferInArena = &LoggingRequestScratchBufferInArena;

  for (size_t i = 0; i < subgraph->operators()->size(); i++) {
    auto node = &nodeAndRegs[i].node;
    auto reg = nodeAndRegs[i].registration;
    if (reg->prepare) {
      g_currentNodeIndex = i;
      reg->prepare(ctx, node);
    }
    allocator->ResetTempAllocations();
  }
  
  allocator->FinishModelAllocation(model, eval_tensors);

  tflmc::UnloadCustom(custom);
  for( auto &sb_i : g_logged_scratch_buffers )
  {
      auto sb_idx = sb_i.first;
      void *sb_start = ctx_GetScratchBuffer( ctx, sb_idx );
      assert(sb_start != nullptr && "Unknown Scratch Buffer");
      ptrdiff_t offset = (uint8_t *)sb_start - g_arenaPtr;
      g_loggedAllocations.push_back(
        {offset, sb_i.second.bytes,
         sb_i.second.node_id, tflmc::AllocKind::Scratch, -1});
  }

}


TfLiteEvalTensor *tflmc::GetEvalTensor(tflite::MicroInterpreter *interpreter, int i) {
  auto ctx = &interpreter->context_;
  return ctx->GetEvalTensor(ctx, i);
}

TfLiteTensor *tflmc::GetTensor(tflite::MicroInterpreter *interpreter, int i) {
  auto ctx = &interpreter->context_;
  return ctx->GetTensor(ctx, i);
}

#endif

const std::vector<tflmc::Allocation> &tflmc::RecordedAllocations() { 
  return g_loggedAllocations; 
}
