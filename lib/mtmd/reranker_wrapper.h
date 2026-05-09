#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct llama_model;
struct llama_context;
typedef struct mtmd_context mtmd_context;

// Find the token IDs for "yes" and "no" in the model vocabulary.
// Stores -1 in each output if the token is not found as a single token.
void reranker_wrapper_find_yn_tokens(
    const struct llama_model* model,
    int32_t*                  out_yes_id,
    int32_t*                  out_no_id
);

// Score a (query, image) pair using the reranker cross-encoder.
// lctx must be a GENERATION context (embeddings=false).
// Returns logit["yes"] - logit["no"] at the last prompt position.
// Higher score = more relevant. Returns NAN on error.
float reranker_wrapper_score_image_file(
    mtmd_context*              mctx,
    struct llama_context*      lctx,
    const char*                query,
    const char*                instruction,
    const char*                image_path,
    int32_t                    token_yes_id,
    int32_t                    token_no_id,
    int32_t                    n_batch,
    uint32_t                   max_size
);

#ifdef __cplusplus
}
#endif
