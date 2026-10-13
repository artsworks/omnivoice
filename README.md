# omnivoice.cpp

Local AI text-to-speech with voice cloning and voice design, powered
by GGML. C++17 port of OmniVoice (k2-fsa/OmniVoice). 646 languages,
24 kHz mono output, runs on CPU, CUDA, ROCm, Metal, Vulkan.

## Features

- Voice cloning from a reference WAV plus its transcript
- Voice design via attribute keywords (gender, age, pitch, style,
  volume, emotion)
- Auto voice with consistent speaker identity across long inputs
- Long-form synthesis with punctuation-aware text chunking, voice
  prompt promotion, cross-fade and pydub-strict silence removal
- Bit deterministic generation in greedy mode, seedable Philox PRNG
  for stochastic sampling
- Q8_0 quantisation of the 612 M parameter Qwen3 backbone
- Three tools : `omnivoice-tts` (text -> WAV), `omnivoice-codec`
  (WAV <-> RVQ codes) and `tts-server` (OpenAI-compatible HTTP server
  with a cloned voice registry)

## Build

```
git clone --recurse-submodules https://github.com/ServeurpersoCom/omnivoice.cpp.git
cd omnivoice.cpp
./buildcuda.sh                   # NVIDIA GPU
./buildvulkan.sh                 # AMD/Intel GPU (Vulkan)
./buildcpu.sh                    # CPU only
./buildall.sh                    # all backends, runtime DL loading
NVCC_CCBIN=g++-13 ./buildcuda.sh # rolling release distros (Arch w/ GCC 16, etc.)
```

`-DGGML_SOURCE_DIR=<path>` swaps the ggml submodule for another tree (upstream ggml, llama.cpp/ggml).

## Model conversion

Pre-converted GGUFs are available on Hugging Face :

  https://huggingface.co/Serveurperso/OmniVoice-GGUF

Drop them in `models/` and skip to the quick start. To convert from
the original checkpoint :

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

Pre-encoded reference (`clone.sh`): `omnivoice-codec` encodes a reference WAV
into a compact `.rvq` latent (it applies the exact TTS reference
preprocessing, so the codes are bit-identical to the `--ref-wav` path).
Passing it via `--ref-rvq` skips the codec encode on every synthesis:

```
build/omnivoice-codec --model models/omnivoice-tokenizer-F32.gguf -i ref.wav
build/omnivoice-tts \
    --model models/omnivoice-base-Q8_0.gguf \
    --codec models/omnivoice-tokenizer-F32.gguf \
    --ref-rvq ref.rvq --ref-text ref.txt \
    --lang English -o out.wav < prompt.txt
```

OpenAI-compatible server (`server.sh`, `client.sh`) : `response_format`
"pcm" streams s16le as it is generated, "wav" returns a one-shot file.
Cloned voices register once over HTTP (a WAV encoded server side, or a
`.rvq` from `omnivoice-codec`), stay resident in RAM and are then
selected by name on every request, so a caller holds one voice per
language across turns without touching the disk. `language` overrides
the server default for a single request :

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

A `.rvq` payload must come from the same codec quantisation the server
runs, otherwise the codes are read in the wrong space and the voice is
not the expected one.

`--ref-audio ref.wav --ref-text ref.txt` sets a default voice. A request
without `voice` then clones that clip instead of running voice design. The
transcript must match the clip word for word. `position_temperature` and
`class_temperature` override the MaskGIT sampler per request. Both at 0
give bit deterministic output. See `playground/README.md` for the full
voice lock.

Use `--locked` with a reference clip and transcript to make the server own
the voice, seed, steps, temperatures and language. Clients send only
`input`. Every reply is mono s16 24 kHz `audio/wav`. Other request fields
are ignored. The cache runs only when both temperatures are 0, because only
then does the same text always give the same audio. The seed has no effect at
temperatures 0. Above 0, a random seed gives different output each request.
The LRU cache holds 512 entries and 128 MiB of WAV data.

The server has no `-m`, `--tokenizer`, `-b` or `-fa` flag. Use `--model`
and `--codec`. Flash attention is on by default. Use `--no-fa` to disable
it. `models.sh` downloads only the F32 tokenizer. Get the Q8_0 tokenizer
from Hugging Face with
`hf download Serveurperso/OmniVoice-GGUF omnivoice-tokenizer-Q8_0.gguf --local-dir models`,
or run
`./build/quantize models/omnivoice-tokenizer-F32.gguf models/omnivoice-tokenizer-Q8_0.gguf Q8_0`.
Do not use `./quantize.sh` for the tokenizer. That script quantizes
`omnivoice-base-F32.gguf` first, which `models.sh` does not download, and
then exits because it uses `set -eu`. RVQ codebooks and their fc/fc2
projections stay F32 in every variant.

## Embedding the library

The CLI tools are thin wrappers over a public ABI. Single-header,
single-name-prefix, plain C linkage so that C, C++, Python ctypes,
Rust bindgen and Go cgo all consume it the same way.

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

`tests/abi-c.c` is built with `-std=c99 -Wall -Werror -pedantic` on
every build, so any regression that breaks plain C consumability fails
the build, not just an opt-in target.

For a binding-friendly shared library (libomnivoice.so / .dll / .dylib),
configure with `cmake -DOMNIVOICE_SHARED=ON ...`. The shared target
exports only the `ov_*` symbols ; every internal `pipeline_*` and
`backend_*` stays hidden inside the .so.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the model, the
GGUF layout, the inference pipeline, every CLI flag, the public API
reference and the validation results.

## License

MIT. See [LICENSE](LICENSE).

Upstream model : OmniVoice by Xiaomi / k2-fsa, Apache 2.0.
Audio codec : Higgs Audio v2 (`bosonai/higgs-audio-v2-tokenizer`),
Apache 2.0.
