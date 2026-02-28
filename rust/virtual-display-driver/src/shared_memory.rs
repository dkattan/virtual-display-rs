use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};

use log::error;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Security::{
    InitializeSecurityDescriptor, SetSecurityDescriptorDacl, PSECURITY_DESCRIPTOR,
    SECURITY_ATTRIBUTES, SECURITY_DESCRIPTOR,
};
use windows::Win32::System::Memory::{
    CreateFileMappingW, MapViewOfFile, UnmapViewOfFile, FILE_MAP_ALL_ACCESS, PAGE_READWRITE,
};
use windows::Win32::System::Performance::QueryPerformanceCounter;
use windows::Win32::System::SystemServices::SECURITY_DESCRIPTOR_REVISION1;

/// Magic bytes: "VDD\0"
const SHM_MAGIC: u32 = 0x00444456;
const SHM_VERSION: u32 = 1;

/// Shared memory header (64 bytes, aligned)
#[repr(C)]
pub struct FrameHeader {
    pub magic: u32,
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: u32,        // DXGI_FORMAT value
    pub frame_count: u32,   // number of frame slots in ring buffer
    pub frame_size: u32,    // size of each frame in bytes
    pub write_sequence: AtomicU64, // monotonically increasing write counter (seqlock)
    pub timestamp_qpc: i64, // QueryPerformanceCounter value at last write
    pub dirty_rect_count: u32,
    pub _reserved: [u8; 12],
}

const HEADER_SIZE: usize = std::mem::size_of::<FrameHeader>();

pub struct SharedMemoryWriter {
    mapping_handle: HANDLE,
    view: *mut u8,
    total_size: usize,
    frame_size: usize,
    frame_count: u32,
    name: Vec<u16>,
}

// SAFETY: The shared memory is only written from a single thread (swap chain processor)
unsafe impl Send for SharedMemoryWriter {}
unsafe impl Sync for SharedMemoryWriter {}

impl SharedMemoryWriter {
    /// Create a new shared memory region for frame capture.
    ///
    /// `monitor_id` is used to name the mapping: `Global\VDD_Frame_{monitor_id}`
    pub fn new(
        monitor_id: u32,
        width: u32,
        height: u32,
        stride: u32,
        format: u32,
    ) -> Result<Self, &'static str> {
        let frame_size = (stride * height) as usize;
        let frame_count = 2u32; // double-buffered ring
        let total_size = HEADER_SIZE + frame_size * frame_count as usize;

        let name = format!("Global\\VDD_Frame_{monitor_id}");
        let name_wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();

        // Create security descriptor allowing anyone access (cross-session)
        let mut sd = SECURITY_DESCRIPTOR::default();
        unsafe {
            InitializeSecurityDescriptor(
                PSECURITY_DESCRIPTOR(ptr::addr_of_mut!(sd).cast()),
                SECURITY_DESCRIPTOR_REVISION1,
            )
            .map_err(|_| "InitializeSecurityDescriptor failed")?;

            SetSecurityDescriptorDacl(
                PSECURITY_DESCRIPTOR(ptr::addr_of_mut!(sd).cast()),
                true,
                None,
                false,
            )
            .map_err(|_| "SetSecurityDescriptorDacl failed")?;
        }

        let mut sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: ptr::addr_of_mut!(sd).cast(),
            bInheritHandle: false.into(),
        };

        let mapping_handle = unsafe {
            CreateFileMappingW(
                HANDLE(-1isize as *mut _), // INVALID_HANDLE_VALUE = backed by pagefile
                Some(&mut sa),
                PAGE_READWRITE,
                (total_size >> 32) as u32,
                total_size as u32,
                PCWSTR(name_wide.as_ptr()),
            )
            .map_err(|_| "CreateFileMappingW failed")?
        };

        let view = unsafe {
            MapViewOfFile(mapping_handle, FILE_MAP_ALL_ACCESS, 0, 0, total_size)
        };

        if view.Value.is_null() {
            unsafe { let _ = CloseHandle(mapping_handle); }
            return Err("MapViewOfFile failed");
        }

        let view_ptr = view.Value as *mut u8;

        // Initialize header
        let header = view_ptr as *mut FrameHeader;
        unsafe {
            (*header).magic = SHM_MAGIC;
            (*header).version = SHM_VERSION;
            (*header).width = width;
            (*header).height = height;
            (*header).stride = stride;
            (*header).format = format;
            (*header).frame_count = frame_count;
            (*header).frame_size = frame_size as u32;
            (*header).write_sequence = AtomicU64::new(0);
            (*header).timestamp_qpc = 0;
            (*header).dirty_rect_count = 0;
            (*header)._reserved = [0; 12];
        }

        Ok(Self {
            mapping_handle,
            view: view_ptr,
            total_size,
            frame_size,
            frame_count,
            name: name_wide,
        })
    }

    /// Write a frame to the shared memory ring buffer.
    ///
    /// `data` must be exactly `frame_size` bytes (stride * height).
    pub fn write_frame(&self, data: &[u8]) {
        if data.len() != self.frame_size {
            error!(
                "SharedMemoryWriter::write_frame: data len {} != frame_size {}",
                data.len(),
                self.frame_size
            );
            return;
        }

        let header = self.view as *mut FrameHeader;

        // Read current sequence, compute write slot
        let seq = unsafe { (*header).write_sequence.load(Ordering::Relaxed) };
        let slot = (seq as u32) % self.frame_count;
        let offset = HEADER_SIZE + (slot as usize) * self.frame_size;

        // Write the pixel data
        unsafe {
            ptr::copy_nonoverlapping(data.as_ptr(), self.view.add(offset), self.frame_size);
        }

        // Update timestamp
        let mut qpc = 0i64;
        unsafe {
            let _ = QueryPerformanceCounter(&mut qpc);
        }
        unsafe {
            (*header).timestamp_qpc = qpc;
        }

        // Memory fence + increment sequence to signal readers
        unsafe {
            (*header).write_sequence.store(seq + 1, Ordering::Release);
        }
    }

    /// Get the shared memory name (for reporting to IPC clients).
    pub fn shm_name(&self) -> String {
        String::from_utf16_lossy(
            &self.name[..self.name.len().saturating_sub(1)], // strip null terminator
        )
    }
}

impl Drop for SharedMemoryWriter {
    fn drop(&mut self) {
        unsafe {
            let _ = UnmapViewOfFile(windows::Win32::System::Memory::MEMORY_MAPPED_VIEW_ADDRESS {
                Value: self.view.cast(),
            });
            let _ = CloseHandle(self.mapping_handle);
        }
    }
}
