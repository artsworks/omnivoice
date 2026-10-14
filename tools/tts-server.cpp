// tts-server.cpp: OpenAI-compatible HTTP server backed by the
// omnivoice ABI. Loads an LM + codec once, GPU resident, and serves
// synthesis over POST /v1/audio/speech. The shared core lives in
// src/tts-server.h ; this file only wires the ov_* ABI into the adapter.
//
// OmniVoice has no named speaker table: every voice comes from the
// registry, filled over POST /v1/audio/voices. A request without a voice
// uses the startup reference (--ref-audio + --ref-text) when one is set,
// otherwise it runs voice design from the instructions field.

#include "tts-server.h"

#include "omnivoice.h"
#include "rvq-file.h"
#include "utf8.h"
#include "version.h"

#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

// Packed .rvq code width, fixed by the OmniVoice codec (2048 entries per
// codebook).
static const int RVQ_CODE_BITS = 11;

// One registered cloned voice: the RVQ codes in the ABI ownership contract
// (malloc-owned, released by ov_voice_ref_free) plus the reference
// transcript that anchors the clone.
struct voice_entry {
    struct ov_voice_ref ref;
    std::string         ref_text;
};

// Registered voices, name keyed. Every access happens under
// g_voices_mutex ; the synthesize lookup copies the codes out so a
// concurrent replace or delete never frees a buffer a running synthesis
// still reads.
static std::mutex                                   g_voices_mutex;
static std::unordered_map<std::string, voice_entry> g_voices;

// Startup reference from --ref-audio / --ref-text. Encoded once before the
// server listens and never modified afterwards, so synthesis reads it
// without a lock. Empty ref_codes means no startup reference.
static voice_entry g_default_voice = {};

static void print_usage(const char * prog) {
    fprintf(stderr, "omnivoice.cpp %s\n\n", OMNIVOICE_VERSION);
    fprintf(stderr,
            "Usage: %s --model <gguf> --codec <gguf> [options]\n\n"
            "Required:\n"
            "  --model <gguf>          LLM GGUF (F32 / BF16 / Q8_0)\n"
            "  --codec <gguf>          Codec GGUF (omnivoice-tokenizer-*.gguf)\n\n"
            "Optional:\n"
            "  --host <ip>             Listen address (default: 127.0.0.1)\n"
            "  --port <n>              Listen port (default: 8080)\n"
            "  --lang <str>            Language label when a request omits one (default 'None')\n"
            "  --ref-audio <wav>       Reference clip, the default voice for requests without 'voice'\n"
            "  --ref-text <path>       Transcript file for --ref-audio (required with it, verbatim)\n"
            "  --locked                Use server-owned synthesis parameters, WAV output by default\n"
            "  --steps <int>           MaskGIT steps in locked mode (default: 32)\n"
            "  --seed <int>            Seed in locked mode (default: -1 random, used only when a temperature > 0)\n"
            "  --position-temperature <f>  Position temperature in locked mode (default: 0)\n"
            "  --class-temperature <f>     Class temperature in locked mode (default: 0)\n"
            "  --no-fa                 Disable flash attention\n"
            "                          Flash attention is enabled by default\n"
            "  --clamp-fp16            Clamp hidden states to FP16 range\n",
            prog);
}

// Read a transcript file: UTF-8 normalised, trailing newlines dropped,
// same as the omnivoice-tts --ref-text path.
static bool read_text_file(const char * path, std::string & out) {
    FILE * f = utf8_fopen(path, "rb");
    if (!f) {
        return false;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) {
        fclose(f);
        return false;
    }
    out.resize((size_t) sz);
    if (sz > 0 && fread(&out[0], 1, (size_t) sz, f) != (size_t) sz) {
        fclose(f);
        return false;
    }
    fclose(f);
    utf8_normalize(out);
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) {
        out.pop_back();
    }
    return true;
}

static bool parse_int_arg(const char * s, int & out) {
    errno = 0;
    char * end;
    long   value = std::strtol(s, &end, 10);
    if (end == s || *end != '\0' || errno == ERANGE || value < INT_MIN || value > INT_MAX) {
        return false;
    }
    out = (int) value;
    return true;
}

static bool parse_float_arg(const char * s, double & out) {
    errno = 0;
    char * end;
    double value = std::strtod(s, &end);
    if (end == s || *end != '\0' || errno == ERANGE || !std::isfinite(value)) {
        return false;
    }
    out = value;
    return true;
}

// Trim a path down to its file name for the reported model id.
static std::string basename_of(const char * path) {
    std::string s = path;
    size_t      p = s.find_last_of("/\\");
    return p == std::string::npos ? s : s.substr(p + 1);
}

int main(int argc, char ** argv) {
    const char *  model_path = NULL;
    const char *  codec_path = NULL;
    std::string   lang       = "None";
    server_config cfg;
    bool          use_fa                     = true;
    bool          clamp_fp16                 = false;
    bool          locked                     = false;
    bool          steps_given                = false;
    bool          seed_given                 = false;
    bool          position_temperature_given = false;
    bool          class_temperature_given    = false;
    int           steps                      = 32;
    int           seed                       = -1;
    double        position_temperature       = 0.0;
    double        class_temperature          = 0.0;
    const char *  ref_audio_path             = NULL;
    const char *  ref_text_path              = NULL;

    for (int i = 1; i < argc; i++) {
        const char * arg = argv[i];
        if (!std::strcmp(arg, "--model") && i + 1 < argc) {
            model_path = argv[++i];
        } else if (!std::strcmp(arg, "--codec") && i + 1 < argc) {
            codec_path = argv[++i];
        } else if (!std::strcmp(arg, "--host") && i + 1 < argc) {
            cfg.host = argv[++i];
        } else if (!std::strcmp(arg, "--port") && i + 1 < argc) {
            cfg.port = std::atoi(argv[++i]);
        } else if (!std::strcmp(arg, "--lang") && i + 1 < argc) {
            lang = argv[++i];
        } else if (!std::strcmp(arg, "--ref-audio") && i + 1 < argc) {
            ref_audio_path = argv[++i];
        } else if (!std::strcmp(arg, "--ref-text") && i + 1 < argc) {
            ref_text_path = argv[++i];
        } else if (!std::strcmp(arg, "--locked")) {
            locked = true;
        } else if (!std::strcmp(arg, "--steps") && i + 1 < argc) {
            const char * value = argv[++i];
            if (!parse_int_arg(value, steps)) {
                fprintf(stderr, "[Server] FATAL: --steps expects an integer, got '%s'\n", value);
                return 1;
            }
            steps_given = true;
            if (steps < 1) {
                fprintf(stderr, "[Server] FATAL: --steps must be >= 1\n");
                return 1;
            }
        } else if (!std::strcmp(arg, "--seed") && i + 1 < argc) {
            const char * value = argv[++i];
            if (!parse_int_arg(value, seed)) {
                fprintf(stderr, "[Server] FATAL: --seed expects an integer, got '%s'\n", value);
                return 1;
            }
            seed_given = true;
        } else if (!std::strcmp(arg, "--position-temperature") && i + 1 < argc) {
            const char * value = argv[++i];
            if (!parse_float_arg(value, position_temperature)) {
                fprintf(stderr, "[Server] FATAL: --position-temperature expects a number, got '%s'\n", value);
                return 1;
            }
            position_temperature_given = true;
        } else if (!std::strcmp(arg, "--class-temperature") && i + 1 < argc) {
            const char * value = argv[++i];
            if (!parse_float_arg(value, class_temperature)) {
                fprintf(stderr, "[Server] FATAL: --class-temperature expects a number, got '%s'\n", value);
                return 1;
            }
            class_temperature_given = true;
        } else if (!std::strcmp(arg, "--no-fa")) {
            use_fa = false;
        } else if (!std::strcmp(arg, "--clamp-fp16")) {
            clamp_fp16 = true;
        } else {
            print_usage(argv[0]);
            return 1;
        }
    }

    if (!locked && (steps_given || seed_given || position_temperature_given || class_temperature_given)) {
        fprintf(stderr, "[Server] FATAL: --steps/--seed/--position-temperature/--class-temperature require --locked\n");
        return 1;
    }
    if (!model_path || !codec_path) {
        print_usage(argv[0]);
        return 1;
    }
    if (locked && (!ref_audio_path || !ref_text_path)) {
        fprintf(stderr, "[Server] FATAL: --locked requires --ref-audio and --ref-text\n");
        return 1;
    }
    if (!ref_audio_path != !ref_text_path) {
        fprintf(stderr, "[Server] FATAL: --ref-audio and --ref-text must be given together\n");
        return 1;
    }
    if (locked && (!std::isfinite(position_temperature) || position_temperature < 0.0)) {
        fprintf(stderr, "[Server] FATAL: --position-temperature must be finite and >= 0\n");
        return 1;
    }
    if (locked && (!std::isfinite(class_temperature) || class_temperature < 0.0)) {
        fprintf(stderr, "[Server] FATAL: --class-temperature must be finite and >= 0\n");
        return 1;
    }
    if (ref_text_path) {
        if (!read_text_file(ref_text_path, g_default_voice.ref_text) || g_default_voice.ref_text.empty()) {
            fprintf(stderr, "[Server] FATAL: cannot read a non-empty transcript from %s\n", ref_text_path);
            return 1;
        }
    }

    struct ov_init_params iparams;
    ov_init_default_params(&iparams);
    iparams.model_path = model_path;
    iparams.codec_path = codec_path;
    iparams.use_fa     = use_fa;
    iparams.clamp_fp16 = clamp_fp16;

    struct ov_context * ov = ov_init(&iparams);
    if (!ov) {
        fprintf(stderr, "[Server] FATAL: %s\n", ov_last_error());
        return 1;
    }

    // Same preprocessing as a WAV registered over POST /v1/audio/voices.
    if (ref_audio_path) {
        int     T   = 0;
        float * pcm = audio_read_mono(ref_audio_path, 24000, &T);
        if (!pcm) {
            fprintf(stderr, "[Server] FATAL: cannot decode %s\n", ref_audio_path);
            ov_free(ov);
            return 1;
        }

        enum ov_status rc;
        {
            std::lock_guard<std::mutex> lock(g_synth_mutex);
            rc = ov_extract_voice_ref(ov, pcm, T, &g_default_voice.ref);
        }

        free(pcm);
        if (rc != OV_STATUS_OK) {
            fprintf(stderr, "[Server] FATAL: %s: %s\n", ref_audio_path, ov_last_error());
            ov_free(ov);
            return 1;
        }
        fprintf(stderr, "[Server] default voice from %s (K=%d T=%d)\n", ref_audio_path,
                g_default_voice.ref.num_codebooks, g_default_voice.ref.ref_T);
    }

    tts_backend be;
    be.model_id = basename_of(model_path);
    be.locked   = locked;

    if (locked && position_temperature == 0.0 && class_temperature == 0.0) {
        const size_t code_bytes =
            (size_t) g_default_voice.ref.num_codebooks * (size_t) g_default_voice.ref.ref_T * sizeof(int32_t);
        std::string voice_data((const char *) g_default_voice.ref.ref_codes, code_bytes);
        voice_data.append(g_default_voice.ref_text);
        voice_data.append((const char *) &g_default_voice.ref.ref_T, sizeof(g_default_voice.ref.ref_T));
        voice_data.append((const char *) &g_default_voice.ref.num_codebooks, sizeof(g_default_voice.ref.num_codebooks));
        const uint64_t voice_hash = tts_fnv1a_64(voice_data.data(), voice_data.size());
        char           voice_id[17];
        char           parameters[192];
        std::snprintf(voice_id, sizeof(voice_id), "%016llx", (unsigned long long) voice_hash);
        std::snprintf(parameters, sizeof(parameters),
                      "|seed=%d|steps=%d|position_temperature=%.9g|class_temperature=%.9g", seed, steps,
                      position_temperature, class_temperature);
        const std::string cache_suffix = "voice=" + std::string(voice_id) + "|lang=" + lang + parameters;
        be.cache_key                   = [cache_suffix](const tts_request & req) {
            std::string key = req.input;
            key.push_back('\0');
            key.append(cache_suffix);
            return key;
        };
    }

    if (locked) {
        char cache_status[64];
        if (position_temperature == 0.0 && class_temperature == 0.0) {
            snprintf(cache_status, sizeof(cache_status), "cache=%zu entries", (size_t) TTS_CACHE_MAX_ENTRIES);
        } else {
            snprintf(cache_status, sizeof(cache_status), "cache=off (temperature > 0)");
        }
        fprintf(stderr,
                "[Server] locked: steps=%d seed=%d position_temperature=%.9g class_temperature=%.9g lang=%s %s\n",
                steps, seed, position_temperature, class_temperature, lang.c_str(), cache_status);
    }

    // A WAV payload is encoded server side through the single synthesis
    // context, so the extraction takes g_synth_mutex. An .rvq payload is
    // unpacked in place and needs no GPU. Re-registering a name replaces
    // the previous entry.
    be.register_voice = [ov](const tts_voice_upload & up, std::string & err) -> bool {
        voice_entry entry;
        entry.ref      = {};
        entry.ref_text = up.ref_text;

        if (!up.wav.empty()) {
            int     T   = 0;
            float * pcm = audio_read_mono_buf((const uint8_t *) up.wav.data(), up.wav.size(), 24000, &T);
            if (!pcm) {
                err = "cannot decode the WAV payload";
                return false;
            }
            enum ov_status rc;
            {
                std::lock_guard<std::mutex> lock(g_synth_mutex);
                rc = ov_extract_voice_ref(ov, pcm, T, &entry.ref);
            }
            free(pcm);
            if (rc != OV_STATUS_OK) {
                err = ov_last_error();
                return false;
            }
        } else {
            std::vector<int32_t> codes;
            int                  ref_T = 0;
            const int            K     = ov_num_codebooks(ov);
            if (!rvq_read_buf((const uint8_t *) up.rvq.data(), up.rvq.size(), K, RVQ_CODE_BITS, codes, &ref_T)) {
                err = "'rvq_b64' does not decode to a valid packed code stream";
                return false;
            }
            const size_t codes_bytes = codes.size() * sizeof(int32_t);
            entry.ref.ref_codes      = (int32_t *) malloc(codes_bytes);
            if (!entry.ref.ref_codes) {
                err = "out of memory";
                return false;
            }
            std::memcpy(entry.ref.ref_codes, codes.data(), codes_bytes);
            entry.ref.ref_T         = ref_T;
            entry.ref.num_codebooks = K;
        }

        std::lock_guard<std::mutex> lock(g_voices_mutex);
        auto                        it = g_voices.find(up.name);
        if (it != g_voices.end()) {
            ov_voice_ref_free(&it->second.ref);
            g_voices.erase(it);
        }
        fprintf(stderr, "[Server] voice '%s' registered (K=%d T=%d)\n", up.name.c_str(), entry.ref.num_codebooks,
                entry.ref.ref_T);
        g_voices.emplace(up.name, std::move(entry));
        return true;
    };

    be.remove_voice = [](const std::string & name) -> bool {
        std::lock_guard<std::mutex> lock(g_voices_mutex);
        auto                        it = g_voices.find(name);
        if (it == g_voices.end()) {
            return false;
        }
        ov_voice_ref_free(&it->second.ref);
        g_voices.erase(it);
        return true;
    };

    be.registered_voices = []() -> std::vector<std::string> {
        std::lock_guard<std::mutex> lock(g_voices_mutex);
        std::vector<std::string>    names;
        names.reserve(g_voices.size());
        for (const auto & kv : g_voices) {
            names.push_back(kv.first);
        }
        return names;
    };

    // The adapter always drives the streaming pipeline : on_chunk routes to
    // the shared sink, which either streams to the socket (pcm) or fills a
    // one-shot buffer (wav). OmniVoice streams at chunk_duration_sec
    // granularity, the same path either way. A named voice injects its
    // pre-encoded reference ; an unknown name is rejected instead of
    // silently falling back to voice design. No name uses the startup
    // reference when one is loaded.
    be.synthesize = [ov, &lang, locked, steps, seed, position_temperature, class_temperature](
                        const tts_request & req, const tts_sink & sink, std::string & err) -> int {
        if (locked) {
            struct ov_tts_params p;
            ov_tts_default_params(&p);
            p.text                    = req.input.c_str();
            p.lang                    = lang.c_str();
            p.ref_audio_tokens        = g_default_voice.ref.ref_codes;
            p.ref_T                   = g_default_voice.ref.ref_T;
            p.ref_text                = g_default_voice.ref_text.c_str();
            p.mg_seed                 = seed >= 0 ? (uint64_t) seed : (uint64_t) std::random_device{}();
            p.mg_num_step             = steps;
            p.mg_position_temperature = (float) position_temperature;
            p.mg_class_temperature    = (float) class_temperature;

            const tts_sink * sink_ptr = &sink;
            p.on_chunk                = [](const float * s, int ns, void * u) -> bool {
                return (*static_cast<const tts_sink *>(u))(s, ns);
            };
            p.on_chunk_user_data = (void *) sink_ptr;

            struct ov_audio out = {};
            enum ov_status  rc  = ov_synthesize(ov, &p, &out);
            ov_audio_free(&out);
            if (rc != OV_STATUS_OK) {
                err = ov_last_error();
                return (int) rc;
            }
            return 0;
        }

        struct ov_tts_params p;
        ov_tts_default_params(&p);
        p.text = req.input.c_str();
        p.lang = req.lang.empty() ? lang.c_str() : req.lang.c_str();

        // Copy the registered codes out under the lock: the synthesis runs
        // for seconds, during which another connection may replace or
        // delete the entry.
        std::vector<int32_t> voice_codes;
        std::string          voice_ref_text;
        int                  voice_ref_T = 0;
        if (!req.voice.empty()) {
            std::lock_guard<std::mutex> lock(g_voices_mutex);
            auto                        vit = g_voices.find(req.voice);
            if (vit == g_voices.end()) {
                err = "unknown voice '" + req.voice + "'";
                return (int) OV_STATUS_INVALID_PARAMS;
            }
            const voice_entry & v = vit->second;
            voice_codes.assign(v.ref.ref_codes, v.ref.ref_codes + (size_t) v.ref.num_codebooks * (size_t) v.ref.ref_T);
            voice_ref_T    = v.ref.ref_T;
            voice_ref_text = v.ref_text;
        }
        if (!voice_codes.empty()) {
            p.ref_audio_tokens = voice_codes.data();
            p.ref_T            = voice_ref_T;
            p.ref_text         = voice_ref_text.c_str();
        } else if (req.voice.empty() && g_default_voice.ref.ref_codes) {
            p.ref_audio_tokens = g_default_voice.ref.ref_codes;
            p.ref_T            = g_default_voice.ref.ref_T;
            p.ref_text         = g_default_voice.ref_text.c_str();
        }
        if (!req.instructions.empty()) {
            p.instruct = req.instructions.c_str();
        }

        // Seed resolution mirrors the CLI: negative or absent draws a
        // fresh hardware random seed, anything else lands verbatim on
        // the MaskGIT sampler for reproducible output.
        p.mg_seed = (req.seed < 0) ? (uint64_t) std::random_device{}() : (uint64_t) req.seed;
        if (req.position_temperature >= 0.0f) {
            p.mg_position_temperature = req.position_temperature;
        }
        if (req.class_temperature >= 0.0f) {
            p.mg_class_temperature = req.class_temperature;
        }

        // Trampoline : the C ABI on_chunk forwards to the C++ sink.
        const tts_sink * sink_ptr = &sink;
        p.on_chunk                = [](const float * s, int ns, void * u) -> bool {
            return (*static_cast<const tts_sink *>(u))(s, ns);
        };
        p.on_chunk_user_data = (void *) sink_ptr;

        struct ov_audio out = {};
        enum ov_status  rc  = ov_synthesize(ov, &p, &out);
        ov_audio_free(&out);
        if (rc != OV_STATUS_OK) {
            err = ov_last_error();
            return (int) rc;
        }
        return 0;
    };

    int rc = tts_server_run(be, cfg);
    ov_voice_ref_free(&g_default_voice.ref);
    ov_free(ov);
    return rc;
}
