import argparse
import json
import math
from pathlib import Path
from typing import Optional

import torch
from torch import nn


DEFAULT_IN_DIM = 4096
DEFAULT_OUT_DIM = 1024
DEFAULT_DTYPE = torch.float32
DEFAULT_ERR_THRESHOLD = 1e-6


def _init_linear_deterministic(linear: nn.Linear, seed: int) -> None:
    """Initialize Linear parameters deterministically without touching global RNG state."""
    gen = torch.Generator(device="cpu")
    gen.manual_seed(seed)

    nn.init.kaiming_uniform_(linear.weight, a=math.sqrt(5), generator=gen)
    if linear.bias is not None:
        fan_in, _ = nn.init._calculate_fan_in_and_fan_out(linear.weight)
        bound = 1.0 / math.sqrt(fan_in) if fan_in > 0 else 0.0
        nn.init.uniform_(linear.bias, -bound, bound, generator=gen)


class Projector(nn.Module):
    def __init__(
        self,
        in_dim: int = DEFAULT_IN_DIM,
        out_dim: int = DEFAULT_OUT_DIM,
        bias: bool = True,
        seed: int = 123,
        dtype: torch.dtype = DEFAULT_DTYPE,
    ) -> None:
        super().__init__()
        self.in_dim = in_dim
        self.out_dim = out_dim
        self.bias = bias
        self.seed = seed

        self.linear = nn.Linear(in_dim, out_dim, bias=bias, dtype=dtype)
        _init_linear_deterministic(self.linear, seed=seed)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if x.shape[-1] != self.in_dim:
            raise ValueError(
                f"Expected input last dim to be {self.in_dim}, got {x.shape[-1]}"
            )
        return self.linear(x)


def _build_reference_linear(
    in_dim: int,
    out_dim: int,
    bias: bool,
    seed: int,
    dtype: torch.dtype,
) -> nn.Linear:
    ref = nn.Linear(in_dim, out_dim, bias=bias, dtype=dtype)
    _init_linear_deterministic(ref, seed=seed)
    return ref


def compute_score(
    projector: Projector,
    seed: int,
    threshold: float = DEFAULT_ERR_THRESHOLD,
) -> tuple[float, float]:
    ref = _build_reference_linear(
        in_dim=projector.in_dim,
        out_dim=projector.out_dim,
        bias=projector.bias,
        seed=seed,
        dtype=projector.linear.weight.dtype,
    )

    gen = torch.Generator(device="cpu")
    gen.manual_seed(seed + 1)
    x = torch.randn(3, 5, projector.in_dim, generator=gen, dtype=projector.linear.weight.dtype)

    with torch.no_grad():
        out_proj = projector(x)
        out_ref = ref(x)

    max_abs_err = (out_proj - out_ref).abs().max().item()
    score = 1.0 if max_abs_err <= threshold else 0.0
    return score, max_abs_err


def run_cli(out_dir: Path, seed: int) -> dict:
    projector = Projector(seed=seed)
    score, max_abs_err = compute_score(projector=projector, seed=seed)

    metrics = {
        "ok": score >= 0.90,
        "score": score,
        "details": (
            f"reference=nn.Linear({projector.in_dim},{projector.out_dim},bias={projector.bias}); "
            f"dtype={projector.linear.weight.dtype}; seed={seed}; "
            f"max_abs_err={max_abs_err:.8e}; threshold={DEFAULT_ERR_THRESHOLD:.1e}"
        ),
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    metrics_path = out_dir / "metrics.json"
    metrics_path.write_text(
        json.dumps(metrics, ensure_ascii=False, separators=(", ", ": ")) + "\n",
        encoding="utf-8",
    )
    return metrics


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Deterministic 4096->1024 projector")
    parser.add_argument("--out", required=True, help="Output directory for metrics.json")
    parser.add_argument("--seed", type=int, default=123, help="Random seed")
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)
    run_cli(out_dir=Path(args.out), seed=args.seed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
