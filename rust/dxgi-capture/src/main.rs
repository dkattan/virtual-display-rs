mod capture;
mod control;
mod display;
mod service;
mod shared_memory;

use std::sync::Arc;

use clap::{Parser, Subcommand};
use log::info;
use tokio::sync::Mutex;

use control::{Command, RecordingMode, Response};
use service::CaptureService;

#[derive(Parser)]
#[command(name = "dxgi-capture", about = "DXGI Desktop Duplication capture service")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the capture service (runs as daemon)
    Serve,
    /// Start recording displays
    Start {
        /// Recording mode: "all" or "primary"
        #[arg(long, default_value = "all")]
        mode: String,
    },
    /// Stop recording
    Stop,
    /// Query service state
    Status,
    /// List available displays (does not require service)
    List,
}

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    let cli = Cli::parse();

    match cli.command.unwrap_or(Commands::Serve) {
        Commands::Serve => run_service().await,
        Commands::Start { mode } => {
            let mode = match mode.as_str() {
                "primary" => RecordingMode::PrimaryOnly,
                _ => RecordingMode::All,
            };
            let cmd = Command::StartRecording { mode };
            send_and_print(&cmd).await;
        }
        Commands::Stop => {
            send_and_print(&Command::StopRecording).await;
        }
        Commands::Status => {
            send_and_print(&Command::QueryState).await;
        }
        Commands::List => {
            list_displays();
        }
    }
}

fn list_displays() {
    match display::enumerate_displays() {
        Ok(displays) => {
            if displays.is_empty() {
                println!("No displays found.");
                return;
            }
            println!("Available displays:");
            for (i, d) in displays.iter().enumerate() {
                println!(
                    "  [{}] {} {}x{} at ({},{}){}",
                    i,
                    d.name,
                    d.width,
                    d.height,
                    d.left,
                    d.top,
                    if d.is_primary { " (primary)" } else { "" }
                );
            }
        }
        Err(e) => {
            eprintln!("Failed to enumerate displays: {e:?}");
            std::process::exit(1);
        }
    }
}

async fn run_service() {
    info!("dxgi-capture service starting");

    let service = Arc::new(Mutex::new(CaptureService::new()));

    // Run the control pipe server (blocks forever)
    control::run_pipe_server(service).await;
}

async fn send_and_print(command: &Command) {
    match control::send_command(command).await {
        Ok(Response::Ok) => println!("OK"),
        Ok(Response::State(state)) => {
            println!("Recording: {}", state.recording);
            if let Some(ref mode) = state.mode {
                println!("Mode: {mode:?}");
            }
            if state.displays.is_empty() {
                println!("No active captures.");
            } else {
                println!("Active captures:");
                for d in &state.displays {
                    println!(
                        "  [{}] {} {}x{}{} -> {}",
                        d.index,
                        d.name,
                        d.width,
                        d.height,
                        if d.primary { " (primary)" } else { "" },
                        d.shm_name
                    );
                }
            }
        }
        Ok(Response::Error(e)) => {
            eprintln!("Error: {e}");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
