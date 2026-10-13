#!/usr/bin/env bash
# Generate voice design candidates to pick a new pit wall voice.
#
# The script sweeps accent x pitch x random seeds and writes 12 candidate
# WAVs. Listen to them, pick a timbre, then register the winner as a cloned
# voice. TEXT_PROMPT below becomes the ref_text of that voice. Keep it
# verbatim, because the transcript must match the winning clip word for word.
#
# Voice design needs an unlocked tts-server started without --ref-audio and
# --ref-text. A server with a default voice clones that voice and ignores
# instructions. omnivoice.service.cuda runs --locked with a fixed ref clip, so
# this script starts its own server on another port (default 8081). The
# service on 8080 keeps running.
#
# Both processes load the model and codec into VRAM. Check the headroom with
# nvidia-smi first. If the GPU cannot fit both, stop the service with
# `systemctl --user stop omnivoice.service.cuda` and run the sweep alone.
#
# Usage: ./scripts/sweep-voices.sh [PORT]
# Run it from the repo root. Candidates go to candidate_voices/ as
# voice_<accent>_<pitch>_seed_<seed>.wav. The server log is
# candidate_voices/server.log. The script needs python3 with requests, curl,
# a CUDA build in build/ (./buildcuda.sh) and the GGUF models in models/.
# The server runs on CUDA0. Set GGML_BACKEND to pick another device.
#
# To use the winner, send POST /v1/audio/voices with
# {name, ref_text: TEXT_PROMPT verbatim, wav_b64}. You can also point the
# --ref-audio and --ref-text of the service unit at the winner.

set -euo pipefail
cd "$(dirname "$0")/.."

MODEL=models/omnivoice-base-Q8_0.gguf
CODEC=models/omnivoice-tokenizer-Q8_0.gguf
HOST=127.0.0.1
PORT="${1:-8081}"
OUTPUT_DIR=./candidate_voices
SERVER_LOG="$OUTPUT_DIR/server.log"
HEALTH_TIMEOUT=600
# Pin the GPU so a missing CUDA device fails startup instead of falling back to CPU.
GGML_BACKEND="${GGML_BACKEND:-CUDA0}"
export PORT

command -v curl >/dev/null || { echo "curl is required"; exit 1; }
python3 -c "import requests" 2>/dev/null || { echo "python3 with requests is required"; exit 1; }

mkdir -p "$OUTPUT_DIR"

health_status() {
    curl -s --connect-timeout 5 --max-time 5 -o /dev/null -w "%{http_code}" "http://$HOST:$PORT/health" || true
}

if [ "$(health_status)" = "200" ]; then
    echo "A server is already running on $HOST:$PORT. Stop it or pass another port."
    exit 1
fi

GGML_BACKEND="$GGML_BACKEND" ./build/tts-server --model "$MODEL" --codec "$CODEC" --host "$HOST" --port "$PORT" --lang English \
    >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# SIGTERM lets the server finish the request in flight. Force it after 5 s.
stop_server() {
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
}
trap stop_server EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo -n "Waiting for tts-server (log: $SERVER_LOG) ... "
start_wait=$SECONDS
until [ "$(health_status)" = "200" ]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "server exited during startup:"
        cat "$SERVER_LOG"
        exit 1
    fi
    if [ $((SECONDS - start_wait)) -ge "$HEALTH_TIMEOUT" ]; then
        echo "no /health response after ${HEALTH_TIMEOUT}s"
        exit 1
    fi
    sleep 1
done
echo "ready after $((SECONDS - start_wait))s"

python3 - <<'PY'
import os, random, requests

URL = f"http://127.0.0.1:{os.environ['PORT']}/v1/audio/speech"
OUT = "./candidate_voices"

TEXT_PROMPT = (
    "Box, box, box! Virtual safety car deployed, delta is plus three point four. "
    "Blue flags ahead, let Hamilton through, then push past Verstappen into turn one. "
    "DRS enabled, gap to the car ahead is one point two. "
    "Double yellow at sector two, no overtaking. "
    "Green flag, green flag -- it is hammer time!"
)

ACCENTS = ["british accent", "american accent"]
PITCHES = ["low pitch", "moderate pitch"]
SEEDS_PER_COMBO = 3

total = len(ACCENTS) * len(PITCHES) * SEEDS_PER_COMBO
done = failed = 0
for accent in ACCENTS:
    for pitch in PITCHES:
        instructions = f"male, middle-aged, {pitch}, {accent}"
        for _ in range(SEEDS_PER_COMBO):
            seed = random.randint(0, 2**31 - 1)
            name = f"voice_{accent.split()[0]}_{pitch.split()[0]}_seed_{seed}.wav"
            done += 1
            print(f"[{done}/{total}] {instructions}, seed {seed} ... ", end="", flush=True)
            try:
                r = requests.post(URL, json={
                    "input": TEXT_PROMPT,
                    "instructions": instructions,
                    "language": "English",
                    "response_format": "wav",
                    "seed": seed,
                })
                r.raise_for_status()
            except requests.RequestException as e:
                failed += 1
                print(f"failed: {e}")
                continue
            with open(os.path.join(OUT, name), "wb") as f:
                f.write(r.content)
            print(name)

print(f"{total - failed}/{total} candidates in {OUT}")
PY
