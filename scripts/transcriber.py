"""
FunASR 转录引擎 — 语言检测 + ASR + 说话人分离。

模型采用懒加载策略：首次使用时加载，之后常驻内存以加速后续转录。
"""

import logging
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# 全局模型缓存 + 锁
_models: dict = {}
_models_lock = threading.Lock()


def _get_audio_duration(audio_path: str) -> float:
    """使用 ffprobe 获取音频时长（秒）。"""
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "quiet",
                "-show_entries", "format=duration",
                "-of", "csv=p=0",
                audio_path,
            ],
            capture_output=True, text=True, timeout=30,
        )
        return float(result.stdout.strip())
    except Exception as e:
        logger.warning(f"无法获取音频时长: {e}")
        return 0.0


def extract_audio(video_path: Path, output_path: Optional[Path] = None) -> Path:
    """从视频中提取 16kHz 单声道 WAV 音频。"""
    if output_path is None:
        output_path = Path(tempfile.mktemp(suffix=".wav"))

    logger.info(f"提取音频: {video_path.name} → {output_path.name}")
    cmd = [
        "ffmpeg", "-y", "-i", str(video_path),
        "-vn",                  # 不要视频
        "-acodec", "pcm_s16le", # 16-bit PCM
        "-ar", "16000",         # 16kHz
        "-ac", "1",             # 单声道
        str(output_path),
    ]
    result = subprocess.run(
        cmd, capture_output=True, text=True, timeout=600,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg 失败: {result.stderr[-500:]}")
    logger.info("音频提取完成")
    return output_path


def _load_model(key: str):
    """懒加载模型，首次加载后常驻内存。"""
    from funasr import AutoModel
    from config import (
        LID_MODEL, ASR_MODEL_ZH,
        VAD_MODEL, SPK_MODEL, PUNC_MODEL,
    )

    with _models_lock:
        if key in _models:
            return _models[key]

        logger.info(f"加载模型: {key}")
        t0 = time.time()

        if key == "lid":
            model = AutoModel(model=LID_MODEL, disable_update=True)
        elif key == "asr":
            # 统一使用中文模型：它同时支持中英文，且是唯一支持
            # 时间戳 + 说话人分离 (punc_model + spk_model) 的模型
            model = AutoModel(
                model=ASR_MODEL_ZH,
                vad_model=VAD_MODEL,
                punc_model=PUNC_MODEL,
                spk_model=SPK_MODEL,
                disable_update=True,
            )
        else:
            raise ValueError(f"未知模型 key: {key}")

        dt = time.time() - t0
        logger.info(f"模型 {key} 加载完成 ({dt:.1f}s)")
        _models[key] = model
        return model


def detect_language(audio_path: Path) -> str:
    """
    使用 SenseVoice 检测音频语言。
    返回 'zh'、'en' 或 'en_cn'（中英混合）。默认 'zh'。
    """
    logger.info("检测语言...")
    try:
        model = _load_model("lid")
        result = model.generate(input=str(audio_path), language="auto")

        if result and len(result) > 0:
            text = str(result[0].get("text", ""))
            logger.info(f"SenseVoice 原始输出: {text[:200]}")

            # 提取语言标签
            tag = ""
            if "<|zh|>" in text or "<|yue|>" in text:
                tag = "zh"
            elif "<|en|>" in text:
                tag = "en"
            elif "<|ja|>" in text:
                tag = "zh"  # 日语 fallback
            else:
                tag = "zh"  # 默认

            # 检查是否中英混合：在转录文本中查找中文字符
            # 去掉 SenseVoice 标签后的纯文本
            import re
            pure_text = re.sub(r"<\|[^|]+\|>", "", text)
            has_chinese = bool(re.search(r"[\u4e00-\u9fff]", pure_text))
            has_english = bool(re.search(r"[a-zA-Z]{2,}", pure_text))

            if has_chinese and has_english:
                logger.info("检测到语言: 中英混合 (en_cn)")
                return "en_cn"
            elif tag == "zh":
                logger.info("检测到语言: 中文")
                return "zh"
            else:
                logger.info("检测到语言: English")
                return "en"
        else:
            logger.warning("SenseVoice 无输出，默认使用中文")
            return "zh"
    except Exception as e:
        logger.error(f"语言检测失败: {e}，默认使用中文")
        return "zh"


def transcribe(video_path: Path) -> dict:
    """
    完整转录流程：提取音频 → 语言检测 → ASR + 说话人分离。

    返回:
        {
            "lang": "zh" | "en",
            "duration": float,   # 秒
            "segments": [
                {"start": int, "end": int, "text": str, "speaker": str},
                ...
            ],
        }
    """
    audio_path = None
    try:
        # 1. 提取音频
        audio_path = extract_audio(video_path)
        duration = _get_audio_duration(str(audio_path))
        logger.info(f"音频时长: {duration:.1f}s")

        # 2. 语言检测（用于文件命名，不影响模型选择）
        lang = detect_language(audio_path)

        # 3. ASR + 说话人分离（统一使用 zh 模型，支持中英文+时间戳+说话人）
        logger.info(f"开始转录 (检测语言: {lang}, 引擎: Paraformer-zh)...")
        t0 = time.time()

        asr_model = _load_model("asr")
        result = asr_model.generate(input=str(audio_path))

        dt = time.time() - t0
        logger.info(f"转录完成，耗时: {dt:.1f}s")

        # 4. 解析结果
        segments = _parse_funasr_result(result)

        return {
            "lang": lang,
            "duration": duration,
            "segments": segments,
        }

    finally:
        # 清理临时音频文件
        if audio_path and audio_path.exists():
            try:
                audio_path.unlink()
            except Exception:
                pass


def _parse_funasr_result(result) -> list[dict]:
    """
    解析 FunASR 的输出结果为统一的 segments 格式。

    FunASR 输出格式可能有多种形式，这里做兼容处理。
    """
    segments = []

    if not result:
        return segments

    for item in result:
        # item 可能是 dict 或其他对象
        if isinstance(item, dict):
            text = item.get("text", "")
            sentence_info = item.get("sentence_info", [])

            if sentence_info:
                # 有逐句信息（含时间戳和说话人）
                for sent in sentence_info:
                    seg = {
                        "start": sent.get("start", 0),
                        "end": sent.get("end", 0),
                        "text": sent.get("text", ""),
                        "speaker": sent.get("spk", ""),
                    }
                    # spk 可能是整数
                    if isinstance(seg["speaker"], int):
                        seg["speaker"] = f"spk{seg['speaker']}"
                    elif seg["speaker"]:
                        seg["speaker"] = str(seg["speaker"])
                    segments.append(seg)
            elif text:
                # 只有文本，没有逐句信息
                timestamp = item.get("timestamp", [])
                if timestamp and len(timestamp) > 0:
                    # 有时间戳列表
                    for i, ts in enumerate(timestamp):
                        if isinstance(ts, (list, tuple)) and len(ts) >= 2:
                            segments.append({
                                "start": ts[0],
                                "end": ts[1],
                                "text": text if i == 0 else "",
                                "speaker": "",
                            })
                else:
                    # 最简单的情况：只有一段文本
                    segments.append({
                        "start": 0,
                        "end": 0,
                        "text": text,
                        "speaker": "",
                    })
        else:
            # 兜底：尝试转为字符串
            segments.append({
                "start": 0,
                "end": 0,
                "text": str(item),
                "speaker": "",
            })

    return segments
