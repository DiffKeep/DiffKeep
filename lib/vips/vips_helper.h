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

/* Number of pages/frames in an image (e.g. animated GIF/WebP). Returns the page
   count (>= 1), or -1 if the image can't be opened. */
int diffkeep_image_n_pages(const char *filename);

/* Encode a packed RGBA8 buffer (width*height*4) to a JPEG, downscaled to fit
   max_size on the long edge. Returns 0 on success; *buf is glib-allocated
   (free with diffkeep_vips_free). Used for video poster-frame thumbnails. */
int diffkeep_rgba_to_jpeg(
    const void *rgba,
    int width,
    int height,
    int max_size,
    void **buf,
    size_t *len
);

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

/* ── Animated-image (GIF / animated WebP) decoder ─────────────────────────────
   libav* only decodes the first frame of animated WebP, so animated images are
   played through vips instead (which composites every page correctly). This is
   a stateful, forward-only session: pages are emitted 0,1,2,… ; seeking backward
   (or looping) reopens the underlying image. Not thread-safe; use from one
   thread. */
typedef struct DiffkeepAnimDecoder DiffkeepAnimDecoder;

/* Open an animated image. Returns NULL if the file can't be opened or has <= 1
   page (i.e. is not actually animated). If max_dim > 0, decoded frames are
   downscaled to fit max_dim on the long edge (for the grid); 0 = native size. */
DiffkeepAnimDecoder *diffkeep_anim_open(const char *filename, int max_dim);
void diffkeep_anim_close(DiffkeepAnimDecoder *d);

int  diffkeep_anim_frame_count(const DiffkeepAnimDecoder *d);
/* Total playback duration (sum of per-frame delays), milliseconds. */
long diffkeep_anim_duration_ms(const DiffkeepAnimDecoder *d);
/* Representative frame rate (frames / total duration). Animated images may use
   variable per-frame delays; this is the average. */
double diffkeep_anim_fps(const DiffkeepAnimDecoder *d);

/* Decode the next page to packed RGBA8. Returns 1 and fills *buf (glib-allocated,
   free with diffkeep_vips_free), *w, *h, *pts_ms (presentation time of this
   frame). Returns 0 at end-of-stream, -1 on error. */
int diffkeep_anim_next(DiffkeepAnimDecoder *d, void **buf, int *w, int *h, long *pts_ms);

/* Reposition so the next diffkeep_anim_next() returns the page at/before ts_ms.
   Seeking backward reopens the image (forward-only decode). */
int diffkeep_anim_seek(DiffkeepAnimDecoder *d, long ts_ms);
