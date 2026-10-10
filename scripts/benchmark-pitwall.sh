#!/bin/bash

# Configuration
MODEL="models/omnivoice-base-Q8_0.gguf"
CODEC="models/omnivoice-tokenizer-F32.gguf"
INSTRUCT="male, young adult, moderate pitch, australian accent"
STEPS=14
SEED=42
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
    " DRS is now enabled. You are within one second of the car ahead."
    "Brake temperatures are critical. Clear the air ducts on the straight."
    "That is the end of the session. Bring the car home."
    "Engine temps are slightly high, try to get some clean air."
    "Understood, we are checking the strategy now."
)

echo "=================================================="
echo "Starting OmniVoice Benchmark: 20 Sequential Calls"
echo "=================================================="
echo "Model: $MODEL"
echo "Steps: $STEPS"
echo "--------------------------------------------------"

total_time=0
count=0

for line in "${chatter_lines[@]}"; do
    count=$((count + 1))
    echo -n "[$count/20] Generating: \"$line\" ... "
    
    # Track starting time in nanoseconds
    start_time=$(date +%s%N)
    
    # Execute the TTS pipeline
    echo "$line" | ./build/omnivoice-tts \
      --model "$MODEL" \
      --codec "$CODEC" \
      --lang English \
      --instruct "$INSTRUCT" \
      --steps $STEPS \
      --seed $SEED \
      -o "$OUTPUT_DIR/call_$count.wav" > /dev/null 2>&1
      
    # Track ending time
    end_time=$(date +%s%N)
    
    # Calculate execution duration in seconds
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
