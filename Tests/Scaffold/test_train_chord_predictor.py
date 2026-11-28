"""Unit tests for CODA ChordPredictor data pipeline and baseline (SPEC §17)."""
import pathlib
import random
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import train_chord_predictor as tcp


class TrainChordPredictorTests(unittest.TestCase):
    def test_vocab_matches_production_vocab_json(self):
        vocab = tcp.PredictorVocab.from_vocab_json(tcp.DEFAULT_VOCAB_PATH)
        self.assertGreaterEqual(len(vocab.quality_ids), 27)
        self.assertEqual(vocab.chord_count, 12 * len(vocab.quality_ids))
        self.assertEqual(vocab.pad_id, 0)
        self.assertNotEqual(vocab.mask_id, vocab.pad_id)
        self.assertNotEqual(vocab.mask_ext_id(0), vocab.mask_ext_id(7))

    def test_chordonomicon_row_parsing_handles_sharps_flats_slash_and_sections(self):
        row = "<intro_1> Csmin7 Abmaj7 Fm9 G7alt <chorus_1> Bbmin7/Fs Dsno3d E7sus4 C"
        samples = tcp.parse_chordonomicon_row(row, "soul")
        self.assertEqual(len(samples), 2)
        self.assertEqual(samples[0].section, "<intro>")
        self.assertEqual(samples[0].genre, "soul")
        self.assertTrue(samples[0].has_extension)
        self.assertEqual(
            samples[0].chords,
            [(1, "minor7"), (8, "major7"), (5, "minor9"), (7, "dominant7alt")],
        )
        self.assertEqual(samples[1].section, "<chorus>")
        self.assertEqual(
            samples[1].chords,
            [(10, "minor7"), (3, "power"), (4, "dominant7sus4"), (0, "major")],
        )

    def test_transition_table_baseline_evaluates_synthetic_smoke_samples(self):
        vocab = tcp.PredictorVocab.from_vocab_json(tcp.DEFAULT_VOCAB_PATH)
        samples = tcp.build_synthetic_smoke_samples(random.Random(7), count=128)
        baseline = tcp.TransitionTableBaseline(vocab.chord_count)
        baseline.fit(samples[:100], vocab)
        metrics = tcp.evaluate_baseline(baseline, samples[100:], vocab)
        self.assertGreater(metrics["count"], 0)
        self.assertGreaterEqual(metrics["top5"], metrics["top1"])


if __name__ == "__main__":
    unittest.main()
