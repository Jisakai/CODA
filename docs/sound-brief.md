# Sound Brief

Milestone M1 is mostly about sound. This brief says what it should feel like. It supports `SPEC.md` §13; if they disagree, `SPEC.md` wins.

## The target
- **References:** the *Balatro* soundtrack and Tame Impala's *Currents*.
- **Qualities to aim for:** warm, slightly detuned, a little wobbly, phased and chorused, soft-edged. Dreamy and lo-fi in feel, but still clear enough to write chords with.
- **Not wanted:** harsh or glassy highs, whistling filter resonance, clicky attacks, a realistic acoustic guitar, anything that gets tiring when one loop plays for 2+ hours.
- **Owner to add:** 3–5 specific reference tracks or moments (title + timestamp) below. Until then, use the qualities above.

| Reference track           | Timestamp   | What to copy from it |
|---------------------------|-------------|----------------------|
| _Nangs - Tame Impala_     | 0.45-Rest   | Just amazing synths  |
| _Balatro Theme - Louis F_ | Whole Thing | It attracts you in   |

## The three presets
Names are provisional. All three share one voice engine; presets are only parameter sets.

### 1. Pluck
- **Feel:** bubbly, short, a little detuned. A synth pluck, **not** a plucked string.
- **Shape:** saw with a touch of square, snappy filter-envelope that closes fast, short decay, no sustain. 2–5 ms attack so there is no click.
- **Extras:** light chorus. Glide off by default.
- **Must work with:** the strum engine, including the chuck (X), which should be a short percussive rake that works on any preset.

### 2. Currents pad
- **Feel:** wide, warm, slow-moving, a little smeared.
- **Shape:** detuned saws (2–3 unison voices) with a quiet sub, slow attack, long release, gentle low-pass.
- **Extras:** slow phaser and chorus, subtle drift in pitch. Glide off by default. Old chord tails overlap under the next chord.

### 3. Wobble lead
- **Feel:** lo-fi, tape-warped, singable.
- **Shape:** detuned triangle or square, tape-style pitch wobble, glide on by default.
- **Extras:** light chorus, soft saturation.

## Macros and knobs
- **Wobble** (one knob): scales tape drift, chorus depth and phaser speed together. 0 = clean, max = properly warped.
- **Warmth** (one knob): closes the filter slightly and adds soft saturation. Turn it up late in a long session when ears need a rest.
- **Five knobs:** Cutoff, Resonance, Attack/Release (or one "Shape"), Detune, Glide.
- **Humanize** also varies detune and filter slightly per note so a repeated chord never sounds identical.

## Ear-safety rules (build these in, don't leave them to the owner)
- Gentle master high cut or shelf around 8–10 kHz.
- Soft dip in the 2–4 kHz harshness zone.
- Limited resonance range so filters can't whistle.
- Soft saturation on the master, **soft-clip, never hard-clip**, plus a safety limiter.
- Conservative default output level with headroom.
- Very slow LFOs on phaser, filter and pitch so a long loop keeps breathing instead of sitting static.
- Chords overlap rather than cut.

## Owner listening checklist for M1 approval
Play a 4-bar progression on loop, then answer:
1. Does the Pluck sound like a synth pluck, not a guitar?
2. Is the Currents pad wide and warm without getting muddy?
3. Does the Wobble lead's glide feel musical, not drunk?
4. Do Wobble and Warmth do what their names say across their whole range?
5. After 20–30 minutes of one loop, is anything tiring (highs, resonance, a repeating click)?
6. Do chord changes overlap smoothly with no pops or clicks?
7. At normal volume, is there headroom, with no clipping on dense chords?

Report failures to the orchestrator in words ("the pad gets harsh when Warmth is low"), and it will turn them into fix briefs.
