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
