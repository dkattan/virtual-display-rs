use log::{error, info};

use crate::capture::CaptureThread;
use crate::control::{DisplayState, RecordingMode, ServiceState};
use crate::display::{self, DisplayInfo};

pub struct CaptureService {
    captures: Vec<CaptureThread>,
    recording: bool,
    mode: Option<RecordingMode>,
}

impl CaptureService {
    pub fn new() -> Self {
        Self {
            captures: Vec::new(),
            recording: false,
            mode: None,
        }
    }

    pub fn start_recording(
        &mut self,
        mode: RecordingMode,
    ) -> Result<(), Box<dyn std::error::Error>> {
        // Stop any existing recording first
        self.stop_recording();

        let displays = display::enumerate_displays()?;

        if displays.is_empty() {
            return Err("No displays found".into());
        }

        let targets: Vec<&DisplayInfo> = match &mode {
            RecordingMode::All => displays.iter().collect(),
            RecordingMode::PrimaryOnly => {
                let primary: Vec<_> = displays.iter().filter(|d| d.is_primary).collect();
                if primary.is_empty() {
                    return Err("No primary display found".into());
                }
                primary
            }
        };

        info!(
            "Starting recording: mode={mode:?}, {} display(s)",
            targets.len()
        );

        for display in targets {
            info!("  Starting capture for {}", display);
            match CaptureThread::start(display.clone()) {
                Ok(thread) => self.captures.push(thread),
                Err(e) => {
                    error!("Failed to start capture for {}: {e:?}", display.name);
                    // Stop all captures started so far
                    self.stop_recording();
                    return Err(format!("Failed to start capture for {}: {e}", display.name).into());
                }
            }
        }

        self.recording = true;
        self.mode = Some(mode);
        Ok(())
    }

    pub fn stop_recording(&mut self) {
        if !self.captures.is_empty() {
            info!("Stopping recording ({} capture threads)", self.captures.len());
            self.captures.clear(); // Drop calls stop() on each CaptureThread
        }
        self.recording = false;
        self.mode = None;
    }

    pub fn get_state(&self) -> ServiceState {
        let displays = self
            .captures
            .iter()
            .enumerate()
            .map(|(i, cap)| {
                let d = cap.display();
                DisplayState {
                    index: i as u32,
                    name: d.name.clone(),
                    width: d.width,
                    height: d.height,
                    primary: d.is_primary,
                    shm_name: cap.shm_name().to_string(),
                }
            })
            .collect();

        ServiceState {
            recording: self.recording,
            mode: self.mode.clone(),
            displays,
        }
    }
}
