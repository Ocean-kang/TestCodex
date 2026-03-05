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

* `metrics.json`（**内容由实现者自行定义**）：

  * 必须是合法 JSON（推荐是一个 object）
  * 必须包含：
    * `ok`：boolean，表示本次运行是否“通过”
    * `details`：string，清晰说明你定义的 metrics 含义、计算方式、以及 `ok` 的判定规则
  * 其他字段（例如 `metrics`/`score`/`max_err` 等）**完全自由**，由你自己决定

> 目标是让 Codex/实现者自行决定什么是“好”的 metrics；只要定义清晰、确定性、可复现即可。

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

本任务**不要求**引入或运行 pytest。

（可选）你可以提供简单的自检脚本或在 CLI 中输出更多调试信息，便于在远端 `run.log` 里定位问题。

## 验收标准

* `python -m src.projector --out <dir> --seed 123` 生成的 `<dir>/metrics.json` 中：

  * `ok == true`
* 结果可复现：同 seed 重复运行，`metrics.json` 完全一致

额外要求：远端运行产生的 `run.log` 中应包含 `metrics.json` 的内容（便于回传后直接查看）。

