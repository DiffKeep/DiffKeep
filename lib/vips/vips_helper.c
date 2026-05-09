#include "vips_helper.h"
#include <vips/vips.h>

int diffkeep_vips_init(const char *name) {
    return vips_init(name);
}

void diffkeep_vips_shutdown(void) {
    vips_shutdown();
}

int diffkeep_thumbnail_to_png(
    const char *filename,
    int max_dimension,
    void **buf,
    size_t *len
) {
    VipsImage *thumb = NULL;

    if (vips_thumbnail(filename, &thumb, max_dimension,
            "height", max_dimension,
            "size", VIPS_SIZE_DOWN,
            NULL) != 0) {
        return -1;
    }

    if (vips_image_write_to_buffer(thumb, ".png", buf, len, NULL) != 0) {
        g_object_unref(thumb);
        return -1;
    }

    g_object_unref(thumb);
    return 0;
}

void diffkeep_vips_free(void *buf) {
    g_free(buf);
}
