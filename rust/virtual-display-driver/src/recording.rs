use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Instant;

use crossbeam_channel::{Receiver, Sender, TrySendError};
use log::{error, warn};

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
        let output_path = config.output_path.clone();

        let handle = thread::spawn(move || {
            encoder_thread_main(rx, &stop_clone, &config.output_path, config.fps)
        });

        trace_log(&format!(
            "RecordingSession started: path={output_path} fps={fps}"
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
            // Too early for next frame -- skip
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
