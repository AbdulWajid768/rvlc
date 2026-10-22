# Subtitle and audio synchronisation

## Conventions

| Control | Positive value | Negative value |
|---|---|---|
| Subtitle offset | subtitles appear **later** | subtitles appear **earlier** |
| Audio delay | audio plays **later** than the picture | audio plays **earlier** than the picture |

Rule of thumb: if subtitles show up *before* the line is spoken, press **+**
(X). If you hear voices *before* lips move, press **+** on the audio delay (V).

Both are independent: changing one never changes the other (covered by
integration tests against libmpv, including after seeks and track switches).

## The timing model

Each imported subtitle is parsed into a document of cues with integer
millisecond timestamps. The correction is a separate transform:

```
displayed = scale × original + offset
```

- `offset` (ms) is applied live through libmpv's `sub-delay`.
- `scale` corrects linear drift (frame-rate mismatches). When it is not 1, a
  preview file with scaled times is generated and attached to the player.
- The original cue times are never changed by offset adjustments, so repeated
  adjustments cannot accumulate errors. Line edits in the editor *do* change the
  document (that is their purpose) and are undoable.
- Export applies the same transform, validates the result (lines that would
  end before 0:00 are omitted, lines that would start before 0:00 are clamped,
  end ≥ start is enforced) and reports every adjustment it made.

## Manual sync with reference points

1. Play until a recognisable line is spoken and pause.
2. In Subtitle Studio, select that line in the list (*Find Current Line* helps).
3. Click **Sync Line to Now** (or press **Y**).

With one point the suggestion is a constant offset (`media − subtitle`). With
two or more points at least a minute apart, a least-squares line `a·t + b` is
fitted. The linear model is only proposed when it reduces the error clearly
(it must reduce the RMS error by at least 100 ms); implausible scales
(outside 0.8–1.25) are rejected with an explanation. A fitted scale within
0.0003 of a common frame-rate ratio (23.976↔25, 24↔25, 23.976↔24, 29.97↔25) is
snapped to the closest such ratio, but only if snapping does not make the fit
worse (23.976→25 and 24→25 differ by just 0.001). A single
mis-clicked point has limited influence because the constant model uses the
median offset.

## Automatic sync from audio

*Analyze Audio* decodes the currently selected audio track to 16 kHz mono PCM
with a private, headless libmpv instance (`ao=pcm`) and analyses it in
fixed-size chunks, so memory use stays at a few megabytes even for a
three-hour film. Then it:

1. Band-pass filters to 300–3400 Hz (vDSP biquads) and computes energy in
   10 ms frames.
2. Marks frames above an adaptive threshold (noise floor + max(6 dB, 35 % of
   the dynamic range)), fills gaps ≤ 200 ms and removes bursts < 80 ms.
3. Builds the same 10 ms grid of "a subtitle is on screen".
4. Cross-correlates both ±1 signals with an FFT (vDSP), normalises each lag by
   the length of the overlap (so large offsets are not penalised), and picks
   the lag with the highest agreement within ±60 s (at most half the file);
   repeats for common frame-rate ratios and only prefers a drift model if it
   agrees at least 1 percentage point better.
5. Reports agreement and a **confidence** based on how much the best alignment
   beats the best alternative more than one second away.

The result is always a **suggestion**: preview it, then apply or discard. It
can be wrong for music videos, silent films, commentary tracks, or subtitles
whose timing does not follow speech (e.g. SDH with many sound descriptions).
Subtitle timestamps alone cannot reveal an offset — the audio (or your
reference points) is the shared reference.

Nothing is uploaded; the temporary PCM file is deleted immediately after use.

## Audio sync

The Audio Sync Lab sets libmpv's `audio-delay`. The value is passed with each
`loadfile` as a file-local option, so it never leaks into the next file, and it
is remembered per file in the local library. External audio files (e.g. a dub)
are added with `audio-add`; the delay applies to whichever audio track is
active.

## Encoding

UTF-8 (with or without BOM) and UTF-16 with BOM are detected exactly. Other
files fall back to Windows-1252 with a visible warning, and any common encoding
can be chosen manually. Preview files and default exports are UTF-8; exports
can use the original encoding when every character fits (otherwise UTF-8 is
used and the user is told).
