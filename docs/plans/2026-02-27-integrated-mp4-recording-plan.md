# Integrated MP4 Recording — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add in-process OpenH264 MP4 recording to the VDD UMDF driver, controlled via the existing named pipe IPC protocol.

**Architecture:** The swap chain processor sends BGRA frames through a bounded crossbeam channel to a dedicated encoder thread. The encoder converts BGRA→YUV420, encodes via OpenH264, and muxes to MP4 via muxide. Start/stop is controlled by extending the existing `DriverCommand::StartRecording`/`StopRecording` IPC messages.

**Tech Stack:** Rust nightly-2024-07-26, openh264 0.9 (compiles from source), muxide (pure-Rust MP4 muxer), crossbeam-channel 0.5

**Design Doc:** `docs/plans/2026-02-27-integrated-mp4-recording-design.md`

**Repo:** `C:\Users\DKattan.IN\source\repos\virtual-display-rs`

**Toolchain note:** This is a UMDF driver (cdylib loaded by WUDFHost.exe). Traditional `cargo test` works for pure logic modules (encoder, color conversion, IPC serialization) but NOT for anything touching IddCx/WDF APIs. Integration testing is done by deploying to DKATTAN-PC3 via `Test-FullLoop.ps1`.

---

## Task 1: Add Dependencies

**Files:**
- Modify: `rust/virtual-display-driver/Cargo.toml`

**Step 1: Add openh264, muxide, and crossbeam-channel to Cargo.toml**

In `rust/virtual-display-driver/Cargo.toml`, add to `[dependencies]`:

```toml
openh264 = "0.9"
muxide = "0.1"
crossbeam-channel = "0.5"
```

**Step 2: Verify the workspace resolves**

Run: `cd rust && cargo check -p virtual-display-driver 2>&1 | tail -5`

Expected: Dependencies download and compile. May see warnings but no errors.
Note: `openh264` compiles Cisco's OpenH264 C++ source from within the crate — this requires a C++ compiler (MSVC is already available from the UMDF build toolchain). First build will be slow (~60s).

**Step 3: Commit**

```bash
git add rust/virtual-display-driver/Cargo.toml rust/Cargo.lock
git commit -m "feat: add openh264, muxide, crossbeam-channel dependencies"
```

---

## Task 2: Extend IPC Protocol

**Files:**
- Modify: `rust/driver-ipc/src/core.rs`

**Step 1: Write test for new field deserialization**

Add to `rust/driver-ipc/src/core.rs` at the bottom:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_recording_with_output_path_deserializes() {
        let json = r#"{"StartRecording":{"monitor_ids":[],"output_path":"C:\\temp\\test.mp4","fps":5}}"#;
        let cmd: DriverCommand = serde_json::from_str(json).unwrap();
        match cmd {
            DriverCommand::StartRecording { monitor_ids, output_path, fps } => {
                assert!(monitor_ids.is_empty());
                assert_eq!(output_path.as_deref(), Some("C:\\temp\\test.mp4"));
                assert_eq!(fps, Some(5));
            }
            _ => panic!("Expected StartRecording"),
        }
    }

    #[test]
    fn start_recording_without_new_fields_deserializes() {
        // Backward compat: old clients send only monitor_ids
        let json = r#"{"StartRecording":{"monitor_ids":[0,1]}}"#;
        let cmd: DriverCommand = serde_json::from_str(json).unwrap();
        match cmd {
            DriverCommand::StartRecording { monitor_ids, output_path, fps } => {
                assert_eq!(monitor_ids, vec![0, 1]);
                assert_eq!(output_path, None);
                assert_eq!(fps, None);
            }
            _ => panic!("Expected StartRecording"),
        }
    }

    #[test]
    fn recording_finished_serializes() {
        let reply = ReplyCommand::RecordingFinished {
            path: "C:\\temp\\out.mp4".to_string(),
            frames: 150,
            duration_ms: 30000,
        };
        let json = serde_json::to_string(&reply).unwrap();
        assert!(json.contains("RecordingFinished"));
        assert!(json.contains("out.mp4"));
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd rust && cargo test -p driver-ipc -- --nocapture 2>&1 | tail -20`

Expected: FAIL — `StartRecording` doesn't have `output_path`/`fps` fields yet, `RecordingFinished` variant doesn't exist.

**Step 3: Update DriverCommand::StartRecording with new optional fields**

In `rust/driver-ipc/src/core.rs`, change `StartRecording` (line 36) from:

```rust
    StartRecording { monitor_ids: Vec<Id> },
```

To:

```rust
    StartRecording {
        monitor_ids: Vec<Id>,
        #[serde(default)]
        output_path: Option<String>,
        #[serde(default)]
        fps: Option<u32>,
    },
```

**Step 4: Add RecordingFinished to ReplyCommand**

In `rust/driver-ipc/src/core.rs`, add after the `RecordingState` variant (after line 62):

```rust
    RecordingFinished {
        path: String,
        frames: u64,
        duration_ms: u64,
    },
```

**Step 5: Run tests to verify they pass**

Run: `cd rust && cargo test -p driver-ipc -- --nocapture 2>&1 | tail -20`

Expected: All 3 tests PASS.

**Step 6: Fix compilation in virtual-display-driver**

The `StartRecording` match arm in `rust/virtual-display-driver/src/ipc.rs:125` needs to destructure the new fields. Update:

```rust
DriverCommand::StartRecording { monitor_ids, output_path, fps } => {
```

(The `output_path` and `fps` will be `_output_path` and `_fps` for now — prefixed with underscore to suppress warnings. We'll wire them up in Task 5.)

Run: `cd rust && cargo check -p virtual-display-driver 2>&1 | tail -5`

Expected: Compiles clean.

**Step 7: Commit**

```bash
git add rust/driver-ipc/src/core.rs rust/virtual-display-driver/src/ipc.rs
git commit -m "feat: extend IPC protocol with output_path, fps, RecordingFinished"
```

---

## Task 3: Create Encoder Module (BGRA→YUV + OpenH264 + MP4)

This is the core encoding pipeline. It's pure Rust with no driver dependencies, so it's fully unit-testable.

**Files:**
- Create: `rust/virtual-display-driver/src/encoder.rs`
- Modify: `rust/virtual-display-driver/src/lib.rs` (add `mod encoder;`)

**Step 1: Write failing test for BGRA→YUV420 conversion**

Create `rust/virtual-display-driver/src/encoder.rs`:

```rust
use std::fs::File;
use std::io::BufWriter;
use std::time::Instant;

use log::{error, info, warn};

/// BGRA → YUV420 planar converter with pre-allocated buffers.
pub struct YuvConverter {
    pub y_plane: Vec<u8>,
    pub u_plane: Vec<u8>,
    pub v_plane: Vec<u8>,
    width: u32,
    height: u32,
}

impl YuvConverter {
    pub fn new(width: u32, height: u32) -> Self {
        let y_size = (width * height) as usize;
        let uv_size = y_size / 4;
        Self {
            y_plane: vec![0u8; y_size],
            u_plane: vec![0u8; uv_size],
            v_plane: vec![0u8; uv_size],
            width,
            height,
        }
    }

    /// Convert BGRA pixel data to YUV420 planar.
    /// `bgra` must be exactly `width * height * 4` bytes.
    pub fn convert(&mut self, bgra: &[u8]) {
        let w = self.width as usize;
        let h = self.height as usize;
        debug_assert_eq!(bgra.len(), w * h * 4);

        for y in 0..h {
            for x in 0..w {
                let idx = (y * w + x) * 4;
                let b = i32::from(bgra[idx]);
                let g = i32::from(bgra[idx + 1]);
                let r = i32::from(bgra[idx + 2]);
                // A = bgra[idx + 3] — ignored

                let luma = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                self.y_plane[y * w + x] = luma.clamp(0, 255) as u8;

                if y % 2 == 0 && x % 2 == 0 {
                    let uv_idx = (y / 2) * (w / 2) + (x / 2);
                    let cb = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                    let cr = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                    self.u_plane[uv_idx] = cb.clamp(0, 255) as u8;
                    self.v_plane[uv_idx] = cr.clamp(0, 255) as u8;
                }
            }
        }
    }
}

/// Encodes BGRA frames to an MP4 file using OpenH264 + muxide.
pub struct Mp4Encoder {
    encoder: openh264::encoder::Encoder,
    muxer: muxide::api::Muxer<BufWriter<File>>,
    yuv: YuvConverter,
    fps: u32,
    frame_count: u64,
    start_time: Instant,
    output_path: String,
}

impl Mp4Encoder {
    /// Create a new encoder. Opens the output file immediately.
    pub fn new(output_path: &str, width: u32, height: u32, fps: u32) -> Result<Self, String> {
        let config = openh264::encoder::EncoderConfig::new(width, height)
            .set_bitrate_bps(2_000_000)
            .max_frame_rate(fps as f32);

        let encoder = openh264::encoder::Encoder::with_config(config)
            .map_err(|e| format!("OpenH264 encoder init failed: {e}"))?;

        let file = File::create(output_path)
            .map_err(|e| format!("Failed to create output file '{output_path}': {e}"))?;
        let writer = BufWriter::new(file);

        let muxer = muxide::api::MuxerBuilder::new(writer)
            .video(muxide::api::VideoCodec::H264, width, height, fps as f64)
            .build()
            .map_err(|e| format!("Muxer init failed: {e}"))?;

        let yuv = YuvConverter::new(width, height);

        Ok(Self {
            encoder,
            muxer,
            yuv,
            fps,
            frame_count: 0,
            start_time: Instant::now(),
            output_path: output_path.to_string(),
        })
    }

    /// Encode one BGRA frame. `bgra` must be `width * height * 4` bytes.
    pub fn encode_frame(&mut self, bgra: &[u8]) -> Result<(), String> {
        // 1. BGRA → YUV420
        self.yuv.convert(bgra);

        // 2. Build YUV source for OpenH264
        let yuv_source = openh264::formats::YUVSource::new(
            &self.yuv.y_plane,
            &self.yuv.u_plane,
            &self.yuv.v_plane,
            self.yuv.width as usize,
            self.yuv.height as usize,
        );

        // 3. Encode
        let bitstream = self.encoder.encode(&yuv_source)
            .map_err(|e| format!("OpenH264 encode failed: {e}"))?;

        // 4. Collect NALUs into Annex-B byte stream
        let mut annex_b = Vec::new();
        for layer_idx in 0..bitstream.num_layers() {
            let layer = bitstream.layer(layer_idx).expect("layer exists");
            for nal_idx in 0..layer.nal_count() {
                let nal = layer.nal_unit(nal_idx);
                // Annex-B start code
                annex_b.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
                annex_b.extend_from_slice(nal);
            }
        }

        if annex_b.is_empty() {
            // Encoder may not produce output for every frame (e.g., skip frames)
            return Ok(());
        }

        // 5. Write to MP4
        let pts_secs = self.frame_count as f64 / self.fps as f64;
        let is_keyframe = self.frame_count == 0 || self.frame_count % (self.fps as u64 * 2) == 0;

        self.muxer
            .write_video(pts_secs, &annex_b, is_keyframe)
            .map_err(|e| format!("Muxer write failed: {e}"))?;

        self.frame_count += 1;
        Ok(())
    }

    /// Finalize the MP4 file and return stats.
    pub fn finish(self) -> Result<(String, u64, u64), String> {
        let duration_ms = self.start_time.elapsed().as_millis() as u64;
        let frame_count = self.frame_count;
        let path = self.output_path.clone();

        self.muxer
            .finish_with_stats()
            .map_err(|e| format!("Muxer finish failed: {e}"))?;

        info!("MP4 finalized: {path} ({frame_count} frames, {duration_ms}ms)");
        Ok((path, frame_count, duration_ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yuv_converter_red_pixel() {
        let mut conv = YuvConverter::new(2, 2);
        // 4 red pixels (BGRA: B=0, G=0, R=255, A=255)
        let bgra = vec![0u8, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255];
        conv.convert(&bgra);

        // Y for pure red: ((66*255 + 128) >> 8) + 16 = 81
        assert_eq!(conv.y_plane[0], 81);
        // Cr for pure red: ((112*255 + 128) >> 8) + 128 = 239
        assert_eq!(conv.v_plane[0], 239);
    }

    #[test]
    fn yuv_converter_dimensions() {
        let conv = YuvConverter::new(1920, 1080);
        assert_eq!(conv.y_plane.len(), 1920 * 1080);
        assert_eq!(conv.u_plane.len(), 960 * 540);
        assert_eq!(conv.v_plane.len(), 960 * 540);
    }
}
```

**Step 2: Add module declaration**

In `rust/virtual-display-driver/src/lib.rs`, add after `mod shared_memory;` (line 10):

```rust
mod encoder;
```

**Step 3: Run tests**

Run: `cd rust && cargo test -p virtual-display-driver -- encoder --nocapture 2>&1 | tail -20`

Expected: `yuv_converter_red_pixel` and `yuv_converter_dimensions` PASS. If the openh264 compilation fails, troubleshoot C++ compiler availability.

**Step 4: Write integration test for full encode pipeline**

Add to the `#[cfg(test)] mod tests` block in `encoder.rs`:

```rust
    #[test]
    fn encode_single_frame_to_mp4() {
        let dir = std::env::temp_dir();
        let path = dir.join("vdd_test_encode.mp4");
        let path_str = path.to_str().unwrap();

        // Create a 64x64 solid blue frame (BGRA)
        let width = 64u32;
        let height = 64u32;
        let bgra: Vec<u8> = (0..width * height)
            .flat_map(|_| [255u8, 0, 0, 255]) // B=255, G=0, R=0, A=255
            .collect();

        let mut enc = Mp4Encoder::new(path_str, width, height, 5).unwrap();
        enc.encode_frame(&bgra).unwrap();
        let (out_path, frames, _dur) = enc.finish().unwrap();

        assert_eq!(frames, 1);
        assert!(std::path::Path::new(&out_path).exists());
        let size = std::fs::metadata(&out_path).unwrap().len();
        assert!(size > 0, "MP4 file should not be empty");

        // Cleanup
        let _ = std::fs::remove_file(&out_path);
    }

    #[test]
    fn encode_multiple_frames_to_mp4() {
        let dir = std::env::temp_dir();
        let path = dir.join("vdd_test_multi.mp4");
        let path_str = path.to_str().unwrap();

        let width = 128u32;
        let height = 128u32;

        let mut enc = Mp4Encoder::new(path_str, width, height, 10).unwrap();

        for i in 0..30 {
            // Gradient frame — different each time
            let bgra: Vec<u8> = (0..width * height)
                .flat_map(|px| {
                    let x = (px % width) as u8;
                    let y = (px / width) as u8;
                    [x.wrapping_add(i as u8), y, 128, 255]
                })
                .collect();
            enc.encode_frame(&bgra).unwrap();
        }

        let (out_path, frames, _dur) = enc.finish().unwrap();
        assert_eq!(frames, 30);
        assert!(std::fs::metadata(&out_path).unwrap().len() > 100);

        let _ = std::fs::remove_file(&out_path);
    }
```

**Step 5: Run tests**

Run: `cd rust && cargo test -p virtual-display-driver -- encoder --nocapture 2>&1 | tail -30`

Expected: All 4 tests PASS. MP4 files are created and are non-empty.

**Step 6: Commit**

```bash
git add rust/virtual-display-driver/src/encoder.rs rust/virtual-display-driver/src/lib.rs
git commit -m "feat: add encoder module — BGRA→YUV420 + OpenH264 + muxide MP4"
```

---

## Task 4: Create Recording Session Module

This manages the lifecycle: channel creation, encoder thread, frame rate throttling, stop signal.

**Files:**
- Create: `rust/virtual-display-driver/src/recording.rs`
- Modify: `rust/virtual-display-driver/src/lib.rs` (add `mod recording;`)

**Step 1: Create recording.rs**

Create `rust/virtual-display-driver/src/recording.rs`:

```rust
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Instant;

use crossbeam_channel::{Receiver, Sender, TrySendError};
use log::{error, info, warn};

use crate::encoder::Mp4Encoder;
use crate::swap_chain_processor::trace_log;

/// A frame of BGRA pixel data ready for encoding.
pub struct Frame {
    pub bgra_data: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Result returned after recording stops.
pub struct RecordingResult {
    pub path: String,
    pub frames: u64,
    pub duration_ms: u64,
}

/// Configuration for a recording session.
pub struct RecordingConfig {
    pub output_path: String,
    pub fps: u32,
}

/// Manages a recording session: channel + encoder thread.
pub struct RecordingSession {
    frame_tx: Sender<Frame>,
    stop_signal: Arc<AtomicBool>,
    encoder_thread: Option<JoinHandle<Option<RecordingResult>>>,
    frames_sent: AtomicU64,
    frames_dropped: AtomicU64,
    start_time: Instant,
    fps: u32,
}

const CHANNEL_CAPACITY: usize = 10;

impl RecordingSession {
    /// Start a new recording session. Spawns the encoder thread immediately.
    /// The encoder initializes lazily on the first frame (needs width/height).
    pub fn start(config: RecordingConfig) -> Self {
        let (tx, rx) = crossbeam_channel::bounded::<Frame>(CHANNEL_CAPACITY);
        let stop = Arc::new(AtomicBool::new(false));
        let stop_clone = stop.clone();
        let fps = config.fps;

        let handle = thread::spawn(move || {
            encoder_thread_main(rx, &stop_clone, &config.output_path, config.fps)
        });

        trace_log(&format!(
            "RecordingSession started: path={} fps={}",
            config.output_path, fps
        ));

        Self {
            frame_tx: tx,
            stop_signal: stop,
            encoder_thread: Some(handle),
            frames_sent: AtomicU64::new(0),
            frames_dropped: AtomicU64::new(0),
            start_time: Instant::now(),
            fps,
        }
    }

    /// Try to send a frame to the encoder. Non-blocking.
    /// Returns true if the frame was sent, false if dropped (channel full or closed).
    pub fn try_send_frame(&self, frame: Frame) -> bool {
        // Frame rate throttle: only send if enough time has elapsed for the next frame
        let elapsed_ms = self.start_time.elapsed().as_millis() as u64;
        let sent = self.frames_sent.load(Ordering::Relaxed);
        let expected = elapsed_ms * u64::from(self.fps) / 1000;

        if sent >= expected {
            // Too early for next frame — skip
            return false;
        }

        match self.frame_tx.try_send(frame) {
            Ok(()) => {
                self.frames_sent.fetch_add(1, Ordering::Relaxed);
                true
            }
            Err(TrySendError::Full(_)) => {
                self.frames_dropped.fetch_add(1, Ordering::Relaxed);
                false
            }
            Err(TrySendError::Disconnected(_)) => false,
        }
    }

    /// Stop the recording and return the result.
    /// Blocks until the encoder thread finishes and the MP4 is finalized.
    pub fn stop(mut self) -> Option<RecordingResult> {
        let sent = self.frames_sent.load(Ordering::Relaxed);
        let dropped = self.frames_dropped.load(Ordering::Relaxed);
        trace_log(&format!(
            "RecordingSession stopping: sent={sent} dropped={dropped}"
        ));

        // Signal stop and drop the sender to unblock the receiver
        self.stop_signal.store(true, Ordering::Release);
        drop(self.frame_tx);

        // Join the encoder thread
        if let Some(handle) = self.encoder_thread.take() {
            match handle.join() {
                Ok(result) => return result,
                Err(e) => {
                    error!("Encoder thread panicked: {e:?}");
                }
            }
        }

        None
    }
}

fn encoder_thread_main(
    rx: Receiver<Frame>,
    stop: &AtomicBool,
    output_path: &str,
    fps: u32,
) -> Option<RecordingResult> {
    trace_log(&format!("Encoder thread started: path={output_path}"));

    let mut encoder: Option<Mp4Encoder> = None;

    loop {
        // Check stop signal
        if stop.load(Ordering::Acquire) {
            // Drain remaining frames in channel before stopping
            while let Ok(frame) = rx.try_recv() {
                if let Some(ref mut enc) = encoder {
                    if let Err(e) = enc.encode_frame(&frame.bgra_data) {
                        error!("Encode error during drain: {e}");
                    }
                }
            }
            break;
        }

        // Wait for a frame with timeout (so we can check stop signal periodically)
        match rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(frame) => {
                // Lazy init encoder on first frame (now we know dimensions)
                if encoder.is_none() {
                    trace_log(&format!(
                        "Encoder init: {}x{} fps={fps} path={output_path}",
                        frame.width, frame.height
                    ));
                    match Mp4Encoder::new(output_path, frame.width, frame.height, fps) {
                        Ok(enc) => encoder = Some(enc),
                        Err(e) => {
                            error!("Failed to create MP4 encoder: {e}");
                            return None;
                        }
                    }
                }

                if let Some(ref mut enc) = encoder {
                    if let Err(e) = enc.encode_frame(&frame.bgra_data) {
                        warn!("Encode error: {e}");
                    }
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }
    }

    // Finalize
    if let Some(enc) = encoder {
        match enc.finish() {
            Ok((path, frames, duration_ms)) => {
                trace_log(&format!(
                    "Encoder finished: {path} frames={frames} duration={duration_ms}ms"
                ));
                Some(RecordingResult {
                    path,
                    frames,
                    duration_ms,
                })
            }
            Err(e) => {
                error!("Failed to finalize MP4: {e}");
                None
            }
        }
    } else {
        warn!("Encoder thread exiting without having encoded any frames");
        None
    }
}
```

**Step 2: Add module declaration**

In `rust/virtual-display-driver/src/lib.rs`, add after `mod encoder;`:

```rust
mod recording;
```

**Step 3: Verify compilation**

Run: `cd rust && cargo check -p virtual-display-driver 2>&1 | tail -10`

Expected: Compiles clean.

**Step 4: Commit**

```bash
git add rust/virtual-display-driver/src/recording.rs rust/virtual-display-driver/src/lib.rs
git commit -m "feat: add recording session module — channel + encoder thread lifecycle"
```

---

## Task 5: Wire Up IPC Handlers

Connect `StartRecording`/`StopRecording` to the recording session.

**Files:**
- Modify: `rust/virtual-display-driver/src/ipc.rs`

**Step 1: Add RecordingSession to RecordingState**

In `rust/virtual-display-driver/src/ipc.rs`, update the imports (around line 1-6) to include:

```rust
use crate::recording::{RecordingConfig, RecordingSession};
```

Update the `RecordingState` struct (lines 38-42) to:

```rust
pub struct RecordingState {
    pub active: bool,
    pub monitor_ids: HashSet<u32>,
    pub session: Option<RecordingSession>,
}
```

Note: Remove `#[derive(Debug, Default)]` since `RecordingSession` doesn't derive those. Add a manual Default impl:

```rust
impl Default for RecordingState {
    fn default() -> Self {
        Self {
            active: false,
            monitor_ids: HashSet::new(),
            session: None,
        }
    }
}
```

**Step 2: Update StartRecording handler**

In `process_message()` (around line 125), update the `StartRecording` match arm:

```rust
DriverCommand::StartRecording { monitor_ids, output_path, fps } => {
    crate::swap_chain_processor::trace_log(&format!(
        "IPC: StartRecording monitor_ids={monitor_ids:?} output_path={output_path:?} fps={fps:?}"
    ));
    let mut state = RECORDING_STATE.lock().unwrap();

    // Stop any existing recording first
    if let Some(old_session) = state.session.take() {
        crate::swap_chain_processor::trace_log("IPC: Stopping previous recording");
        let _ = old_session.stop();
    }

    state.active = true;
    state.monitor_ids = monitor_ids.into_iter().collect();

    // Start MP4 recording if output path provided
    if let Some(path) = output_path {
        let config = RecordingConfig {
            output_path: path,
            fps: fps.unwrap_or(5),
        };
        state.session = Some(RecordingSession::start(config));
    }

    crate::swap_chain_processor::trace_log(&format!(
        "IPC: RecordingState now active={}, monitors={:?}, has_session={}",
        state.active, state.monitor_ids, state.session.is_some()
    ));
}
```

**Step 3: Update StopRecording handler to send reply**

In `process_message()` (around line 138), update the `StopRecording` arm. This is trickier because we need to write a reply to the pipe. The `server` is passed as `&mut NamedPipeServer`:

```rust
DriverCommand::StopRecording => {
    crate::swap_chain_processor::trace_log("IPC: StopRecording");
    let mut state = RECORDING_STATE.lock().unwrap();
    state.active = false;
    state.monitor_ids.clear();

    // Stop recording session and send result
    if let Some(session) = state.session.take() {
        // Drop lock before blocking on encoder thread join
        drop(state);

        let result = session.stop();
        if let Some(result) = result {
            let reply = ReplyCommand::RecordingFinished {
                path: result.path,
                frames: result.frames,
                duration_ms: result.duration_ms,
            };

            if let Ok(mut data) = serde_json::to_string(&reply) {
                data.push(EOF);
                let _ = server.write_all(data.as_bytes()).await;
            }
        }
    }
}
```

**Step 4: Verify compilation**

Run: `cd rust && cargo check -p virtual-display-driver 2>&1 | tail -10`

Expected: Compiles clean. May need to adjust borrow checker issues around `state` lock and `server` — the key pattern is: lock state, take session, drop lock, then join the thread (which may block).

**Step 5: Commit**

```bash
git add rust/virtual-display-driver/src/ipc.rs
git commit -m "feat: wire StartRecording/StopRecording to RecordingSession"
```

---

## Task 6: Wire Up Frame Delivery in SwapChainProcessor

Connect the swap chain's frame capture to the recording session's channel.

**Files:**
- Modify: `rust/virtual-display-driver/src/swap_chain_processor.rs`

**Step 1: Add frame delivery after shared memory write**

In `capture_frame()` (around line 250), after the shared memory write block (the `match map_result` block ending around line 366), add frame delivery to the recording session.

The key insight: we already have the mapped pixel data in the `Ok(())` arm of the map result. We need to send a copy to the recording session BEFORE calling `Unmap`.

Replace the entire `match map_result` block (lines 328-366) with:

```rust
        match map_result {
            Ok(()) => {
                let src_stride = mapped.RowPitch as usize;
                let dst_stride = (desc.Width * 4) as usize; // BGRA = 4 bytes per pixel
                let height = desc.Height as usize;

                // Build contiguous frame buffer (needed for both shm and recording)
                let frame_data = if src_stride == dst_stride {
                    unsafe {
                        std::slice::from_raw_parts(
                            mapped.pData as *const u8,
                            dst_stride * height,
                        )
                    }
                    .to_vec()
                } else {
                    let mut buf = vec![0u8; dst_stride * height];
                    for row in 0..height {
                        let src = unsafe {
                            std::slice::from_raw_parts(
                                (mapped.pData as *const u8).add(row * src_stride),
                                dst_stride,
                            )
                        };
                        buf[row * dst_stride..row * dst_stride + dst_stride]
                            .copy_from_slice(src);
                    }
                    buf
                };

                // Write to shared memory
                resources.shm_writer.write_frame(&frame_data);

                // Send to recording session (if active)
                {
                    let state = RECORDING_STATE.lock().unwrap();
                    if let Some(ref session) = state.session {
                        let frame = crate::recording::Frame {
                            bgra_data: frame_data,
                            width: desc.Width,
                            height: desc.Height,
                        };
                        session.try_send_frame(frame);
                    }
                }

                unsafe {
                    device.device_context.Unmap(&resources.staging_texture, 0);
                }
            }
            Err(e) => {
                error!("Failed to map staging texture: {e:?}");
            }
        }
```

Note: This creates a `Vec<u8>` copy for every frame. When NOT recording, the `to_vec()` is wasteful. Optimize later: only allocate when `state.session.is_some()`. For now, correctness first.

**Step 2: Optimize — only copy when recording**

Actually, let's do this right. Check recording state BEFORE copying:

```rust
        match map_result {
            Ok(()) => {
                let src_stride = mapped.RowPitch as usize;
                let dst_stride = (desc.Width * 4) as usize;
                let height = desc.Height as usize;

                // Check if we need a frame copy for the recording session
                let needs_recording_copy = {
                    let state = RECORDING_STATE.lock().unwrap();
                    state.session.is_some()
                };

                if src_stride == dst_stride {
                    let data = unsafe {
                        std::slice::from_raw_parts(
                            mapped.pData as *const u8,
                            dst_stride * height,
                        )
                    };
                    resources.shm_writer.write_frame(data);

                    if needs_recording_copy {
                        let state = RECORDING_STATE.lock().unwrap();
                        if let Some(ref session) = state.session {
                            session.try_send_frame(crate::recording::Frame {
                                bgra_data: data.to_vec(),
                                width: desc.Width,
                                height: desc.Height,
                            });
                        }
                    }
                } else {
                    let mut frame_buf = vec![0u8; dst_stride * height];
                    for row in 0..height {
                        let src = unsafe {
                            std::slice::from_raw_parts(
                                (mapped.pData as *const u8).add(row * src_stride),
                                dst_stride,
                            )
                        };
                        frame_buf[row * dst_stride..row * dst_stride + dst_stride]
                            .copy_from_slice(src);
                    }
                    resources.shm_writer.write_frame(&frame_buf);

                    if needs_recording_copy {
                        let state = RECORDING_STATE.lock().unwrap();
                        if let Some(ref session) = state.session {
                            session.try_send_frame(crate::recording::Frame {
                                bgra_data: frame_buf,
                                width: desc.Width,
                                height: desc.Height,
                            });
                        }
                    }
                }

                unsafe {
                    device.device_context.Unmap(&resources.staging_texture, 0);
                }
            }
            Err(e) => {
                error!("Failed to map staging texture: {e:?}");
            }
        }
```

**Step 3: Verify compilation**

Run: `cd rust && cargo check -p virtual-display-driver 2>&1 | tail -10`

Expected: Compiles clean.

**Step 4: Commit**

```bash
git add rust/virtual-display-driver/src/swap_chain_processor.rs
git commit -m "feat: deliver frames from swap chain processor to recording session"
```

---

## Task 7: Build Release and Verify

**Step 1: Full release build**

Run: `cd rust && cargo build -p virtual-display-driver --release 2>&1 | tail -20`

Expected: Build succeeds. Note the output DLL path: `rust/target/release/virtual_display_driver.dll`

**Step 2: Check DLL size**

Run: `ls -la rust/target/release/virtual_display_driver.dll`

Expected: 2-4MB (was ~300KB before OpenH264). This is acceptable.

**Step 3: Run all tests**

Run: `cd rust && cargo test -p virtual-display-driver -p driver-ipc 2>&1 | tail -30`

Expected: All tests pass (IPC serialization tests + encoder tests).

**Step 4: Commit (if any clippy fixes were needed)**

```bash
git add -A
git commit -m "build: release build verified, all tests passing"
```

---

## Task 8: Update Test-FullLoop.ps1

**Files:**
- Modify: `C:\Users\DKattan.IN\source\repos\ImmyBot-Authentication-Package\Test-FullLoop.ps1`

This task updates the test script to use VDD pipe recording instead of the RC module. The key changes are in Phases 8-11.

**Step 1: Add VDD pipe helper function**

After the `Import-RCModule` function (around line 211), add:

```powershell
function Send-VDDCommand {
    param(
        [Parameter(Mandatory)][string] $ImmyBaseUrl,
        [Parameter(Mandatory)][string] $BearerToken,
        [Parameter(Mandatory)][int]    $ComputerId,
        [Parameter(Mandatory)][int]    $TenantId,
        [Parameter(Mandatory)][string] $JsonCommand,
        [int] $TimeoutSeconds = 30
    )

    $script = @"
Invoke-ImmyCommand -ContextString 'System' {
    `$pipeName = 'virtualdisplaydriver'
    `$json = '$($JsonCommand -replace "'","''")'
    `$eot = [char]4

    Write-Host "VDD: Connecting to pipe..."
    `$pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', `$pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        `$pipe.Connect(10000)
        Write-Host "VDD: Connected"

        # Send command + EOT
        `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$json + `$eot)
        `$pipe.Write(`$bytes, 0, `$bytes.Length)
        `$pipe.Flush()
        Write-Host "VDD: Sent command ($(`$bytes.Length) bytes)"

        # Read response until EOT
        `$buf = [byte[]]::new(8192)
        `$response = [System.Text.StringBuilder]::new()
        while (`$true) {
            `$n = `$pipe.Read(`$buf, 0, `$buf.Length)
            if (`$n -eq 0) { break }
            `$chunk = [System.Text.Encoding]::UTF8.GetString(`$buf, 0, `$n)
            `$eotIdx = `$chunk.IndexOf(`$eot)
            if (`$eotIdx -ge 0) {
                `$null = `$response.Append(`$chunk.Substring(0, `$eotIdx))
                break
            }
            `$null = `$response.Append(`$chunk)
        }

        `$resp = `$response.ToString()
        Write-Host "VDD: Response: `$resp"
        Write-Host "VDD_COMMAND_DONE"
    }
    catch {
        Write-Host "VDD: ERROR -- `$_"
    }
    finally {
        `$pipe.Dispose()
    }
}
"@

    $output = Invoke-ImmyMetascript -ImmyBaseUrl $ImmyBaseUrl -BearerToken $BearerToken `
        -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds $TimeoutSeconds `
        -ScriptBlock ([ScriptBlock]::Create($script))

    Write-Host $output
    return $output
}
```

**Step 2: Replace Phase 8 — remove RC module, keep VDD deploy**

Replace Phase 8 (lines ~680-690) with:

```powershell
Write-Host "`n== PHASE 8: DEPLOY VDD ==" -ForegroundColor Cyan

if (-not $SkipVDDDeploy -and (Test-Path $VDDRepoRoot)) {
    Deploy-VDD -VDDRepoRoot $VDDRepoRoot -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
        -ComputerId $ComputerId -TenantId $TenantId
}

# No RC module needed — VDD records directly to MP4
```

**Step 3: Replace Phase 9 — send StartRecording via VDD pipe**

Replace Phase 9 (lines ~696-730) with:

```powershell
Write-Host "`n== PHASE 9: START VDD RECORDING ==" -ForegroundColor Cyan

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$remoteMp4Path = "C:\Windows\Temp\vdd_recording_$stamp.mp4"
$startCmd = '{"StartRecording":{"monitor_ids":[],"output_path":"' + ($remoteMp4Path -replace '\\','\\\\') + '","fps":5}}'

Write-Host "  Starting VDD recording: $remoteMp4Path" -ForegroundColor Gray
$startOutput = Send-VDDCommand -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -JsonCommand $startCmd

# Send Ctrl+Alt+Del to wake the display (needed for IddCx path activation)
Write-Host "  Sending Ctrl+Alt+Del to wake display..." -ForegroundColor Gray
# (Use existing RC or ImmyBot remote control API for this — just the wake, not full recording)
Start-Sleep -Seconds 5
```

**Step 4: Replace Phase 11 — send StopRecording, pull MP4 back**

Replace Phase 11 (lines ~797-828) with:

```powershell
Write-Host "`n== PHASE 11: STOP RECORDING + RETRIEVE MP4 ==" -ForegroundColor Cyan

$stopCmd = '{"StopRecording":null}'
Write-Host "  Stopping VDD recording..." -ForegroundColor Gray
$stopOutput = Send-VDDCommand -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
    -ComputerId $ComputerId -TenantId $TenantId -JsonCommand $stopCmd -TimeoutSeconds 60

# Parse RecordingFinished from response
$mp4Path = Join-Path $env:TEMP "vdd_recording_$stamp.mp4"
if ($stopOutput -match '"RecordingFinished"') {
    Write-Host "  Recording finished on target" -ForegroundColor Green

    # Download MP4 via SAS URI
    $downloadScript = @"
Invoke-ImmyCommand -ContextString 'System' {
    `$mp4 = '$remoteMp4Path'
    if (-not (Test-Path `$mp4)) {
        Write-Host "MP4 not found: `$mp4"
        return
    }
    `$size = (Get-Item `$mp4).Length
    Write-Host "MP4 size: `$size bytes"

    `$blobName = 'vdd_recording_$(Get-Date -Format yyyyMMddHHmmss).mp4'
    `$sasUri = New-ImmyUploadSasUri -Permission 'rw' -BlobName `$blobName -ExpiryTime ([datetime]::UtcNow.AddHours(1))
    `$bytes = [System.IO.File]::ReadAllBytes(`$mp4)
    Invoke-RestMethod -Method PUT -Uri `$sasUri -Body `$bytes -ContentType 'video/mp4' -Headers @{'x-ms-blob-type'='BlockBlob'}
    Write-Host "Uploaded to blob"
    Write-Host "DOWNLOAD_URL=`$sasUri"
    Remove-Item `$mp4 -Force -ErrorAction SilentlyContinue
}
"@
    $dlOutput = Invoke-ImmyMetascript -ImmyBaseUrl $immyBaseUrl -BearerToken $bearerToken `
        -ComputerId $ComputerId -TenantId $TenantId -TimeoutSeconds 120 `
        -ScriptBlock ([ScriptBlock]::Create($downloadScript))
    Write-Host $dlOutput

    if ($dlOutput -match 'DOWNLOAD_URL=(\S+)') {
        $downloadUrl = $Matches[1]
        Invoke-WebRequest -Uri $downloadUrl -OutFile $mp4Path -UseBasicParsing
        $localSize = [Math]::Round((Get-Item $mp4Path).Length / 1KB)
        Write-Host "  Downloaded: $mp4Path (${localSize} KB)" -ForegroundColor Green
    }
} else {
    Write-Host "  WARNING: No RecordingFinished response" -ForegroundColor Yellow
}
```

**Step 5: Commit**

```bash
cd "C:\Users\DKattan.IN\source\repos\ImmyBot-Authentication-Package"
git add Test-FullLoop.ps1
git commit -m "feat: update Test-FullLoop to use VDD pipe recording instead of RC module"
```

---

## Task 9: Deploy and Integration Test on DKATTAN-PC3

This is the end-to-end validation on the real target machine.

**Step 1: Build release**

```bash
cd "C:\Users\DKattan.IN\source\repos\virtual-display-rs\rust"
cargo build -p virtual-display-driver --release
```

**Step 2: Run IDDFrameGrabberTestOnly mode first**

This tests that the VDD is working and frames are flowing before testing recording:

```powershell
cd "C:\Users\DKattan.IN\source\repos\ImmyBot-Authentication-Package"
.\Test-FullLoop.ps1 -IDDFrameGrabberTestOnly
```

**Step 3: Test recording via manual pipe command**

Before running the full loop, test just the recording pipeline by sending StartRecording/StopRecording via ImmyBot:

```powershell
# This would be a one-off test script — send StartRecording, wait 10s, send StopRecording, check for MP4
```

**Step 4: Run full Test-FullLoop**

```powershell
.\Test-FullLoop.ps1 -Mode NamedPipe -SkipVDDDeploy
```

Expected: Recording captures the logon transition, MP4 is pulled back and playable.

**Step 5: Verify MP4 is playable**

Open the downloaded MP4 in Windows Media Player or VLC. Should show the lock screen → logon transition.

---

## Summary of Files Changed

| File | Action | Purpose |
|------|--------|---------|
| `rust/virtual-display-driver/Cargo.toml` | Modify | Add openh264, muxide, crossbeam-channel |
| `rust/driver-ipc/src/core.rs` | Modify | Add output_path, fps to StartRecording; add RecordingFinished |
| `rust/virtual-display-driver/src/encoder.rs` | Create | BGRA→YUV + OpenH264 + muxide MP4 encoding |
| `rust/virtual-display-driver/src/recording.rs` | Create | RecordingSession lifecycle (channel, thread, throttle) |
| `rust/virtual-display-driver/src/lib.rs` | Modify | Add `mod encoder; mod recording;` |
| `rust/virtual-display-driver/src/ipc.rs` | Modify | Wire Start/StopRecording to RecordingSession |
| `rust/virtual-display-driver/src/swap_chain_processor.rs` | Modify | Send frames to recording channel |
| `Test-FullLoop.ps1` (other repo) | Modify | Use VDD pipe recording instead of RC module |
