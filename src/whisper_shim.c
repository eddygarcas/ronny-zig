/* whisper.cpp boundary.
 *
 * Kept in C for the same reason as the libetpan shim: whisper_full_params is
 * a large struct with nested unions and function pointers, which translate-c
 * handles poorly. Building it here and exposing one flat call keeps the
 * awkwardness in one place.
 *
 * The model is loaded once and kept resident. Reloading per voice note would
 * dominate the latency -- the medium model takes ~30s to load and under a
 * second to transcribe.
 */

#include <whisper.h>
#include <ggml-backend.h>
#include <stdlib.h>
#include <string.h>

static struct whisper_context *g_ctx = NULL;

int ronny_whisper_load(const char *model_path) {
    if (g_ctx != NULL) return 0;

    /* Backends are runtime plugins, not something linking pulls in: with
     * libggml linked but this call missing, ggml_backend_dev_count() is 0 and
     * model load aborts with GGML_ASSERT(device) failed. whisper-cli calls
     * this too. Linking alone is not enough -- verified with plain gcc. */
    ggml_backend_load_all();

    struct whisper_context_params cparams = whisper_context_default_params();
    g_ctx = whisper_init_from_file_with_params(model_path, cparams);
    return g_ctx == NULL ? -1 : 0;
}

void ronny_whisper_free(void) {
    if (g_ctx != NULL) {
        whisper_free(g_ctx);
        g_ctx = NULL;
    }
}

/* Transcribes 16kHz mono float samples into `out`.
 *
 * Returns the number of bytes written, or -1 on failure. Language is left to
 * auto-detection so the owner can switch between English and Spanish
 * mid-conversation without configuration.
 *
 * `prompt` biases the decoder toward vocabulary actually in use, and may be
 * NULL. It is the only customization lever whisper offers -- there is no
 * speaker enrollment -- and it is what stops "1Password" coming back as "one
 * password". Whisper truncates it around 224 tokens, so the caller sends a
 * slice of the vocabulary and matches the rest afterwards.
 */
int ronny_whisper_transcribe(const float *samples, int n_samples, const char *prompt,
                             char *out, int cap) {
    if (g_ctx == NULL || samples == NULL || out == NULL || cap <= 0) return -1;
    out[0] = '\0';

    struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_progress   = false;
    wparams.print_realtime   = false;
    wparams.print_timestamps = false;
    wparams.no_timestamps    = true;
    wparams.language         = NULL;   /* auto-detect */
    wparams.detect_language  = false;
    wparams.n_threads        = 4;
    wparams.initial_prompt   = (prompt != NULL && prompt[0] != '\0') ? prompt : NULL;

    if (whisper_full(g_ctx, wparams, samples, n_samples) != 0) return -1;

    int written = 0;
    const int segments = whisper_full_n_segments(g_ctx);
    for (int i = 0; i < segments; i++) {
        const char *text = whisper_full_get_segment_text(g_ctx, i);
        if (text == NULL) continue;
        int len = (int)strlen(text);
        if (written + len >= cap) len = cap - written - 1;
        if (len <= 0) break;
        memcpy(out + written, text, len);
        written += len;
    }
    out[written] = '\0';
    return written;
}
