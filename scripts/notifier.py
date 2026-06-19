"""macOS 弹窗确认 & 通知中心集成 & 进度弹窗。"""

import subprocess
import logging
import threading
from dataclasses import dataclass

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RouteOption:
    label: str
    engine: str
    recommendation: str


ROUTE_DETAILS = (
    RouteOption("Whisper Turbo（通用/快速）", "whisper", "默认推荐：速度快、通用、最稳。"),
    RouteOption("FunASR（中文优先）", "funasr", "中文长音频/会议优先。"),
    RouteOption("Qwen3-ASR MLX（能力上限）", "qwen-mlx", "准确率上限：复杂中英混合。"),
)

ROUTE_OPTIONS = {route.label: route.engine for route in ROUTE_DETAILS}
ROUTE_RECOMMENDATIONS = {route.label: route.recommendation for route in ROUTE_DETAILS}


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

def route_from_dialog_result(result: str) -> str:
    """Map the AppleScript route label to an ASR engine name."""
    value = (result or "").strip()
    if value in {route.engine for route in ROUTE_DETAILS}:
        return value
    first_line = value.splitlines()[0].strip() if value else ""
    return ROUTE_OPTIONS.get(first_line, "")


def _route_by_engine(engine: str) -> RouteOption | None:
    for route in ROUTE_DETAILS:
        if route.engine == engine:
            return route
    return None


def _escape_applescript_text(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _applescript_string(value: str) -> str:
    return '"' + _escape_applescript_text(value).replace("\n", "\\n") + '"'


def _route_help_text() -> str:
    return "\\n".join(f"{route.label}\\n  {route.recommendation}" for route in ROUTE_DETAILS)


def _confirm_route_applescript(filename: str, filesize_mb: float, route: RouteOption) -> str:
    safe_name = _escape_applescript_text(filename)
    safe_route = _escape_applescript_text(route.label)
    safe_recommendation = _escape_applescript_text(route.recommendation)
    script = f'''
        tell application "Finder" to activate
        delay 0.1
        set confirmResult to display dialog "请确认转录任务:\\n\\n📄 {safe_name}\\n📦 大小: {filesize_mb:.1f} MB\\n🎛 路线: {safe_route}\\n   {safe_recommendation}" ¬
            buttons {{"返回选择", "跳过", "开始转录"}} default button "开始转录" cancel button "跳过" ¬
            with title "🎙 自动转录确认" with icon note ¬
            giving up after 300
        if gave up of confirmResult is true then
            return ""
        end if
        return button returned of confirmResult
    '''
    return _run_osascript(script, timeout=360)


def _ask_transcription_route_applescript(filename: str, filesize_mb: float) -> str:
    safe_name = _escape_applescript_text(filename)
    route_vars = "\n".join(
        f'            set route{index} to {_applescript_string(route.label)} & return & "  " & {_applescript_string(route.recommendation)}'
        for index, route in enumerate(ROUTE_DETAILS)
    )
    route_list = ", ".join(f"route{index}" for index, _route in enumerate(ROUTE_DETAILS))
    default_route = "route0"

    while True:
        script = f'''
{route_vars}
            tell application "Finder" to activate
            delay 0.1
            set routeChoice to choose from list {{{route_list}}} ¬
                with title "🎙 自动转录系统" ¬
                with prompt "检测到新音视频文件:\\n\\n📄 {safe_name}\\n📦 大小: {filesize_mb:.1f} MB\\n\\n请选择转录路线。每条路线下方是推荐说明，下一步会再次确认：" ¬
                default items {{{default_route}}} ¬
                OK button name "下一步" cancel button name "跳过"
            if routeChoice is false then
                return ""
            else
                return item 1 of routeChoice
            end if
        '''
        engine = route_from_dialog_result(_run_osascript(script, timeout=300))
        route = _route_by_engine(engine)
        if route is None:
            return ""

        action = _confirm_route_applescript(filename, filesize_mb, route)
        if action == "开始转录":
            return route.engine
        if action != "返回选择":
            return ""


def _ask_transcription_route_tk(filename: str, filesize_mb: float) -> str:
    import tkinter as tk
    from tkinter import font as tkfont

    def place_center(window: tk.Tk) -> None:
        window.update_idletasks()
        width = window.winfo_width()
        height = window.winfo_height()
        x = max(0, (window.winfo_screenwidth() - width) // 2)
        y = max(0, (window.winfo_screenheight() - height) // 3)
        window.geometry(f"+{x}+{y}")

    def choose_route() -> str:
        selected = {"engine": ""}
        root = tk.Tk()
        root.title("自动转录系统")
        root.resizable(False, False)
        root.attributes("-topmost", True)

        body = tk.Frame(root, padx=22, pady=18)
        body.pack(fill="both", expand=True)

        title_font = tkfont.nametofont("TkDefaultFont").copy()
        title_font.configure(size=16, weight="bold")
        hint_font = tkfont.nametofont("TkDefaultFont").copy()
        hint_font.configure(size=max(10, hint_font.cget("size") - 2))

        tk.Label(body, text="检测到新音视频文件", font=title_font, anchor="w").pack(fill="x")
        tk.Label(
            body,
            text=f"{filename}\n大小: {filesize_mb:.1f} MB",
            justify="left",
            anchor="w",
            pady=10,
        ).pack(fill="x")
        tk.Label(body, text="请选择转录路线：", anchor="w").pack(fill="x", pady=(4, 6))

        route_var = tk.StringVar(value=ROUTE_DETAILS[0].engine)
        for route in ROUTE_DETAILS:
            option_frame = tk.Frame(body)
            option_frame.pack(fill="x", pady=(4, 6))
            tk.Radiobutton(
                option_frame,
                text=route.label,
                variable=route_var,
                value=route.engine,
                anchor="w",
                justify="left",
            ).pack(fill="x")
            tk.Label(
                option_frame,
                text=route.recommendation,
                font=hint_font,
                fg="#6b7280",
                anchor="w",
                justify="left",
                padx=28,
            ).pack(fill="x")

        buttons = tk.Frame(body)
        buttons.pack(fill="x", pady=(12, 0))

        def skip() -> None:
            selected["engine"] = ""
            root.destroy()

        def next_step() -> None:
            selected["engine"] = route_var.get()
            root.destroy()

        tk.Button(buttons, text="跳过", width=10, command=skip).pack(side="right")
        tk.Button(buttons, text="下一步", width=12, command=next_step, default="active").pack(side="right", padx=(0, 8))
        root.bind("<Return>", lambda _event: next_step())
        root.bind("<Escape>", lambda _event: skip())
        place_center(root)
        root.focus_force()
        root.mainloop()
        return selected["engine"]

    def confirm_route(route: RouteOption) -> str:
        selected = {"action": "skip"}
        root = tk.Tk()
        root.title("自动转录确认")
        root.resizable(False, False)
        root.attributes("-topmost", True)

        body = tk.Frame(root, padx=22, pady=18)
        body.pack(fill="both", expand=True)

        title_font = tkfont.nametofont("TkDefaultFont").copy()
        title_font.configure(size=16, weight="bold")
        hint_font = tkfont.nametofont("TkDefaultFont").copy()
        hint_font.configure(size=max(10, hint_font.cget("size") - 2))

        tk.Label(body, text="确认开始转录", font=title_font, anchor="w").pack(fill="x")
        tk.Label(
            body,
            text=f"{filename}\n大小: {filesize_mb:.1f} MB\n路线: {route.label}",
            justify="left",
            anchor="w",
            pady=10,
        ).pack(fill="x")
        tk.Label(
            body,
            text=route.recommendation,
            font=hint_font,
            fg="#6b7280",
            anchor="w",
            justify="left",
        ).pack(fill="x")

        buttons = tk.Frame(body)
        buttons.pack(fill="x", pady=(16, 0))

        def choose(action: str) -> None:
            selected["action"] = action
            root.destroy()

        tk.Button(buttons, text="跳过", width=10, command=lambda: choose("skip")).pack(side="right")
        tk.Button(buttons, text="返回选择", width=10, command=lambda: choose("back")).pack(side="right", padx=(0, 8))
        tk.Button(buttons, text="开始转录", width=12, command=lambda: choose("start"), default="active").pack(side="right", padx=(0, 8))
        root.bind("<Return>", lambda _event: choose("start"))
        root.bind("<Escape>", lambda _event: choose("skip"))
        place_center(root)
        root.focus_force()
        root.mainloop()
        return selected["action"]

    while True:
        engine = choose_route()
        route = _route_by_engine(engine)
        if route is None:
            return ""
        action = confirm_route(route)
        if action == "start":
            return route.engine
        if action != "back":
            return ""


def ask_transcription_route(filename: str, filesize_mb: float) -> str:
    """弹出对话框询问用户转录路线，返回 engine；空字符串表示跳过。"""
    engine = _ask_transcription_route_applescript(filename, filesize_mb)
    if not engine:
        logger.info(f"用户选择跳过: {filename}")
    return engine


def ask_confirm(filename: str, filesize_mb: float) -> bool:
    """弹出对话框询问用户是否转录，返回 True/False。"""
    return bool(ask_transcription_route(filename, filesize_mb))


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
