import json
import subprocess
import sys
from pathlib import Path

import torch

from src.projector import Projector, _build_reference_linear


def test_shapes() -> None:
    projector = Projector(seed=123)

    x1 = torch.randn(4096)
    y1 = projector(x1)
    assert y1.shape == (1024,)

    x2 = torch.randn(4, 4096)
    y2 = projector(x2)
    assert y2.shape == (4, 1024)

    x3 = torch.randn(2, 3, 4096)
    y3 = projector(x3)
    assert y3.shape == (2, 3, 1024)


def test_numerical_match_reference_linear() -> None:
    seed = 321
    projector = Projector(seed=seed)
    ref = _build_reference_linear(4096, 1024, bias=True, seed=seed, dtype=torch.float32)

    x = torch.randn(2, 5, 4096)
    with torch.no_grad():
        y_proj = projector(x)
        y_ref = ref(x)

    torch.testing.assert_close(y_proj, y_ref, rtol=1e-6, atol=1e-6)


def test_determinism_same_seed_same_output() -> None:
    seed = 999
    gen = torch.Generator(device="cpu")
    gen.manual_seed(2026)
    x = torch.randn(3, 4096, generator=gen)

    p1 = Projector(seed=seed)
    p2 = Projector(seed=seed)

    with torch.no_grad():
        y1 = p1(x)
        y2 = p2(x)

    assert torch.equal(y1, y2)


def test_cli_writes_metrics_and_is_reproducible(tmp_path: Path) -> None:
    out_dir = tmp_path / "out"

    cmd = [sys.executable, "-m", "src.projector", "--out", str(out_dir), "--seed", "123"]
    subprocess.run(cmd, check=True)

    metrics_path = out_dir / "metrics.json"
    assert metrics_path.exists()

    text1 = metrics_path.read_text(encoding="utf-8")
    data1 = json.loads(text1)
    assert data1["ok"] is True
    assert data1["score"] >= 0.90
    assert set(data1.keys()) == {"ok", "score", "details"}

    subprocess.run(cmd, check=True)
    text2 = metrics_path.read_text(encoding="utf-8")

    assert text1 == text2
