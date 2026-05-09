#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct llama_model;
struct llama_context;

typedef struct mtmd_context mtmd_context;

// Load the vision encoder from an mmproj file.
// Returns NULL on failure.
mtmd_context* mtmd_wrapper_init(
    const char*          mmproj_fname,
    struct llama_model*  text_model,
    int                  n_threads
);

void mtmd_wrapper_free(mtmd_context* ctx);

// Embed an image given a file path and an instruction prefix.
// The prefix is prepended before the image token (pass "" for no prefix).
// out_embd must point to n_embd pre-allocated floats.
// max_size: longest edge is scaled down to this many pixels before encoding
//           (0 = no resize).
// Returns 0 on success.
int mtmd_wrapper_embed_image_file(
    mtmd_context*        mctx,
    struct llama_context* lctx,
    const char*          image_path,
    const char*          prefix,
    float*               out_embd,
    int                  n_embd,
    int                  n_batch,
    uint32_t             max_size
);

// Embed an image from raw RGB bytes (RGBRGB..., length = nx*ny*3).
// max_size: same semantics as above.
int mtmd_wrapper_embed_rgb(
    mtmd_context*        mctx,
    struct llama_context* lctx,
    const unsigned char* rgb,
    uint32_t             nx,
    uint32_t             ny,
    const char*          prefix,
    float*               out_embd,
    int                  n_embd,
    int                  n_batch,
    uint32_t             max_size
);

#ifdef __cplusplus
}
#endif
