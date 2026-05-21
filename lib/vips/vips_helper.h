#pragma once
#include <stddef.h>

int diffkeep_vips_init(const char *name);
void diffkeep_vips_shutdown(void);
void diffkeep_vips_thread_shutdown(void);

/* Returns 0 on success. On success *buf is a glib-allocated JPEG buffer of
   *len bytes; caller must free it with diffkeep_vips_free(). */
int diffkeep_thumbnail_to_jpeg(
    const char *filename,
    int size,
    void **buf,
    size_t *len
);

void diffkeep_vips_free(void *buf);

/* Load a full-resolution image as a packed RGBA8 buffer.
   Returns 0 on success; *buf is g_malloc-allocated, free with diffkeep_vips_free(). */
int diffkeep_load_image_rgba(
    const char *filename,
    void **buf,
    size_t *len,
    int *width,
    int *height
);

/* Load image, center-crop to square, resize to size×size.
   Returns packed RGB uint8 (HWC, 3 bytes/pixel) of exactly size*size*3 bytes.
   Returns 0 on success; *buf is g_malloc-allocated, free with diffkeep_vips_free(). */
int diffkeep_image_to_rgb_square(
    const char *filename,
    int size,
    void **buf,
    size_t *len
);

/* Decode JPEG bytes to packed RGBA8, scaled to fit within `size` x `size` pixels.
   Returns 0 on success; *buf is g_malloc-allocated, free with diffkeep_vips_free(). */
int diffkeep_jpeg_bytes_to_rgba(
    const void *data,
    size_t data_len,
    int size,
    void **buf,
    size_t *out_len,
    int *out_width,
    int *out_height
);
