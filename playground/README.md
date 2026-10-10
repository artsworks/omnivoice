# Voice lock for pit wall radio

These settings keep one speaker across every request, with no drift and no gender flips.

## What locks the voice

The voice is locked only when all three settings below are in place:

- The reference clip. Start `tts-server` with `--ref-audio audio/reference-01.wav --ref-text audio/reference-01.txt`. A request without `voice` then clones that clip. A request with `voice` clones a clip that you registered over `POST /v1/audio/voices`.
- Both sampler temperatures at 0. Send `"position_temperature": 0` and `"class_temperature": 0`. The MaskGIT decoder is then greedy and bit deterministic.
- A fixed integer `seed`. The server ignores the seed when both temperatures are 0. Send it anyway, because a request that raises a temperature then stays reproducible.

Do not send `instructions`. The clip sets the speaker identity, and an instruct string only pulls the voice away from the clip.

Without `--ref-audio` and without `voice`, the server runs voice design. Voice design picks a new speaker for each request, and this is the drift.

## Reference transcript

`--ref-text` is a file that holds the words spoken in `--ref-audio`. The model uses the transcript to align the clip, so it must match the clip word for word. If you replace `reference-01.wav`, update `reference-01.txt` too.

`audio/reference-01.wav` is a clean clip of one female speaker with a British accent, 7.9 s long.

## Example request

```
curl -X POST localhost:8080/v1/audio/speech -H "Content-Type: application/json" \
    -d '{"input":"Box this lap.","language":"English","response_format":"wav",
         "seed":42,"position_temperature":0,"class_temperature":0}' -o out.wav
```

`scripts/benchmark-pitwall.sh` sends 20 requests with these settings.

## Temperature is not an urgency control

Temperature controls only how random the decoding is. A higher temperature gives a less predictable voice, not a more urgent one. Keep both temperatures at 0 for radio calls.

Get urgency from a separate mechanism, for example:

- Piper speaking rate or expression settings.
- Chatterbox `exaggeration`.

The request still exposes both temperatures, so you can test them on their own without a change to the urgency setup.

## Loudness

The server keeps a reference as RVQ codes only. This applies to `--ref-audio` and to every registered voice. The RMS of the source clip is lost, so the output gets peak normalisation and does not match the loudness of the reference. Set the playback level on the client.
