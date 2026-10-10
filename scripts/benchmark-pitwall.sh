#!/bin/bash
# Time 20 pit wall lines against a running tts-server with the voice locked.
#
# Start the server with the reference clip first (see omnivoice.service):
#   build/tts-server --model ... --codec ... \
#       --ref-audio audio/reference-01.wav --ref-text audio/reference-01.txt
#
# Every request sends a fixed seed, both MaskGIT temperatures at 0 and no
# instructions, so the voice comes from the reference clip alone.
#
# Usage: scripts/benchmark-pitwall.sh [host] [port] [voice]
#   voice: a name registered over POST /v1/audio/voices. Empty uses the
#   server startup reference.

HOST="${1:-127.0.0.1}"
PORT="${2:-8080}"
VOICE="${3:-}"
LANGUAGE="English"
SEED=42
POSITION_TEMPERATURE=0
CLASS_TEMPERATURE=0
OUTPUT_DIR="./bench_outputs"

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

voice_field=""
if [ -n "$VOICE" ]; then
    voice_field="\"voice\":\"$VOICE\","
fi

echo "=================================================="
echo "Starting OmniVoice Benchmark: 20 Sequential Calls"
echo "=================================================="
echo "Server: http://$HOST:$PORT  Voice: ${VOICE:-startup reference}"
echo "Seed: $SEED  Temperatures: position $POSITION_TEMPERATURE, class $CLASS_TEMPERATURE"
echo "--------------------------------------------------"

total_time=0
count=0

for line in "${chatter_lines[@]}"; do
    count=$((count + 1))
    echo -n "[$count/20] Generating: \"$line\" ... "

    body="{\"input\":\"$line\",${voice_field}\"language\":\"$LANGUAGE\",\"response_format\":\"wav\",\"seed\":$SEED,\"position_temperature\":$POSITION_TEMPERATURE,\"class_temperature\":$CLASS_TEMPERATURE}"

    start_time=$(date +%s%N)
    status=$(curl -s -o "$OUTPUT_DIR/call_$count.wav" -w "%{http_code}" -X POST "http://$HOST:$PORT/v1/audio/speech" \
        -H "Content-Type: application/json" -d "$body")
    end_time=$(date +%s%N)

    if [ "$status" != "200" ]; then
        echo "HTTP $status: $(cat "$OUTPUT_DIR/call_$count.wav")"
        exit 1
    fi

    duration=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc)
    echo "${duration}s"

    total_time=$(echo "scale=3; $total_time + $duration" | bc)
done

average_time=$(echo "scale=3; $total_time / 20" | bc)

echo "=================================================="
echo "BENCHMARK RESULTS"
echo "=================================================="
echo "Total Time for 20 calls: ${total_time}s"
echo "Average Time per call:   ${average_time}s"
echo "=================================================="
