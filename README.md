# gertrude-steinema

Claude Code edits videos. You hand it a folder of clips, a few songs, a prompt
("make a happy vacation video"), and optionally a reference video whose style it
should copy. It returns a rendered MP4.

This file is the tech-stack decision, researched 2026-10-19. Nothing is built yet.
The bar is "a skilled editor with taste", not "a beat-synced slideshow". The
three sections marked **(quality)** are what separate the two.

## Setup

```bash
./setup.sh
```
Pop!_OS / Ubuntu / Debian and macOS natively; Windows 11 inside a WSL2 Ubuntu
shell. The script installs ffmpeg and wget from the system package manager,
installs `uv`, creates `.venv` once (Python 3.12, downloaded if the system lacks
it), installs `requirements.txt`, and ends with a doctor check that prints
versions, the torch device, and any missing ffmpeg filters. Re-running only
checks; nothing is rebuilt. On Linux without an NVIDIA GPU it pulls the CPU torch
wheel to skip a 2.5 GB download.

Platform swaps, handled by markers in `requirements.txt` and at runtime:

| | Apple Silicon | Linux / WSL2 |
|---|---|---|
| Transcription | mlx-whisper | faster-whisper (CTranslate2, CUDA or CPU int8) |
| torch device | MPS | CUDA if `nvidia-smi` exists, else CPU |
| Draft encoder | `hevc_videotoolbox` | `h264_nvenc`, `h264_vaapi`, else `libx264 -preset ultrafast` |

The local VLM option (mlx-vlm) is Mac-only; on Linux the same role goes to
Qwen3-VL through Ollama or vLLM if it is ever needed.

## The one idea everything hangs on

**Claude never watches video. It reads video.** Every tool below turns pixels and
audio into small JSON files and contact-sheet JPEGs. Claude reads those, writes
one `edit.json`, and a dumb renderer executes it with ffmpeg. Claude's own vision
(the `Read` tool opens images) is the primary visual-understanding model; local
ML models only pre-digest and rank so Claude looks at less, and at the right
frames.

```
clips/ music/ reference.mp4 prompt
        │
        ▼  tools/*.py  (each writes JSON, idempotent, cached by file hash)
analysis/
  clips/<name>.json        shots, transcript, audio events, motion, faces, per-frame scores
  clips/<name>.sheet.jpg   contact sheet, 1 frame/sec, timestamp in each cell
  clips/<name>.dense/      8 fps sheets around action peaks and candidate cuts
  music/<song>.json        bpm, beats, downbeats, energy per beat, sections
  reference/style.json     cut rhythm, transition mix, color, motion, beat-sync ratio
        │
        ▼  Claude reads analysis + prompt + playbook, writes
concept.md                 story beats, hero shots, where the drop lands, look
edit.json                  video segments, audio timeline, sfx, look, titles
        │
        ▼  tools/render.py --proxy   (540p, seconds)
out/proxy.mp4 → tools/review.py → cut sheets + QC report → Claude revises edit.json
        │   (2–3 passes)
        ▼  tools/render.py
out/final.mp4 → tools/style.py → compare to reference/style.json
```

## This machine

| | |
|---|---|
| Hardware | Apple M1, 16 GB unified memory, macOS 14.1.1 |
| ffmpeg | 8.1.2 (Homebrew). Has `xfade` (58 transitions), `setpts`, `minterpolate`, `zoompan`, `crop` with time expressions, `deshake`, `noise`, `curves` presets, `lut3d`, `haldclut`, `colortemperature`, `vibrance`, `exposure`, `adelay`, `amix` (with `normalize`), `sidechaincompress`, `loudnorm`, `ebur128`, `astats`, `aevalsrc`, `anoisesrc`, `scdet`, `signalstats`, `tile`, `blackdetect`, `freezedetect`, VideoToolbox H.264/HEVC/ProRes encoders. **Lacks** `drawtext`, `vidstab`, `rubberband`, and the new `whisper` filter. |
| Python | 3.10 default (too old). Homebrew has 3.12 and 3.13. Use 3.12 via `uv`. |
| Node | 24.11 (only needed if Remotion is ever added) |
| NLEs | none installed |

## Stack

One sentence of why per pick. Versions are what PyPI served on 2026-10-19.

### Rendering: **ffmpeg** (already installed) driven by `tools/render.py`
ffmpeg is the lowest-level building block that exists, is already on the
machine, and every alternative (MLT, Resolve, Remotion) ends up calling it anyway.
- Hard cuts: render each segment to a uniform intermediate, then concat demuxer. Fast and frame-accurate.
- Encode drafts with `hevc_videotoolbox` (hardware, seconds), finals with `libx264 -crf 18` (plays everywhere).

Considered and rejected: **MLT/melt** (great transition engine, but the only OTIO bridge, `otio-mlt-adapter` 0.3.0, is from 2021 and targets Python 3.8); **MoviePy** (a Python wrapper over ffmpeg that is slower and hides the filter graph); **Remotion** (renders through headless Chrome, wrong tool for 4K camera footage, but see "Titles" below).

### Render vocabulary **(quality)**
A renderer that only does cuts and dissolves makes slideshows. These are the
moves a skilled editor uses on music-driven pieces; every one is an ffmpeg
filter on this build, so the renderer grows to roughly 500 lines, not a new tool.

| Move | How | Notes |
|---|---|---|
| Speed ramp | Segment carries a list of `speed` pieces; renderer trims each piece, applies `setpts=PTS/speed`, conforms with `fps=30`, concatenates. Three to five short steps read as an eased ramp. | For true slow-mo, **check source fps first**: iPhone 60/120 fps clips give 0.5x/0.25x for free. Only 30 fps sources need frame synthesis: `minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:vsbmc=1`, or `rife-ncnn-vulkan` (macOS binary, runs on M1 single-threaded) when minterpolate smears. Clip audio under a ramp is usually dropped; if kept, chain `atempo` (0.5–2.0 per stage). |
| Hold / freeze | `tpad=stop_mode=clone:stop_duration=0.4` | Landing a drop on a frozen peak frame. |
| Punch-in / reframe | `crop=w:h:x(t):y(t)` with `t` expressions, then `scale=1920:1080`. `zoompan` for slow push-ins, always with explicit `fps=` and `d=1` or it desyncs. | 4K sources give 2x headroom. Auto-reframe targets come from face positions (below). |
| J-cut / L-cut | Audio is its own timeline in `edit.json` (below). Each event: `atrim`, `asetpts=PTS-STARTPTS`, `adelay=<ms>:all=1`, `afade`; then `amix=inputs=N:normalize=0:duration=longest`. | This is the single biggest "feels edited" lever: the next shot's sound arrives before its picture, or a laugh carries over a cut. |
| Nat-sound bed | The clip's own ambience at about -18 dB under music, carried across cuts (an L-cut by construction). | Sets the acoustic space and hides cuts. |
| Ducking | `[music][voice]sidechaincompress=threshold=0.05:ratio=8:attack=20:release=300` | Music drops under speech automatically. Target voice 3–6 dB over music. |
| Silence before impact | `volume=enable='between(t,a,b)':volume=0` on the music for 0.2–0.4 s before the drop. | Trailer trick, works on travel pieces. |
| Risers / whooshes / impacts | MVP: synthesize license-free with `aevalsrc` (frequency sweep) and `anoisesrc` + `afade` + `lowpass`. Real libraries: Sonniss GDC bundles (royalty-free commercial, no attribution), Freesound with the CC0 filter (free API key), Pixabay. | Keep a `sfx/` folder of 10–20 files; Claude picks by name. |
| Loudness | `loudnorm=I=-14:TP=-1.5:LRA=11` as the last audio step. | Streaming-platform target. |
| Transitions | Cuts first. `fade`/`fadeblack` for section breaks, `dissolve` rarely, directional `smoothleft`/`hblur`/`zoomin` only when the outgoing shot's motion direction motivates it. `xfade=transition=custom:expr=` for anything else. | 58 built-in kinds; the playbook forbids gimmicks. |
| Grade | A base look per film: `curves=preset=vintage` or a `.cube` via `lut3d`, plus `colortemperature`, `vibrance`, `exposure`, `vignette`. Grain: `noise=alls=6:allf=t+u`. `deflicker` for timelapses. | Free LUT packs: Q-DDL 800+ cubes (CC-BY 4.0), Freevisuals 22-pack (commercial OK). |
| Shot matching | **color-matcher 0.6.0** (`mkl`, `reinhard`, `hm` methods) on sampled frames of each clip vs. a hero frame; bake the transfer into a 33-point `.cube` by passing an identity HALD image through it; apply with `lut3d`. Blend strength 0.5–0.8 so clips don't go flat. | Exposure and white-balance drift between clips is the most visible amateur tell. |
| Stabilization | Phone footage is already stabilized; leave it. For action-cam or still frames: `deshake` (mild), or **vidstab 1.7.4** (pip, OpenCV-based) for proper two-pass. ffmpeg's `vidstab` filters need the `varenc/homebrew-ffmpeg` tap build. | Stabilize before cropping, never after. |
| Titles / cards | **Pillow 13** renders text to PNG with alpha; `overlay` with `enable='between(t,a,b)'`, `format=rgba,fade=t=in:alpha=1` for fades. Remotion only if animated typography is wanted. | Brew ffmpeg has no `drawtext`; Pillow is the text engine throughout. |

Rejected: masked or object-aware transitions (After Effects territory, low payoff on
montage work); Gyroflow (needs gyro logs phones don't export).

### Edit plan: **a custom, flat `edit.json`** + optional OTIO export
Claude writes it, so the schema is optimized for an LLM to author without
arithmetic: video segments are ordered and the renderer computes their timeline
positions; the audio timeline is absolute because split edits need it.

```json
{
  "output": { "path": "out/final.mp4", "width": 1920, "height": 1080, "fps": 30 },
  "look": { "lut": "luts/kodak_warm.cube", "lut_strength": 0.7, "match_to": "clips/IMG_0031.mov@4.0",
            "grain": 6, "vignette": 0.2, "temperature": 5600 },
  "segments": [
    { "src": "clips/IMG_0012.mov", "in": 3.20, "out": 5.60 },
    { "src": "clips/IMG_0019.mov", "in": 0.00, "out": 2.40,
      "speed": [ { "until": 0.6, "x": 1.0 }, { "until": 1.6, "x": 0.25 }, { "until": 2.4, "x": 1.0 } ],
      "reframe": { "from": [0.5, 0.45, 1.0], "to": [0.55, 0.40, 0.75] },
      "transition_in": { "type": "smoothleft", "duration": 0.3 } },
    { "src": "clips/IMG_0044.mov", "in": 10.0, "out": 10.0, "hold": 0.4 }
  ],
  "audio": [
    { "src": "music/sunny.mp3", "in": 12.5, "at": 0.0, "gain_db": -2, "duck_under": "voice",
      "mute": [ { "from": 31.6, "to": 31.9 } ] },
    { "src": "clips/IMG_0019.mov", "in": 0.0, "out": 3.2, "at": 1.9, "gain_db": -18, "role": "ambience",
      "fade_in": 0.3, "fade_out": 0.8 },
    { "src": "clips/IMG_0027.mov", "in": 4.1, "out": 6.0, "at": 7.5, "gain_db": 0, "role": "voice" },
    { "src": "sfx/riser_long.wav", "at": 29.9, "gain_db": -8 },
    { "src": "sfx/impact_soft.wav", "at": 32.0, "gain_db": -6 }
  ],
  "titles": [ { "text": "Lisbon, June", "at": 1.0, "duration": 2.5, "style": "lower-third", "fade": 0.4 } ],
  "end": { "fade_out": 1.0 }
}
```
`reframe` is `[center_x, center_y, zoom]` in normalized units at segment start and
end; the renderer interpolates. `hold` freezes the `in` frame. An audio event with
`at` later than the picture cut it belongs to is a J-cut; one that outlasts it is
an L-cut. Claude never computes those, it just places sound where it should be heard.

**OpenTimelineIO 0.18.1** is the export, not the source of truth: a ten-line
`tools/export_otio.py` turns `edit.json` into a `.otio` that DaVinci Resolve
(free) imports via File → Import → Timeline, and Premiere imports in beta. That is
the "hand it to a human in a GUI" escape hatch at zero cost. Speed pieces and
reframes export as plain clips; only the cut structure survives the round trip.

### Transcription: **mlx-whisper 0.4.3** (large-v3-turbo, `word_timestamps=True`)
Runs on the M1 GPU through MLX, is multilingual, gives word-level timestamps, and
its per-segment `no_speech_prob` is a free signal for "is this clip's audio
worth keeping".
Alternative: **parakeet-mlx 0.5.3** is faster and tops English word-error-rate
leaderboards, but English-centric. Swap in if clips are all English and whisper
feels slow.

### Beats and music energy: **beat_this 1.1.0** + **librosa 1.0.0**
beat_this is the current accurate beat and downbeat tracker, pip-installable with
no madmom dependency; downbeats matter because phrase-level cuts (every 1, 2 or 4
bars) feel edited while every-beat cuts feel strobed.
librosa gives RMS energy per beat and onset strength with no model download, so
Claude can see where the chorus hits, and `onset_detect` gives exact hit times
for landing impacts.
Optional: **allin1 1.1.0** labels sections (intro/verse/chorus/outro) but pulls in
madmom-from-git, NATTEN and Demucs. Add only if energy curves are not enough.

### Shot detection: **PySceneDetect 0.7.2** (`AdaptiveDetector`)
CPU-only, fast, scriptable, and good enough for hard cuts in both your clips and
the reference. Upgrade path: **transnetv2-pytorch 1.0.5** if a reference video is
dissolve-heavy; benchmarks put it a few F1 points above PySceneDetect on
gradual transitions.

### Visual understanding: **Claude itself on contact sheets**, pre-filtered by cheap heuristics
- `ffmpeg -vf "fps=1,scale=320:-1,tile=6x5"` makes one JPEG per 30 s of clip; Pillow stamps the timestamp in each cell. Claude reads the sheet and picks moments. Roughly 1.5k tokens per sheet.
- **OpenCV 5.0** per sampled frame: Laplacian variance (sharpness), mean luma (exposure). Lets `frames.py` throw away blurry, black, or static seconds before Claude sees them.
- **open_clip_torch 3.3.0** with SigLIP2 (`ViT-B-16-SigLIP2`, `webli`): one embedding per sampled frame enables text search ("kids laughing on beach"), near-duplicate removal across clips, matching a reference's shots to your clips, and **match-cut candidates** (cosine similarity between the last frame of one shot and the first frame of another). Optional for MVP.
- **aesthetic-predictor-v2-5** (SigLIP-based 1–10 score): optional, cheap, known to have narrow taste, use as a tiebreaker only.
- **mlx-vlm 0.7.9 + Qwen3-VL 8B 4-bit** (~5 GB RAM): optional local captioner for when there are hundreds of clips and sending every sheet to Claude is too slow or costly. Pin the mlx-vlm version; its video API churns.

### Perception for frame-accurate cutting **(quality)**
Skilled editors cut on action, on a glance, on a sound. At 1 fps Claude cannot
see the frame a kid leaves the ground. These tools find the candidates so Claude
chooses frames, not seconds. All run on OpenCV and torch already in the stack;
one new package.

| Signal | Tool | What it feeds |
|---|---|---|
| Motion magnitude and direction, 10 Hz | **OpenCV DIS optical flow** (`cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_FAST)`) on 320 px frames. Fit a similarity transform with `estimateAffinePartial2D` + RANSAC to split **camera motion** (static / pan L-R / tilt / push / handheld) from **subject motion** (residual flow). | Action peaks = local maxima of residual motion → cut-on-action candidates and the exact peak frame for a hold or ramp. Camera direction → which directional transition is motivated. Handheld jitter score → stabilize or skip. |
| Faces: count, size, screen position, 2 Hz | **YuNet** via `cv2.FaceDetectorYN` (ships with OpenCV, one small ONNX file). | Subject present? Big enough? Which side of frame (eye-trace continuity across cuts)? Auto-reframe targets with exponential smoothing. |
| Dense sheets at candidates only | `select='between(t,a,b)',fps=8,scale=240:-1,tile=8x3` for ±1.5 s around every action peak, audio event, and candidate cut. | Claude picks the exact in/out frame from a 24-frame strip instead of guessing from a 1 fps grid. |
| Audio events with timestamps | **panns-inference 0.1.1** `SoundEventDetection` (AudioSet, 527 classes, about 10 ms frames): Laughter, Cheering, Applause, Splash, Wind noise, Dog, Music… | "Cut on the laugh", "keep this nat sound", "wind-ruined, mute it". Combined with librosa onsets for the exact hit. Whisper-AT does transcription and tagging in one pass but is torch-only and slower than MLX whisper; PANNs stays separate. |
| Match-cut candidates | SigLIP2 cosine similarity across shot boundaries + flow direction agreement. | Graphic and motion match cuts, the move that makes a montage feel designed. |

Per-clip JSON ends up with a sparse list of **moments**: `{t, kind: action_peak|laugh|face_closeup|onset, score, sheet}`.
That list is what Claude actually reads; the raw curves stay on disk.

### Audio judgement (keep the clip's own sound or not)
whisper `no_speech_prob` + transcript + librosa RMS and spectral flatness (wind
noise is flat and loud) + PANNs tags go into the clip JSON and Claude decides,
per segment, between `voice`, `ambience`, and mute.

### Reference-video style: `tools/style.py` → `style.json`
Reuses the tools above on the reference and reduces to numbers Claude can copy:
- shot lengths: median, p10, p90, and the **rhythm curve** over the song (shot length per music section, so cuts speed up at the chorus the way the reference does)
- cut timing: fraction of cuts within ±80 ms of a beat or downbeat, which, and the signed offset (many editors cut 1–2 frames early)
- transition mix: hard cut vs dissolve vs directional, typical duration
- color: `signalstats` luma/saturation/hue averages per shot, plus a 3-bin shadows/mids/highlights summary
- motion: camera-motion label mix and mean subject motion per shot
- speech ratio, whether music ducks under it, whether nat sound beds exist
The same script runs on `out/final.mp4` so Claude can diff its output against the reference and iterate.

### Craft: the playbook and the concept pass **(quality)**
Claude knows editing theory but applies it reliably only when the repo spells it
out. `CLAUDE.md` carries the playbook; Claude reads it before every plan. The
rules below are the researched starting set; the file grows from your notes on
each finished video, which is how quality compounds.

**Priorities when rules conflict (Murch's Rule of Six):** emotion 51%, story 23%,
rhythm 10%, eye trace 7%, 2D screen plane 5%, 3D continuity 4%. If the emotion is
right, lower-order flaws go unnoticed.

**Structure for a 60–120 s music-driven piece:**
1. Hook (0–3 s): the single most striking shot, or a face, never an empty wide.
2. Establish: place and people, longer shots, nat sound audible.
3. Build: shot lengths shorten with the music's energy; introduce a motif (a color, a gesture, a recurring subject).
4. Climax: the chorus or drop lands on the hero moment, often with a hold, a ramp, or silence-then-impact just before.
5. Breath: one long quiet shot after the peak.
6. Button: an emotional close, a callback to the hook, then fade.

**Rhythm:** major cuts on downbeats, not every beat; leave some beats unanswered;
cut 1–2 frames before the beat so the hit lands on motion already visible; vary
shot length at least 3:1 within a section; hold the wide; speed ramps only where
the music breathes or surges; let the *action* land on the beat, not just the cut.

**Continuity:** cut on action; keep the subject on the same side of frame across
a cut (eye trace); match cuts on shape or motion when the embeddings offer one;
no dissolves except across time or place, at most one per minute; directional
transitions only when the outgoing shot moves that way.

**Sound:** every cut has a sound reason or a sound bridge (J/L cut); nat sound
bed under music at about -18 dB; voice 3–6 dB over music; risers into section
changes, impacts on the downbeat after; silence 0.3 s before the drop.

**Discipline:** no clip twice unless it is a callback; no shot under 8 frames; no
gimmick transitions; grade for one consistent look, match exposure between
adjacent shots; subtitles only when speech carries the story.

**Concept first.** Before `edit.json`, Claude writes `concept.md`: the one-line
story, the hero moments (3–5, with timestamps), where the drop lands, the motif,
the look, and which clips are cut. A plan that cannot be explained in ten lines
is a random montage.

### Review loop **(quality)**
Editors never ship the first assembly. The loop:
1. `tools/render.py --proxy`: 540p, `hevc_videotoolbox`, renders in seconds.
2. `tools/review.py out/proxy.mp4 edit.json` produces, per cut, a strip of the
   last 3 outgoing frames and first 3 incoming frames at 8 fps, plus an audio
   waveform with cut markers, and a QC report: `blackdetect`, `freezedetect`,
   `astats` peak/clipping, `ebur128` loudness, `photosensitivity`, duplicate-shot
   check via embeddings, cut-on-beat ratio, shot-length histogram vs. reference.
3. Claude critiques its own cut against the playbook and the concept (not against
   the numbers alone), revises `edit.json`, re-renders. Two or three passes.
4. After you watch it: your notes go in `notes/<video>.md`; anything repeated
   twice becomes a playbook rule.

The self-check idea is borrowed from video-use, which verifies cut boundaries the
same way; the difference here is the critique is about craft, not just clicks.

### Titles and motion graphics (later, if wanted): **Remotion** or Pillow
Remotion renders React to transparent-background clips that `edit.json` references like any other source; Pillow handles static cards with zero new runtime.

### Environment
`brew install uv` then `uv venv --python 3.12`. torch 2.14 uses the M1 GPU through MPS; MLX packages use it natively.
New packages for the quality sections: `panns-inference`, `color-matcher`, optional `vidstab`, optional `rife-ncnn-vulkan` binary.

## GUI and "take control of software" options, explored

| Option | Verdict |
|---|---|
| DaVinci Resolve free, import `.otio` | Best free hand-off: Claude plans and renders, you polish in Resolve. Import only, no API. |
| DaVinci Resolve Studio ($295) Python API | Full programmatic control (timeline build, Fusion, color, render). Since 21.1 (Sept 2026) Python scripting is Studio-only, so this is a paid path. Worth it only if you already want Resolve's color tools. |
| Shotcut (free) | Native project format is MLT XML, so a timeline written as `.mlt` opens in the GUI and renders headless with `melt`. Cleanest open-source GUI bridge, but means writing MLT XML by hand since the OTIO adapter is dead. |
| Premiere Pro / Final Cut | OTIO import exists (Premiere still beta as of 2025), FCPXML via OTIO's built-in adapter. Paid, no scripting from outside. |
| Claude driving a GUI by screenshots (computer use) | Slow, brittle, and every NLE above has a file-based path that works better. Skip. |
| Existing agent editors | **video-use** (browser-use, MIT, 29k stars): same "read, don't watch" philosophy, but ElevenLabs cloud transcription, no beat sync, no reference style. **Oh My Cassette** (MIT MCP server): beat sync and clip analysis, but renders on a hosted backend. Both validate the approach; neither is local-first with reference matching. Steal the self-check loop idea from video-use. |

## The riskiest piece

**Taste.** Every library above is proven. The open question is whether a
playbook, a reference's statistics, and a self-critique loop get Claude from
"competent and formulaic" to "I would not have thought of that". Nobody has
published a local tool that does this, so there is no prior to borrow.
Mitigation: make craft explicit (playbook), make style measurable (`style.py` on
output vs. reference), make the loop cheap (proxy renders in seconds), and feed
your notes back so the playbook is yours after five videos, not generic.

Second risk: slow-motion quality from 30 fps sources. Mitigation: shoot 60 fps
when you expect to ramp; otherwise RIFE, and ramp less.

Third risk: perception misses. A 1 fps grid plus motion peaks will still miss a
glance. Mitigation: dense sheets are cheap, so widen the candidate windows when a
section feels flat.

## Milestones

**M1, plumbing (smallest MVP).** Prove a beat-synced montage from Claude's own
choices looks deliberate. No transcription, no reference, no ramps.
1. `tools/beats.py song.mp3` → beats, downbeats, energy per beat.
2. `tools/sheet.py clips/*.mov` → timestamped contact sheets.
3. Claude writes `edit.json`: ~15 segments, each 1 or 2 bars, in/out from the sheets.
4. `tools/render.py`: per-segment trims, concat, music via the audio timeline, `hevc_videotoolbox`.
5. Check: ≥ 90% of cuts within one frame of a beat, and it does not feel random.
About 150 lines of Python.

**M2, perception and sound.** `frames.py` (DIS flow, YuNet, moments list, dense
sheets), `events.py` (PANNs + onsets), full audio timeline with J/L cuts, nat-sound
beds, ducking, loudnorm. First video that sounds edited.

**M3, craft and loop.** `CLAUDE.md` playbook, `concept.md` step, `review.py` with
cut sheets and QC, proxy renders, `style.py` on a reference. First video that
holds up next to a human cut.

**M4, polish moves.** Speed ramps and holds, reframes, shot matching LUTs, grain,
sfx library, titles. Then OTIO export.

## Sources

Transcription: [Self-hosted Whisper 2026](https://www.digitalapplied.com/blog/local-speech-to-text-whisper-self-hosted-transcription-2026), [Parakeet vs Whisper](https://spokenly.app/blog/parakeet-vs-whisper), [whisper.cpp vs faster-whisper](https://www.promptquorum.com/power-local-llm/local-whisper-stt-comparison-2026), [parakeet-mlx](https://osrepos.com/repo/senstella-parakeet-mlx), [FFmpeg 8 whisper filter](https://www.phoronix.com/news/FFmpeg-Lands-Whisper), [whisper filter on macOS brew](https://0110.be/posts/FFmpeg_with_Whisper_support_on_macOS_via_Homebrew).
Beats/music: [beat_this](https://github.com/CPJKU/beat_this), [BeatNet](https://github.com/mjhydri/BeatNet), [allin1](https://github.com/mir-aidj/all-in-one), [librosa onset_detect](https://librosa.org/doc/main/generated/librosa.onset.onset_detect.html).
Shots: [TransNetV2](https://arxiv.org/pdf/2008.04838), [OmniShotCut comparison](https://arxiv.org/html/2604.24762v2), [CineTrans pipeline](https://arxiv.org/html/2508.11484v2).
Timeline/NLE: [otio-mlt-adapter](https://pypi.org/project/otio-mlt-adapter), [Remotion OTIO export](https://www.remotion.dev/docs/export-opentimeline), [OTIO import in Resolve free](https://pulseedit.com/otio-import-davinci-resolve-free.html), [Resolve 21.1 scripting moves to Studio](https://www.cined.com/davinci-resolve-21-1-released-ai-assistant-integration-via-mcp-individual-hdr-trims-and-python-scripting-moves-to-studio/), [Resolve scripting in free](https://forum.blackmagicdesign.com/viewtopic.php?f=21&t=113252), [Premiere OTIO beta](https://community.adobe.com/t5/premiere-pro-beta-discussions/now-in-beta-otio-import-and-export/td-p/14937493), [melt docs](https://www.mltframework.org/docs/melt), [Shotcut + melt on macOS](https://forum.shotcut.org/t/is-there-a-way-to-use-shotcut-as-a-command-line-in-macbook/33968).
Vision: [mlx-vlm](https://github.com/Blaizzy/mlx-vlm), [Qwen3-VL](https://github.com/qwenlm/qwen3-vl), [aesthetic-predictor-v2-5](https://pypi.org/project/aesthetic-predictor-v2-5/), [LAION aesthetics audit](https://arxiv.org/html/2601.09896v2), [HL-CLIP](https://cs.paperswithcode.com/paper/unleash-the-potential-of-clip-for-video), [Lighthouse highlight detection](https://preview.aclanthology.org/fix-8040/2024.emnlp-demo.6).
Perception: [OpenCV optical flow](https://learnopencv.com/optical-flow-in-opencv/), [camera-motion from flow + affine fit](https://openskillindex.com/skills/benchflow-ai-skillsbench-egomotion-estimation), [YuNet in OpenCV](https://transloadit.com/devtips/real-time-face-detection-with-opencv-s-yunet/), [YuNet tracking with smoothing](https://habr.com/en/articles/1022298/), [detection-based auto framing](https://blog.roboflow.com/keep-objects-centered-with-object-detection-based-camera-framing/amp), [panns-inference](https://pypi.org/project/panns-inference/0.1.0), [laughter detection models](https://github.com/ideo/LaughDetection).
Render moves: [setpts piecewise speed](https://ffmpeg.org/pipermail/ffmpeg-user/2017-May/036262.html), [ffmpeg speed/slow wiki](https://trac.ffmpeg.org/wiki/How%20to%20speed%20up%20/%20slow%20down%20a%20video?version=13), [animated crop with t](https://ffmpeg.org/pipermail/ffmpeg-user/2020-April/048487.html), [zoompan source](https://ffmpeg.org/doxygen/8.0/vf__zoompan_8c_source.html), [rife-ncnn-vulkan](https://github.com/TNTwise/rife-ncnn-vulkan), [RIFE on Apple Silicon](https://svp-team.com/wiki/RIFE_AI_interpolation), [vidstab tap for Homebrew](https://github.com/varenc/homebrew-ffmpeg), [vidstab two-pass guide](https://paulirish.com/2021/video-stabilization-with-ffmpeg-and-vidstab/), [color-matcher](https://pypi.org/project/color-matcher/0.4.1), [colortrans](https://github.com/dstein64/colortrans), [LUT banding notes](https://arxiv.org/pdf/2608.14702), [Q-DDL 800 free LUTs](https://digitalproduction.com/2020/01/22/kostenlos-ueber-800-3d-luts/), [Freevisuals LUT pack](https://www.freevisuals.net/item/mega-lut-pack).
Sound libraries: [free SFX sources and licenses](https://app.cinevva.com/guides/free-sound-effects-music), [Sonniss GDC bundle](https://toucharcade.com/?p=166172), [film sound design guide](https://webflow.krotos.studio/blog/film-sound-design), [trailer sound palette](https://sounddesign.irpr.agency/styles/trailer-rise/).
Craft: [Murch's Rule of Six](https://nofilmschool.com/2016/11/6-rules-good-cutting-according-oscar-winning-editor-walter-murch), [Rule of Six weights](https://www.studiobinder.com/blog/walter-murch-rule-of-six/), [J-cuts and L-cuts](https://spotlightfx.com/blog/what-are-j-cuts-and-l-cuts-professional-dialogue-editing-explained), [match cuts](https://spotlightfx.com/blog/what-is-a-match-cut), [10 essential cuts](https://www.storyblocks.com/resources/tutorials/film-editing-techniques), [cutting a music video (Creative COW)](https://creativecow.net/forums/thread/cutting-a-music-videoae-3/), [editing to music without cutting on every beat](https://davinciresolve21.com/blog/how-to-edit-video-to-music-without-cutting-on-beat), [beat-sync guide](https://beat2cut.com/blog/beat-sync-video-editing-complete-guide/), [travel edit breakdown](https://www.therookies.co/projects/84273), [travel reel pacing case](https://contra.com/p/FekYbERO-some-places-deserve-more-than), [speed ramp basics](https://kapwing.com/resources/how-to-use-the-speed-ramp-effect), [travel vlog hooks](https://spliceapp.com/blog/crafting-engaging-travel-vlog-hooks-beginners-guide/).
Prior art: [video-use](https://github.com/browser-use/video-use), [Video Use write-up](https://www.solosoft.dev/post/video-use-ai-editing-2026/), [Oh My Cassette](https://github.com/cassette-editor/oh-my-cassette), [montage-ai](https://tomevault.io/tome/mfahsold/montage-ai), [FableCut](https://linkloot.io/loot/edit-agent-made-videos-through-a-json-timeline-with-fablecut).
ffmpeg: [xfade with many inputs](https://ffmpeg.org/pipermail/ffmpeg-user/2020-June/048925.html), [VideoToolbox on macOS](https://dev.to/vuhung16au/ffmpeg-tutorial-creating-professional-videos-with-advanced-filtering-and-gpu-acceleration-3h6).
