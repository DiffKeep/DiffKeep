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
