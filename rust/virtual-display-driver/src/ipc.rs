use std::{
    collections::HashSet,
    mem::size_of,
    ptr::{addr_of_mut, NonNull},
    sync::{LazyLock, Mutex, OnceLock},
    thread,
};

use driver_ipc::{
    Dimen, DriverCommand, EventCommand, Mode, Monitor, RefreshRate, ReplyCommand,
    RequestCommand, ServerCommand,
};
use log::{error, warn};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt as _},
    net::windows::named_pipe::{NamedPipeServer, ServerOptions},
    sync::broadcast::{self, error::RecvError, Sender},
    task,
};
use wdf_umdf::IddCxMonitorDeparture;
use wdf_umdf_sys::{IDDCX_ADAPTER__, IDDCX_MONITOR__};
use windows::Win32::{
    Security::{
        InitializeSecurityDescriptor, SetSecurityDescriptorDacl, PSECURITY_DESCRIPTOR,
        SECURITY_ATTRIBUTES, SECURITY_DESCRIPTOR,
    },
    System::SystemServices::SECURITY_DESCRIPTOR_REVISION1,
};

use crate::context::DeviceContext;
use crate::recording::{RecordingConfig, RecordingSession};

pub static ADAPTER: OnceLock<AdapterObject> = OnceLock::new();
pub static MONITOR_MODES: LazyLock<Mutex<Vec<MonitorObject>>> =
    LazyLock::new(|| Mutex::new(Vec::new()));
pub static RECORDING_STATE: LazyLock<Mutex<RecordingState>> =
    LazyLock::new(|| Mutex::new(RecordingState::default()));

pub struct RecordingState {
    pub active: bool,
    pub monitor_ids: HashSet<u32>,
    pub session: Option<RecordingSession>,
}

impl Default for RecordingState {
    fn default() -> Self {
        Self {
            active: false,
            monitor_ids: HashSet::new(),
            session: None,
        }
    }
}

impl RecordingState {
    pub fn is_recording(&self, monitor_id: u32) -> bool {
        self.active && (self.monitor_ids.is_empty() || self.monitor_ids.contains(&monitor_id))
    }

    pub fn shm_names(&self) -> Vec<String> {
        let lock = MONITOR_MODES.lock().unwrap();
        lock.iter()
            .filter(|m| self.is_recording(m.data.id))
            .map(|m| format!("Global\\VDD_Frame_{}", m.data.id))
            .collect()
    }
}

#[derive(Debug)]
pub struct AdapterObject(pub NonNull<IDDCX_ADAPTER__>);
unsafe impl Sync for AdapterObject {}
unsafe impl Send for AdapterObject {}

#[derive(Debug)]
pub struct MonitorObject {
    pub object: Option<NonNull<IDDCX_MONITOR__>>,
    pub data: Monitor,
}
unsafe impl Sync for MonitorObject {}
unsafe impl Send for MonitorObject {}

const BUFFER_SIZE: u32 = 4096;
// EOT
const EOF: char = '\x04';

/// DEADEND: SendInput from UMDF driver process (Session 0) does not work.
/// OpenInputDesktop fails with ERROR_INVALID_FUNCTION (0x80070001) because the
/// UMDF host process has no interactive desktop. SendInput returns 0.
/// The display wake must be performed by the IPC client (running in user session).
///
/// Spawns a thread that attempts a Space keypress to wake the display.
/// Left in for diagnostic logging — will log the failure to VDD_trace.log.
fn send_wake_keypress() {
    crate::swap_chain_processor::trace_log("IPC: Spawning thread to send wake keypress...");

    thread::spawn(|| {
        // Small delay to let recording state settle before waking display
        thread::sleep(std::time::Duration::from_millis(500));

        send_wake_keypress_inner()
    });
}

fn send_wake_keypress_inner() {
    use std::mem::{size_of, zeroed};
    use windows::Win32::{
        System::StationsAndDesktops::{
            CloseDesktop, GetThreadDesktop, OpenInputDesktop, SetThreadDesktop,
            DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS,
        },
        System::Threading::GetCurrentThreadId,
        UI::Input::KeyboardAndMouse::{
            SendInput, INPUT, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VK_SPACE,
        },
    };

    // Save the current thread's desktop so we can restore it
    let thread_id = unsafe { GetCurrentThreadId() };
    let original_desktop = unsafe { GetThreadDesktop(thread_id) };

    // Try to switch to the input desktop (the one receiving user input).
    // This is critical when the driver host runs in Session 0 or on a different desktop.
    // dwFlags=0, fInherit=false, dwDesiredAccess=GENERIC_ALL (0x10000000)
    let switched_desktop = match unsafe {
        OpenInputDesktop(
            DESKTOP_CONTROL_FLAGS(0),
            false,
            DESKTOP_ACCESS_FLAGS(0x10000000),
        )
    } {
        Ok(hdesk) => {
            crate::swap_chain_processor::trace_log("IPC: OpenInputDesktop succeeded");
            match unsafe { SetThreadDesktop(hdesk) } {
                Ok(()) => {
                    crate::swap_chain_processor::trace_log("IPC: SetThreadDesktop succeeded");
                    Some(hdesk)
                }
                Err(e) => {
                    crate::swap_chain_processor::trace_log(&format!(
                        "IPC: SetThreadDesktop failed: {e}"
                    ));
                    let _ = unsafe { CloseDesktop(hdesk) };
                    None
                }
            }
        }
        Err(e) => {
            crate::swap_chain_processor::trace_log(&format!(
                "IPC: OpenInputDesktop failed: {e} — will try SendInput anyway"
            ));
            None
        }
    };

    // Send Space key down + up
    let mut inputs: [INPUT; 2] = unsafe { zeroed() };

    inputs[0].r#type = INPUT_KEYBOARD;
    inputs[0].Anonymous.ki = unsafe {
        KEYBDINPUT {
            wVk: VK_SPACE,
            ..zeroed()
        }
    };

    inputs[1].r#type = INPUT_KEYBOARD;
    inputs[1].Anonymous.ki = unsafe {
        KEYBDINPUT {
            wVk: VK_SPACE,
            dwFlags: KEYEVENTF_KEYUP,
            ..zeroed()
        }
    };

    let sent = unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
    crate::swap_chain_processor::trace_log(&format!(
        "IPC: SendInput returned {sent} (expected 2)"
    ));

    if sent == 0 {
        let err = windows::core::Error::from_win32();
        crate::swap_chain_processor::trace_log(&format!(
            "IPC: SendInput last error: {err}"
        ));
    }

    // Restore original desktop and clean up
    if let Some(hdesk) = switched_desktop {
        if let Ok(orig) = original_desktop {
            let _ = unsafe { SetThreadDesktop(orig) };
        }
        let _ = unsafe { CloseDesktop(hdesk) };
    }
}

// message processor
async fn process_message(
    id: usize,
    server: &mut NamedPipeServer,
    tx: &Sender<(usize, Vec<Monitor>)>,
    buf: &[u8],
    iter: impl Iterator<Item = usize>,
) -> Result<(), ()> {
    // process each message in the buffer
    let mut start = 0;
    for eidx in iter {
        let sidx = start;
        start = eidx + 1;

        crate::swap_chain_processor::trace_log(&format!(
            "IPC: Processing message bytes [{sidx}..{eidx}] ({} bytes)", eidx - sidx
        ));

        let Ok(msg) = std::str::from_utf8(&buf[sidx..eidx]) else {
            crate::swap_chain_processor::trace_log(&format!(
                "IPC: UTF-8 decode failed for bytes [{sidx}..{eidx}]"
            ));
            continue;
        };

        // Strip UTF-8 BOM if present (PowerShell StreamWriter adds it)
        let msg = msg.trim_start_matches('\u{FEFF}');
        crate::swap_chain_processor::trace_log(&format!(
            "IPC: Raw message text ({} chars): {msg}", msg.len()
        ));

        let Ok(command) = serde_json::from_str::<ServerCommand>(msg) else {
            crate::swap_chain_processor::trace_log(&format!(
                "IPC: DESERIALIZE FAILED for message: {msg}"
            ));
            continue;
        };
        crate::swap_chain_processor::trace_log(&format!("IPC: Deserialized command: {command:?}"));

        match command {
            // driver commands
            ServerCommand::Driver(cmd) => match cmd {
                DriverCommand::Notify(monitors) => {
                    notify(monitors.clone());
                    _ = tx.send((id, monitors));
                }

                DriverCommand::Remove(ids) => {
                    remove(&ids);

                    let lock = MONITOR_MODES.lock().unwrap();
                    let monitors = lock.iter().map(|m| m.data.clone()).collect();
                    _ = tx.send((id, monitors));
                }

                DriverCommand::RemoveAll => {
                    remove_all();
                    _ = tx.send((id, Vec::new()));
                }

                DriverCommand::StartRecording { monitor_ids, output_path, fps } => {
                    crate::swap_chain_processor::trace_log(&format!(
                        "IPC: StartRecording monitor_ids={monitor_ids:?} output_path={output_path:?} fps={fps:?}"
                    ));

                    // Scoped block so MutexGuard is dropped before any .await
                    let reply = {
                        let mut state = RECORDING_STATE.lock().unwrap();
                        crate::swap_chain_processor::trace_log("IPC: StartRecording acquired RECORDING_STATE lock");

                        // Stop any existing recording first
                        if let Some(old_session) = state.session.take() {
                            crate::swap_chain_processor::trace_log("IPC: Stopping previous recording");
                            let _ = old_session.stop();
                            crate::swap_chain_processor::trace_log("IPC: Previous recording stopped");
                        }

                        state.active = true;
                        state.monitor_ids = monitor_ids.into_iter().collect();
                        crate::swap_chain_processor::trace_log(&format!(
                            "IPC: Set active=true, monitor_ids={:?}", state.monitor_ids
                        ));

                        // Start MP4 recording if output path provided
                        if let Some(path) = output_path {
                            crate::swap_chain_processor::trace_log(&format!(
                                "IPC: Creating RecordingSession path={path:?} fps={fps:?}"
                            ));
                            let config = RecordingConfig {
                                output_path: path,
                                fps: fps.unwrap_or(5),
                            };
                            state.session = Some(RecordingSession::start(config));
                            crate::swap_chain_processor::trace_log("IPC: RecordingSession created");
                        } else {
                            crate::swap_chain_processor::trace_log("IPC: No output_path — no RecordingSession created");
                        }

                        crate::swap_chain_processor::trace_log(&format!(
                            "IPC: RecordingState now active={}, monitors={:?}, has_session={}",
                            state.active, state.monitor_ids, state.session.is_some()
                        ));

                        ReplyCommand::RecordingStarted {
                            active: state.active,
                            monitor_ids: state.monitor_ids.iter().copied().collect(),
                            has_session: state.session.is_some(),
                        }
                        // MutexGuard dropped here
                    };

                    if let Ok(mut data) = serde_json::to_string(&reply) {
                        data.push(EOF);
                        crate::swap_chain_processor::trace_log(&format!(
                            "IPC: Sending RecordingStarted reply ({} bytes)", data.len()
                        ));
                        let _ = server.write_all(data.as_bytes()).await;
                        crate::swap_chain_processor::trace_log("IPC: RecordingStarted reply sent");
                    } else {
                        crate::swap_chain_processor::trace_log("IPC: ERROR — failed to serialize RecordingStarted reply");
                    }

                    // Wake the display by sending a keypress — IddCx only activates
                    // display paths when the display is awake
                    send_wake_keypress();
                }

                DriverCommand::StopRecording => {
                    crate::swap_chain_processor::trace_log("IPC: StopRecording");

                    // Take session out of state in a limited scope so the
                    // MutexGuard is dropped before any .await
                    let session = {
                        let mut state = RECORDING_STATE.lock().unwrap();
                        state.active = false;
                        state.monitor_ids.clear();
                        state.session.take()
                    };

                    // Stop recording session and ALWAYS send a reply (even with 0 frames)
                    let reply = if let Some(session) = session {
                        match session.stop() {
                            Some(result) => ReplyCommand::RecordingFinished {
                                path: result.path,
                                frames: result.frames,
                                duration_ms: result.duration_ms,
                            },
                            None => ReplyCommand::RecordingFinished {
                                path: String::new(),
                                frames: 0,
                                duration_ms: 0,
                            },
                        }
                    } else {
                        ReplyCommand::RecordingFinished {
                            path: String::new(),
                            frames: 0,
                            duration_ms: 0,
                        }
                    };

                    crate::swap_chain_processor::trace_log(&format!(
                        "IPC: StopRecording reply: {reply:?}"
                    ));

                    if let Ok(mut data) = serde_json::to_string(&reply) {
                        data.push(EOF);
                        let _ = server.write_all(data.as_bytes()).await;
                    }
                }

                _ => (),
            },

            // request commands
            ServerCommand::Request(RequestCommand::State) => {
                let mut data = {
                    let lock = MONITOR_MODES.lock().unwrap();
                    let monitors = lock.iter().map(|m| m.data.clone()).collect();
                    let command = ReplyCommand::State(monitors);

                    let Ok(serialized) = serde_json::to_string(&command) else {
                        error!("Command::Request - failed to serialize reply");
                        break;
                    };

                    serialized
                };

                data.push(EOF);

                if server.write_all(data.as_bytes()).await.is_err() {
                    // a server error means we should completely stop trying
                    return Err(());
                }
            }

            ServerCommand::Request(RequestCommand::RecordingState) => {
                let mut data = {
                    let state = RECORDING_STATE.lock().unwrap();
                    let command = ReplyCommand::RecordingState {
                        active: state.active,
                        monitor_ids: state.monitor_ids.iter().copied().collect(),
                        shm_names: state.shm_names(),
                    };

                    let Ok(serialized) = serde_json::to_string(&command) else {
                        error!("Command::Request - failed to serialize recording state reply");
                        break;
                    };

                    serialized
                };

                data.push(EOF);

                if server.write_all(data.as_bytes()).await.is_err() {
                    return Err(());
                }
            }

            // Everything else is an invalid command
            _ => (),
        }
    }

    Ok(())
}

#[allow(clippy::too_many_lines)]
pub fn startup() {
    thread::spawn(move || {
        // These security attributes will allow anyone access, so local account does not need admin privileges to use it

        let mut sd = SECURITY_DESCRIPTOR::default();

        unsafe {
            InitializeSecurityDescriptor(
                PSECURITY_DESCRIPTOR(addr_of_mut!(sd).cast()),
                SECURITY_DESCRIPTOR_REVISION1,
            )
            .unwrap();
        }

        unsafe {
            SetSecurityDescriptorDacl(
                PSECURITY_DESCRIPTOR(addr_of_mut!(sd).cast()),
                true,
                None,
                false,
            )
            .unwrap();
        }

        let mut sa = SECURITY_ATTRIBUTES {
            #[allow(clippy::cast_possible_truncation)]
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: addr_of_mut!(sd).cast(),
            bInheritHandle: false.into(),
        };

        // async time!
        let pipe_server = async {
            crate::swap_chain_processor::trace_log(
                "=== VDD CANARY 2026-02-27-B === Pipe server starting (tokio async loop, with SendInput wake)"
            );

            let (tx, _rx) = broadcast::channel(1);

            let mut id = 0usize;

            loop {
                let mut server = unsafe {
                    ServerOptions::new()
                        .access_inbound(true)
                        .access_outbound(true)
                        .reject_remote_clients(true)
                        .in_buffer_size(BUFFER_SIZE)
                        .out_buffer_size(BUFFER_SIZE)
                        // default is unlimited instances
                        .create_with_security_attributes_raw(
                            r"\\.\pipe\virtualdisplaydriver",
                            std::ptr::from_mut::<SECURITY_ATTRIBUTES>(&mut sa).cast(),
                        )
                        .unwrap()
                };

                if server.connect().await.is_err() {
                    crate::swap_chain_processor::trace_log("IPC: server.connect() failed, retrying");
                    continue;
                }

                id += 1;
                crate::swap_chain_processor::trace_log(&format!(
                    "IPC: Client #{id} connected to pipe"
                ));

                let mut msg_buf: Vec<u8> = Vec::with_capacity(BUFFER_SIZE as usize);
                let mut buf = vec![0; BUFFER_SIZE as usize];
                let tx = tx.clone();
                let mut rx = tx.subscribe();

                let client_id = id;
                task::spawn(async move {
                    loop {
                        tokio::select! {
                            val = server.read(&mut buf) =>  {
                                match val {
                                    // 0 = no more data to read
                                    // or break on err
                                    Ok(0) => {
                                        crate::swap_chain_processor::trace_log(&format!(
                                            "IPC: Client #{client_id} read returned 0 — disconnected"
                                        ));
                                        break;
                                    }
                                    Err(e) => {
                                        crate::swap_chain_processor::trace_log(&format!(
                                            "IPC: Client #{client_id} read error: {e}"
                                        ));
                                        break;
                                    }

                                    Ok(size) => {
                                        crate::swap_chain_processor::trace_log(&format!(
                                            "IPC: Client #{client_id} read {size} bytes, msg_buf total={}",
                                            msg_buf.len() + size
                                        ));
                                        msg_buf.extend(&buf[..size]);
                                    }
                                }

                                // get all eof boundary positions
                                let eof_iter = msg_buf.iter().enumerate().filter_map(|(i, &byte)| {
                                    if byte == EOF as u8 {
                                        Some(i)
                                    } else {
                                        None
                                    }
                                });

                                if process_message(id, &mut server, &tx, &msg_buf, eof_iter.clone()).await.is_err() {
                                    break;
                                }

                                // remove processed messages from buffer
                                // we can exploit the fact that these are sequential
                                // so just get the last index and chop off everything before that
                                if let Some(last) = eof_iter.last() {
                                    // remove everything up to and including the last EOF
                                    msg_buf.drain(..=last);
                                }
                            },

                            val = rx.recv() => {
                                let command = match val {
                                    // ignore if this value was sent for the current client (current client doesn't need notification)
                                    Ok((client_id, _)) if client_id == id => continue,

                                    Ok((_, data)) => EventCommand::Changed(data),

                                    Err(RecvError::Lagged(_)) => continue,

                                    // closed
                                    Err(_) => break
                                };

                                let Ok(mut serialized) = serde_json::to_string(&command) else {
                                    error!("Command::Request - failed to serialize reply");
                                    break;
                                };

                                serialized.push(EOF);

                                if server.write_all(serialized.as_bytes()).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                });
            }
        };

        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Failed building the Runtime")
            .block_on(pipe_server);
    });
}

/// used to check the validity of a Vec<Monitor>
/// the validity invariants are:
/// 1. unique monitor ids
/// 2. unique monitor modes (width+height must be unique per array element)
/// 3. unique refresh rates per monitor mode
fn has_duplicates(monitors: &[Monitor]) -> bool {
    let mut monitor_iter = monitors.iter();
    while let Some(monitor) = monitor_iter.next() {
        let duplicate_id = monitor_iter.clone().any(|b| monitor.id == b.id);
        if duplicate_id {
            warn!("Found duplicate monitor id {}", monitor.id);
            return true;
        }

        let mut mode_iter = monitor.modes.iter();
        while let Some(mode) = mode_iter.next() {
            let duplicate_mode = mode_iter
                .clone()
                .any(|m| mode.height == m.height && mode.width == m.width);
            if duplicate_mode {
                warn!(
                    "Found duplicate mode {}x{} on monitor {}",
                    mode.width, mode.height, monitor.id
                );
                return true;
            }

            let mut refresh_iter = mode.refresh_rates.iter().copied();
            while let Some(rr) = refresh_iter.next() {
                let duplicate_rr = refresh_iter.clone().any(|r| rr == r);
                if duplicate_rr {
                    warn!(
                        "Found duplicate refresh rate {rr} on mode {}x{} for monitor {}",
                        mode.width, mode.height, monitor.id
                    );
                    return true;
                }
            }
        }
    }

    false
}

/// Notifies driver of new system monitor state
///
/// Adds, updates, or removes monitors as needed
///
/// Note that updated monitors causes a detach, update, and reattach. (Required for windows to see the changes)
///
/// Only detaches/reattaches if required
/// e.g. only a monitor name update would not detach/arrive a monitor
fn notify(monitors: Vec<Monitor>) {
    // Duplicated id's will not cause any issue, however duplicated resolutions/refresh rates are possible
    // They should all be unique anyways. So warn + noop if the sender sent incorrect data
    if has_duplicates(&monitors) {
        warn!("notify(): Duplicate data was detected; update aborted");
        return;
    }

    let adapter = ADAPTER.get().unwrap().0.as_ptr();

    let mut lock = MONITOR_MODES.lock().unwrap();

    // Remove monitors from internal list which are missing from the provided list

    lock.retain_mut(|mon| {
        let id = mon.data.id;
        let found = monitors.iter().any(|m| m.id == id);

        // if it doesn't exist, then add to removal list
        if !found {
            // monitor not found in monitors list, so schedule to remove it
            if let Some(mut obj) = mon.object.take() {
                // remove any monitors scheduled for removal
                let obj = unsafe { obj.as_mut() };
                if let Err(e) = unsafe { IddCxMonitorDeparture(obj) } {
                    error!("Failed to remove monitor: {e:?}");
                }
            }
        }

        found
    });

    let should_arrive = monitors
        .into_iter()
        .map(|monitor| {
            let id = monitor.id;

            let should_arrive;

            let cur_mon = lock.iter_mut().find(|mon| mon.data.id == id);

            if let Some(mon) = cur_mon {
                let modes_changed = mon.data.modes != monitor.modes;

                #[allow(clippy::nonminimal_bool)]
                {
                    should_arrive =
                        // previously was disabled, and it was just enabled
                        (!mon.data.enabled && monitor.enabled) ||
                        // OR monitor is enabled and the display modes changed
                        (monitor.enabled && modes_changed) ||
                        // OR monitor is enabled and the monitor was disconnected
                        (monitor.enabled && mon.object.is_none());
                }

                // should only detach if modes changed, or if state is false
                if modes_changed || !monitor.enabled {
                    if let Some(mut obj) = mon.object.take() {
                        let obj = unsafe { obj.as_mut() };
                        if let Err(e) = unsafe { IddCxMonitorDeparture(obj) } {
                            error!("Failed to remove monitor: {e:?}");
                        }
                    }
                }

                // update monitor data
                mon.data = monitor;
            } else {
                should_arrive = monitor.enabled;

                lock.push(MonitorObject {
                    object: None,
                    data: monitor,
                });
            }

            (id, should_arrive)
        })
        .collect::<Vec<_>>();

    // context.create_monitor locks again, so this avoids deadlock
    drop(lock);

    let cb = |context: &mut DeviceContext| {
        // arrive any monitors that need arriving
        for (id, arrive) in should_arrive {
            if arrive {
                if let Err(e) = context.create_monitor(id) {
                    error!("Failed to create monitor: {e:?}");
                }
            }
        }
    };

    unsafe {
        DeviceContext::get_mut(adapter.cast(), cb).unwrap();
    }
}

fn remove_all() {
    let mut lock = MONITOR_MODES.lock().unwrap();

    for monitor in lock.drain(..) {
        if let Some(mut monitor_object) = monitor.object {
            let obj = unsafe { monitor_object.as_mut() };
            if let Err(e) = unsafe { IddCxMonitorDeparture(obj) } {
                error!("Failed to remove monitor: {e:?}");
            }
        }
    }
}

fn remove(ids: &[u32]) {
    let mut lock = MONITOR_MODES.lock().unwrap();

    for &id in ids {
        lock.retain_mut(|monitor| {
            if id == monitor.data.id {
                if let Some(mut monitor_object) = monitor.object.take() {
                    let obj = unsafe { monitor_object.as_mut() };
                    if let Err(e) = unsafe { IddCxMonitorDeparture(obj) } {
                        error!("Failed to remove monitor: {e:?}");
                    }
                }

                false
            } else {
                true
            }
        });
    }
}

pub trait FlattenModes {
    fn flatten(&self) -> impl Iterator<Item = ModeItem>;
}

#[derive(Copy, Clone)]
pub struct ModeItem {
    pub width: Dimen,
    pub height: Dimen,
    pub refresh_rate: RefreshRate,
}

/// Takes a slice of modes and creates a flattened structure that can be iterated over
impl FlattenModes for Vec<Mode> {
    fn flatten(&self) -> impl Iterator<Item = ModeItem> {
        self.iter().flat_map(|m| {
            m.refresh_rates.iter().map(|&rr| ModeItem {
                width: m.width,
                height: m.height,
                refresh_rate: rr,
            })
        })
    }
}
