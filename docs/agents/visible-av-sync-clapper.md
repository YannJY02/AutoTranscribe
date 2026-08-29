# Visible AV sync clapper retest

Use this protocol when an installed-app retest must prove perceived audio/video
sync. Stream duration equality is not sufficient evidence.

1. Launch the canonical installed app at
   `/Users/yann.jy/Applications/InsightKit.app` and start a new Live Workspace
   recording with the same camera/screen and microphone path that reproduced the
   problem.
2. Keep both hands visible. After two seconds of silence, clap once sharply,
   wait two seconds, and clap twice more with the same pauses.
3. Stop the recording and preserve its Record Folder. Do not reuse an older
   recording after rebuilding the app.
4. For each clap, inspect `recording.mp4` frame by frame and note:
   - the audio click onset in seconds;
   - the timestamp of the first video frame where the hands touch.
5. Run the diagnostic once per clap:

   ```sh
   python3 scripts/diagnose_visible_av_sync.py \
     /absolute/path/to/recording.mp4 AUDIO_EVENT_SEC VIDEO_EVENT_SEC
   ```

This closure gate reports the approximate signed offset in milliseconds and one of
`video_lags_audio`, `video_leads_audio`, or `aligned`. Every clap must be green;
an absolute offset of 150 ms or more is red. Keep the three outputs under
`logs/diagnostics/<date>/` and reference the Record Folder as visual GUI proof.
