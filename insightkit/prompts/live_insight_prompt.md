任务：基于最近 120 秒转写片段，生成直播洞察增量。
要求：
- 输出纯 JSON，key 必须使用英文（session_overview, highlight_insights, speaker_perspectives, decision_ledger, action_tracks, timeline_beats, provenance_links）。
- 优先更新：session_overview, highlight_insights, decision_ledger, action_tracks。
- session_overview 必须包含 title, overview, topics。
- 新条目必须附 evidence_span（start_ms, end_ms）。
- 如果某模块无内容，返回空数组 []。
- 严格保持 JSON Schema 可校验。
输入：
{{TRANSCRIPT_WINDOW_JSON}}
