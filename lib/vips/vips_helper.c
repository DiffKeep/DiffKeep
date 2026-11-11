#include "vips_helper.h"
#include <vips/vips.h>

/* Convert *img in place to 4-band sRGB uchar (RGBA8), the layout every caller
   indexes as w*h*4. vips keeps greyscale as 1 band (2 with alpha) and 16-bit
   sources as ushort, so colourspace/cast before adding alpha. On failure *img
   is unreffed and set to NULL. */
static int to_rgba8(VipsImage **img) {
    VipsImage *t = NULL;
    if (vips_image_get_bands(*img) < 3 ||
        vips_image_guess_interpretation(*img) != VIPS_INTERPRETATION_sRGB) {
        if (vips_colourspace(*img, &t, VIPS_INTERPRETATION_sRGB, NULL) != 0) goto fail;
        g_object_unref(*img);
        *img = t;
    }
    if (vips_image_get_format(*img) != VIPS_FORMAT_UCHAR) {
        if (vips_cast(*img, &t, VIPS_FORMAT_UCHAR, NULL) != 0) goto fail;
        g_object_unref(*img);
        *img = t;
    }
    if (!vips_image_hasalpha(*img)) {
        if (vips_addalpha(*img, &t, NULL) != 0) goto fail;
        g_object_unref(*img);
        *img = t;
    }
    if (vips_image_get_bands(*img) != 4) goto fail;
    return 0;
fail:
    g_object_unref(*img);
    *img = NULL;
    return -1;
}

int diffkeep_vips_init(const char *name) {
    int rc = vips_init(name);
    if (rc == 0) {
        /* Bound vips's operation cache. We only generate one-shot thumbnails, so
         * caching prior operations buys nothing but costs memory. The defaults
         * (1000 ops / ~100MB / 100 open files) are far more than we need. */
        vips_cache_set_max(0);
        vips_cache_set_max_mem(0);
        vips_cache_set_max_files(0);
    }
    return rc;
}

void diffkeep_vips_shutdown(void) {
    vips_shutdown();
}

void diffkeep_vips_thread_shutdown(void) {
    vips_thread_shutdown();
}

int diffkeep_thumbnail_to_jpeg(
    const char *filename,
    int size,
    void **buf,
    size_t *len
) {
    VipsImage *thumb = NULL;

    if (vips_thumbnail(filename, &thumb, size,
            "height", size,
            "size", VIPS_SIZE_DOWN,
            NULL) != 0) {
        return -1;
    }

    /* Flatten alpha before JPEG encoding */
    if (vips_image_hasalpha(thumb)) {
        VipsImage *flat = NULL;
        if (vips_flatten(thumb, &flat, NULL) != 0) {
            g_object_unref(thumb);
            return -1;
        }
        g_object_unref(thumb);
        thumb = flat;
    }

    if (vips_image_write_to_buffer(thumb, ".jpg[Q=85,strip]", buf, len, NULL) != 0) {
        g_object_unref(thumb);
        return -1;
    }

    g_object_unref(thumb);
    return 0;
}

void diffkeep_vips_free(void *buf) {
    g_free(buf);
}

int diffkeep_image_n_pages(const char *filename) {
    VipsImage *im = vips_image_new_from_file(filename, NULL);
    if (!im) return -1;
    int n = 1;
    if (vips_image_get_typeof(im, "n-pages") != 0)
        vips_image_get_int(im, "n-pages", &n);
    g_object_unref(im);
    return n;
}

int diffkeep_rgba_to_jpeg(
    const void *rgba,
    int width,
    int height,
    int max_size,
    void **buf,
    size_t *len
) {
    /* Copy the pixels into a vips image (so the caller's buffer needn't outlive
       this call), downscale to fit max_size, flatten alpha, encode JPEG. */
    VipsImage *img = vips_image_new_from_memory_copy(
        rgba, (size_t)width * (size_t)height * 4, width, height, 4, VIPS_FORMAT_UCHAR);
    if (!img) return -1;

    VipsImage *thumb = NULL;
    if (vips_thumbnail_image(img, &thumb, max_size,
            "height", max_size,
            "size", VIPS_SIZE_DOWN,
            NULL) != 0) {
        g_object_unref(img);
        return -1;
    }
    g_object_unref(img);

    if (vips_image_hasalpha(thumb)) {
        VipsImage *flat = NULL;
        if (vips_flatten(thumb, &flat, NULL) != 0) {
            g_object_unref(thumb);
            return -1;
        }
        g_object_unref(thumb);
        thumb = flat;
    }

    if (vips_image_write_to_buffer(thumb, ".jpg[Q=85,strip]", buf, len, NULL) != 0) {
        g_object_unref(thumb);
        return -1;
    }
    g_object_unref(thumb);
    return 0;
}

int diffkeep_image_to_rgb_square(
    const char *filename,
    int size,
    void **buf,
    size_t *len
) {
    VipsImage *thumb = NULL;
    if (vips_thumbnail(filename, &thumb, size,
            "height", size,
            "size", VIPS_SIZE_FORCE,
            "no_rotate", TRUE,
            NULL) != 0)
        return -1;

    /* Flatten alpha; we want plain RGB */
    if (vips_image_hasalpha(thumb)) {
        VipsImage *flat = NULL;
        if (vips_flatten(thumb, &flat, NULL) != 0) {
            g_object_unref(thumb);
            return -1;
        }
        g_object_unref(thumb);
        thumb = flat;
    }

    /* Ensure 3-band sRGB uchar */
    if (vips_image_get_bands(thumb) != 3) {
        VipsImage *rgb = NULL;
        if (vips_colourspace(thumb, &rgb, VIPS_INTERPRETATION_sRGB, NULL) != 0) {
            g_object_unref(thumb);
            return -1;
        }
        g_object_unref(thumb);
        thumb = rgb;
    }
    if (vips_image_get_format(thumb) != VIPS_FORMAT_UCHAR) {
        VipsImage *u8img = NULL;
        if (vips_cast(thumb, &u8img, VIPS_FORMAT_UCHAR, NULL) != 0) {
            g_object_unref(thumb);
            return -1;
        }
        g_object_unref(thumb);
        thumb = u8img;
    }

    size_t out_len = 0;
    void *pixels = vips_image_write_to_memory(thumb, &out_len);
    g_object_unref(thumb);
    if (!pixels) return -1;

    *buf = pixels;
    *len = out_len;
    return 0;
}

/* ── Animated-image decoder ───────────────────────────────────────────────── */

/* Two modes. CACHED: the whole (downscaled) animation is decoded once into a
   single RGBA buffer at open time; each frame is then a cheap memcpy and looping
   is free — this is what makes many grid cells affordable, since per-frame libwebp
   decode is ~9ms. STREAM: no cache, pages decoded on demand from a live vips
   "toilet-roll" image (reopened on backward seek) — used when the decoded
   animation would exceed the cache budget (e.g. the viewer at native resolution,
   or a very long clip). Cached mode is chosen when width*height*n_pages*4 fits. */
#define DIFFKEEP_ANIM_CACHE_MAX_BYTES (96u * 1024u * 1024u)

struct DiffkeepAnimDecoder {
    /* Cached mode (pixels != NULL): the whole roll, width*page_height*n_pages*4. */
    unsigned char *pixels;
    /* Stream mode (pixels == NULL): live toilet-roll + reopen info. */
    VipsImage *roll;
    char *filename;
    int max_dim;       /* downscale long edge to this if > 0; 0 = native */

    int width;
    int page_height;
    int n_pages;
    long *pts_ms;      /* pts_ms[k] = start time of page k (cumulative delay) */
    long duration_ms;  /* total = sum of all per-frame delays */
    int cur;           /* index of the next page diffkeep_anim_next emits */
};

/* Scale (sw,sh) to fit max_dim on the long edge (never upscales). */
static void anim_fit_dims(int sw, int sh, int max_dim, int *dw, int *dh) {
    if (max_dim <= 0 || (sw <= max_dim && sh <= max_dim)) { *dw = sw; *dh = sh; return; }
    double scale = (sw >= sh) ? (double)max_dim / sw : (double)max_dim / sh;
    int w = (int)(sw * scale + 0.5), h = (int)(sh * scale + 0.5);
    *dw = w < 1 ? 1 : w;
    *dh = h < 1 ? 1 : h;
}

/* Open a fresh sequential toilet-roll (all pages). */
static VipsImage *anim_open_roll_file(const char *filename) {
    return vips_image_new_from_file(filename, "access", VIPS_ACCESS_SEQUENTIAL, "n", -1, NULL);
}

DiffkeepAnimDecoder *diffkeep_anim_open(const char *filename, int max_dim) {
    DiffkeepAnimDecoder *d = g_new0(DiffkeepAnimDecoder, 1);
    d->filename = g_strdup(filename);
    d->max_dim = max_dim;

    VipsImage *src = anim_open_roll_file(filename);
    if (!src) { diffkeep_anim_close(d); return NULL; }

    d->n_pages = vips_image_get_n_pages(src);
    if (d->n_pages <= 1) { g_object_unref(src); diffkeep_anim_close(d); return NULL; }
    int src_ph = vips_image_get_page_height(src);
    int src_w = vips_image_get_width(src);
    if (src_ph <= 0 || src_w <= 0) { g_object_unref(src); diffkeep_anim_close(d); return NULL; }

    /* Per-frame delays (ms). Fall back to 100ms/frame if the metadata is absent
       or malformed — the common case for GIFs that omit an explicit delay. */
    int *delays = NULL, n_delays = 0;
    int have_delays = (vips_image_get_typeof(src, "delay") != 0 &&
                       vips_image_get_array_int(src, "delay", &delays, &n_delays) == 0);
    d->pts_ms = g_new0(long, d->n_pages);
    long acc = 0;
    for (int k = 0; k < d->n_pages; k++) {
        d->pts_ms[k] = acc;
        int delay = (have_delays && k < n_delays && delays[k] > 0) ? delays[k] : 100;
        acc += delay;
    }
    d->duration_ms = acc;

    /* Decide cached vs stream from the projected decoded size at the target size. */
    int tw, th;
    anim_fit_dims(src_w, src_ph, max_dim, &tw, &th);
    size_t frame_bytes = (size_t)tw * (size_t)th * 4;
    int use_cache = frame_bytes > 0 &&
        frame_bytes * (size_t)d->n_pages <= DIFFKEEP_ANIM_CACHE_MAX_BYTES;

    if (!use_cache) {
        /* Stream mode: keep the live roll; per-page decode happens in _next. */
        d->roll = src;
        d->width = src_w;
        d->page_height = src_ph;
        return d;
    }

    /* Cached mode. Produce the (optionally downscaled) roll, then decode it whole.
       For downscaling use vips_thumbnail with "[n=-1]" so page geometry stays
       correct across the resize (the same path vips uses for animated thumbnails). */
    VipsImage *roll = NULL;
    if (max_dim > 0 && (src_w > max_dim || src_ph > max_dim)) {
        char *fn = g_strdup_printf("%s[n=-1]", filename);
        int rc = vips_thumbnail(fn, &roll, max_dim, "height", max_dim, "size", VIPS_SIZE_DOWN, NULL);
        g_free(fn);
        g_object_unref(src);
        src = NULL;
        if (rc != 0) { diffkeep_anim_close(d); return NULL; }
    } else {
        roll = src;
        src = NULL;
    }

    if (to_rgba8(&roll) != 0) { diffkeep_anim_close(d); return NULL; }

    d->width = vips_image_get_width(roll);
    d->page_height = vips_image_get_page_height(roll);
    int rn = vips_image_get_n_pages(roll);
    if (rn > 0 && rn < d->n_pages) d->n_pages = rn;
    if (d->width <= 0 || d->page_height <= 0) { g_object_unref(roll); diffkeep_anim_close(d); return NULL; }

    size_t len = 0;
    void *px = vips_image_write_to_memory(roll, &len);
    g_object_unref(roll);
    if (!px) { diffkeep_anim_close(d); return NULL; }
    d->pixels = (unsigned char *)px;

    /* Trust the buffer size over metadata: clamp n_pages to what actually landed. */
    size_t fb = (size_t)d->width * (size_t)d->page_height * 4;
    if (fb > 0) {
        int actual = (int)(len / fb);
        if (actual > 0 && actual < d->n_pages) d->n_pages = actual;
    }
    return d;
}

void diffkeep_anim_close(DiffkeepAnimDecoder *d) {
    if (!d) return;
    if (d->pixels) g_free(d->pixels);
    if (d->roll) g_object_unref(d->roll);
    g_free(d->pts_ms);
    g_free(d->filename);
    g_free(d);
}

int diffkeep_anim_frame_count(const DiffkeepAnimDecoder *d) { return d ? d->n_pages : 0; }
long diffkeep_anim_duration_ms(const DiffkeepAnimDecoder *d) { return d ? d->duration_ms : 0; }
double diffkeep_anim_fps(const DiffkeepAnimDecoder *d) {
    if (!d || d->duration_ms <= 0) return 0.0;
    return (double)d->n_pages * 1000.0 / (double)d->duration_ms;
}

/* Stream mode: decode the current page from the live roll (with optional resize). */
static int anim_next_stream(DiffkeepAnimDecoder *d, void **buf, int *w, int *h, long *pts_ms) {
    /* A failed reopen on a backward seek leaves no roll to read. */
    if (!d->roll) return -1;
    VipsImage *page = NULL;
    if (vips_extract_area(d->roll, &page, 0, d->cur * d->page_height,
                          d->width, d->page_height, NULL) != 0)
        return -1;

    if (d->max_dim > 0 && (d->width > d->max_dim || d->page_height > d->max_dim)) {
        VipsImage *thumb = NULL;
        if (vips_thumbnail_image(page, &thumb, d->max_dim,
                "height", d->max_dim, "size", VIPS_SIZE_DOWN, NULL) != 0) {
            g_object_unref(page);
            return -1;
        }
        g_object_unref(page);
        page = thumb;
    }

    if (to_rgba8(&page) != 0) return -1;

    size_t len = 0;
    void *pixels = vips_image_write_to_memory(page, &len);
    if (!pixels) { g_object_unref(page); return -1; }
    *buf = pixels;
    *w = vips_image_get_width(page);
    *h = vips_image_get_height(page);
    *pts_ms = d->pts_ms[d->cur];
    g_object_unref(page);
    d->cur++;
    return 1;
}

int diffkeep_anim_next(DiffkeepAnimDecoder *d, void **buf, int *w, int *h, long *pts_ms) {
    if (!d || d->cur >= d->n_pages) return 0; /* EOF */

    if (d->pixels) {
        /* Cached: hand back a copy of the pre-decoded frame (cheap). */
        size_t fb = (size_t)d->width * (size_t)d->page_height * 4;
        void *out = g_malloc(fb);
        memcpy(out, d->pixels + (size_t)d->cur * fb, fb);
        *buf = out;
        *w = d->width;
        *h = d->page_height;
        *pts_ms = d->pts_ms[d->cur];
        d->cur++;
        return 1;
    }
    return anim_next_stream(d, buf, w, h, pts_ms);
}

int diffkeep_anim_seek(DiffkeepAnimDecoder *d, long ts_ms) {
    if (!d) return -1;
    /* Find the last page whose start time is <= ts_ms. */
    int target = 0;
    for (int k = 0; k < d->n_pages; k++) {
        if (d->pts_ms[k] <= ts_ms) target = k; else break;
    }
    if (d->pixels) {
        d->cur = target; /* random access is free in cached mode */
        return 0;
    }
    /* Stream mode is forward-only: rewind by reopening, then let the caller decode
       forward to the target. Forward seeks need no reopen. */
    if (target < d->cur) {
        if (d->roll) { g_object_unref(d->roll); d->roll = NULL; }
        d->roll = anim_open_roll_file(d->filename);
        d->cur = 0;
        if (!d->roll) return -1;
    }
    return 0;
}

int diffkeep_jpeg_bytes_to_rgba(
    const void *data,
    size_t data_len,
    int size,
    void **buf,
    size_t *out_len,
    int *out_width,
    int *out_height
) {
    VipsImage *image = NULL;
    if (vips_jpegload_buffer((void *)data, data_len, &image, NULL) != 0)
        return -1;

    VipsImage *thumb = NULL;
    if (vips_thumbnail_image(image, &thumb, size,
            "height", size,
            "size", VIPS_SIZE_DOWN,
            NULL) != 0) {
        g_object_unref(image);
        return -1;
    }
    g_object_unref(image);

    if (to_rgba8(&thumb) != 0) return -1;

    size_t len = 0;
    void *pixels = vips_image_write_to_memory(thumb, &len);
    if (!pixels) {
        g_object_unref(thumb);
        return -1;
    }

    *out_width  = vips_image_get_width(thumb);
    *out_height = vips_image_get_height(thumb);
    *buf        = pixels;
    *out_len    = len;
    g_object_unref(thumb);
    return 0;
}

int diffkeep_load_image_rgba(
    const char *filename,
    void **buf,
    size_t *len,
    int *width,
    int *height
) {
    /* vips_thumbnail with a huge target and VIPS_SIZE_DOWN returns the image
       at its original resolution converted to sRGB(A) uint8 — the same path
       used by the thumbnail worker, which is known to work from threads. */
    VipsImage *image = NULL;
    if (vips_thumbnail(filename, &image, 65535,
            "height", 65535,
            "size", VIPS_SIZE_DOWN,
            "no_rotate", TRUE,
            NULL) != 0)
        return -1;

    /* dvui wants 4-band RGBA8; vips_thumbnail keeps greyscale as 1-2 bands. */
    if (to_rgba8(&image) != 0) return -1;

    size_t out_len = 0;
    void *pixels = vips_image_write_to_memory(image, &out_len);
    if (!pixels) {
        g_object_unref(image);
        return -1;
    }

    *width  = vips_image_get_width(image);
    *height = vips_image_get_height(image);
    *buf    = pixels;
    *len    = out_len;

    g_object_unref(image);
    return 0;
}
