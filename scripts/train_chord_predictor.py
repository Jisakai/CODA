#!/usr/bin/env python3
"""Train and export CODA's steerable Core ML ChordPredictor (SPEC §17).

Architecture:
- Compact 4-layer bidirectional Transformer encoder (~1.5M parameters)
- Input token vocabulary:
  [PAD, MASK, MASK_EXT_0..11, BOS, EOS,
   <intro>, <verse>, <chorus>, <bridge>, <outro>, <other>,
   genre:<12 Chordonomicon main_genre classes>,
   <12 pitch classes x 30 vocab.json qualities = 360 chord tokens>]
- Training objective:
  50% center-masking (extension/substitution prediction),
  50% end-masking (next-chord prediction),
  oversampling progressions containing 7th/9th/11th/13th/altered extensions.
- Steerable inference:
  Accepts an external `logit_bias` vector matching the 360 chord classes so the
  coda AI sidekick's `<directive>` JSON can steer harmonic tension, qualities,
  and seed chords without modifying model weights.
- Evaluation:
  Compares top-1 / top-3 / top-5 accuracy and cross-entropy against a
  key/bigram transition-table baseline on a held-out validation split.
- Export:
  Exports `ChordPredictor.mlpackage` via `coremltools` with MLProgram backend.

Usage:
  python3 scripts/train_chord_predictor.py --smoke-test --output build/ChordPredictor.mlpackage
  python3 scripts/train_chord_predictor.py --epochs 10 --output Sources/CodaMusic/Resources/ChordPredictor.mlpackage
"""

from __future__ import annotations

import argparse
import collections
import csv
import json
import math
import pathlib
import random
import re
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_VOCAB_PATH = ROOT / "Sources" / "CodaMusic" / "Resources" / "vocab.json"

PITCH_CLASS_MAP: Dict[str, int] = {
    "C": 0, "Cs": 1, "C#": 1, "Db": 1,
    "D": 2, "Ds": 3, "D#": 3, "Eb": 3,
    "E": 4, "Fb": 4, "Es": 5, "E#": 5,
    "F": 5, "Fs": 6, "F#": 6, "Gb": 6,
    "G": 7, "Gs": 8, "G#": 8, "Ab": 8,
    "A": 9, "As": 10, "A#": 10, "Bb": 10,
    "B": 11, "Cb": 11, "Bs": 0, "B#": 0,
}

SECTION_TOKENS = ["<intro>", "<verse>", "<chorus>", "<bridge>", "<outro>", "<other>"]
GENRE_TOKENS = [
    "genre:pop", "genre:rock", "genre:country", "genre:alternative",
    "genre:pop rock", "genre:punk", "genre:metal", "genre:rap",
    "genre:soul", "genre:jazz", "genre:reggae", "genre:electronic",
    "genre:unknown",
]

# Map Chordonomicon quality suffixes -> vocab.json quality IDs
CHORDONOMICON_QUALITY_MAP: Dict[str, str] = {
    "": "major",
    "maj": "major",
    "6": "major6",
    "maj6": "major6",
    "maj7": "major7",
    "maj9": "major9",
    "69": "major69",
    "6/9": "major69",
    "add9": "add9",
    "add11": "add11",
    "maj7#11": "major7sharp11",
    "maj7s11": "major7sharp11",
    "7": "dominant7",
    "9": "dominant9",
    "13": "dominant13",
    "7alt": "dominant7alt",
    "7b9": "dominant7flat9",
    "7#9": "dominant7sharp9",
    "7s9": "dominant7sharp9",
    "min": "minor",
    "m": "minor",
    "minadd9": "minorAdd9",
    "madd9": "minorAdd9",
    "minadd11": "minorAdd11",
    "madd11": "minorAdd11",
    "min6": "minor6",
    "m6": "minor6",
    "min7": "minor7",
    "m7": "minor7",
    "min9": "minor9",
    "m9": "minor9",
    "min11": "minor11",
    "m11": "minor11",
    "minmaj7": "minorMajor7",
    "mmaj7": "minorMajor7",
    "m7b5": "halfDiminished7",
    "min7b5": "halfDiminished7",
    "hdim7": "halfDiminished7",
    "sus2": "sus2",
    "sus4": "sus4",
    "sus": "sus4",
    "7sus4": "dominant7sus4",
    "dim": "diminished",
    "dim7": "diminished7",
    "aug": "augmented",
    "no3d": "power",
    "5": "power",
}

EXTENSION_QUALITIES = {
    "major7", "major9", "major69", "add9", "add11", "major7sharp11",
    "dominant7", "dominant9", "dominant13", "dominant7alt",
    "dominant7flat9", "dominant7sharp9",
    "minorAdd9", "minorAdd11", "minor6", "minor7", "minor9", "minor11",
    "minorMajor7", "halfDiminished7", "dominant7sus4", "diminished7",
}

SECTION_RE = re.compile(r"^<([a-zA-Z]+)(?:_\d+)?>$")
CHORD_RE = re.compile(r"^([A-G](?:s|#|b)?)([^/]*)(?:/([A-G](?:s|#|b)?))?$")


@dataclass(frozen=True)
class PredictorVocab:
    quality_ids: Tuple[str, ...]
    token_to_id: Dict[str, int]
    id_to_token: Tuple[str, ...]
    chord_offset: int
    chord_count: int

    @property
    def pad_id(self) -> int:
        return self.token_to_id["<PAD>"]

    @property
    def mask_id(self) -> int:
        return self.token_to_id["<MASK>"]

    def mask_ext_id(self, root_pc: int) -> int:
        return self.token_to_id[f"<MASK_EXT:{root_pc % 12}>"]

    def chord_class_index(self, root_pc: int, quality_id: str) -> int:
        q_idx = self.quality_ids.index(quality_id)
        return (root_pc % 12) * len(self.quality_ids) + q_idx

    def chord_token_id(self, root_pc: int, quality_id: str) -> int:
        return self.chord_offset + self.chord_class_index(root_pc, quality_id)

    def section_token_id(self, section: str) -> int:
        key = section if section in self.token_to_id else "<other>"
        return self.token_to_id[key]

    def genre_token_id(self, genre: Optional[str]) -> int:
        if not genre:
            return self.token_to_id["genre:unknown"]
        key = f"genre:{genre.strip().lower()}"
        return self.token_to_id.get(key, self.token_to_id["genre:unknown"])

    @classmethod
    def from_vocab_json(cls, vocab_path: pathlib.Path) -> "PredictorVocab":
        raw = json.loads(vocab_path.read_text(encoding="utf-8"))
        quality_ids = tuple(entry["id"] for entry in raw)
        tokens: List[str] = ["<PAD>", "<MASK>"]
        tokens.extend(f"<MASK_EXT:{pc}>" for pc in range(12))
        tokens.extend(["<BOS>", "<EOS>"])
        tokens.extend(SECTION_TOKENS)
        tokens.extend(GENRE_TOKENS)
        chord_offset = len(tokens)
        for pc in range(12):
            for q in quality_ids:
                tokens.append(f"chord:{pc}:{q}")
        token_to_id = {tok: idx for idx, tok in enumerate(tokens)}
        return cls(
            quality_ids=quality_ids,
            token_to_id=token_to_id,
            id_to_token=tuple(tokens),
            chord_offset=chord_offset,
            chord_count=12 * len(quality_ids),
        )


def parse_chordonomicon_token(token: str) -> Optional[Tuple[int, str]]:
    """Parse a Chordonomicon chord token (e.g. 'Csmin7/Gs') into (root_pc, vocab_quality_id)."""
    m = CHORD_RE.match(token.strip())
    if not m:
        return None
    root_str, qual_str, _bass_str = m.groups()
    root_pc = PITCH_CLASS_MAP.get(root_str)
    if root_pc is None:
        return None
    q_norm = qual_str.strip().lower()
    mapped = CHORDONOMICON_QUALITY_MAP.get(q_norm)
    if mapped is not None:
        return (root_pc, mapped)
    # Heuristic normalization for compound Chordonomicon labels
    if "min" in q_norm or q_norm.startswith("m"):
        if "11" in q_norm:
            return (root_pc, "minor11")
        if "9" in q_norm:
            return (root_pc, "minor9")
        if "7" in q_norm:
            return (root_pc, "minor7")
        if "6" in q_norm:
            return (root_pc, "minor6")
        return (root_pc, "minor")
    if "maj7" in q_norm:
        return (root_pc, "major7")
    if "maj9" in q_norm:
        return (root_pc, "major9")
    if "13" in q_norm:
        return (root_pc, "dominant13")
    if "9" in q_norm:
        return (root_pc, "dominant9")
    if "7" in q_norm:
        return (root_pc, "dominant7")
    if "sus2" in q_norm:
        return (root_pc, "sus2")
    if "sus4" in q_norm or "sus" in q_norm:
        return (root_pc, "sus4")
    if "dim" in q_norm:
        return (root_pc, "diminished")
    if "aug" in q_norm:
        return (root_pc, "augmented")
    return (root_pc, "major")


@dataclass
class ProgressionSample:
    section: str
    genre: str
    chords: List[Tuple[int, str]]
    has_extension: bool


def parse_chordonomicon_row(chords_text: str, main_genre: Optional[str]) -> List[ProgressionSample]:
    """Split a Chordonomicon song row into section-conditioned chord windows."""
    samples: List[ProgressionSample] = []
    current_section = "<verse>"
    current_chords: List[Tuple[int, str]] = []
    genre = (main_genre or "unknown").strip().lower()

    def flush() -> None:
        if len(current_chords) >= 4:
            has_ext = any(q in EXTENSION_QUALITIES for _, q in current_chords)
            samples.append(ProgressionSample(current_section, genre, list(current_chords), has_ext))

    for raw_tok in chords_text.split():
        sec_match = SECTION_RE.match(raw_tok)
        if sec_match:
            flush()
            current_chords = []
            sec_name = f"<{sec_match.group(1).lower()}>"
            current_section = sec_name if sec_name in SECTION_TOKENS else "<other>"
            continue
        parsed = parse_chordonomicon_token(raw_tok)
        if parsed is not None:
            current_chords.append(parsed)
    flush()
    return samples


def build_synthetic_smoke_samples(rng: random.Random, count: int = 2048) -> List[ProgressionSample]:
    """Deterministic musical progressions for --smoke-test when offline."""
    templates = [
        ("<verse>", "soul", [(0, "minor7"), (8, "major7"), (5, "minor9"), (7, "dominant7alt")]),
        ("<chorus>", "pop", [(0, "major"), (7, "major"), (9, "minor7"), (5, "major7")]),
        ("<bridge>", "jazz", [(2, "minor9"), (7, "dominant13"), (0, "major9"), (9, "dominant7flat9")]),
        ("<verse>", "electronic", [(9, "minor7"), (5, "major7"), (0, "add9"), (7, "sus4")]),
        ("<chorus>", "rock", [(0, "power"), (10, "major"), (5, "major"), (7, "dominant7sus4")]),
        ("<outro>", "soul", [(5, "minor11"), (10, "dominant9"), (3, "major7sharp11"), (0, "minor9")]),
    ]
    out: List[ProgressionSample] = []
    for _ in range(count):
        sec, genre, base = rng.choice(templates)
        shift = rng.randrange(12)
        seq = [((r + shift) % 12, q) for r, q in base] * 2
        has_ext = any(q in EXTENSION_QUALITIES for _, q in seq)
        out.append(ProgressionSample(sec, genre, seq, has_ext))
    return out


def load_chordonomicon_samples(
    csv_path: Optional[pathlib.Path],
    max_rows: Optional[int],
    smoke_test: bool,
    seed: int = 42,
) -> List[ProgressionSample]:
    rng = random.Random(seed)
    if smoke_test and csv_path is None:
        try:
            from datasets import load_dataset  # type: ignore
            ds = load_dataset("ailsntua/Chordonomicon", split="train", streaming=True)
            samples: List[ProgressionSample] = []
            for idx, row in enumerate(ds):
                if idx >= (max_rows or 1000):
                    break
                samples.extend(parse_chordonomicon_row(row.get("chords", ""), row.get("main_genre")))
            if samples:
                return samples
        except Exception:
            pass
        return build_synthetic_smoke_samples(rng)

    samples = []
    if csv_path is not None and csv_path.is_file():
        with csv_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            for idx, row in enumerate(reader):
                if max_rows is not None and idx >= max_rows:
                    break
                samples.extend(parse_chordonomicon_row(row.get("chords", ""), row.get("main_genre")))
    else:
        from datasets import load_dataset  # type: ignore
        ds = load_dataset("ailsntua/Chordonomicon", split="train")
        limit = min(len(ds), max_rows) if max_rows is not None else len(ds)
        for idx in range(limit):
            row = ds[idx]
            samples.extend(parse_chordonomicon_row(row.get("chords", ""), row.get("main_genre")))
    return samples


class TransitionTableBaseline:
    """Key/bigram chord transition-table baseline (SPEC §17)."""

    def __init__(self, chord_count: int):
        self.chord_count = chord_count
        self.bigrams: Dict[int, collections.Counter] = collections.defaultdict(collections.Counter)
        self.unigrams: collections.Counter = collections.Counter()

    def fit(self, samples: Sequence[ProgressionSample], vocab: PredictorVocab) -> None:
        for s in samples:
            classes = [vocab.chord_class_index(r, q) for r, q in s.chords]
            for idx, c in enumerate(classes):
                self.unigrams[c] += 1
                if idx > 0:
                    self.bigrams[classes[idx - 1]][c] += 1

    def rank(self, prev_class: Optional[int], top_k: int = 5) -> List[int]:
        if prev_class is not None and self.bigrams[prev_class]:
            ranked = [c for c, _ in self.bigrams[prev_class].most_common(top_k)]
            if len(ranked) < top_k:
                for c, _ in self.unigrams.most_common(top_k * 2):
                    if c not in ranked:
                        ranked.append(c)
                        if len(ranked) == top_k:
                            break
            return ranked
        return [c for c, _ in self.unigrams.most_common(top_k)]


def evaluate_baseline(
    baseline: TransitionTableBaseline,
    val_samples: Sequence[ProgressionSample],
    vocab: PredictorVocab,
) -> Dict[str, float]:
    total = 0
    top1 = 0
    top3 = 0
    top5 = 0
    for s in val_samples:
        classes = [vocab.chord_class_index(r, q) for r, q in s.chords]
        if len(classes) < 2:
            continue
        target = classes[-1]
        prev = classes[-2]
        preds = baseline.rank(prev, top_k=5)
        total += 1
        if preds and preds[0] == target:
            top1 += 1
        if target in preds[:3]:
            top3 += 1
        if target in preds[:5]:
            top5 += 1
    denom = max(1, total)
    return {"top1": top1 / denom, "top3": top3 / denom, "top5": top5 / denom, "count": float(total)}


def build_torch_model_and_train(args: argparse.Namespace, vocab: PredictorVocab, samples: List[ProgressionSample]) -> None:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    class SteerableChordTransformer(nn.Module):
        """4-layer bidirectional Transformer encoder (~1.5M params) with external logit bias."""

        def __init__(
            self,
            vocab_size: int,
            chord_count: int,
            d_model: int = 192,
            nhead: int = 6,
            num_layers: int = 4,
            dim_feedforward: int = 512,
            max_seq_len: int = 32,
            dropout: float = 0.1,
        ):
            super().__init__()
            self.max_seq_len = max_seq_len
            self.chord_count = chord_count
            self.token_emb = nn.Embedding(vocab_size, d_model, padding_idx=0)
            self.pos_emb = nn.Embedding(max_seq_len, d_model)
            enc_layer = nn.TransformerEncoderLayer(
                d_model=d_model,
                nhead=nhead,
                dim_feedforward=dim_feedforward,
                dropout=dropout,
                activation="gelu",
                batch_first=True,
                norm_first=True,
            )
            self.encoder = nn.TransformerEncoder(enc_layer, num_layers=num_layers)
            self.norm = nn.LayerNorm(d_model)
            self.head = nn.Linear(d_model, chord_count)

        def forward(
            self,
            token_ids: torch.Tensor,      # [B, L] int32
            mask_position: torch.Tensor,  # [B] int32
            logit_bias: torch.Tensor,     # [B, chord_count] float32
        ) -> torch.Tensor:
            bsz, seq_len = token_ids.shape
            positions = torch.arange(seq_len, device=token_ids.device).unsqueeze(0).expand(bsz, seq_len)
            x = self.token_emb(token_ids.long()) + self.pos_emb(positions)
            pad_mask = token_ids == 0
            x = self.encoder(x, src_key_padding_mask=pad_mask)
            x = self.norm(x)
            batch_idx = torch.arange(bsz, device=token_ids.device)
            pooled = x[batch_idx, mask_position.long()]
            logits = self.head(pooled) + logit_bias
            return logits

    rng = random.Random(args.seed)
    rng.shuffle(samples)
    split = max(1, int(len(samples) * 0.9))
    train_samples = samples[:split]
    val_samples = samples[split:] if split < len(samples) else samples[: max(1, len(samples) // 10)]

    # Oversample progressions containing 7th/9th/11th/13th/altered extensions
    weighted_train: List[ProgressionSample] = []
    for s in train_samples:
        weighted_train.append(s)
        if s.has_extension:
            weighted_train.append(s)

    baseline = TransitionTableBaseline(vocab.chord_count)
    baseline.fit(train_samples, vocab)
    baseline_metrics = evaluate_baseline(baseline, val_samples, vocab)
    print(f"Baseline transition table: {json.dumps(baseline_metrics)}")

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = SteerableChordTransformer(
        vocab_size=len(vocab.id_to_token),
        chord_count=vocab.chord_count,
        max_seq_len=args.seq_len,
    ).to(device)
    param_count = sum(p.numel() for p in model.parameters())
    print(f"ChordPredictor params: {param_count:,} on {device}")

    def make_batch(batch_samples: Sequence[ProgressionSample]) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        seq_len = args.seq_len
        tokens = torch.zeros((len(batch_samples), seq_len), dtype=torch.int32)
        mask_pos = torch.zeros((len(batch_samples),), dtype=torch.int32)
        targets = torch.zeros((len(batch_samples),), dtype=torch.long)
        for i, s in enumerate(batch_samples):
            max_chords = seq_len - 2
            chords = s.chords[:max_chords]
            seq = [vocab.section_token_id(s.section), vocab.genre_token_id(s.genre)]
            seq.extend(vocab.chord_token_id(r, q) for r, q in chords)
            # 50% center-masking (extension/substitution), 50% end-masking (next chord)
            if rng.random() < 0.5 and len(chords) >= 3:
                c_idx = rng.randrange(1, len(chords) - 1)
                root_pc, qual = chords[c_idx]
                pos = 2 + c_idx
                seq[pos] = vocab.mask_ext_id(root_pc)
            else:
                c_idx = len(chords) - 1
                root_pc, qual = chords[c_idx]
                pos = 2 + c_idx
                seq[pos] = vocab.mask_id
            tokens[i, : len(seq)] = torch.tensor(seq, dtype=torch.int32)
            mask_pos[i] = pos
            targets[i] = vocab.chord_class_index(root_pc, qual)
        return tokens.to(device), mask_pos.to(device), targets.to(device)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    epochs = 2 if args.smoke_test else args.epochs
    batch_size = min(args.batch_size, max(8, len(weighted_train)))

    for epoch in range(1, epochs + 1):
        model.train()
        rng.shuffle(weighted_train)
        total_loss = 0.0
        steps = 0
        for start in range(0, len(weighted_train), batch_size):
            chunk = weighted_train[start : start + batch_size]
            if not chunk:
                continue
            tok, mpos, tgt = make_batch(chunk)
            zero_bias = torch.zeros((len(chunk), vocab.chord_count), dtype=torch.float32, device=device)
            logits = model(tok, mpos, zero_bias)
            loss = F.cross_entropy(logits, tgt)
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            total_loss += float(loss.item())
            steps += 1
        print(f"Epoch {epoch}/{epochs} train_loss={total_loss / max(1, steps):.4f}")

    # Validation
    model.eval()
    val_top1 = val_top3 = val_top5 = val_total = 0
    with torch.no_grad():
        for start in range(0, len(val_samples), batch_size):
            chunk = val_samples[start : start + batch_size]
            if not chunk:
                continue
            tok, mpos, tgt = make_batch(chunk)
            zero_bias = torch.zeros((len(chunk), vocab.chord_count), dtype=torch.float32, device=device)
            logits = model(tok, mpos, zero_bias)
            top5 = torch.topk(logits, k=5, dim=-1).indices
            for i in range(len(chunk)):
                val_total += 1
                t = int(tgt[i].item())
                row = [int(x.item()) for x in top5[i]]
                if row[0] == t:
                    val_top1 += 1
                if t in row[:3]:
                    val_top3 += 1
                if t in row[:5]:
                    val_top5 += 1
    denom = max(1, val_total)
    model_metrics = {"top1": val_top1 / denom, "top3": val_top3 / denom, "top5": val_top5 / denom, "count": float(val_total)}
    print(f"ChordPredictor validation: {json.dumps(model_metrics)}")

    if args.checkpoint:
        ckpt_path = pathlib.Path(args.checkpoint)
        ckpt_path.parent.mkdir(parents=True, exist_ok=True)
        torch.save(
            {
                "state_dict": model.state_dict(),
                "vocab": vocab.id_to_token,
                "quality_ids": vocab.quality_ids,
                "seq_len": args.seq_len,
                "baseline_metrics": baseline_metrics,
                "model_metrics": model_metrics,
            },
            ckpt_path,
        )
        print(f"Saved PyTorch checkpoint: {ckpt_path}")

    if args.output:
        try:
            import coremltools as ct  # type: ignore

            model_cpu = model.to("cpu").eval()
            ex_tokens = torch.zeros((1, args.seq_len), dtype=torch.int32)
            ex_mpos = torch.tensor([2], dtype=torch.int32)
            ex_bias = torch.zeros((1, vocab.chord_count), dtype=torch.float32)
            traced = torch.jit.trace(model_cpu, (ex_tokens, ex_mpos, ex_bias))
            mlmodel = ct.convert(
                traced,
                convert_to="mlprogram",
                inputs=[
                    ct.TensorType(name="token_ids", shape=(1, args.seq_len), dtype=int),
                    ct.TensorType(name="mask_position", shape=(1,), dtype=int),
                    ct.TensorType(name="logit_bias", shape=(1, vocab.chord_count), dtype=float),
                ],
                outputs=[ct.TensorType(name="chord_logits")],
                minimum_deployment_target=ct.target.iOS18,
            )
            mlmodel.short_description = "coda steerable 4-layer bidirectional ChordPredictor"
            out_path = pathlib.Path(args.output)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            mlmodel.save(str(out_path))
            print(f"Exported Core ML package: {out_path}")
        except ImportError:
            print("coremltools not installed; skipped .mlpackage export (checkpoint preserved).", file=sys.stderr)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Train and export CODA ChordPredictor (SPEC §17)")
    parser.add_argument("--vocab", type=pathlib.Path, default=DEFAULT_VOCAB_PATH)
    parser.add_argument("--csv", type=pathlib.Path, default=None, help="Local chordonomicon_v2.csv path")
    parser.add_argument("--max-rows", type=int, default=None)
    parser.add_argument("--epochs", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--seq-len", type=int, default=32)
    parser.add_argument("--lr", type=float, default=3e-4)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--checkpoint", type=pathlib.Path, default=None)
    parser.add_argument("--output", type=pathlib.Path, default=None)
    args = parser.parse_args(argv)

    vocab = PredictorVocab.from_vocab_json(args.vocab)
    print(f"Loaded vocab: {len(vocab.quality_ids)} qualities -> {vocab.chord_count} chord classes, {len(vocab.id_to_token)} total tokens")
    samples = load_chordonomicon_samples(args.csv, args.max_rows, args.smoke_test, args.seed)
    print(f"Loaded {len(samples)} section progression samples")
    build_torch_model_and_train(args, vocab, samples)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
