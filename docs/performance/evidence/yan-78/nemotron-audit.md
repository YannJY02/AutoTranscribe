**Nemotron 58 秒双遍实测独立审计**

结论：保存的输入、输出、评分和 native 调用耗时一致；57 项一致性核对通过。两遍最终原文逐字相同，分别与 native final 和最后一条 final 文本事件相同。英文漏词已经存在于 native 输出，不能归因于 driver 累加、去重或 final 拼接。此结论只针对本次模型、运行时及 auto prompt 配置，尚未定位 native 内部原因。

两遍最终原文如下；JSON 审计分别保存了每遍原文、事件编号及校验值：

> 我们先固定今天的测试文件和操作顺序 for every measured run决定使用冻结方案不再运行中修改内容s before the next run 这段短暂交叉发言也保留在测试里 a failed validation produces no benchmark result 内容都是合成的 不来自私人会议。

独立使用标准库动态规划与回溯复算，未调用实验 scorer。归一化为 NFKC、小写和标准撇号；中文按汉字计数，英文按字母数字及词内撇号提取。孤立的 `s` 计作一个英文单位。两遍结果均为：

| 指标 | 参考分母 | 输出单位 | 替换 | 删除 | 插入 | 总错误率 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 中文 CER | 65 | 63 | 1 | 2 | 0 | 3/65 = 4.6154% |
| 英文 WER | 28 | 16 | 1 | 12 | 0 | 13/28 = 46.4286% |

中文为 `在→再` 和删除 `所有`。英文删除 `The same input will be replayed`、`I will check the hashes and`，将 `durations` 对齐为 `s`；最后一段英文完整。两个英文开头的完整短语从未出现在任一原始 native result 中。原始 partial 已从 `for ever` 和 `s befor` 继续增长，原始 final 保留同样的缺词。每遍 175 条 partial 均按前缀增长；flush 只把 `A` 改为 `a`、去掉两处逗号并加句末 `。`，评分用的汉字/英文单位未改变。

每遍各有 182 次 release 和 push，共 928000 帧（16000 Hz、58 秒）；181 包为 5120 帧，最后一包 1280 帧。release 在对应 push 前发生，输入区间从 0 连续覆盖至 928000，没有遗漏或重复。每遍保留 176 个 native result（175 partial、1 final）、60 次文本发布和 359 次 next；唯一 final 均在成功同步 finish 后返回。

| 时间核查项 | 第 1 遍 | 第 2 遍 |
| --- | ---: | ---: |
| 首次非空文本，报告值 / ms | 2620.194 | 2603.042 |
| 首次非空文本，原始事件 / ms | 2620.203 | 2603.054 |
| 原始 final 文本事件 / ms | 58080.187 | 58080.980 |
| adapter 返回，报告 final 值 / ms | 58080.774 | 58081.253 |
| final 距名义音频结束 / ms | 80.187 | 80.980 |
| native next 合计 / ms | 6992.504 | 6283.083 |
| 同步 finish / ms | 50.134 | 52.109 |
| next + finish / ms | 7042.638 | 6335.192 |
| 最大 source lateness / ms | 566.892 | 12.070 |

首次文本均为“我”。固定 reference 的第一段从 2000 ms 开始，因此首次文本事件分别位于该标注起点后 620.203 / 603.054 ms；它们不等同于每个词的端到端延迟。第 1 遍最大输入迟到发生在第 3 次 release（名义 960 ms），之前对 640 ms 输入的 native next 用了 878.094 ms。这个停顿发生在第一段标注语音之前，含 2 秒起始静音的本样本不能检验冷启动后立即说话的表现。

报告中的 `final_text_available_ms` 是 adapter.run 返回时刻，原始 final 发布事件更早（两遍分别早 0.587 / 0.273 ms）。`native_next_ms` 含 C next 和结果读回/释放，finish 是同步尾部解码；合计不包括 pacing、Python/音频准备、日志写入、push 和 stream 创建/释放，不能当完整实时墙钟或纯 encoder 时间。

模型 setup 为 13367.864 ms，其中动态库 ready 2548.317 ms、recognizer create 10818.848 ms；native stderr 记录 `backend=MTL0`。

RSS 共 128 次采样，128 次可用，采样区间为 driver 时钟 0.00194–129.57703 秒。最大采样间隔 1.097 秒，记录的进程墙钟为 130.592 秒，最后样本到 driver 结束约 1.015 秒。观测到的 RSS 峰值为 1031728 KiB = 1007.54688 MiB（15.215 秒处）；`max_rss_mib=8192` 是停止阈值。该 RSS 只覆盖 worker 驻留内存，不能代表完整 GPU/统一内存、整个应用内存或两次采样之间的真实峰值，也未按独立时钟强行拆分每遍 RSS。

本次 Nemotron 运行期间，其他公开模型权重下载仍在进行。controller 在开始时列出了：

- `vibevoice/official-model/model-00002-of-00003.safetensors.partial`
- `vibevoice/official-model/model-00001-of-00003.safetensors.partial`
- `vibevoice/official-model/tokenizer.json.partial`
- `voxtral/model/model.safetensors.partial`

没有同步记录下载速率、磁盘 I/O 或换页活动，无法扣除其影响。setup 和首流时延可能受 I/O 干扰；两遍首次文本的约 17 ms 差异以及与其他模型的小差值不能形成严格性能排名。controller 的 26 次采样 thermal 均为 0，未观察到可写录音记录句柄，结束后安装应用、运行配置与 consent 校验值保持一致；这些检查不能排除下载、缓存或后台系统负载。

native 词时间戳另有边界：最后一个词结束在 58320 ms，比输入长 320 ms，且一个中英文粘连“词”跨 17280 ms。这些 offset 未作为延迟或 CER/WER 的依据。此审计按固定 reference 检查一个合成片段，未重新听音、运行模型或安装依赖；未检验标点质量、说话人、跨语言词序、capture/IPC/UI、产品队列策略或真实会议质量。

证据：原始报告 (`logs/yan78/nemotron/short.json`)、原始事件 (`logs/yan78/nemotron/short.json.events.jsonl`)、RSS 样本 (`logs/yan78/nemotron/short.json.resources.json`)、controller (`logs/yan78/nemotron-short.controller.json`)、固定 reference (`logs/yan78/inputs/reference-58s.json`)。审计 JSON 保存了这些文件的 SHA256、逐遍核查、独立编辑操作和原始事件编号。
