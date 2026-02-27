# Integrated MP4 Recording in VDD Driver

**Date:** 2026-02-27
**Status:** Proposed
**Branch:** `feature/dxgi-capture`

## Problem

ImmyBot's remote control screen caster dies on session disconnect during logon transitions (lock -> Ctrl+Alt+Del -> credential provider -> user session). We need continuous video capture across that entire transition to verify the authentication package works end-to-end.

## Solution

Integrate MP4 recording directly into the VDD (Virtual Display Driver) UMDF driver. The driver already receives every frame from IddCx via its swap chain processor regardless of session state. Adding OpenH264 encoding in-process eliminates the need for a separate consumer binary, shared memory transport, or cross-process coordination.

## Architecture

```
  Test-FullLoop.ps1 (via Invoke-ImmyCommand)
          │
          │ Named pipe: \\.\pipe\virtualdisplaydriver
          ▼
  ┌─────────────────────────────────────────────────┐
  │  VDD Driver (MttVDD.dll / WUDFHost.exe)         │
  │                                                  │
  │  IPC handler                                     │
  │    │  StartRecording{path, fps, monitor_ids}     │
  │    │  StopRecording                              │
  │    ▼                                             │
  │  RecordingSession (new)                          │
  │    - Creates bounded crossbeam channel           │
  │    - Spawns encoder thread                       │
  │                                                  │
  │  SwapChainProcessor::capture_frame()             │
  │    - Existing frame acquisition from IddCx       │
  │    - If recording: send BGRA frame to channel    │
  │      (try_send, drop if full — no backpressure)  │
  │    - Shared memory write remains (optional)      │
  │                                                  │
  │  Encoder Thread (new)                            │
  │    - Receives BGRA frames from channel           │
  │    - BGRA → YUV420 conversion                    │
  │    - OpenH264 encode → H.264 NALUs              │
  │    - MP4 mux via mp4 crate → disk               │
  │    - On stop: flush encoder, finalize MP4        │
  │    - Send RecordingFinished reply via callback   │
  └─────────────────────────────────────────────────┘
          │
          ▼
  C:\Windows\Temp\vdd_recording_<timestamp>.mp4
```

## IPC Protocol Changes

### driver-ipc/src/core.rs

Extend `DriverCommand::StartRecording`:

```rust
StartRecording {
    monitor_ids: Vec<Id>,
    /// Filesystem path for the output MP4. If None, uses a default temp path.
    output_path: Option<String>,
    /// Target frames per second for the recording. Default: 5.
    fps: Option<u32>,
},
```

Add new reply variant to `ReplyCommand`:

```rust
RecordingFinished {
    path: String,
    frames: u64,
    duration_ms: u64,
},
```

### Backward Compatibility

The `StartRecording` struct already has `monitor_ids`. Adding `output_path` and `fps` as `Option<>` fields with `#[serde(default)]` means existing clients that send `StartRecording { monitor_ids: [] }` continue to work — they just won't get MP4 output (shared memory only, existing behavior).

## New Modules

### `virtual-display-driver/src/recording.rs`

Core recording session management:

```rust
pub struct RecordingSession {
    encoder_thread: JoinHandle<RecordingResult>,
    frame_tx: crossbeam_channel::Sender<Frame>,
    stop_signal: Arc<AtomicBool>,
}

pub struct Frame {
    pub bgra_data: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub timestamp_ms: u64,
}

pub struct RecordingResult {
    pub path: String,
    pub frames: u64,
    pub duration_ms: u64,
}
```

**Lifecycle:**
1. `RecordingSession::start(config)` — creates channel, spawns encoder thread
2. `session.send_frame(frame)` — non-blocking try_send, logs dropped frames
3. `session.stop()` — signals stop, joins thread, returns `RecordingResult`

### `virtual-display-driver/src/encoder.rs`

OpenH264 encoding + MP4 muxing:

```rust
pub struct Mp4Encoder {
    openh264_encoder: openh264::encoder::Encoder,
    mp4_writer: /* mp4 crate writer */,
    frame_count: u64,
    start_time: Instant,
    fps: u32,
    width: u32,
    height: u32,
}
```

**Frame pipeline:**
1. Receive `Frame` with BGRA pixel data
2. Convert BGRA → YUV420p (in-place buffer, reused across frames)
3. Encode via OpenH264 → get NALUs
4. Write NALUs to MP4 container with correct timestamps
5. On finalize: write moov atom, close file

### Color Conversion: BGRA → YUV420

This is a hot path. For 1920x1080 at 5 FPS it's ~40MB/s of pixel data. A straightforward scalar loop is sufficient at this rate, but the conversion should use a pre-allocated buffer to avoid per-frame allocation.

```
Y  = (( 66 * R + 129 * G +  25 * B + 128) >> 8) + 16
Cb = ((-38 * R -  74 * G + 112 * B + 128) >> 8) + 128
Cr = ((112 * R -  94 * G -  18 * B + 128) >> 8) + 128
```

## Integration Points

### SwapChainProcessor (swap_chain_processor.rs)

In `capture_frame()`, after the existing shared memory write (or instead of it when recording to MP4):

```rust
if is_recording {
    if let Some(ref session) = recording_session {
        // Clone the mapped pixel data into a Frame
        let frame = Frame {
            bgra_data: mapped_data.to_vec(),
            width: desc.Width,
            height: desc.Height,
            timestamp_ms: elapsed_since_start(),
        };
        session.send_frame(frame);
    }
    // Existing shared memory write continues unchanged
    Self::capture_frame(device, &buffer, swap_chain, monitor_id, &mut capture);
}
```

### IPC Handler (ipc.rs)

In `process_message()`, the `StartRecording` handler:

```rust
DriverCommand::StartRecording { monitor_ids, output_path, fps } => {
    let mut state = RECORDING_STATE.lock().unwrap();
    state.active = true;
    state.monitor_ids = monitor_ids.into_iter().collect();

    // NEW: Start MP4 recording session if output_path provided
    if let Some(path) = output_path {
        let config = RecordingConfig {
            output_path: path,
            fps: fps.unwrap_or(5),
            // width/height determined from first frame
        };
        state.recording_session = Some(RecordingSession::start(config));
    }
}
```

`StopRecording` handler:

```rust
DriverCommand::StopRecording => {
    let mut state = RECORDING_STATE.lock().unwrap();
    state.active = false;

    // NEW: Stop recording and get result
    if let Some(session) = state.recording_session.take() {
        let result = session.stop();
        // Send RecordingFinished reply back to the client
        let reply = ReplyCommand::RecordingFinished {
            path: result.path,
            frames: result.frames,
            duration_ms: result.duration_ms,
        };
        // serialize + write to pipe
    }
}
```

## New Dependencies

Add to `virtual-display-driver/Cargo.toml`:

```toml
openh264 = "0.6"           # Cisco OpenH264 encoder (BSD, prebuilt binary downloaded at build)
mp4 = "0.14"               # Pure-Rust MP4 muxer
crossbeam-channel = "0.5"  # Bounded MPSC channel for frame delivery
```

**Build impact:** `openh264` crate downloads Cisco's prebuilt `libopenh264.dll` at build time (~2MB). This DLL must be deployed alongside `MttVDD.dll`, OR we use `openh264-sys2` with static linking.

**Driver DLL size:** Current MttVDD.dll is ~300KB. With OpenH264 statically linked, expect ~2-3MB total. Acceptable for a diagnostic tool.

## Test-FullLoop.ps1 Changes

Phase 8-11 simplifies significantly:

### Before (current)
- Phase 8: Deploy VDD + build/load ImmyBot.RemoteControl C# module
- Phase 9: Start background job with `Connect-ImmyRemoteControl` + `Start-ImmyScreenRecording` (SignalR-based)
- Phase 10: Send SID via pipe
- Phase 11: Wait for recording job, collect JPEG frames, encode with ffmpeg

### After (new)
- Phase 8: Deploy VDD (no RC module needed)
- Phase 9: Send `StartRecording { output_path, fps: 5 }` to VDD pipe via `Invoke-ImmyCommand`
- Phase 10: Send SID via CP pipe (unchanged)
- Phase 11: Send `StopRecording` to VDD pipe, read `RecordingFinished`, pull MP4 back via SAS URI

The `ImmyBot.RemoteControl` module, SignalR connection, background PowerShell job, and ffmpeg dependency on the target are all eliminated.

## Frame Delivery Strategy

The crossbeam channel between the swap chain thread and encoder thread uses a **bounded capacity** (e.g., 10 frames). If the encoder falls behind:

- `try_send` drops the frame silently
- A dropped-frame counter is maintained for diagnostics
- At 5 FPS target with 1920x1080 OpenH264 encoding, this should never happen (OpenH264 encodes 1080p in ~5-10ms per frame)

The swap chain processor runs at display refresh rate (e.g., 60Hz). At 5 FPS target recording, we only send every Nth frame to the channel based on elapsed time:

```rust
let elapsed = start.elapsed().as_millis();
let expected_frame = elapsed * fps / 1000;
if expected_frame > frames_sent {
    session.send_frame(frame);
    frames_sent += 1;
}
```

## Deployment

The recording capability ships as part of the existing MttVDD.dll. No additional binaries to deploy. The `Deploy-VDD` function in `Test-FullLoop.ps1` already handles replacing MttVDD.dll on the target.

If OpenH264 requires a separate DLL (dynamic linking), it must be placed alongside MttVDD.dll in `C:\Windows\System32\drivers\UMDF\`. The deploy script would be updated to copy both files.

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| OpenH264 encoding stalls swap chain | Encoding runs on separate thread; channel is non-blocking; frames are dropped not queued |
| Driver DLL size increase | ~2MB is acceptable; static linking avoids deploying separate DLL |
| MP4 corruption on crash | Use fragmented MP4 (fMP4) so partial recordings are still playable |
| Resolution changes mid-recording | Flush current encoder, start new segment, or reject recording across mode changes |
| OpenH264 prebuilt download at build time | Pin version; vendor the binary if build isolation is needed |
