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
        if x.ndim not in (1, 2, 3):
            raise ValueError(f"Expected input rank in (1,2,3), got rank={x.ndim}")
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
) -> tuple[float, float, dict[str, float]]:
    ref = _build_reference_linear(
        in_dim=projector.in_dim,
        out_dim=projector.out_dim,
        bias=projector.bias,
        seed=seed,
        dtype=projector.linear.weight.dtype,
    )

    gen = torch.Generator(device="cpu")
    gen.manual_seed(seed + 1)
    x_1d = torch.randn(projector.in_dim, generator=gen, dtype=projector.linear.weight.dtype)
    x_2d = torch.randn(3, projector.in_dim, generator=gen, dtype=projector.linear.weight.dtype)
    x_3d = torch.randn(3, 5, projector.in_dim, generator=gen, dtype=projector.linear.weight.dtype)

    with torch.no_grad():
        err_1d = (projector(x_1d) - ref(x_1d)).abs().max().item()
        err_2d = (projector(x_2d) - ref(x_2d)).abs().max().item()
        err_3d = (projector(x_3d) - ref(x_3d)).abs().max().item()

    max_abs_err = max(err_1d, err_2d, err_3d)
    score = 1.0 if max_abs_err <= threshold else 0.0
    err_by_shape = {
        "[4096]": err_1d,
        "[B,4096]": err_2d,
        "[B,T,4096]": err_3d,
    }
    return score, max_abs_err, err_by_shape


def run_cli(out_dir: Path, seed: int) -> dict:
    projector = Projector(seed=seed)
    score, max_abs_err, err_by_shape = compute_score(projector=projector, seed=seed)
    ok = max_abs_err <= DEFAULT_ERR_THRESHOLD

    metrics = {
        "ok": ok,
        "score": score,
        "max_abs_err": max_abs_err,
        "threshold": DEFAULT_ERR_THRESHOLD,
        "err_by_shape": err_by_shape,
        "config": {
            "in_dim": projector.in_dim,
            "out_dim": projector.out_dim,
            "bias": projector.bias,
            "dtype": str(projector.linear.weight.dtype),
            "seed": seed,
        },
        "details": (
            "Metric definition: build a reference nn.Linear with identical dims/bias and "
            "the same deterministic initialization seed; compare Projector and reference "
            "outputs on 1D/2D/3D float32 CPU inputs; compute max absolute error over all "
            "elements and shapes. "
            f"Rule: ok=true iff max_abs_err <= {DEFAULT_ERR_THRESHOLD:.1e}. "
            f"Reference used: nn.Linear({projector.in_dim},{projector.out_dim},bias={projector.bias})."
        ),
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    metrics_path = out_dir / "metrics.json"
    metrics_json = json.dumps(metrics, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    metrics_path.write_text(metrics_json, encoding="utf-8")
    print(metrics_json, end="")
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
