#pragma once
#include <stddef.h>
#include <stdint.h>

/* Thin C wrapper over libav* for DiffKeep. Portable across Linux/macOS/Windows;
   only build.zig wires the platform include/lib paths. */

typedef struct {
    int width;
    int height;
    double duration_sec;
    int has_video;
    int has_audio;
    int64_t nb_frames; /* video stream frame count if known, else 0 */
} DiffkeepVideoInfo;

/* Probe container/streams. Returns 0 on success, -1 on error. */
int diffkeep_video_probe(const char *filename, DiffkeepVideoInfo *out);

/* Read a format-level metadata tag (case-insensitive, e.g. "workflow"/"prompt").
   On success returns 0 and *out is a malloc'd NUL-terminated copy (free with
   diffkeep_video_free). Returns -1 if absent or on error. */
int diffkeep_video_read_tag(const char *filename, const char *key, char **out);

/* Decode the first video frame to packed RGBA8 (width*height*4 bytes).
   On success returns 0; *buf is malloc'd (free with diffkeep_video_free). */
int diffkeep_video_first_frame_rgba(const char *filename, void **buf, int *width, int *height);

void diffkeep_video_free(void *p);

/* ── Stateful decoder session (for playback) ─────────────────────────────── */

typedef struct DiffkeepDecoder DiffkeepDecoder;

/* Open a decoder for the file's video stream. NULL on failure. If max_dim > 0,
   frames are downscaled (during the sws RGBA conversion) to fit max_dim on the
   long edge — used for the grid, which only needs thumbnail-size frames. 0 keeps
   native resolution. */
DiffkeepDecoder *diffkeep_decoder_open(const char *filename, int max_dim);

/* Average frames-per-second of the video stream (0 if unknown). */
double diffkeep_decoder_fps(DiffkeepDecoder *d);

/* Decode the next frame to packed RGBA8. Returns 1 and sets *buf (malloc'd
   width*height*4, free with diffkeep_video_free), *width, *height, *pts_ms on a
   frame; 0 at end-of-stream; -1 on error. */
int diffkeep_decoder_next(DiffkeepDecoder *d, void **buf, int *width, int *height, int64_t *pts_ms);

/* Seek to ~ts_ms (to the keyframe at or before it) and flush. 0 on success. */
int diffkeep_decoder_seek(DiffkeepDecoder *d, int64_t ts_ms);

void diffkeep_decoder_close(DiffkeepDecoder *d);

/* ── Audio decoder session ───────────────────────────────────────────────── */

typedef struct DiffkeepAudioDecoder DiffkeepAudioDecoder;

/* Open the file's audio stream, resampling to interleaved float32 stereo.
   Returns NULL if there is no audio stream or on error. On success sets
   *sample_rate (source rate) and *channels (always 2). */
DiffkeepAudioDecoder *diffkeep_audio_open(const char *filename, int *sample_rate, int *channels);

/* Decode the next audio chunk to interleaved f32 stereo. Returns 1 and sets
   *buf (malloc'd, free with diffkeep_video_free), *nbytes, *pts_ms; 0 at EOS;
   -1 on error. */
int diffkeep_audio_next(DiffkeepAudioDecoder *d, void **buf, int *nbytes, int64_t *pts_ms);

int diffkeep_audio_seek(DiffkeepAudioDecoder *d, int64_t ts_ms);

void diffkeep_audio_close(DiffkeepAudioDecoder *d);
