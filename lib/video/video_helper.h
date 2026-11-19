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

/* Everything a library scan needs from a video, from one open of the file. */
typedef struct {
    void *pixels;   /* first frame, packed RGBA8 width*height*4, or NULL if it didn't decode */
    int width;
    int height;
    char *workflow; /* "workflow" tag (ComfyUI), or NULL */
    char *prompt;   /* "prompt" tag (ComfyUI), or NULL */
    char *parameters; /* "parameters" tag (A1111-style; TensorPencil), or NULL */
} DiffkeepVideoScan;

/* Open `filename` once: read its ComfyUI tags and decode the first frame,
   fitted to max_dim on the long edge (0 = native). Returns -1 if the file
   can't be opened; otherwise 0, with any part that failed left NULL. Free
   with diffkeep_video_scan_free. */
int diffkeep_video_scan(const char *filename, int max_dim, DiffkeepVideoScan *out);
void diffkeep_video_scan_free(DiffkeepVideoScan *s);

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

/* Decode the next frame: returns 1 and sets its output size *width x
   *height and *pts_ms, 0 at end-of-stream, -1 on error. Then
   diffkeep_decoder_read converts it to packed RGBA8 in the caller's buffer
   (len = width*height*4). */
int diffkeep_decoder_next(DiffkeepDecoder *d, int *width, int *height, int64_t *pts_ms);
int diffkeep_decoder_read(DiffkeepDecoder *d, void *out, size_t len);

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
