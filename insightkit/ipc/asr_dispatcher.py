"""ASR runtime dispatcher for InsightKit RPC."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from scripts.asr_runtime_profile import attach_asr_runtime_profile
from scripts.asr_runtime_bootstrap import bootstrap_runtime, runtime_status
from scripts.transcriber import prewarm_asr, runtime_backend_status, runtime_warm_status, transcribe, transcribe_audio_chunk


class ASRDispatcher:
    def asr_runtime_status(self, params: dict[str, Any]) -> dict[str, Any]:
        engine = str(params.get("engine", "") or "").strip() or None
        status = runtime_status(engine=engine)
        return attach_asr_runtime_profile(
            status,
            backend=runtime_backend_status(engine=engine),
            warm=runtime_warm_status(),
            configured_engine=engine,
        )

    def asr_runtime_bootstrap(self, params: dict[str, Any]) -> dict[str, Any]:
        model = str(params.get("model", "") or "").strip() or None
        engine = str(params.get("engine", "") or "").strip() or None
        return bootstrap_runtime(model_name=model, engine=engine)

    def asr_prewarm(self, params: dict[str, Any]) -> dict[str, Any]:
        engine = str(params.get("engine", "") or "").strip() or None
        model = str(params.get("model", "") or "").strip() or None
        try:
            timeout_sec = max(3, min(120, int(params.get("timeout_sec", 20))))
        except Exception:
            timeout_sec = 20
        result = prewarm_asr(engine=engine, model=model, timeout_sec=timeout_sec)
        if "backend" not in result:
            result["backend"] = runtime_backend_status(engine=engine)
        if "warm" not in result:
            result["warm"] = runtime_warm_status()
        return result

    def asr_transcribe_chunk(self, params: dict[str, Any]) -> dict[str, Any]:
        wav_path = str(params.get("wav_path", "") or "").strip()
        if not wav_path:
            raise ValueError("wav_path is required")
        offset_ms = int(params.get("offset_ms", 0))
        source = str(params.get("source", "") or "").strip() or "mixed"
        segments = transcribe_audio_chunk(Path(wav_path).expanduser().resolve(), offset_ms=offset_ms)
        for seg in segments:
            seg["source"] = source
        return {"segments": segments}

    def asr_transcribe_media(self, params: dict[str, Any]) -> dict[str, Any]:
        media_path = str(params.get("media_path", "") or "").strip()
        if not media_path:
            raise ValueError("media_path is required")
        source = str(params.get("source", "") or "").strip() or "media"
        result = transcribe(Path(media_path).expanduser().resolve())
        segments = []
        for seg in result.get("segments", []):
            text = str(seg.get("text", "") or "").strip()
            if not text:
                continue
            start_ms = int(seg.get("start", 0) or 0)
            end_ms = int(seg.get("end", 0) or 0)
            if end_ms <= start_ms:
                end_ms = start_ms + 1200
            segments.append({
                "start_ms": start_ms,
                "end_ms": end_ms,
                "speaker": str(seg.get("speaker", "") or ""),
                "text": text,
                "confidence": float(seg.get("confidence", 0.0) or 0.0),
                "source": source,
            })
        return {
            "duration": float(result.get("duration", 0.0) or 0.0),
            "lang": str(result.get("lang", "") or ""),
            "segments": segments,
        }
