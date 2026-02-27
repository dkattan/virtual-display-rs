use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};

use log::{debug, error};
use windows::{
    core::{HSTRING, PCWSTR},
    Win32::{
        Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE},
        System::Memory::{
            CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, FILE_MAP_ALL_ACCESS,
            PAGE_READWRITE,
        },
    },
};

const MAGIC: u32 = 0x4458_4749; // "DXGI"
const VERSION: u32 = 1;
const HEADER_SIZE: usize = 64;

/// Header layout in shared memory (64 bytes)
#[repr(C)]
pub struct ShmHeader {
    pub magic: u32,
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: u32, // DXGI_FORMAT_B8G8R8A8_UNORM = 87
    pub frame_count: u32,
    pub frame_size: u32,
    pub write_sequence: AtomicU64,
    pub timestamp_qpc: u64,
    pub dirty_rect_count: u32,
    pub _reserved: [u8; 12],
}

pub struct SharedMemoryWriter {
    mapping: HANDLE,
    view: *mut u8,
    total_size: usize,
    frame_count: u32,
    frame_size: u32,
    name: String,
}

unsafe impl Send for SharedMemoryWriter {}

impl SharedMemoryWriter {
    pub fn create(
        name: &str,
        width: u32,
        height: u32,
        stride: u32,
        frame_count: u32,
    ) -> Result<Self, windows::core::Error> {
        let frame_size = stride * height;
        let total_size = HEADER_SIZE + (frame_count as usize * frame_size as usize);

        let wide_name = HSTRING::from(name);

        let mapping = unsafe {
            CreateFileMappingW(
                INVALID_HANDLE_VALUE,
                None,
                PAGE_READWRITE,
                (total_size >> 32) as u32,
                total_size as u32,
                PCWSTR(wide_name.as_ptr()),
            )?
        };

        let view = unsafe {
            MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, total_size)
        };

        if view.Value.is_null() {
            unsafe { CloseHandle(mapping)?; }
            return Err(windows::core::Error::from_win32());
        }

        let view_ptr = view.Value as *mut u8;

        // Initialize header
        unsafe {
            let header = &mut *(view_ptr as *mut ShmHeader);
            header.magic = MAGIC;
            header.version = VERSION;
            header.width = width;
            header.height = height;
            header.stride = stride;
            header.format = 87; // DXGI_FORMAT_B8G8R8A8_UNORM
            header.frame_count = frame_count;
            header.frame_size = frame_size;
            header.write_sequence = AtomicU64::new(0);
            header.timestamp_qpc = 0;
            header.dirty_rect_count = 0;
            header._reserved = [0; 12];
        }

        debug!(
            "Created shared memory '{}': {}x{}, stride={}, {} frames, total={}KB",
            name,
            width,
            height,
            stride,
            frame_count,
            total_size / 1024
        );

        Ok(Self {
            mapping,
            view: view_ptr,
            total_size,
            frame_count,
            frame_size,
            name: name.to_string(),
        })
    }

    /// Write a frame to the ring buffer. `data` must be `frame_size` bytes (stride * height).
    /// `timestamp_qpc` is the QPC value from `QueryPerformanceCounter`.
    pub fn write_frame(&self, data: &[u8], timestamp_qpc: u64, dirty_rect_count: u32) {
        unsafe {
            let header = &mut *(self.view as *mut ShmHeader);

            // Get current sequence and compute slot
            let seq = header.write_sequence.load(Ordering::Acquire);
            let slot = (seq % u64::from(self.frame_count)) as usize;

            // Write frame data to slot
            let frame_offset = HEADER_SIZE + slot * self.frame_size as usize;
            let dest = self.view.add(frame_offset);
            let copy_len = data.len().min(self.frame_size as usize);
            ptr::copy_nonoverlapping(data.as_ptr(), dest, copy_len);

            // Update header metadata
            header.timestamp_qpc = timestamp_qpc;
            header.dirty_rect_count = dirty_rect_count;

            // Increment sequence (signals readers that a new frame is available)
            header.write_sequence.store(seq + 1, Ordering::Release);
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }
}

impl Drop for SharedMemoryWriter {
    fn drop(&mut self) {
        unsafe {
            let view = windows::Win32::System::Memory::MEMORY_MAPPED_VIEW_ADDRESS {
                Value: self.view as *mut _,
            };
            if let Err(e) = UnmapViewOfFile(view) {
                error!("Failed to unmap view: {e:?}");
            }
            if let Err(e) = CloseHandle(self.mapping) {
                error!("Failed to close mapping: {e:?}");
            }
        }
        debug!("Destroyed shared memory '{}'", self.name);
    }
}
