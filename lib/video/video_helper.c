#include "video_helper.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <stdlib.h>
#include <string.h>

int diffkeep_video_probe(const char *filename, DiffkeepVideoInfo *out) {
    memset(out, 0, sizeof(*out));

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, filename, NULL, NULL) != 0) return -1;
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return -1;
    }

    int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int aidx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    out->has_video = vidx >= 0;
    out->has_audio = aidx >= 0;
    if (vidx >= 0) {
        AVStream *st = fmt->streams[vidx];
        out->width = st->codecpar->width;
        out->height = st->codecpar->height;
        out->nb_frames = st->nb_frames;
    }
    if (fmt->duration != AV_NOPTS_VALUE)
        out->duration_sec = (double)fmt->duration / (double)AV_TIME_BASE;

    avformat_close_input(&fmt);
    return 0;
}

/* Scale (sw,sh) to fit max_dim on the long edge, preserving aspect. Never
   upscales. Dimensions stay even (some pixel formats/scalers prefer it). */
static void fit_dims(int sw, int sh, int max_dim, int *dw, int *dh) {
    if (max_dim <= 0 || (sw <= max_dim && sh <= max_dim)) { *dw = sw; *dh = sh; return; }
    double scale = (sw >= sh) ? (double)max_dim / sw : (double)max_dim / sh;
    int w = (int)(sw * scale + 0.5);
    int h = (int)(sh * scale + 0.5);
    *dw = w < 2 ? 2 : (w & ~1);
    *dh = h < 2 ? 2 : (h & ~1);
}

/* The container's start time in ms (0 if unknown). Clips can start at a
   non-zero timestamp; video and audio both count from it, so they stay in
   sync, position 0 is the first frame, and seeks use the same clock. */
static int64_t start_ms(const AVFormatContext *fmt) {
    return fmt->start_time == AV_NOPTS_VALUE ? 0 : fmt->start_time / 1000;
}

static int64_t pts_to_ms(const AVFormatContext *fmt, int stream, int64_t pts) {
    if (pts == AV_NOPTS_VALUE) return 0;
    const AVRational tb = fmt->streams[stream]->time_base;
    return (int64_t)(pts * av_q2d(tb) * 1000.0) - start_ms(fmt);
}

static int seek_ms(AVFormatContext *fmt, int stream, int64_t ts_ms) {
    const AVRational tb = fmt->streams[stream]->time_base;
    int64_t ts = (int64_t)((double)(ts_ms + start_ms(fmt)) / 1000.0 / av_q2d(tb));
    return av_seek_frame(fmt, stream, ts, AVSEEK_FLAG_BACKWARD);
}

static int open_input(const char *filename, AVFormatContext **fmt) {
    *fmt = NULL;
    if (avformat_open_input(fmt, filename, NULL, NULL) != 0) return -1;
    if (avformat_find_stream_info(*fmt, NULL) < 0) {
        avformat_close_input(fmt);
        return -1;
    }
    return 0;
}

/* malloc'd copy of format-level tag `key` (case-insensitive), or NULL. */
static char *dup_tag(AVFormatContext *fmt, const char *key) {
    AVDictionaryEntry *e = av_dict_get(fmt->metadata, key, NULL, 0);
    return (e && e->value) ? strdup(e->value) : NULL;
}

int diffkeep_video_read_tag(const char *filename, const char *key, char **out) {
    AVFormatContext *fmt = NULL;
    *out = NULL;
    if (open_input(filename, &fmt) != 0) return -1;
    *out = dup_tag(fmt, key);
    avformat_close_input(&fmt);
    return *out ? 0 : -1;
}

/* Decode the first video frame of an opened input to packed RGBA8, fitted to
   max_dim on the long edge (0 = native). 0 on success, *buf malloc'd. */
static int first_frame(AVFormatContext *fmt, int max_dim, void **buf, int *width, int *height) {
    AVCodecContext *ctx = NULL;
    AVPacket *pkt = NULL;
    AVFrame *frame = NULL;
    struct SwsContext *sws = NULL;
    uint8_t *out = NULL;
    uint8_t *dst_data[4] = { NULL, NULL, NULL, NULL };
    int dst_linesize[4] = { 0, 0, 0, 0 };
    const AVCodec *dec = NULL;
    int vidx = -1;
    int got = 0;
    int w = 0, h = 0, dw = 0, dh = 0;
    int rc = -1;

    *buf = NULL;
    vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
    if (vidx < 0 || dec == NULL) goto done;

    ctx = avcodec_alloc_context3(dec);
    if (ctx == NULL) goto done;
    if (avcodec_parameters_to_context(ctx, fmt->streams[vidx]->codecpar) < 0) goto done;
    if (avcodec_open2(ctx, dec, NULL) < 0) goto done;

    pkt = av_packet_alloc();
    frame = av_frame_alloc();
    if (pkt == NULL || frame == NULL) goto done;

    while (!got && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == vidx && avcodec_send_packet(ctx, pkt) == 0) {
            if (avcodec_receive_frame(ctx, frame) == 0) got = 1;
        }
        av_packet_unref(pkt);
    }
    if (!got) { /* flush the decoder */
        avcodec_send_packet(ctx, NULL);
        if (avcodec_receive_frame(ctx, frame) == 0) got = 1;
    }
    if (!got) goto done;

    w = ctx->width;
    h = ctx->height;
    if (w <= 0 || h <= 0) goto done;
    fit_dims(w, h, max_dim, &dw, &dh);

    sws = sws_getContext(w, h, ctx->pix_fmt, dw, dh, AV_PIX_FMT_RGBA,
                         SWS_BILINEAR, NULL, NULL, NULL);
    if (sws == NULL) goto done;

    /* Scale into a SIMD-aligned, padded buffer (swscale may write past a tight
       w*4 row), then copy tight rows into the contiguous output. */
    if (av_image_alloc(dst_data, dst_linesize, dw, dh, AV_PIX_FMT_RGBA, 32) < 0) goto done;
    sws_scale(sws, (const uint8_t * const *)frame->data, frame->linesize, 0, h, dst_data, dst_linesize);

    out = (uint8_t *)malloc((size_t)dw * (size_t)dh * 4);
    if (out == NULL) goto done;
    for (int y = 0; y < dh; y++) {
        memcpy(out + (size_t)y * (size_t)dw * 4,
               dst_data[0] + (size_t)y * (size_t)dst_linesize[0],
               (size_t)dw * 4);
    }

    *buf = out;
    out = NULL;
    *width = dw;
    *height = dh;
    rc = 0;

done:
    if (out) free(out);
    if (dst_data[0]) av_freep(&dst_data[0]);
    if (sws) sws_freeContext(sws);
    if (frame) av_frame_free(&frame);
    if (pkt) av_packet_free(&pkt);
    if (ctx) avcodec_free_context(&ctx);
    return rc;
}

int diffkeep_video_first_frame_rgba(const char *filename, void **buf, int *width, int *height) {
    AVFormatContext *fmt = NULL;
    *buf = NULL;
    if (open_input(filename, &fmt) != 0) return -1;
    int rc = first_frame(fmt, 0, buf, width, height);
    avformat_close_input(&fmt);
    return rc;
}

int diffkeep_video_scan(const char *filename, int max_dim, DiffkeepVideoScan *out) {
    AVFormatContext *fmt = NULL;
    memset(out, 0, sizeof(*out));
    if (open_input(filename, &fmt) != 0) return -1;
    out->workflow = dup_tag(fmt, "workflow");
    out->prompt = dup_tag(fmt, "prompt");
    first_frame(fmt, max_dim, &out->pixels, &out->width, &out->height);
    avformat_close_input(&fmt);
    return 0;
}

void diffkeep_video_scan_free(DiffkeepVideoScan *s) {
    free(s->pixels);
    free(s->workflow);
    free(s->prompt);
    memset(s, 0, sizeof(*s));
}

void diffkeep_video_free(void *p) {
    free(p);
}

/* ── Stateful decoder session ────────────────────────────────────────────── */

struct DiffkeepDecoder {
    AVFormatContext *fmt;
    AVCodecContext *ctx;
    struct SwsContext *sws;
    AVPacket *pkt;
    AVFrame *frame;
    int vidx;
    int sws_w, sws_h;
    int sws_fmt;
    int max_dim; /* downscale long edge to this if > 0; 0 = native */
    uint8_t *dst[4];     /* swscale output, reused across frames */
    int dst_linesize[4];
    int dst_w, dst_h;
};

DiffkeepDecoder *diffkeep_decoder_open(const char *filename, int max_dim) {
    DiffkeepDecoder *d = (DiffkeepDecoder *)calloc(1, sizeof(DiffkeepDecoder));
    if (!d) return NULL;
    d->vidx = -1;
    d->max_dim = max_dim;

    if (avformat_open_input(&d->fmt, filename, NULL, NULL) != 0) goto fail;
    if (avformat_find_stream_info(d->fmt, NULL) < 0) goto fail;

    const AVCodec *dec = NULL;
    d->vidx = av_find_best_stream(d->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &dec, 0);
    if (d->vidx < 0 || dec == NULL) goto fail;

    d->ctx = avcodec_alloc_context3(dec);
    if (!d->ctx) goto fail;
    if (avcodec_parameters_to_context(d->ctx, d->fmt->streams[d->vidx]->codecpar) < 0) goto fail;
    if (avcodec_open2(d->ctx, dec, NULL) < 0) goto fail;

    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->pkt || !d->frame) goto fail;
    return d;

fail:
    diffkeep_decoder_close(d);
    return NULL;
}

double diffkeep_decoder_fps(DiffkeepDecoder *d) {
    if (!d || d->vidx < 0) return 0.0;
    AVRational r = d->fmt->streams[d->vidx]->avg_frame_rate;
    if (r.num == 0 || r.den == 0)
        r = d->fmt->streams[d->vidx]->r_frame_rate;
    if (r.num == 0 || r.den == 0) return 0.0;
    return av_q2d(r);
}

int diffkeep_decoder_next(DiffkeepDecoder *d, int *width, int *height, int64_t *pts_ms) {
    if (!d) return -1;
    av_frame_unref(d->frame); /* a frame _next prepared but nobody read */

    int have = 0;
    while (!have) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == 0) { have = 1; break; }
        if (r == AVERROR_EOF) return 0;
        if (r != AVERROR(EAGAIN)) return -1;

        /* Need more input. */
        int rp = av_read_frame(d->fmt, d->pkt);
        if (rp < 0) {
            avcodec_send_packet(d->ctx, NULL); /* enter drain mode */
            continue;
        }
        if (d->pkt->stream_index == d->vidx)
            avcodec_send_packet(d->ctx, d->pkt);
        av_packet_unref(d->pkt);
    }

    const int w = d->frame->width;
    const int h = d->frame->height;
    if (w <= 0 || h <= 0) { av_frame_unref(d->frame); return -1; }
    fit_dims(w, h, d->max_dim, width, height);

    *pts_ms = pts_to_ms(d->fmt, d->vidx, d->frame->best_effort_timestamp);
    return 1;
}

int diffkeep_decoder_read(DiffkeepDecoder *d, void *out, size_t len) {
    if (!d || !d->frame->data[0]) return -1;
    const int w = d->frame->width;
    const int h = d->frame->height;
    int dw, dh;
    fit_dims(w, h, d->max_dim, &dw, &dh);
    if (len != (size_t)dw * (size_t)dh * 4) { av_frame_unref(d->frame); return -1; }

    if (!d->sws || d->sws_w != w || d->sws_h != h || d->sws_fmt != d->frame->format) {
        if (d->sws) sws_freeContext(d->sws);
        d->sws = sws_getContext(w, h, (enum AVPixelFormat)d->frame->format, dw, dh, AV_PIX_FMT_RGBA,
                                SWS_BILINEAR, NULL, NULL, NULL);
        d->sws_w = w; d->sws_h = h; d->sws_fmt = d->frame->format;
    }
    if (!d->sws) { av_frame_unref(d->frame); return -1; }

    /* swscale writes into a SIMD-aligned, padded buffer (it may write past a
       tight w*4 row), kept across frames; then tight rows go to `out`. */
    if (!d->dst[0] || d->dst_w != dw || d->dst_h != dh) {
        av_freep(&d->dst[0]);
        if (av_image_alloc(d->dst, d->dst_linesize, dw, dh, AV_PIX_FMT_RGBA, 32) < 0) {
            d->dst[0] = NULL;
            av_frame_unref(d->frame);
            return -1;
        }
        d->dst_w = dw; d->dst_h = dh;
    }
    sws_scale(d->sws, (const uint8_t * const *)d->frame->data, d->frame->linesize, 0, h, d->dst, d->dst_linesize);
    for (int y = 0; y < dh; y++) {
        memcpy((uint8_t *)out + (size_t)y * (size_t)dw * 4,
               d->dst[0] + (size_t)y * (size_t)d->dst_linesize[0],
               (size_t)dw * 4);
    }
    av_frame_unref(d->frame);
    return 0;
}

int diffkeep_decoder_seek(DiffkeepDecoder *d, int64_t ts_ms) {
    if (!d || d->vidx < 0) return -1;
    if (seek_ms(d->fmt, d->vidx, ts_ms) < 0) return -1;
    avcodec_flush_buffers(d->ctx);
    return 0;
}

void diffkeep_decoder_close(DiffkeepDecoder *d) {
    if (!d) return;
    if (d->sws) sws_freeContext(d->sws);
    av_freep(&d->dst[0]);
    if (d->frame) av_frame_free(&d->frame);
    if (d->pkt) av_packet_free(&d->pkt);
    if (d->ctx) avcodec_free_context(&d->ctx);
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d);
}

/* ── Audio decoder session ───────────────────────────────────────────────── */

struct DiffkeepAudioDecoder {
    AVFormatContext *fmt;
    AVCodecContext *ctx;
    SwrContext *swr;
    AVPacket *pkt;
    AVFrame *frame;
    int aidx;
    int out_rate;
};

DiffkeepAudioDecoder *diffkeep_audio_open(const char *filename, int *sample_rate, int *channels) {
    DiffkeepAudioDecoder *d = (DiffkeepAudioDecoder *)calloc(1, sizeof(DiffkeepAudioDecoder));
    if (!d) return NULL;
    d->aidx = -1;

    if (avformat_open_input(&d->fmt, filename, NULL, NULL) != 0) goto fail;
    if (avformat_find_stream_info(d->fmt, NULL) < 0) goto fail;

    const AVCodec *dec = NULL;
    d->aidx = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &dec, 0);
    if (d->aidx < 0 || dec == NULL) goto fail;

    d->ctx = avcodec_alloc_context3(dec);
    if (!d->ctx) goto fail;
    if (avcodec_parameters_to_context(d->ctx, d->fmt->streams[d->aidx]->codecpar) < 0) goto fail;
    if (avcodec_open2(d->ctx, dec, NULL) < 0) goto fail;

    d->out_rate = d->ctx->sample_rate;

    AVChannelLayout out_layout;
    av_channel_layout_default(&out_layout, 2);
    if (swr_alloc_set_opts2(&d->swr,
            &out_layout, AV_SAMPLE_FMT_FLT, d->out_rate,
            &d->ctx->ch_layout, d->ctx->sample_fmt, d->ctx->sample_rate,
            0, NULL) < 0) { av_channel_layout_uninit(&out_layout); goto fail; }
    av_channel_layout_uninit(&out_layout);
    if (swr_init(d->swr) < 0) goto fail;

    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->pkt || !d->frame) goto fail;

    *sample_rate = d->out_rate;
    *channels = 2;
    return d;

fail:
    diffkeep_audio_close(d);
    return NULL;
}

int diffkeep_audio_next(DiffkeepAudioDecoder *d, void **buf, int *nbytes, int64_t *pts_ms) {
    *buf = NULL;
    *nbytes = 0;
    if (!d) return -1;

    int have = 0;
    while (!have) {
        int r = avcodec_receive_frame(d->ctx, d->frame);
        if (r == 0) { have = 1; break; }
        if (r == AVERROR_EOF) return 0;
        if (r != AVERROR(EAGAIN)) return -1;

        int rp = av_read_frame(d->fmt, d->pkt);
        if (rp < 0) {
            avcodec_send_packet(d->ctx, NULL);
            continue;
        }
        if (d->pkt->stream_index == d->aidx)
            avcodec_send_packet(d->ctx, d->pkt);
        av_packet_unref(d->pkt);
    }

    const int out_samples = (int)swr_get_out_samples(d->swr, d->frame->nb_samples);
    const int cap_bytes = out_samples * 2 * (int)sizeof(float);
    uint8_t *out = (uint8_t *)malloc((size_t)(cap_bytes > 0 ? cap_bytes : 4));
    if (!out) { av_frame_unref(d->frame); return -1; }

    uint8_t *out_ptrs[1] = { out };
    const int got = swr_convert(d->swr, out_ptrs, out_samples,
                                (const uint8_t **)d->frame->extended_data, d->frame->nb_samples);
    if (got < 0) { free(out); av_frame_unref(d->frame); return -1; }

    *pts_ms = pts_to_ms(d->fmt, d->aidx, d->frame->best_effort_timestamp);
    *nbytes = got * 2 * (int)sizeof(float);
    *buf = out;
    av_frame_unref(d->frame);
    return 1;
}

int diffkeep_audio_seek(DiffkeepAudioDecoder *d, int64_t ts_ms) {
    if (!d || d->aidx < 0) return -1;
    if (seek_ms(d->fmt, d->aidx, ts_ms) < 0) return -1;
    avcodec_flush_buffers(d->ctx);
    return 0;
}

void diffkeep_audio_close(DiffkeepAudioDecoder *d) {
    if (!d) return;
    if (d->swr) swr_free(&d->swr);
    if (d->frame) av_frame_free(&d->frame);
    if (d->pkt) av_packet_free(&d->pkt);
    if (d->ctx) avcodec_free_context(&d->ctx);
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d);
}
