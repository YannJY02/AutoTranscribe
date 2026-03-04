任务：基于最近 120 秒转写片段，生成直播洞察增量。
要求：
- 优先更新：会话总览、高光洞察、决策账本、执行清单。
- 严格保持 JSON Schema 可校验。
- 新条目必须附 evidence_span。
输入：
{{TRANSCRIPT_WINDOW_JSON}}
