任务：基于全量会议转写，生成定稿洞察。
要求：
- 覆盖六大模块：会话总览、高光洞察、观点图谱、决策账本、执行清单、时间脉络。
- 决策账本需给出：problem/options/decision/rationale/owner/evidence_span。
- 执行清单需给出：task/owner/due_at/priority/status/evidence_span。
- 严格保持 JSON Schema 可校验。
输入：
{{FULL_TRANSCRIPT_JSON}}
