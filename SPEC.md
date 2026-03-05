or 映射到 1024 维，并满足可复现与可测试要求。

## 目标功能

1. 实现一个 Python 模块：`src/projector.py`
2. 该模块提供一个可调用的 Projector：

   * `Projector(in_dim=4096, out_dim=1024, ...)`
   * `forward(x)` 支持输入形状：

     * `[4096]`
     * `[B, 4096]`
     * `[B, T, 4096]`
   * 输出形状对应为：

     * `[1024]`
     * `[B, 1024]`
     * `[B, T, 1024]`

## CLI（用于远端运行与产物落盘）

必须支持命令：

```bash
python -m src.projector --out <dir> --seed 123
```

运行后必须在 `<dir>` 下写出：

* `metrics.json`，格式严格为：

```json
{"ok": true, "score": <0~1的浮点数>, "details": "..."}
```

其中：

* `score` 定义为：在固定随机输入上，输出与“参考实现”的最大绝对误差满足阈值时得分为 1，否则为 0（或根据误差映射为 0~1，但必须确定性）
* `ok` 判定规则：`ok = (score >= 0.90)`

> 注意：同一 seed 多次运行，`metrics.json` 内容必须完全一致（逐字一致）。

## 参考实现（必须一致）

参考实现为：

* 一个 `nn.Linear(4096, 1024, bias=<可选>)`（你可以选择 bias=True/False，但要在 details 里说明）
* 权重初始化必须是确定性的（由 seed 控制）
* Projector 前向就是线性层前向，不允许偷偷改变行为（例如随机 dropout）。

也就是说：你的 `Projector` 的输出应与“同参数、同权重”的 `nn.Linear` 输出一致（误差在 float32 数值误差范围内）。

## 约束

* 必须使用 PyTorch（torch）
* 不要联网下载大文件
* 不要依赖 GPU（默认用 CPU 跑即可）
* 只能修改仓库工作区代码（例如 `src/`、`tests/`、必要的配置文件），不要做 git push/ssh/scp（这些由外层脚本完成）
* 如果存在 `log/last_run/`（或 `.autolog/last_run/`）里的 `run.log` / `metrics.json`，请阅读并据此改进

## 测试要求

新增 pytest 测试，要求 `pytest -q` 通过（如果本地环境没有 pytest 命令，请用 venv 的 python -m pytest）。
测试至少覆盖：

1. 形状检查：三种输入形状都输出正确形状
2. 数值一致性：与参考 `nn.Linear` 的输出 close（例如 `torch.testing.assert_close`，rtol/atol 合理）
3. 确定性：同 seed 初始化与同输入下输出完全一致（可用 `torch.allclose` 或直接比较 tensor）
4. CLI 产物：`python -m src.projector --out tmp --seed 123` 会生成 `metrics.json`，且 `ok=true`、`score>=0.90`

## 验收标准

* `python -m src.projector --out <dir> --seed 123` 生成的 `<dir>/metrics.json` 中：

  * `ok == true`
  * `score >= 0.90`
* 结果可复现：同 seed 重复运行，`metrics.json` 完全一致
* 测试通过：`pytest -q` 通过

