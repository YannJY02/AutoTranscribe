---
description: package InsightKit macOS app (release build + sign)
---

# Package InsightKit App

Every time code changes are made to the Swift source or Python runtime, run this workflow to produce a fresh signed release build in `dist/macos/InsightKit.app`.

// turbo-all

## Steps

1. Build and package the app:

```bash
repo_root="$(git rev-parse --show-toplevel)"
bash "$repo_root/scripts/package_insightkit_app.sh"
```

Expected output ends with:

```
Build complete!
Built app bundle: .../dist/macos/InsightKit.app
```

2. Open the packaged app to verify it launches:

```bash
repo_root="$(git rev-parse --show-toplevel)"
open "$repo_root/dist/macos/InsightKit.app"
```

3. Run Python tests to confirm runtime integrity:

```bash
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root" && python3.11 -m pytest tests/ -v --tb=short
```
