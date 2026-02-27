use std::{
    mem::ManuallyDrop,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread::{self, JoinHandle},
};

use log::{debug, error, info};
use wdf_umdf::{
    IddCxSwapChainFinishedProcessingFrame, IddCxSwapChainReleaseAndAcquireBuffer,
    IddCxSwapChainSetDevice, WdfObjectDelete,
};
use wdf_umdf_sys::{
    HANDLE, IDARG_IN_SWAPCHAINSETDEVICE, IDARG_OUT_RELEASEANDACQUIREBUFFER, IDDCX_SWAPCHAIN,
    NTSTATUS, WAIT_TIMEOUT, WDFOBJECT,
};
use windows::{
    core::{w, Interface},
    Win32::{
        Foundation::HANDLE as WHANDLE,
        Graphics::{
            Direct3D11::{
                ID3D11Texture2D, D3D11_CPU_ACCESS_READ, D3D11_MAP_READ,
                D3D11_MAPPED_SUBRESOURCE, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
            },
            Dxgi::IDXGIDevice,
        },
        System::Threading::{
            AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, WaitForSingleObject,
        },
    },
};

use crate::{
    direct_3d_device::Direct3DDevice,
    helpers::Sendable,
    ipc::RECORDING_STATE,
    shared_memory::SharedMemoryWriter,
};

pub fn trace_log(msg: &str) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(r"C:\Windows\Temp\VDD_trace.log")
    {
        let _ = writeln!(f, "[{:?}] {msg}", std::time::SystemTime::now());
    }
}

pub struct SwapChainProcessor {
    monitor_id: u32,
    terminate: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

unsafe impl Send for SwapChainProcessor {}
unsafe impl Sync for SwapChainProcessor {}

/// Cached resources for frame capture (created lazily, reused across frames)
struct CaptureResources {
    staging_texture: ID3D11Texture2D,
    shm_writer: SharedMemoryWriter,
    width: u32,
    height: u32,
}

impl SwapChainProcessor {
    pub fn new(monitor_id: u32) -> Self {
        Self {
            monitor_id,
            terminate: Arc::new(AtomicBool::new(false)),
            thread: None,
        }
    }

    pub fn run(
        &mut self,
        swap_chain: IDDCX_SWAPCHAIN,
        device: Direct3DDevice,
        available_buffer_event: HANDLE,
    ) {
        let available_buffer_event = unsafe { Sendable::new(available_buffer_event) };
        let swap_chain = unsafe { Sendable::new(swap_chain) };
        let terminate = self.terminate.clone();
        let monitor_id = self.monitor_id;

        let join_handle = thread::spawn(move || {
            trace_log(&format!("SwapChainProcessor thread started for monitor {monitor_id}"));
            // It is very important to prioritize this thread by making use of the Multimedia Scheduler Service.
            // It will intelligently prioritize the thread for improved throughput in high CPU-load scenarios.
            let mut av_task = 0u32;
            let res = unsafe { AvSetMmThreadCharacteristicsW(w!("Distribution"), &mut av_task) };
            let Ok(av_handle) = res else {
                error!("Failed to prioritize thread: {res:?}");
                return;
            };

            Self::run_core(
                *swap_chain,
                &device,
                *available_buffer_event,
                &terminate,
                monitor_id,
            );

            let res = unsafe { WdfObjectDelete(*swap_chain as WDFOBJECT) };
            if let Err(e) = res {
                error!("Failed to delete wdf object: {e:?}");
                return;
            }

            // Revert the thread to normal once it's done
            let res = unsafe { AvRevertMmThreadCharacteristics(av_handle) };
            if let Err(e) = res {
                error!("Failed to revert prioritize thread: {e:?}");
            }
        });

        self.thread = Some(join_handle);
    }

    fn run_core(
        swap_chain: IDDCX_SWAPCHAIN,
        device: &Direct3DDevice,
        available_buffer_event: HANDLE,
        terminate: &AtomicBool,
        monitor_id: u32,
    ) {
        let dxgi_device = device.device.cast::<IDXGIDevice>();
        let Ok(dxgi_device) = dxgi_device else {
            error!("Failed to cast ID3D11Device to IDXGIDevice: {dxgi_device:?}");
            return;
        };

        let set_device = IDARG_IN_SWAPCHAINSETDEVICE {
            pDevice: dxgi_device.into_raw().cast(),
        };

        let res = unsafe { IddCxSwapChainSetDevice(swap_chain, &set_device) };
        if res.is_err() {
            trace_log(&format!("Failed to set swapchain device: {res:?}"));
            debug!("Failed to set swapchain device: {res:?}");
            return;
        }
        trace_log(&format!("SwapChain device set OK for monitor {monitor_id}"));

        let mut capture: Option<CaptureResources> = None;
        let mut was_recording = false;
        let mut frame_count: u64 = 0;
        let mut pending_count: u64 = 0;
        let mut loop_count: u64 = 0;

        trace_log(&format!("run_core: entering main loop for monitor {monitor_id}"));

        loop {
            loop_count += 1;
            // Log periodically to avoid flooding
            if loop_count == 1 || loop_count == 10 || loop_count == 100 || loop_count % 1000 == 0 {
                trace_log(&format!(
                    "run_core: monitor {monitor_id} loop={loop_count} frames={frame_count} pending={pending_count}"
                ));
            }

            let mut buffer = IDARG_OUT_RELEASEANDACQUIREBUFFER::default();
            let hr: NTSTATUS =
                unsafe { IddCxSwapChainReleaseAndAcquireBuffer(swap_chain, &mut buffer).into() };

            #[allow(clippy::items_after_statements)]
            const E_PENDING: u32 = 0x8000_000A;
            if u32::from(hr) == E_PENDING {
                pending_count += 1;
                let wait_result =
                    unsafe { WaitForSingleObject(WHANDLE(available_buffer_event.cast()), 16).0 };

                // thread requested an end
                let should_terminate = terminate.load(Ordering::Relaxed);
                if should_terminate {
                    trace_log(&format!("run_core: terminating for monitor {monitor_id}"));
                    break;
                }

                // WAIT_OBJECT_0 | WAIT_TIMEOUT
                if matches!(wait_result, 0 | WAIT_TIMEOUT) {
                    // We have a new buffer, so try the AcquireBuffer again
                    continue;
                }

                // The wait was cancelled or something unexpected happened
                trace_log(&format!(
                    "run_core: unexpected wait result {wait_result} for monitor {monitor_id}"
                ));
                break;
            } else if hr.is_success() {
                frame_count += 1;
                if frame_count <= 3 || frame_count % 100 == 0 {
                    trace_log(&format!(
                        "run_core: acquired frame #{frame_count} for monitor {monitor_id}"
                    ));
                }
                // Check if we should be recording this monitor
                let is_recording = {
                    let state = RECORDING_STATE.lock().unwrap();
                    state.is_recording(monitor_id)
                };

                if is_recording {
                    // Capture frame: get surface → copy to staging → release swap chain → map & write to shm
                    if !was_recording {
                        trace_log(&format!("First recording frame for monitor {monitor_id}"));
                    }
                    Self::capture_frame(device, &buffer, swap_chain, monitor_id, &mut capture);

                    if !was_recording {
                        info!("Started recording monitor {monitor_id}");
                        was_recording = true;
                    }
                } else {
                    // Not recording — just release the frame immediately
                    let hr = unsafe { IddCxSwapChainFinishedProcessingFrame(swap_chain) };
                    if hr.is_err() {
                        break;
                    }

                    // Clean up capture resources when recording stops
                    if was_recording {
                        info!("Stopped recording monitor {monitor_id}");
                        capture = None;
                        was_recording = false;
                    }
                }
            } else {
                // The swap-chain was likely abandoned (e.g. DXGI_ERROR_ACCESS_LOST), so exit the processing loop
                trace_log(&format!(
                    "run_core: swap chain error hr=0x{:08X} for monitor {monitor_id}, exiting loop",
                    u32::from(hr)
                ));
                break;
            }
        }

        trace_log(&format!(
            "run_core: exited main loop for monitor {monitor_id} (loops={loop_count} frames={frame_count} pending={pending_count})"
        ));
    }

    fn capture_frame(
        device: &Direct3DDevice,
        buffer: &IDARG_OUT_RELEASEANDACQUIREBUFFER,
        swap_chain: IDDCX_SWAPCHAIN,
        monitor_id: u32,
        capture: &mut Option<CaptureResources>,
    ) {
        // 1. Get the IDXGIResource from the swap chain buffer
        let surface_ptr = buffer.MetaData.pSurface;
        if surface_ptr.is_null() {
            trace_log(&format!("capture_frame: surface_ptr is null for monitor {monitor_id}"));
            let _ = unsafe { IddCxSwapChainFinishedProcessingFrame(swap_chain) };
            return;
        }

        // Cast the IUnknown surface to ID3D11Texture2D via QueryInterface.
        // ManuallyDrop prevents Release on the original ref (owned by IddCx).
        // cast() calls QueryInterface which AddRefs — the returned texture has its own ref.
        let unknown = ManuallyDrop::new(unsafe {
            windows::core::IUnknown::from_raw(surface_ptr.cast())
        });
        let texture: ID3D11Texture2D = match unknown.cast::<ID3D11Texture2D>() {
            Ok(tex) => tex,
            Err(e) => {
                error!("Failed to cast surface to ID3D11Texture2D: {e:?}");
                let _ = unsafe { IddCxSwapChainFinishedProcessingFrame(swap_chain) };
                return;
            }
        };

        // Get texture description
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        unsafe { texture.GetDesc(&mut desc) };

        // 2. Ensure capture resources exist and match current dimensions
        let resources = match capture {
            Some(res) if res.width == desc.Width && res.height == desc.Height => res,
            _ => {
                // Create or recreate staging texture + shared memory
                match Self::create_capture_resources(device, &desc, monitor_id) {
                    Ok(res) => {
                        *capture = Some(res);
                        capture.as_mut().unwrap()
                    }
                    Err(e) => {
                        error!("Failed to create capture resources: {e}");
                        let _ = unsafe { IddCxSwapChainFinishedProcessingFrame(swap_chain) };
                        return;
                    }
                }
            }
        };

        // 3. GPU copy: acquired texture → staging texture (fast GPU-side operation)
        unsafe {
            device
                .device_context
                .CopyResource(&resources.staging_texture, &texture);
        }

        // 4. Release the swap chain frame ASAP
        let hr = unsafe { IddCxSwapChainFinishedProcessingFrame(swap_chain) };
        if hr.is_err() {
            return;
        }

        // 5. Map the staging texture and copy to shared memory (slower CPU read)
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        let map_result = unsafe {
            device.device_context.Map(
                &resources.staging_texture,
                0,
                D3D11_MAP_READ,
                0,
                Some(&mut mapped),
            )
        };

        match map_result {
            Ok(()) => {
                let src_stride = mapped.RowPitch as usize;
                let dst_stride = (desc.Width * 4) as usize;
                let height = desc.Height as usize;

                if src_stride == dst_stride {
                    let data = unsafe {
                        std::slice::from_raw_parts(
                            mapped.pData as *const u8,
                            dst_stride * height,
                        )
                    };
                    resources.shm_writer.write_frame(data);

                    // Single lock: check session and send frame in one acquisition
                    let state = RECORDING_STATE.lock().unwrap();
                    if let Some(ref session) = state.session {
                        session.try_send_frame(crate::recording::Frame {
                            bgra_data: data.to_vec(),
                            width: desc.Width,
                            height: desc.Height,
                        });
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

                    // Single lock: check session and send frame in one acquisition
                    let state = RECORDING_STATE.lock().unwrap();
                    if let Some(ref session) = state.session {
                        session.try_send_frame(crate::recording::Frame {
                            bgra_data: frame_buf,
                            width: desc.Width,
                            height: desc.Height,
                        });
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
    }

    fn create_capture_resources(
        device: &Direct3DDevice,
        desc: &D3D11_TEXTURE2D_DESC,
        monitor_id: u32,
    ) -> Result<CaptureResources, String> {
        // Create staging texture
        let staging_desc = D3D11_TEXTURE2D_DESC {
            Width: desc.Width,
            Height: desc.Height,
            MipLevels: 1,
            ArraySize: 1,
            Format: desc.Format,
            SampleDesc: windows::Win32::Graphics::Dxgi::Common::DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: Default::default(),
        };

        let staging_texture = {
            let mut texture = None;
            unsafe {
                device
                    .device
                    .CreateTexture2D(&staging_desc, None, Some(&mut texture))
                    .map_err(|e| format!("CreateTexture2D failed: {e:?}"))?;
            }
            texture.ok_or("CreateTexture2D succeeded but texture is None")?
        };

        let stride = desc.Width * 4; // BGRA = 4 bytes per pixel
        let format = desc.Format.0 as u32;

        let shm_writer = SharedMemoryWriter::new(monitor_id, desc.Width, desc.Height, stride, format)
            .map_err(|e| format!("SharedMemoryWriter::new failed: {e}"))?;

        trace_log(&format!(
            "Created capture resources for monitor {monitor_id}: {}x{} stride={stride} format={format} shm={}",
            desc.Width,
            desc.Height,
            shm_writer.shm_name()
        ));
        info!(
            "Created capture resources for monitor {monitor_id}: {}x{} stride={stride} format={format} shm={}",
            desc.Width,
            desc.Height,
            shm_writer.shm_name()
        );

        Ok(CaptureResources {
            staging_texture,
            shm_writer,
            width: desc.Width,
            height: desc.Height,
        })
    }
}

impl Drop for SwapChainProcessor {
    fn drop(&mut self) {
        if let Some(handle) = self.thread.take() {
            // send signal to end thread
            self.terminate.store(true, Ordering::Relaxed);

            // wait until thread is finished
            _ = handle.join();
        }
    }
}
