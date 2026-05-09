#include "reranker_wrapper.h"
#include "mtmd-helper.h"
#include "llama.h"
#include "mtmd.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

// Bilinear downsample (same as mtmd_wrapper.cpp).
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

// Qwen3 chat template applied manually:
//   <|im_start|>system\n{system}<|im_end|>\n
//   <|im_start|>user\n<Instruct>: {instr}\n<Query>: {query}\n<Document>: {marker}<|im_end|>\n
//   <|im_start|>assistant\n
//
// The image replaces the mtmd marker. We get logits at the last token of the
// assistant prefix, which predicts the first generated token ("yes" or "no").
static const char* SYSTEM_MSG =
    "Judge whether the Document meets the requirements based on the Query and "
    "the Instruct provided. Note that the answer can only be \"yes\" or \"no\".";

extern "C" {

void reranker_wrapper_find_yn_tokens(
    const struct llama_model* model,
    int32_t*                  out_yes_id,
    int32_t*                  out_no_id
) {
    const llama_vocab* vocab = llama_model_get_vocab(model);
    std::vector<llama_token> buf(8);

    auto tok1 = [&](const char* text) -> int32_t {
        int n = llama_tokenize(vocab, text, (int)strlen(text),
                               buf.data(), (int)buf.size(),
                               /*add_special=*/false, /*parse_special=*/false);
        return (n == 1) ? buf[0] : -1;
    };

    *out_yes_id = tok1("yes");
    *out_no_id  = tok1("no");
}

float reranker_wrapper_score_image_file(
    mtmd_context*         mctx,
    struct llama_context* lctx,
    const char*           query,
    const char*           instruction,
    const char*           image_path,
    int32_t               token_yes_id,
    int32_t               token_no_id,
    int32_t               n_batch,
    uint32_t              max_size
) {
    const char* marker = mtmd_default_marker();

    // Build the full prompt string with the media marker in the Document slot.
    char prompt[65536];
    int written = snprintf(prompt, sizeof(prompt),
        "<|im_start|>system\n%s<|im_end|>\n"
        "<|im_start|>user\n"
        "<Instruct>: %s\n"
        "<Query>: %s\n"
        "<Document>: %s<|im_end|>\n"
        "<|im_start|>assistant\n",
        SYSTEM_MSG, instruction, query, marker);
    if (written < 0 || (size_t)written >= sizeof(prompt)) return NAN;

    // Load and optionally resize the image.
    mtmd_bitmap* bitmap = mtmd_helper_bitmap_init_from_file(mctx, image_path);
    if (!bitmap) return NAN;
    bitmap = maybe_resize(bitmap, max_size);
    if (!bitmap) return NAN;

    // Tokenize: parse_special=true to handle <|im_start|>/<|im_end|>;
    // add_special=false because the chat template already includes BOS-equivalent.
    mtmd_input_text text;
    text.text          = prompt;
    text.add_special   = false;
    text.parse_special = true;

    const mtmd_bitmap* bitmaps[1] = { bitmap };
    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    if (!chunks) { mtmd_bitmap_free(bitmap); return NAN; }

    if (mtmd_tokenize(mctx, chunks, &text, bitmaps, 1) != 0) {
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        return NAN;
    }
    mtmd_bitmap_free(bitmap);

    // Clear KV cache for a clean forward pass.
    llama_memory_clear(llama_get_memory(lctx), true);

    // Evaluate all chunks; only the last token needs logits.
    llama_pos new_n_past = 0;
    if (mtmd_helper_eval_chunks(mctx, lctx, chunks, /*n_past=*/0, /*seq_id=*/0,
                                n_batch, /*logits_last=*/true, &new_n_past) != 0) {
        mtmd_input_chunks_free(chunks);
        return NAN;
    }
    mtmd_input_chunks_free(chunks);

    // logits_last=true means llama_get_logits() points at the last token's logits.
    float* logits = llama_get_logits(lctx);
    if (!logits) return NAN;

    return logits[token_yes_id] - logits[token_no_id];
}

} // extern "C"
