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

/* Names the fastest backend ggml actually registered, e.g. "CUDA0" or "CPU".
 *
 * Exists because the difference is invisible until you measure it: a build
 * without -Dwhisper-prefix links the distro's CPU-only whisper, loads fine,
 * transcribes fine, and is ~150x slower. That regression shipped twice --
 * once when the CUDA build was first set up, and once when a routine
 * `zig build` silently relinked over it. whisper.cpp prints the backend to
 * its own log, which is not somewhere a service's own warnings are looked
 * for, so Ronny reports it itself. */
int ronny_whisper_backend(char *out, int max_out) {
    if (out == NULL || max_out <= 0) return -1;
    out[0] = '\0';

    /* A GPU device, if any, otherwise the last device seen. Device 0 is not
     * reliably the accelerator. */
    const char *best = NULL;
    size_t count = ggml_backend_dev_count();
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (dev == NULL) continue;
        const char *name = ggml_backend_dev_name(dev);
        if (name == NULL) continue;
        if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU) {
            best = name;
            break;
        }
        if (best == NULL) best = name;
    }
    if (best == NULL) return -1;

    size_t len = strlen(best);
    if (len >= (size_t)max_out) len = (size_t)max_out - 1;
    memcpy(out, best, len);
    out[len] = '\0';
    return (int)len;
}

void ronny_whisper_free(void) {
    if (g_ctx != NULL) {
        whisper_free(g_ctx);
        g_ctx = NULL;
    }
}

/* Is `lang` one of the comma-separated codes in `allowed`? */
static int language_allowed(const char *allowed, const char *lang) {
    if (allowed == NULL || allowed[0] == '\0' || lang == NULL) return 1;

    size_t lang_len = strlen(lang);
    const char *cursor = allowed;
    while (*cursor != '\0') {
        while (*cursor == ' ' || *cursor == ',') cursor++;
        const char *end = cursor;
        while (*end != '\0' && *end != ',') end++;
        size_t len = (size_t)(end - cursor);
        while (len > 0 && cursor[len - 1] == ' ') len--;
        if (len == lang_len && strncasecmp(cursor, lang, len) == 0) return 1;
        cursor = end;
    }
    return 0;
}

static int collect_segments(char *out, int cap) {
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

/* Transcribes 16kHz mono float samples into `out`.
 *
 * Returns the number of bytes written, or -1 on failure.
 *
 * `prompt` biases the decoder toward vocabulary actually in use, and may be
 * NULL. It is the only customization lever whisper offers -- there is no
 * speaker enrollment -- and it is what stops "1Password" coming back as "one
 * password". Whisper truncates it around 224 tokens, so the caller sends a
 * slice of the vocabulary and matches the rest afterwards.
 *
 * `allowed` is a comma-separated list of languages the speaker actually uses
 * ("en,es"), or NULL to accept whatever is detected. Auto-detect is kept
 * because this owner switches language mid-conversation, but on short
 * utterances it has twice settled on a language they do not speak -- once
 * Greek, once Romanian -- and the second time the nonsense became the body of
 * an email. When that happens the audio is decoded again, forced to the first
 * allowed language. On the GPU that second pass costs under a tenth of a
 * second, which is nothing against sending a mail composed of noise.
 *
 * `lang_out` receives the language finally used, so the caller can log it and
 * notice a speaker whose language keeps being guessed wrong.
 */
int ronny_whisper_transcribe(const float *samples, int n_samples, const char *prompt,
                             const char *allowed, char *out, int cap,
                             char *lang_out, int lang_cap) {
    if (g_ctx == NULL || samples == NULL || out == NULL || cap <= 0) return -1;
    out[0] = '\0';
    if (lang_out != NULL && lang_cap > 0) lang_out[0] = '\0';

    struct whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_progress   = false;
    wparams.print_realtime   = false;
    wparams.print_timestamps = false;
    wparams.no_timestamps    = true;
    wparams.language         = NULL;   /* auto-detect */
    wparams.detect_language  = false;
    /* Measured on this host (i7-8086K, 6c/12t, medium model, CPU backend):
     * encode per 30s window was 13.2s at 4 threads, 6.6s at 8, 6.1s at 12.
     * Eight is the knee -- hyperthreads add 7% while contending with Ollama
     * and the watcher for the same cores. Irrelevant on the GPU. */
    wparams.n_threads        = 8;
    wparams.initial_prompt   = (prompt != NULL && prompt[0] != '\0') ? prompt : NULL;

    if (whisper_full(g_ctx, wparams, samples, n_samples) != 0) return -1;

    const char *used = whisper_lang_str(whisper_full_lang_id(g_ctx));
    char forced[8];
    if (!language_allowed(allowed, used)) {
        size_t n = 0;
        while (allowed[n] != '\0' && allowed[n] != ',' && n < sizeof(forced) - 1) {
            forced[n] = allowed[n];
            n++;
        }
        forced[n] = '\0';

        wparams.language = forced;
        if (whisper_full(g_ctx, wparams, samples, n_samples) != 0) return -1;
        used = forced;
    }

    if (lang_out != NULL && lang_cap > 0 && used != NULL) {
        size_t n = strlen(used);
        if (n >= (size_t)lang_cap) n = (size_t)lang_cap - 1;
        memcpy(lang_out, used, n);
        lang_out[n] = '\0';
    }
    return collect_segments(out, cap);
}
