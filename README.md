# omnivoice.cpp

Local text-to-speech with voice cloning and voice design, in C++17 on
GGML. It speaks 646 languages, outputs 24 kHz mono and runs on CPU, CUDA,
ROCm, Metal and Vulkan. This fork is the TTS backend for
[f1-pitwall](https://github.com/artsworks/f1-pitwall).

## Features

- Voice cloning from a reference WAV plus its transcript
- Voice design from attribute keywords (gender, age, pitch, style,
  volume, emotion)
- Auto voice with consistent speaker identity across long inputs
- Long-form synthesis with punctuation-aware text chunking, voice
  prompt promotion, cross-fade and pydub-strict silence removal
- Bit deterministic generation in greedy mode, seedable Philox PRNG
  for stochastic sampling
- Q8_0 quantisation of the 612 M parameter Qwen3 backbone
- Three tools : `omnivoice-tts` (text to WAV), `omnivoice-codec`
  (WAV to RVQ codes and back) and `tts-server` (OpenAI-compatible HTTP
  server with a cloned voice registry)

## Build

```
git clone --recurse-submodules https://github.com/artsworks/omnivoice.git
cd omnivoice
./buildcuda.sh                   # NVIDIA GPU
./buildvulkan.sh                 # AMD/Intel GPU (Vulkan)
./buildcpu.sh                    # CPU only
./buildall.sh                    # all backends, runtime DL loading
NVCC_CCBIN=g++-13 ./buildcuda.sh # rolling release distros (Arch with GCC 16)
```

`-DGGML_SOURCE_DIR=<path>` swaps the ggml submodule for another tree (upstream ggml, llama.cpp/ggml).

## Model conversion

Pre-converted GGUFs are on Hugging Face :

  https://huggingface.co/Serveurperso/OmniVoice-GGUF

Put them in `models/` and skip to the quick start. To convert the
original checkpoint :

```
./checkpoints.sh      # hf download k2-fsa/OmniVoice -> checkpoints/
./convert.py          # 2 GGUFs in BF16 -> models/
./quantize.sh         # base LM Q8_0 (tokenizer stays at native dtype)
```

## Quick start

```
echo "Hello world." | ./build/omnivoice-tts \
    --model models/omnivoice-base-Q8_0.gguf \
    --codec models/omnivoice-tokenizer-F32.gguf \
    --lang English -o hello.wav
```

Voice cloning :

```
./build/omnivoice-tts \
    --model models/omnivoice-base-Q8_0.gguf \
    --codec models/omnivoice-tokenizer-F32.gguf \
    --ref-wav ref.wav --ref-text ref.txt \
    --lang English -o out.wav < prompt.txt
```

`clone.sh` pre-encodes the reference. `omnivoice-codec` writes a `.rvq`
with the same preprocessing as `--ref-wav`, so the codes are bit-identical,
and `--ref-rvq` skips the encode on every synthesis :

```
build/omnivoice-codec --model models/omnivoice-tokenizer-F32.gguf -i ref.wav
build/omnivoice-tts \
    --model models/omnivoice-base-Q8_0.gguf \
    --codec models/omnivoice-tokenizer-F32.gguf \
    --ref-rvq ref.rvq --ref-text ref.txt \
    --lang English -o out.wav < prompt.txt
```

`server.sh` and `client.sh` run the OpenAI-compatible server.
`response_format` "pcm" streams s16le as it generates, and "wav" returns
one file. Register a cloned voice once over HTTP as a WAV or a `.rvq`. The
server keeps it in RAM, and each request picks it by name. `language`
overrides the server default per request :

```
./build/tts-server \
    --model models/omnivoice-base-Q8_0.gguf \
    --codec models/omnivoice-tokenizer-F32.gguf \
    --port 8080

curl -X POST localhost:8080/v1/audio/voices -H "Content-Type: application/json" \
    -d "{\"name\":\"freeman\",\"ref_text\":\"$(cat ref.txt)\",
         \"rvq_b64\":\"$(base64 -w0 ref.rvq)\"}"

curl -X POST localhost:8080/v1/audio/speech -H "Content-Type: application/json" \
    -d '{"input":"Hello world.","voice":"freeman","language":"English",
         "response_format":"wav","seed":42}' -o out.wav
```

A `.rvq` must come from the codec quantisation the server runs, or the
voice sounds wrong.

The server has no `-m`, `--tokenizer`, `-b` or `-fa` flag. Flash attention
is on unless you pass `--no-fa`. `models.sh` downloads only the F32
tokenizer. For Q8_0, run
`hf download Serveurperso/OmniVoice-GGUF omnivoice-tokenizer-Q8_0.gguf --local-dir models`
or
`./build/quantize models/omnivoice-tokenizer-F32.gguf models/omnivoice-tokenizer-Q8_0.gguf Q8_0`.
Do not use `./quantize.sh` for the tokenizer. It quantizes
`omnivoice-base-F32.gguf` first, which `models.sh` does not download, and
fails. RVQ codebooks and their fc/fc2 projections stay F32
in every variant.

`--ref-audio ref.wav --ref-text ref.txt` sets a default voice. A request
without `voice` then clones that clip instead of running voice design. The
transcript must match the clip word for word. The request fields
`position_temperature` and `class_temperature` override the MaskGIT
sampler. Both at 0 give bit deterministic output.

## Used by f1-pitwall

f1-pitwall calls `tts-server` over HTTP as its `omnivoice` speech engine.
`omnivoice.service.cuda` runs it with `--locked`, a fixed `--ref-audio` and
`--ref-text`, `--steps 8`, `--seed 0`, `--position-temperature 0` and
`--class-temperature 0`. `omnivoice.service` is the unlocked unit.
Clients send only `input` and get mono s16 24 kHz `audio/wav`. If both
temperatures are 0, an LRU cache of 512 entries and 128 MiB serves
repeated phrases.

`scripts/benchmark-pitwall.sh` times 20 pit wall lines and checks for a
byte-identical cache hit. `playground/README.md` covers the voice lock.

`scripts/sweep-voices.sh` writes voice design candidates to
`candidate_voices/` to pick a new `--ref-audio`. It starts an unlocked
`tts-server` on `CUDA0` and port 8081 (or its first argument), so the
locked service keeps running. Its fixed prompt becomes the `--ref-text`,
so keep it verbatim. Both servers load the model into VRAM. If they do not
fit, stop the service first.

## Embedding the library

The CLI tools wrap a public C ABI in one header (`omnivoice.h`, prefix
`ov_`), usable from C, C++, Python ctypes, Rust bindgen and Go cgo.

```c
#include "omnivoice.h"

struct ov_init_params iparams;
ov_init_default_params(&iparams);
iparams.model_path = "models/omnivoice-base-Q8_0.gguf";
iparams.codec_path = "models/omnivoice-tokenizer-F32.gguf";

struct ov_context * ov = ov_init(&iparams);

struct ov_tts_params params;
ov_tts_default_params(&params);
params.text = "Hello world.";
params.lang = "English";

struct ov_audio audio = { 0 };
ov_synthesize(ov, &params, &audio);
/* audio.samples, audio.n_samples, audio.sample_rate, audio.channels */
ov_audio_free(&audio);
ov_free(ov);
```

Every build compiles `tests/abi-c.c` with `-std=c99 -Wall -Werror
-pedantic`. `cmake -DOMNIVOICE_SHARED=ON ...` builds a shared library
(libomnivoice.so / .dll / .dylib) that exports only the `ov_*` symbols.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers the internals, every
CLI flag and the public API.

## License

MIT. See [LICENSE](LICENSE).

Fork of [ServeurpersoCom/omnivoice.cpp](https://github.com/ServeurpersoCom/omnivoice.cpp),
a C++17 port of OmniVoice.

Upstream model : OmniVoice by Xiaomi / k2-fsa, Apache 2.0.
Audio codec : Higgs Audio v2 (`bosonai/higgs-audio-v2-tokenizer`),
Apache 2.0.
