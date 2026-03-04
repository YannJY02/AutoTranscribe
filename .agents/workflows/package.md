---
description: package InsightKit macOS app (release build + sign)
---

# Package InsightKit App

Every time code changes are made to the Swift source or Python runtime, run this workflow to produce a fresh signed release build in `dist/macos/InsightKit.app`.

// turbo-all

## Steps

1. Build and package the app:

```bash
cd /Users/yann.jy/Desktop/AI/transcription && bash scripts/package_insightkit_app.sh
```

Expected output ends with:

```
Build complete!
Built app bundle: .../dist/macos/InsightKit.app
```

2. Open the packaged app to verify it launches:

```bash
open "/Users/yann.jy/Desktop/AI/transcription/dist/macos/InsightKit.app"
```

3. Run Python tests to confirm runtime integrity:

```bash
cd /Users/yann.jy/Desktop/AI/transcription && python3 -m pytest tests/ -v --tb=short 2>&1 | tail -20
```
