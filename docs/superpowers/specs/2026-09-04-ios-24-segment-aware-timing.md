# IOS-24 Segment-aware word timing and fallback rendering

## Problem

The IOS-22 rail can pace a response against received audio, but its speech
timing path treats every aligned word as one response-level track. RELAY-07
now sends one timing record per PCM segment, including duration metadata when
alignment is disabled or fails. The client must not let a late, partial, or
older segment record control a newer segment's caption.

## Goal

Render the assistant caption from the active turn's ordered audio segments.
Use validated word timing for an aligned segment, use that segment's duration
for a fallback segment, and preserve the already-visible valid transcript
prefix whenever metadata arrives late or is revised.

## Wire contract

`speech_timing` records contain:

- `segment_id`: stable identity for revisions of one PCM segment;
- `text`: Hermes' normalized spoken text for that segment;
- `timing_source`: `alignment` or `duration_fallback`;
- `audio_offset_ms`: absolute start offset in the inbound audio stream;
- `duration_ms`: positive PCM duration for the segment;
- `words`: complete validated absolute word spans for alignment, or an empty
  list for duration fallback; and
- `fallback_reason` for duration fallback, limited to the relay contract's
  bounded values.

An aligned record is authoritative only when its required fields and complete
word spans are valid. A fallback record is always duration-paced, regardless
of whether an unexpected word list is present. A malformed aligned record with
valid segment identity, text, offset, and duration degrades to duration
pacing; a record without safe segment geometry is ignored and the overall
audio-duration fallback remains available.

## Rendering behavior

- Timing state is reset at the start of each voice or typed response and is
  invalidated when a response is interrupted.
- Segment records are deduplicated by `segment_id`, ordered by
  `audio_offset_ms`, and revised records replace earlier records.
- Each segment's normalized spoken tokens are matched in order against the
  rendered transcript's tokens. Markdown markers, punctuation, case, and
  whitespace differences do not prevent a match; the returned visible text
  always uses the original rendered prefix, including its Markdown and line
  breaks.
- Aligned segments reveal the mapped rendered words whose absolute start time
  has been reached.
- Fallback segments reveal their mapped rendered words proportionally from
  `audio_offset_ms` through `audio_offset_ms + duration_ms`.
- A segment whose mapping or word spans cannot be trusted uses duration
  pacing. If no segment metadata is usable, IOS-22's whole-audio duration
  fallback remains in force.
- Visible text is monotonic for a message. A late or revised candidate may
  advance the stored prefix, never replace it with a shorter or unrelated
  paragraph. The latest assistant message remains the only live caption.

## Non-goals

- Do not enable provider alignment in local or media profiles.
- Do not add microphone upload, remote undo, usage, compression, or a new
  server operation.
- Do not change text-only reveal, history navigation, interruption UX,
  reconnect behavior, or persisted transcript contents.

## Acceptance scenarios

Deterministic tests cover:

1. multiple ordered aligned segments;
2. an aligned segment, a failed middle segment, and a later aligned segment;
3. timing metadata that arrives after the audio clock has advanced;
4. a revised record with the same segment ID;
5. Markdown, punctuation, and paragraph whitespace differences;
6. malformed or partial alignment fields degrading to duration pacing;
7. a new turn and an interrupted turn rejecting stale timing; and
8. absent timing metadata retaining the IOS-22 duration fallback.
