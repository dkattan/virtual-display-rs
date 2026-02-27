use serde::{Deserialize, Serialize};

pub type Id = u32;
pub type Dimen = u32;
pub type RefreshRate = u32;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, PartialOrd)]
pub struct Monitor {
    // identifier
    pub id: Id,
    pub name: Option<String>,
    pub enabled: bool,
    pub modes: Vec<Mode>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, PartialOrd)]
pub struct Mode {
    pub width: Dimen,
    pub height: Dimen,
    pub refresh_rates: Vec<RefreshRate>,
}

#[non_exhaustive]
#[derive(Debug, Clone, Deserialize, Serialize)]
pub enum DriverCommand {
    // Single line of communication client->server
    // Driver commands
    //
    // Notify of monitor changes (whether adding or updating)
    Notify(Vec<Monitor>),
    // Remove a monitor from system
    Remove(Vec<Id>),
    // Remove all monitors from system
    RemoveAll,
    // Start recording frames from specified monitors (empty = all)
    StartRecording {
        monitor_ids: Vec<Id>,
        #[serde(default)]
        output_path: Option<String>,
        #[serde(default)]
        fps: Option<u32>,
    },
    // Stop recording frames
    StopRecording,
}

/// Request command sent from client->server
#[non_exhaustive]
#[derive(Debug, Clone, Deserialize, Serialize)]
pub enum RequestCommand {
    // Request information on the current system monitor state
    State,
    // Request recording state
    RecordingState,
}

/// Reply command sent from server->client
#[non_exhaustive]
#[derive(Debug, Clone, Deserialize, Serialize)]
pub enum ReplyCommand {
    // Reply to previous current system monitor state request
    State(Vec<Monitor>),
    // Reply with current recording state
    RecordingState {
        active: bool,
        monitor_ids: Vec<Id>,
        shm_names: Vec<String>,
    },
    // Notification that recording has finished with stats
    RecordingFinished {
        path: String,
        frames: u64,
        duration_ms: u64,
    },
}

/// An event happened
#[non_exhaustive]
#[derive(Debug, Clone, Deserialize, Serialize)]
pub enum EventCommand {
    // Monitor state was changed while client was connected
    Changed(Vec<Monitor>),
}

/// An untagged enum of commands to be used with deserialization.
/// This makes the deserialization process much easier to handle
/// when a received command could be of multiple types
#[non_exhaustive]
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ServerCommand {
    Driver(DriverCommand),
    Request(RequestCommand),
}

/// An untagged enum of commands to be used with deserialization.
/// This makes the deserialization process much easier to handle
/// when a received command could be of multiple types
#[non_exhaustive]
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ClientCommand {
    Reply(ReplyCommand),
    Event(EventCommand),
}

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
