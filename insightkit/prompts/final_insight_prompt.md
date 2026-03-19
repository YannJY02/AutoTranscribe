任务：基于全量会议转写，生成定稿洞察。
要求：
- 输出纯 JSON，key 必须使用英文（session_overview, highlight_insights, speaker_perspectives, decision_ledger, action_tracks, timeline_beats, provenance_links）。
- 覆盖全部七个模块，每个模块不得缺失。
- session_overview 必须包含 title, overview, topics。
- decision_ledger 每条需给出：problem, options, decision, rationale, owner, needs_review, evidence_span。
- action_tracks 每条需给出：task, owner, due_at, priority, status, needs_review, evidence_span。
- highlight_insights 每条需给出：quote, reason, speaker, evidence_span。
- timeline_beats 每条需给出：timestamp, title, summary。
- 如果某模块无内容，返回空数组 []。
- 严格保持 JSON Schema 可校验。
输入：
{{FULL_TRANSCRIPT_JSON}}
