"""macOS 弹窗确认 & 通知中心集成 & 进度弹窗。"""

import subprocess
import logging
import threading

logger = logging.getLogger(__name__)


def _run_osascript(script: str, timeout: int = 120) -> str:
    """执行 AppleScript 并返回结果。"""
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=timeout,
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        logger.warning("osascript 超时（用户可能未响应）")
        return ""
    except Exception as e:
        logger.error(f"osascript 执行失败: {e}")
        return ""


def _run_osascript_async(script: str) -> None:
    """在后台线程执行 AppleScript（不阻塞主流程）。"""
    def _run():
        _run_osascript(script, timeout=10)
    t = threading.Thread(target=_run, daemon=True)
    t.start()


# ── 确认弹窗 ──────────────────────────────────────────────

def ask_confirm(filename: str, filesize_mb: float) -> bool:
    """弹出对话框询问用户是否转录，返回 True/False。"""
    # 转义文件名中的特殊字符
    safe_name = filename.replace('"', '\\"').replace("'", "'")
    script = f'''
        display dialog "检测到新视频文件:\\n\\n📄 {safe_name}\\n📦 大小: {filesize_mb:.1f} MB\\n\\n是否进行自动转录？" ¬
            buttons {{"跳过", "转录"}} default button "转录" ¬
            with title "🎙 自动转录系统" with icon note ¬
            giving up after 60
        set theButton to button returned of result
        return theButton
    '''
    result = _run_osascript(script)
    if result == "转录":
        return True
    else:
        logger.info(f"用户选择跳过: {filename}")
        return False


# ── 通知中心（自动消失，不打断用户）─────────────────────

def notify(title: str, message: str, sound: str = "default") -> None:
    """发送 macOS 通知中心消息（异步，不阻塞）。"""
    # 转义引号
    safe_msg = message.replace('"', '\\"')
    safe_title = title.replace('"', '\\"')
    script = f'''
        display notification "{safe_msg}" ¬
            with title "{safe_title}" ¬
            sound name "{sound}"
    '''
    _run_osascript_async(script)


# ── 阶段进度通知 ──────────────────────────────────────────

def notify_stage(filename: str, stage: str, detail: str = "") -> None:
    """
    发送转录阶段进度通知。

    stage 示例: "1/4 提取音频", "2/4 检测语言", "3/4 转录中", "4/4 保存文件"
    """
    msg = f"{filename}\\n⏳ {stage}"
    if detail:
        msg += f"\\n{detail}"
    notify("🎙 转录进度", msg)


def notify_start(filename: str, filesize_mb: float) -> None:
    """通知开始转录。"""
    notify("🎙 开始转录", f"{filename} ({filesize_mb:.1f} MB)\\n⏳ 准备中...")


# ── 结果弹窗（需要用户点击确认，确保看到）──────────────

def show_result_dialog(
    filename: str,
    success: bool,
    lang: str = "",
    duration_str: str = "",
    elapsed_str: str = "",
    segments_count: int = 0,
    speakers_count: int = 0,
    output_file: str = "",
    error: str = "",
) -> None:
    """
    弹出结果对话框，显示转录结果摘要。
    用户必须点击关闭，确保不会错过。
    """
    if success:
        lang_label = {"zh": "中文", "en": "English", "en_cn": "中英混合"}.get(lang, lang)
        msg_lines = [
            f"✅ 转录完成！\\n",
            f"📄 文件: {filename}",
            f"🌐 语言: {lang_label}",
            f"⏱ 音频时长: {duration_str}",
            f"⚡ 转录耗时: {elapsed_str}",
            f"📝 识别片段: {segments_count} 段",
            f"👥 说话人数: {speakers_count} 人",
            f"\\n💾 文稿已保存: {output_file}",
        ]
        msg = "\\n".join(msg_lines)
        icon = "note"
        title = "✅ 转录完成"
        buttons = '"好的"'
    else:
        short_error = error[:120] + "..." if len(error) > 120 else error
        # 转义错误消息中的特殊字符
        short_error = short_error.replace('"', '\\"').replace("'", "'")
        msg_lines = [
            f"❌ 转录失败\\n",
            f"📄 文件: {filename}",
            f"⚡ 已用时: {elapsed_str}",
            f"\\n❗ 错误: {short_error}",
        ]
        msg = "\\n".join(msg_lines)
        icon = "stop"
        title = "❌ 转录失败"
        buttons = '"确定"'

    script = f'''
        display dialog "{msg}" ¬
            buttons {{{buttons}}} default button 1 ¬
            with title "{title}" with icon {icon} ¬
            giving up after 300
    '''
    # 在后台线程运行，不阻塞监控
    _run_osascript_async(script)


# ── 保留的简单通知（向后兼容）─────────────────────────

def notify_done(filename: str, lang: str, duration_str: str) -> None:
    """通知中心消息：转录完成。"""
    lang_label = {"zh": "中文", "en": "English", "en_cn": "中英混合"}.get(lang, lang)
    notify(
        "✅ 转录完成",
        f"{filename}\\n语言: {lang_label} | 耗时: {duration_str}",
        sound="Glass",
    )


def notify_fail(filename: str, error: str) -> None:
    """通知中心消息：转录失败。"""
    short_error = error[:80] + "..." if len(error) > 80 else error
    notify("❌ 转录失败", f"{filename}\\n{short_error}", sound="Basso")
