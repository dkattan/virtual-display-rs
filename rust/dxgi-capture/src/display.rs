use std::fmt;

use log::debug;
use windows::Win32::{
    Foundation::RECT,
    Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter1, IDXGIFactory1, IDXGIOutput},
};

#[derive(Debug, Clone)]
pub struct DisplayInfo {
    pub adapter_index: u32,
    pub output_index: u32,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub left: i32,
    pub top: i32,
    pub is_primary: bool,
    pub adapter_luid: i64,
}

impl fmt::Display for DisplayInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Display {} ({}x{}{}) adapter={} output={}",
            self.name,
            self.width,
            self.height,
            if self.is_primary { " PRIMARY" } else { "" },
            self.adapter_index,
            self.output_index,
        )
    }
}

pub fn enumerate_displays() -> Result<Vec<DisplayInfo>, windows::core::Error> {
    let factory: IDXGIFactory1 = unsafe { CreateDXGIFactory1()? };
    let mut displays = Vec::new();
    let mut adapter_index = 0u32;

    loop {
        let adapter: IDXGIAdapter1 = match unsafe { factory.EnumAdapters1(adapter_index) } {
            Ok(a) => a,
            Err(_) => break,
        };

        let adapter_desc = unsafe { adapter.GetDesc1()? };
        let adapter_luid = (i64::from(adapter_desc.AdapterLuid.HighPart) << 32)
            | i64::from(adapter_desc.AdapterLuid.LowPart);

        let mut output_index = 0u32;
        loop {
            let output: IDXGIOutput = match unsafe { adapter.EnumOutputs(output_index) } {
                Ok(o) => o,
                Err(_) => break,
            };

            let desc = unsafe { output.GetDesc()? };

            if desc.AttachedToDesktop.as_bool() {
                let name = String::from_utf16_lossy(
                    &desc.DeviceName[..desc
                        .DeviceName
                        .iter()
                        .position(|&c| c == 0)
                        .unwrap_or(desc.DeviceName.len())],
                );

                let rect: RECT = desc.DesktopCoordinates;
                let width = (rect.right - rect.left) as u32;
                let height = (rect.bottom - rect.top) as u32;

                // Primary monitor has origin at (0,0)
                let is_primary = rect.left == 0 && rect.top == 0;

                debug!(
                    "Found display: {} ({}x{}) at ({},{}) primary={}",
                    name, width, height, rect.left, rect.top, is_primary
                );

                displays.push(DisplayInfo {
                    adapter_index,
                    output_index,
                    name,
                    width,
                    height,
                    left: rect.left,
                    top: rect.top,
                    is_primary,
                    adapter_luid,
                });
            }

            output_index += 1;
        }

        adapter_index += 1;
    }

    Ok(displays)
}
