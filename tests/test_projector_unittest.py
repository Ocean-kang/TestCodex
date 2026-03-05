import json
import tempfile
import unittest
from pathlib import Path

import torch
from torch import nn

from src.projector import (
    DEFAULT_ERR_THRESHOLD,
    Projector,
    _build_reference_linear,
    _init_linear_deterministic,
    run_cli,
)


class ProjectorTests(unittest.TestCase):
    def test_forward_shapes(self) -> None:
        p = Projector(seed=123)
        x_1d = torch.randn(4096)
        x_2d = torch.randn(2, 4096)
        x_3d = torch.randn(2, 3, 4096)

        self.assertEqual(tuple(p(x_1d).shape), (1024,))
        self.assertEqual(tuple(p(x_2d).shape), (2, 1024))
        self.assertEqual(tuple(p(x_3d).shape), (2, 3, 1024))

    def test_output_matches_reference_linear(self) -> None:
        seed = 123
        p = Projector(seed=seed)
        ref = _build_reference_linear(
            in_dim=4096,
            out_dim=1024,
            bias=True,
            seed=seed,
            dtype=torch.float32,
        )
        x = torch.randn(4, 5, 4096)
        with torch.no_grad():
            y = p(x)
            y_ref = ref(x)
        max_abs_err = (y - y_ref).abs().max().item()
        self.assertLessEqual(max_abs_err, DEFAULT_ERR_THRESHOLD)

    def test_deterministic_init_without_global_rng_side_effect(self) -> None:
        torch.manual_seed(999)
        before = torch.randn(8)

        layer = nn.Linear(4096, 1024, bias=True)
        _init_linear_deterministic(layer, seed=123)

        torch.manual_seed(999)
        after = torch.randn(8)
        self.assertTrue(torch.equal(before, after))

    def test_cli_metrics_is_reproducible(self) -> None:
        with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
            out1 = Path(d1)
            out2 = Path(d2)
            run_cli(out1, seed=123)
            run_cli(out2, seed=123)

            m1 = (out1 / "metrics.json").read_text(encoding="utf-8")
            m2 = (out2 / "metrics.json").read_text(encoding="utf-8")
            self.assertEqual(m1, m2)

            parsed = json.loads(m1)
            self.assertIs(parsed["ok"], True)
            self.assertIsInstance(parsed["details"], str)


if __name__ == "__main__":
    unittest.main()
