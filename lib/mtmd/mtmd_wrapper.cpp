#include "mtmd_wrapper.h"
#include "mtmd-helper.h"
#include "llama.h"

#include <algorithm>
#include <cstring>
#include <cstdio>
#include <vector>

// Bilinear downsample. Frees src and returns a new bitmap (or returns src unchanged).
static mtmd_bitmap* maybe_resize(mtmd_bitmap* bitmap, uint32_t max_size) {
    if (max_size == 0) return bitmap;

    const uint32_t nx = mtmd_bitmap_get_nx(bitmap);
    const uint32_t ny = mtmd_bitmap_get_ny(bitmap);
    if (nx <= max_size && ny <= max_size) return bitmap;

    const float scale = (float)max_size / (float)std::max(nx, ny);
    const uint32_t new_nx = std::max(1u, (uint32_t)(nx * scale + 0.5f));
    const uint32_t new_ny = std::max(1u, (uint32_t)(ny * scale + 0.5f));

    const unsigned char* src = mtmd_bitmap_get_data(bitmap);
    std::vector<unsigned char> dst(new_nx * new_ny * 3);

    for (uint32_t y = 0; y < new_ny; y++) {
        for (uint32_t x = 0; x < new_nx; x++) {
            const float fx = (x + 0.5f) / new_nx * nx - 0.5f;
            const float fy = (y + 0.5f) / new_ny * ny - 0.5f;
            const int x0 = std::max(0, (int)fx);
            const int y0 = std::max(0, (int)fy);
            const int x1 = std::min((int)nx - 1, x0 + 1);
            const int y1 = std::min((int)ny - 1, y0 + 1);
            const float wx = fx - x0;
            const float wy = fy - y0;
            for (int c = 0; c < 3; c++) {
                const float v = src[(y0 * nx + x0) * 3 + c] * (1-wx) * (1-wy)
                              + src[(y0 * nx + x1) * 3 + c] * wx     * (1-wy)
                              + src[(y1 * nx + x0) * 3 + c] * (1-wx) * wy
                              + src[(y1 * nx + x1) * 3 + c] * wx     * wy;
                dst[(y * new_nx + x) * 3 + c] = (unsigned char)(v + 0.5f);
            }
        }
    }

    mtmd_bitmap_free(bitmap);
    return mtmd_bitmap_init(new_nx, new_ny, dst.data());
}

static int do_embed(
    mtmd_context*  mctx,
    llama_context* lctx,
    mtmd_bitmap*   bitmap,     // ownership taken; freed here
    const char*    prefix,
    float*         out_embd,
    int            n_embd,
    int            n_batch
) {
    const char* marker = mtmd_default_marker();
    char prompt[4096];
    snprintf(prompt, sizeof(prompt), "%s%s", prefix, marker);

    mtmd_input_text text;
    text.text          = prompt;
    text.add_special   = true;
    text.parse_special = true;

    const mtmd_bitmap* bitmaps[1] = { bitmap };
    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    if (!chunks) {
        mtmd_bitmap_free(bitmap);
        return 1;
    }

    if (mtmd_tokenize(mctx, chunks, &text, bitmaps, 1) != 0) {
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        return 2;
    }
    mtmd_bitmap_free(bitmap);

    llama_pos new_n_past = 0;
    // Caller is responsible for clearing the KV cache before this call.
    if (mtmd_helper_eval_chunks(mctx, lctx, chunks, 0, 0, n_batch, false, &new_n_past) != 0) {
        mtmd_input_chunks_free(chunks);
        return 3;
    }
    mtmd_input_chunks_free(chunks);

    float* embd = llama_get_embeddings_seq(lctx, 0);
    if (!embd)
        embd = llama_get_embeddings(lctx);
    if (!embd)
        return 4;

    std::memcpy(out_embd, embd, (size_t)n_embd * sizeof(float));
    return 0;
}

extern "C" {

mtmd_context* mtmd_wrapper_init(
    const char*         mmproj_fname,
    struct llama_model* text_model,
    int                 n_threads
) {
    struct mtmd_context_params p = mtmd_context_params_default();
    p.use_gpu       = true;
    p.print_timings = false;
    p.n_threads     = n_threads;
    p.warmup        = false;
    return mtmd_init_from_file(mmproj_fname, text_model, p);
}

void mtmd_wrapper_free(mtmd_context* ctx) {
    mtmd_free(ctx);
}

int mtmd_wrapper_embed_image_file(
    mtmd_context*         mctx,
    struct llama_context* lctx,
    const char*           image_path,
    const char*           prefix,
    float*                out_embd,
    int                   n_embd,
    int                   n_batch,
    uint32_t              max_size
) {
    mtmd_bitmap* bitmap = mtmd_helper_bitmap_init_from_file(mctx, image_path);
    if (!bitmap)
        return 1;
    bitmap = maybe_resize(bitmap, max_size);
    if (!bitmap)
        return 1;
    return do_embed(mctx, lctx, bitmap, prefix, out_embd, n_embd, n_batch);
}

int mtmd_wrapper_embed_rgb(
    mtmd_context*         mctx,
    struct llama_context* lctx,
    const unsigned char*  rgb,
    uint32_t              nx,
    uint32_t              ny,
    const char*           prefix,
    float*                out_embd,
    int                   n_embd,
    int                   n_batch,
    uint32_t              max_size
) {
    mtmd_bitmap* bitmap = mtmd_bitmap_init(nx, ny, rgb);
    if (!bitmap)
        return 1;
    bitmap = maybe_resize(bitmap, max_size);
    if (!bitmap)
        return 1;
    return do_embed(mctx, lctx, bitmap, prefix, out_embd, n_embd, n_batch);
}

} // extern "C"
