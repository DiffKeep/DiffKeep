#include "vips_helper.h"
#include <vips/vips.h>

int diffkeep_vips_init(const char *name) {
    return vips_init(name);
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

    /* Ensure 3-band sRGB */
    if (vips_image_get_bands(thumb) != 3) {
        VipsImage *rgb = NULL;
        if (vips_colourspace(thumb, &rgb, VIPS_INTERPRETATION_sRGB, NULL) != 0) {
            g_object_unref(thumb);
            return -1;
        }
        g_object_unref(thumb);
        thumb = rgb;
    }

    size_t out_len = 0;
    void *pixels = vips_image_write_to_memory(thumb, &out_len);
    g_object_unref(thumb);
    if (!pixels) return -1;

    *buf = pixels;
    *len = out_len;
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

    if (!vips_image_hasalpha(thumb)) {
        VipsImage *rgba = NULL;
        if (vips_addalpha(thumb, &rgba, NULL) != 0) {
            g_object_unref(thumb);
            return -1;
        }
        g_object_unref(thumb);
        thumb = rgba;
    }

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

    /* vips_thumbnail outputs 3-band sRGB or 4-band sRGB-A.
       Ensure we always have 4 bands for dvui. */
    if (!vips_image_hasalpha(image)) {
        VipsImage *rgba = NULL;
        if (vips_addalpha(image, &rgba, NULL) != 0) {
            g_object_unref(image);
            return -1;
        }
        g_object_unref(image);
        image = rgba;
    }

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
