# Smart Minutes eval v1

This versioned corpus contains only invented Chinese, English, and mixed-language meeting text. Run it without credentials:

```bash
python3.11 scripts/smart_minutes_eval.py --output-dir logs/smart-minutes-eval/local
```

The local extractive leg always runs. External generation runs only with explicit `--external-vendor` configuration; an approved semantic evaluator can be isolated behind `--semantic-adapter module:function`. Missing configuration or credentials is reported as unobserved, never as a pass. Semantic and latency scores are diagnostic until separately accepted.
