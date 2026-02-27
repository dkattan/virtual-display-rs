use std::sync::Arc;

use log::{debug, error, info};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::windows::named_pipe::{NamedPipeServer, ServerOptions},
    sync::Mutex,
    task,
};

use crate::service::CaptureService;

pub const PIPE_NAME: &str = r"\\.\pipe\dxgi-capture-control";
const BUFFER_SIZE: u32 = 4096;
const EOF: char = '\x04';

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum RecordingMode {
    All,
    PrimaryOnly,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Command {
    StartRecording { mode: RecordingMode },
    StopRecording,
    QueryState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DisplayState {
    pub index: u32,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub primary: bool,
    pub shm_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServiceState {
    pub recording: bool,
    pub mode: Option<RecordingMode>,
    pub displays: Vec<DisplayState>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Response {
    Ok,
    State(ServiceState),
    Error(String),
}

pub async fn run_pipe_server(service: Arc<Mutex<CaptureService>>) {
    info!("Starting control pipe server at {}", PIPE_NAME);

    loop {
        let mut server = match ServerOptions::new()
            .access_inbound(true)
            .access_outbound(true)
            .reject_remote_clients(true)
            .in_buffer_size(BUFFER_SIZE)
            .out_buffer_size(BUFFER_SIZE)
            .create(PIPE_NAME)
        {
            Ok(s) => s,
            Err(e) => {
                error!("Failed to create pipe server: {e:?}");
                return;
            }
        };

        if server.connect().await.is_err() {
            continue;
        }

        debug!("Client connected to control pipe");

        let service = service.clone();

        task::spawn(async move {
            let mut msg_buf: Vec<u8> = Vec::with_capacity(BUFFER_SIZE as usize);
            let mut buf = vec![0u8; BUFFER_SIZE as usize];

            loop {
                match server.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(size) => msg_buf.extend_from_slice(&buf[..size]),
                }

                // Process all complete messages (delimited by EOF)
                while let Some(eof_pos) = msg_buf.iter().position(|&b| b == EOF as u8) {
                    let msg_bytes = msg_buf.drain(..=eof_pos).collect::<Vec<_>>();
                    let msg_str = match std::str::from_utf8(&msg_bytes[..msg_bytes.len() - 1]) {
                        Ok(s) => s.to_string(),
                        Err(_) => continue,
                    };

                    let command: Command = match serde_json::from_str(&msg_str) {
                        Ok(c) => c,
                        Err(e) => {
                            let resp = Response::Error(format!("Invalid command: {e}"));
                            send_response(&mut server, &resp).await;
                            continue;
                        }
                    };

                    let response = handle_command(&service, command).await;
                    send_response(&mut server, &response).await;
                }
            }

            debug!("Client disconnected from control pipe");
        });
    }
}

async fn handle_command(service: &Arc<Mutex<CaptureService>>, command: Command) -> Response {
    let mut svc = service.lock().await;

    match command {
        Command::StartRecording { mode } => {
            info!("StartRecording: mode={mode:?}");
            match svc.start_recording(mode) {
                Ok(()) => Response::Ok,
                Err(e) => Response::Error(format!("{e}")),
            }
        }
        Command::StopRecording => {
            info!("StopRecording");
            svc.stop_recording();
            Response::Ok
        }
        Command::QueryState => {
            let state = svc.get_state();
            Response::State(state)
        }
    }
}

async fn send_response(server: &mut NamedPipeServer, response: &Response) {
    let mut data = match serde_json::to_string(response) {
        Ok(s) => s,
        Err(e) => {
            error!("Failed to serialize response: {e:?}");
            return;
        }
    };
    data.push(EOF);

    if let Err(e) = server.write_all(data.as_bytes()).await {
        error!("Failed to write response: {e:?}");
    }
}

/// Send a command to a running capture service and return the response
pub async fn send_command(command: &Command) -> Result<Response, String> {
    use tokio::net::windows::named_pipe::ClientOptions;

    let client = ClientOptions::new()
        .read(true)
        .write(true)
        .open(PIPE_NAME)
        .map_err(|e| format!("Failed to connect to capture service at {PIPE_NAME}: {e}"))?;

    let mut data = serde_json::to_string(command).map_err(|e| format!("Serialize error: {e}"))?;
    data.push(EOF);

    client
        .writable()
        .await
        .map_err(|e| format!("Pipe not writable: {e}"))?;
    client
        .try_write(data.as_bytes())
        .map_err(|e| format!("Write error: {e}"))?;

    // Read response
    let mut buf = vec![0u8; BUFFER_SIZE as usize];
    let mut msg = Vec::new();

    loop {
        client
            .readable()
            .await
            .map_err(|e| format!("Pipe not readable: {e}"))?;

        match client.try_read(&mut buf) {
            Ok(0) => break,
            Ok(n) => msg.extend_from_slice(&buf[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(e) => return Err(format!("Read error: {e}")),
        }

        if let Some(eof_pos) = msg.iter().position(|&b| b == EOF as u8) {
            let response_str = std::str::from_utf8(&msg[..eof_pos])
                .map_err(|e| format!("UTF-8 error: {e}"))?;
            let response: Response =
                serde_json::from_str(response_str).map_err(|e| format!("Deserialize error: {e}"))?;
            return Ok(response);
        }
    }

    Err("Connection closed before receiving response".to_string())
}
