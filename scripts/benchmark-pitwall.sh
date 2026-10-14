#!/bin/bash
# Time 20 pit wall lines against one tts-server with the voice locked.
#
# The script starts its own tts-server with the reference clip, waits for
# /health, sends every line over HTTP and stops the server on exit. The model
# stays loaded across all 20 calls.
#
# The server is locked. It owns the seed, steps, temperatures, voice and
# language, and sets the default response format. A PCM check verifies that
# streaming fills the WAV cache.
#
# The server runs 8 MaskGIT steps. The old CLI benchmark used --steps 14
# and the server default is 32, so timings are not comparable.
#
# Usage: scripts/benchmark-pitwall.sh [host] [port]
# Run it from any directory. Paths resolve from the repo root.

cd "$(dirname "$0")/.." || exit 1

HOST="${1:-127.0.0.1}"
PORT="${2:-8080}"
MODEL="models/omnivoice-base-Q8_0.gguf"
CODEC="models/omnivoice-tokenizer-F32.gguf"
REF_AUDIO="audio/reference-01.wav"
REF_TEXT="audio/reference-01.txt"
LANGUAGE="English"
STEPS=8
SEED=0
POSITION_TEMPERATURE=0
CLASS_TEMPERATURE=0
OUTPUT_DIR="./bench_outputs"
SERVER_LOG="$OUTPUT_DIR/server.log"
HEALTH_TIMEOUT=600

mkdir -p "$OUTPUT_DIR"

# Array of 20 realistic F1 pit wall chatter variations
chatter_lines=(
    "Copy that, box this lap. Box this lap."
    "Watch the fronts, surface temperatures are climbing."
    "Yellow flag in sector two. Stay alert."
    "Pace is good, you are matching the car ahead."
    "Gap to the car behind is growing, now three point two seconds."
    "Fuel margin is negative zero point one laps. Switch to lean mix."
    "We are looking at plan B. Confirm if you can extend this stint."
    "Lock up detected turn one. Check your brake bias."
    "You have wing damage. Copy that, we see it on the telemetry."
    "Clear air ahead, push now. Use the overtake button."
    "Safety car deployed. Reduce your speed, manage the delta."
    "Great job, that is P3. Solid lap."
    "The car ahead is pitting. Let us try the overcut."
    "Watch the curbs at turn four, you are pushing track limits."
    "Rain expected in five minutes. Stay out on the slicks for now."
    "DRS is now enabled. You are within one second of the car ahead."
    "Brake temperatures are critical. Clear the air ducts on the straight."
    "That is the end of the session. Bring the car home."
    "Engine temps are slightly high, try to get some clean air."
    "Understood, we are checking the strategy now."
)

for tool in curl jq bc flock ss; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool is required"
        exit 1
    fi
done

# Runs from this checkout share the output files, so only one runs at a time.
exec 9>"$OUTPUT_DIR/.lock"
if ! flock -n 9; then
    echo "Another benchmark is using $OUTPUT_DIR. Wait for it to finish."
    exit 1
fi

health_status() {
    curl -s --connect-timeout 5 --max-time 5 -o /dev/null -w "%{http_code}" "http://$HOST:$PORT/health"
}

# A server already on the port would answer /health and get benchmarked
# instead of ours.
if [ "$(health_status)" = "200" ]; then
    echo "A server is already running on $HOST:$PORT. Stop it or pass another port."
    exit 1
fi

./build/tts-server \
    --model "$MODEL" \
    --codec "$CODEC" \
    --ref-audio "$REF_AUDIO" --ref-text "$REF_TEXT" \
    --host "$HOST" --port "$PORT" --lang "$LANGUAGE" \
    --locked --steps "$STEPS" --seed "$SEED" \
    --position-temperature "$POSITION_TEMPERATURE" --class-temperature "$CLASS_TEMPERATURE" \
    >"$SERVER_LOG" 2>&1 9>&- &
SERVER_PID=$!

# SIGTERM lets the server finish the request in flight, which takes minutes on
# CPU. Force it after 5 s so Ctrl-C returns promptly.
stop_server() {
    kill "$SERVER_PID" 2>/dev/null
    for _ in 1 2 3 4 5; do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
}
trap stop_server EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Another process can bind the port while our server loads. Only accept
# /health once SERVER_PID owns the listening socket.
owns_port() {
    ss -Hltnp "sport = :$PORT" | grep -q "pid=$SERVER_PID,"
}

echo -n "Waiting for tts-server (log: $SERVER_LOG) ... "
start_wait=$SECONDS
until [ "$(health_status)" = "200" ] && owns_port; do
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

echo "=================================================="
echo "Starting OmniVoice Benchmark: 20 Sequential Calls"
echo "=================================================="
echo "Server: http://$HOST:$PORT  Voice: $REF_AUDIO"
echo "Seed: $SEED  Temperatures: position $POSITION_TEMPERATURE, class $CLASS_TEMPERATURE"
echo "--------------------------------------------------"

total_time=0
count=0

for line in "${chatter_lines[@]}"; do
    count=$((count + 1))
    echo -n "[$count/20] Generating: \"$line\" ... "

    body=$(jq -cn \
        --arg input "$line" \
        '{input: $input}')

    # Bash defers traps until a foreground command returns. Running curl in
    # the background and waiting on it lets SIGTERM stop the run mid-request.
    start_time=$(date +%s%N)
    curl -s -o "$OUTPUT_DIR/call_$count.wav" -w "%{http_code}" -X POST "http://$HOST:$PORT/v1/audio/speech" \
        -H "Content-Type: application/json" -d "$body" >"$OUTPUT_DIR/.status" &
    wait $!
    end_time=$(date +%s%N)
    status=$(cat "$OUTPUT_DIR/.status")

    if [ "$status" != "200" ]; then
        echo "HTTP $status: $(cat "$OUTPUT_DIR/call_$count.wav")"
        exit 1
    fi

    duration=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc)
    echo "${duration}s"

    total_time=$(echo "scale=3; $total_time + $duration" | bc)
done

repeat_line="${chatter_lines[0]}"
repeat_body=$(jq -cn --arg input "$repeat_line" '{input: $input}')
repeat_start=$(date +%s%N)
curl -s -o "$OUTPUT_DIR/call_repeat.wav" -w "%{http_code}" -X POST "http://$HOST:$PORT/v1/audio/speech" \
    -H "Content-Type: application/json" -d "$repeat_body" >"$OUTPUT_DIR/.repeat-status" &
wait $!
repeat_end=$(date +%s%N)
repeat_status=$(cat "$OUTPUT_DIR/.repeat-status")
if [ "$repeat_status" != "200" ]; then
    echo "Repeat request failed with HTTP $repeat_status: $(cat "$OUTPUT_DIR/call_repeat.wav")"
    exit 1
fi
repeat_duration=$(echo "scale=3; ($repeat_end - $repeat_start) / 1000000000" | bc)
if cmp -s "$OUTPUT_DIR/call_repeat.wav" "$OUTPUT_DIR/call_1.wav"; then
    echo "Repeat of line 1 (cache hit): ${repeat_duration}s, identical audio: yes"
else
    echo "Repeat of line 1 (cache hit): ${repeat_duration}s, identical audio: no"
    exit 1
fi

stream_line="Streamed check, box box."
stream_body=$(jq -cn --arg input "$stream_line" '{input: $input, response_format: "pcm"}')
pcm_start=$(date +%s%N)
curl -s -o "$OUTPUT_DIR/call_stream.pcm" -w "%{http_code}" -X POST "http://$HOST:$PORT/v1/audio/speech" \
    -H "Content-Type: application/json" -d "$stream_body" >"$OUTPUT_DIR/.stream-pcm-status" &
wait $!
pcm_end=$(date +%s%N)
pcm_status=$(cat "$OUTPUT_DIR/.stream-pcm-status")
if [ "$pcm_status" != "200" ]; then
    echo "PCM stream failed with HTTP $pcm_status: $(cat "$OUTPUT_DIR/call_stream.pcm")"
    exit 1
fi
if [ ! -s "$OUTPUT_DIR/call_stream.pcm" ]; then
    echo "PCM stream returned an empty body"
    exit 1
fi
pcm_duration=$(echo "scale=3; ($pcm_end - $pcm_start) / 1000000000" | bc)

wav_body=$(jq -cn --arg input "$stream_line" '{input: $input}')
wav_start=$(date +%s%N)
curl -s -o "$OUTPUT_DIR/call_stream.wav" -w "%{http_code}" -X POST "http://$HOST:$PORT/v1/audio/speech" \
    -H "Content-Type: application/json" -d "$wav_body" >"$OUTPUT_DIR/.stream-wav-status" &
wait $!
wav_end=$(date +%s%N)
wav_status=$(cat "$OUTPUT_DIR/.stream-wav-status")
if [ "$wav_status" != "200" ]; then
    echo "WAV request after PCM stream failed with HTTP $wav_status: $(cat "$OUTPUT_DIR/call_stream.wav")"
    exit 1
fi
wav_duration=$(echo "scale=3; ($wav_end - $wav_start) / 1000000000" | bc)
pcm_size=$(stat -c %s "$OUTPUT_DIR/call_stream.pcm")
wav_size=$(($(stat -c %s "$OUTPUT_DIR/call_stream.wav") - 44))
if [ "$wav_size" -eq "$pcm_size" ]; then
    same_length=yes
else
    same_length=no
fi
echo "Wav after pcm stream (cache hit): ${wav_duration}s, stream ${pcm_duration}s, same length: ${same_length}"
if [ "$same_length" != yes ] || (( (wav_end - wav_start) * 2 >= pcm_end - pcm_start )); then
    echo "WAV request did not confirm a PCM-filled cache hit"
    exit 1
fi

average_time=$(echo "scale=3; $total_time / 20" | bc)

echo "=================================================="
echo "BENCHMARK RESULTS"
echo "=================================================="
echo "Total Time for 20 calls: ${total_time}s"
echo "Average Time per call:   ${average_time}s"
echo "=================================================="
