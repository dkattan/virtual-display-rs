use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

use log::{debug, error, info, warn};
use windows::{
    core::{w, Interface},
    Win32::{
        Graphics::{
            Direct3D::D3D_DRIVER_TYPE_UNKNOWN,
            Direct3D11::{
                D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
                D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                D3D11_CREATE_DEVICE_SINGLETHREADED, D3D11_MAP_READ, D3D11_MAPPED_SUBRESOURCE,
                D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
            },
            Dxgi::{
                CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1, IDXGIOutput1,
                IDXGIOutputDuplication, IDXGIResource, DXGI_ERROR_ACCESS_LOST,
                DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO,
            },
            Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM,
        },
        System::{
            Performance::QueryPerformanceCounter,
            Threading::{
                AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW,
            },
        },
    },
};

use crate::display::DisplayInfo;
use crate::shared_memory::SharedMemoryWriter;

const FRAME_SLOTS: u32 = 3; // Triple buffering

pub struct CaptureThread {
    terminate: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    display: DisplayInfo,
    shm_name: String,
}

impl CaptureThread {
    pub fn start(display: DisplayInfo) -> Result<Self, windows::core::Error> {
        let shm_name = format!(
            "Local\\DxgiCapture_{}_{}",
            display.adapter_index, display.output_index
        );

        let terminate = Arc::new(AtomicBool::new(false));
        let term_clone = terminate.clone();
        let display_clone = display.clone();
        let shm_name_clone = shm_name.clone();

        let thread = thread::spawn(move || {
            // MMCSS: prioritize this thread for improved throughput
            let mut av_task = 0u32;
            let av_handle =
                unsafe { AvSetMmThreadCharacteristicsW(w!("Distribution"), &mut av_task) };

            if let Err(ref e) = av_handle {
                warn!("Failed to set MMCSS thread characteristics: {e:?}");
            }

            if let Err(e) = capture_loop(&display_clone, &shm_name_clone, &term_clone) {
                error!("Capture loop for {} failed: {e:?}", display_clone.name);
            }

            if let Ok(handle) = av_handle {
                let _ = unsafe { AvRevertMmThreadCharacteristics(handle) };
            }

            info!("Capture thread for {} exited", display_clone.name);
        });

        Ok(Self {
            terminate,
            thread: Some(thread),
            display,
            shm_name,
        })
    }

    pub fn display(&self) -> &DisplayInfo {
        &self.display
    }

    pub fn shm_name(&self) -> &str {
        &self.shm_name
    }

    pub fn stop(&mut self) {
        self.terminate.store(true, Ordering::Relaxed);
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for CaptureThread {
    fn drop(&mut self) {
        self.stop();
    }
}

fn create_device_for_adapter(
    adapter_index: u32,
) -> Result<(IDXGIAdapter1, ID3D11Device, ID3D11DeviceContext), windows::core::Error> {
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1()? };
    let adapter: IDXGIAdapter1 = unsafe { factory.EnumAdapters1(adapter_index)? };

    let mut device = None;
    let mut context = None;

    unsafe {
        D3D11CreateDevice(
            &adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            None,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_SINGLETHREADED,
            None, // feature levels
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )?;
    }

    Ok((
        adapter,
        device.expect("D3D11CreateDevice succeeded but device is None"),
        context.expect("D3D11CreateDevice succeeded but context is None"),
    ))
}

fn create_duplication(
    adapter: &IDXGIAdapter1,
    output_index: u32,
    device: &ID3D11Device,
) -> Result<IDXGIOutputDuplication, windows::core::Error> {
    let output = unsafe { adapter.EnumOutputs(output_index)? };
    let output1: IDXGIOutput1 = output.cast()?;
    let duplication = unsafe { output1.DuplicateOutput(device)? };
    Ok(duplication)
}

fn create_staging_texture(
    device: &ID3D11Device,
    width: u32,
    height: u32,
) -> Result<ID3D11Texture2D, windows::core::Error> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: windows::Win32::Graphics::Dxgi::Common::DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        Usage: D3D11_USAGE_STAGING,
        BindFlags: 0,
        CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
        MiscFlags: Default::default(),
    };

    let mut texture = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut texture))? };
    Ok(texture.expect("CreateTexture2D succeeded but texture is None"))
}

fn capture_loop(
    display: &DisplayInfo,
    shm_name: &str,
    terminate: &AtomicBool,
) -> Result<(), windows::core::Error> {
    info!(
        "Starting capture for {} ({}x{})",
        display.name, display.width, display.height
    );

    let (adapter, device, context) = create_device_for_adapter(display.adapter_index)?;

    let staging = create_staging_texture(&device, display.width, display.height)?;

    // BGRA = 4 bytes per pixel
    let estimated_stride = display.width * 4;

    let shm = SharedMemoryWriter::create(
        shm_name,
        display.width,
        display.height,
        estimated_stride,
        FRAME_SLOTS,
    )?;

    // Frame buffer for CPU-side copy
    let frame_size = (estimated_stride * display.height) as usize;
    let mut frame_buf = vec![0u8; frame_size];

    // Create duplication
    let mut duplication = create_duplication(&adapter, display.output_index, &device)?;
    info!("DXGI duplication created for {}", display.name);

    let mut frames_captured: u64 = 0;

    loop {
        if terminate.load(Ordering::Relaxed) {
            break;
        }

        let mut frame_info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource: Option<IDXGIResource> = None;

        let hr = unsafe { duplication.AcquireNextFrame(16, &mut frame_info, &mut resource) };

        match hr {
            Ok(()) => {
                let resource = resource.expect("AcquireNextFrame succeeded but resource is None");
                let texture: ID3D11Texture2D = resource.cast()?;

                // Copy GPU texture to staging (CPU-readable)
                unsafe { context.CopyResource(&staging, &texture) };

                // Release the frame ASAP (per Microsoft guidance)
                unsafe { duplication.ReleaseFrame()? };

                // Map staging texture to read pixels
                let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                unsafe {
                    context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))?;
                }

                // Get QPC timestamp
                let mut qpc = 0i64;
                unsafe { QueryPerformanceCounter(&mut qpc)? };

                // Copy pixels to frame buffer, handling stride mismatch
                let src = mapped.pData as *const u8;
                let src_pitch = mapped.RowPitch as usize;
                let dst_pitch = estimated_stride as usize;

                if src_pitch == dst_pitch {
                    unsafe {
                        std::ptr::copy_nonoverlapping(src, frame_buf.as_mut_ptr(), frame_size);
                    }
                } else {
                    // Row-by-row copy for stride mismatch
                    let row_bytes = dst_pitch.min(src_pitch);
                    for y in 0..display.height as usize {
                        unsafe {
                            std::ptr::copy_nonoverlapping(
                                src.add(y * src_pitch),
                                frame_buf.as_mut_ptr().add(y * dst_pitch),
                                row_bytes,
                            );
                        }
                    }
                }

                unsafe { context.Unmap(&staging, 0) };

                // Write to shared memory
                let dirty_count = frame_info.TotalMetadataBufferSize;
                shm.write_frame(&frame_buf, qpc as u64, dirty_count);

                frames_captured += 1;
                if frames_captured % 300 == 0 {
                    debug!("{}: captured {} frames", display.name, frames_captured);
                }
            }
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => {
                continue;
            }
            Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                warn!(
                    "{}: DXGI_ERROR_ACCESS_LOST, recreating duplication...",
                    display.name
                );
                match create_duplication(&adapter, display.output_index, &device) {
                    Ok(new_dup) => {
                        duplication = new_dup;
                        info!("{}: duplication recreated", display.name);
                    }
                    Err(e) => {
                        error!("{}: failed to recreate duplication: {e:?}", display.name);
                        std::thread::sleep(std::time::Duration::from_millis(500));
                    }
                }
            }
            Err(e) => {
                error!("{}: AcquireNextFrame failed: {e:?}", display.name);
                break;
            }
        }
    }

    info!(
        "Capture stopped for {} after {} frames",
        display.name, frames_captured
    );
    Ok(())
}
