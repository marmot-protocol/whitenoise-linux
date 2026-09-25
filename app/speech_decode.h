// Included by stt.c. Decode directly from a private mapping: no PCM file or URL.
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>

typedef struct {
    const unsigned char *data;
    int64_t size, position, deadline;
} AudioInput;

static int audio_read(void *opaque, uint8_t *buffer, int size) {
    AudioInput *input = opaque;
    int count = (int)MIN((int64_t)size, input->size - input->position);
    if (count <= 0)
        return AVERROR_EOF;
    memcpy(buffer, input->data + input->position, (size_t)count);
    input->position += count;
    return count;
}

static int64_t audio_seek(void *opaque, int64_t offset, int whence) {
    AudioInput *input = opaque;
    if (whence == AVSEEK_SIZE)
        return input->size;
    whence &= ~AVSEEK_FORCE;
    int64_t base = whence == SEEK_SET   ? 0
                   : whence == SEEK_CUR ? input->position
                   : whence == SEEK_END ? input->size
                                        : -1;
    if (base < 0 || offset < -base || offset > input->size - base)
        return AVERROR(EINVAL);
    input->position = base + offset;
    return input->position;
}

static int audio_timeout(void *opaque) {
    return g_get_monotonic_time() >= ((AudioInput *)opaque)->deadline;
}

static int deny_external_io(AVFormatContext *context, AVIOContext **io, const char *url, int flags,
                            AVDictionary **options) {
    (void)context;
    (void)io;
    (void)url;
    (void)flags;
    (void)options;
    return AVERROR(EACCES);
}

static int receive_audio(AVCodecContext *decoder, SwrContext *resampler, AVFrame *frame,
                         float *samples, int *count) {
    for (;;) {
        int result = avcodec_receive_frame(decoder, frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF)
            return 0;
        if (result < 0)
            return AUDIO_ERROR;
        uint8_t *output = (uint8_t *)(samples + *count);
        int produced = swr_convert(resampler, &output, MAX_AUDIO_SAMPLES + 1 - *count,
                                   (const uint8_t **)frame->extended_data, frame->nb_samples);
        av_frame_unref(frame);
        if (produced < 0)
            return AUDIO_ERROR;
        *count += produced;
        if (*count > MAX_AUDIO_SAMPLES)
            return LENGTH_ERROR;
    }
}

static int decode_audio(WnIpc *input, float **samples_out, int *count_out) {
    AudioInput source = {wn_ipc_data(input), (int64_t)wn_ipc_size(input), 0,
                         g_get_monotonic_time() + 60 * G_USEC_PER_SEC};
    AVFormatContext *format = avformat_alloc_context();
    unsigned char *buffer = av_malloc(32768);
    AVIOContext *io =
        buffer ? avio_alloc_context(buffer, 32768, 0, &source, audio_read, NULL, audio_seek) : NULL;
    AVCodecContext *decoder = NULL;
    SwrContext *resampler = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    float *samples = NULL;
    int code = AUDIO_ERROR, count = 0;
    if (!format || !io || !packet || !frame)
        goto done;
    format->pb = io;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    format->io_open = deny_external_io;
    format->interrupt_callback = (AVIOInterruptCB){audio_timeout, &source};
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "", 0);
    int opened = avformat_open_input(&format, NULL, NULL, &options);
    av_dict_free(&options);
    if (opened < 0 || avformat_find_stream_info(format, NULL) < 0)
        goto done;
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (stream < 0)
        goto done;
    AVCodecParameters *params = format->streams[stream]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(params->codec_id);
    decoder = codec ? avcodec_alloc_context3(codec) : NULL;
    if (!decoder || avcodec_parameters_to_context(decoder, params) < 0 ||
        avcodec_open2(decoder, codec, NULL) < 0)
        goto done;
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
    if (swr_alloc_set_opts2(&resampler, &mono, AV_SAMPLE_FMT_FLT, SAMPLE_RATE, &decoder->ch_layout,
                            decoder->sample_fmt, decoder->sample_rate, 0, NULL) < 0 ||
        swr_init(resampler) < 0)
        goto done;
    samples = g_try_new(float, MAX_AUDIO_SAMPLES + 1);
    if (!samples)
        goto done;
    for (;;) {
        int result = av_read_frame(format, packet);
        if (result == AVERROR_EOF)
            break;
        if (result < 0 || audio_timeout(&source))
            goto done;
        if (packet->stream_index == stream) {
            if (avcodec_send_packet(decoder, packet) < 0)
                goto done;
            code = receive_audio(decoder, resampler, frame, samples, &count);
            if (code)
                goto done;
            code = AUDIO_ERROR;
        }
        av_packet_unref(packet);
    }
    if (avcodec_send_packet(decoder, NULL) < 0)
        goto done;
    code = receive_audio(decoder, resampler, frame, samples, &count);
    if (code)
        goto done;
    for (;;) {
        uint8_t *output = (uint8_t *)(samples + count);
        int produced = swr_convert(resampler, &output, MAX_AUDIO_SAMPLES + 1 - count, NULL, 0);
        if (produced < 0) {
            code = AUDIO_ERROR;
            goto done;
        }
        count += produced;
        if (count > MAX_AUDIO_SAMPLES) {
            code = LENGTH_ERROR;
            goto done;
        }
        if (!produced)
            break;
    }
    if (!count) {
        code = AUDIO_ERROR;
        goto done;
    }
    *samples_out = samples;
    *count_out = count;
    samples = NULL;
done:
    g_free(samples);
    av_frame_free(&frame);
    av_packet_free(&packet);
    swr_free(&resampler);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    if (io)
        av_freep(&io->buffer);
    else
        av_free(buffer);
    avio_context_free(&io);
    return code;
}
