use std::fs::File;
use std::io::BufWriter;
use std::time::Instant;

use log::info;

/// BGRA to YUV420 planar converter with pre-allocated buffers.
///
/// Performs color space conversion from BGRA (Blue, Green, Red, Alpha) pixel
/// format -- the native format used by DXGI/Direct3D swap chains -- to YUV420
/// planar format as required by the H.264 encoder.
///
/// Buffers are pre-allocated at construction time to avoid per-frame allocation.
pub struct YuvConverter {
    pub y_plane: Vec<u8>,
    pub u_plane: Vec<u8>,
    pub v_plane: Vec<u8>,
    width: u32,
    height: u32,
}

impl YuvConverter {
    /// Create a new converter for the given frame dimensions.
    ///
    /// Both `width` and `height` must be even (required for YUV420 subsampling).
    pub fn new(width: u32, height: u32) -> Self {
        let y_size = (width * height) as usize;
        let uv_size = y_size / 4;
        Self {
            y_plane: vec![0u8; y_size],
            u_plane: vec![0u8; uv_size],
            v_plane: vec![0u8; uv_size],
            width,
            height,
        }
    }

    /// Convert BGRA pixel data to YUV420 planar.
    ///
    /// `bgra` must be exactly `width * height * 4` bytes in BGRA order.
    ///
    /// Uses the BT.601 full-range conversion matrix:
    /// - Y  = ((66*R + 129*G + 25*B + 128) >> 8) + 16
    /// - Cb = ((-38*R - 74*G + 112*B + 128) >> 8) + 128
    /// - Cr = ((112*R - 94*G - 18*B + 128) >> 8) + 128
    ///
    /// Chroma (U/V) planes are subsampled 2x2: only the top-left pixel of each
    /// 2x2 block contributes to the chroma value. This is standard practice for
    /// real-time encoding where speed is prioritized over chroma accuracy.
    pub fn convert(&mut self, bgra: &[u8]) {
        let w = self.width as usize;
        let h = self.height as usize;
        debug_assert_eq!(bgra.len(), w * h * 4);

        for y in 0..h {
            for x in 0..w {
                let idx = (y * w + x) * 4;
                let b = i32::from(bgra[idx]);
                let g = i32::from(bgra[idx + 1]);
                let r = i32::from(bgra[idx + 2]);
                // A = bgra[idx + 3] -- ignored

                let luma = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                self.y_plane[y * w + x] = luma.clamp(0, 255) as u8;

                if y % 2 == 0 && x % 2 == 0 {
                    let uv_idx = (y / 2) * (w / 2) + (x / 2);
                    let cb = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                    let cr = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                    self.u_plane[uv_idx] = cb.clamp(0, 255) as u8;
                    self.v_plane[uv_idx] = cr.clamp(0, 255) as u8;
                }
            }
        }
    }
}

/// MP4 encoder that accepts raw BGRA frames, encodes them via OpenH264, and
/// muxes the resulting H.264 NAL units into an MP4 container via muxide.
///
/// Typical usage:
/// ```ignore
/// let mut enc = Mp4Encoder::new("output.mp4", 1920, 1080, 30)?;
/// enc.encode_frame(&bgra_data)?;
/// // ... more frames ...
/// let (path, frames, duration_ms) = enc.finish()?;
/// ```
pub struct Mp4Encoder {
    encoder: openh264::encoder::Encoder,
    muxer: muxide::api::Muxer<BufWriter<File>>,
    yuv: YuvConverter,
    width: u32,
    height: u32,
    fps: u32,
    frame_count: u64,
    start_time: Instant,
    output_path: String,
}

impl Mp4Encoder {
    /// Create a new MP4 encoder.
    ///
    /// - `output_path`: filesystem path for the output .mp4 file
    /// - `width`, `height`: frame dimensions in pixels (must be even)
    /// - `fps`: target frame rate (used for bitrate calculation and muxer timing)
    ///
    /// The encoder is configured with a bitrate of 2 Mbps and the OpenH264
    /// library is loaded from the bundled source.
    pub fn new(output_path: &str, width: u32, height: u32, fps: u32) -> Result<Self, String> {
        // Configure OpenH264 encoder
        let config = openh264::encoder::EncoderConfig::new()
            .set_bitrate_bps(2_000_000)
            .max_frame_rate(fps as f32);

        let api = openh264::OpenH264API::from_source();
        let encoder = openh264::encoder::Encoder::with_api_config(api, config)
            .map_err(|e| format!("OpenH264 encoder init failed: {e}"))?;

        // Open the output file with buffering
        let file = File::create(output_path)
            .map_err(|e| format!("Failed to create output file '{output_path}': {e}"))?;
        let writer = BufWriter::new(file);

        // Create the MP4 muxer
        let muxer = muxide::api::MuxerBuilder::new(writer)
            .video(
                muxide::api::VideoCodec::H264,
                width,
                height,
                fps as f64,
            )
            .build()
            .map_err(|e| format!("Muxer init failed: {e}"))?;

        let yuv = YuvConverter::new(width, height);

        info!(
            "Mp4Encoder initialized: {}x{} @ {} fps -> {}",
            width, height, fps, output_path
        );

        Ok(Self {
            encoder,
            muxer,
            yuv,
            width,
            height,
            fps,
            frame_count: 0,
            start_time: Instant::now(),
            output_path: output_path.to_string(),
        })
    }

    /// Encode a single BGRA frame and write it to the MP4 file.
    ///
    /// `bgra` must be exactly `width * height * 4` bytes.
    ///
    /// The presentation timestamp is computed from the frame index and fps.
    /// Each frame is converted to YUV420, encoded to H.264 via OpenH264,
    /// and the resulting Annex B NAL units are written to the MP4 container.
    pub fn encode_frame(&mut self, bgra: &[u8]) -> Result<(), String> {
        let expected_len = (self.width * self.height * 4) as usize;
        if bgra.len() != expected_len {
            return Err(format!(
                "BGRA buffer size mismatch: expected {} bytes, got {}",
                expected_len,
                bgra.len()
            ));
        }

        // Convert BGRA to YUV420 planar
        self.yuv.convert(bgra);

        // Build YUV source for OpenH264
        let w = self.width as usize;
        let h = self.height as usize;
        let y_stride = w;
        let uv_stride = w / 2;

        let yuv_source = openh264::formats::YUVSlices::new(
            (&self.yuv.y_plane, &self.yuv.u_plane, &self.yuv.v_plane),
            (w, h),
            (y_stride, uv_stride, uv_stride),
        );

        // Compute timestamp in milliseconds for OpenH264
        let timestamp_ms = (self.frame_count * 1000) / self.fps as u64;
        let timestamp = openh264::Timestamp::from_millis(timestamp_ms);

        // Encode frame
        let bitstream = self
            .encoder
            .encode_at(&yuv_source, timestamp)
            .map_err(|e| format!("OpenH264 encode failed: {e}"))?;

        // Check for skip frames (no data produced)
        if bitstream.num_layers() == 0 {
            self.frame_count += 1;
            return Ok(());
        }

        // Collect the Annex B bitstream data from the encoder output.
        // OpenH264 produces NAL units with Annex B start codes already embedded
        // in the raw bitstream buffer, so `to_vec()` gives us valid Annex B data.
        let annex_b = bitstream.to_vec();

        if annex_b.is_empty() {
            self.frame_count += 1;
            return Ok(());
        }

        // Determine if this is a keyframe
        let is_keyframe = matches!(
            bitstream.frame_type(),
            openh264::encoder::FrameType::IDR | openh264::encoder::FrameType::I
        );

        // Compute PTS in seconds for the muxer
        let pts_secs = self.frame_count as f64 / self.fps as f64;

        // Write to MP4 container
        self.muxer
            .write_video(pts_secs, &annex_b, is_keyframe)
            .map_err(|e| format!("Muxer write failed: {e}"))?;

        self.frame_count += 1;
        Ok(())
    }

    /// Finalize the MP4 file and return recording statistics.
    ///
    /// Returns `(output_path, frame_count, duration_ms)` on success.
    ///
    /// This method consumes the encoder. The MP4 file is flushed and closed,
    /// making it ready for playback.
    pub fn finish(self) -> Result<(String, u64, u64), String> {
        let frame_count = self.frame_count;
        let elapsed_ms = self.start_time.elapsed().as_millis() as u64;
        let output_path = self.output_path.clone();

        let stats = self
            .muxer
            .finish_with_stats()
            .map_err(|e| format!("Muxer finish failed: {e}"))?;

        info!(
            "Mp4Encoder finished: {} frames, {:.1}s video duration, {} bytes written -> {}",
            stats.video_frames, stats.duration_secs, stats.bytes_written, output_path
        );

        Ok((output_path, frame_count, elapsed_ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yuv_converter_red_pixel() {
        let mut conv = YuvConverter::new(2, 2);
        // 4 red pixels (BGRA: B=0, G=0, R=255, A=255)
        let bgra = vec![
            0u8, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255,
        ];
        conv.convert(&bgra);

        // Y for pure red: ((66*255 + 128) >> 8) + 16 = 81
        assert_eq!(conv.y_plane[0], 81);
        // Cr for pure red: ((112*255 + 128) >> 8) + 128 = 239
        assert_eq!(conv.v_plane[0], 239);
    }

    #[test]
    fn yuv_converter_green_pixel() {
        let mut conv = YuvConverter::new(2, 2);
        // 4 green pixels (BGRA: B=0, G=255, R=0, A=255)
        let bgra = vec![
            0u8, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255,
        ];
        conv.convert(&bgra);

        // Y for pure green: ((129*255 + 128) >> 8) + 16 = 144
        assert_eq!(conv.y_plane[0], 144);
        // Cb for pure green: ((-74*255 + 128) >> 8) + 128 = 54
        assert_eq!(conv.u_plane[0], 54);
        // Cr for pure green: ((-94*255 + 128) >> 8) + 128 = 34
        assert_eq!(conv.v_plane[0], 34);
    }

    #[test]
    fn yuv_converter_black_pixel() {
        let mut conv = YuvConverter::new(2, 2);
        // 4 black pixels (BGRA: all zeros except alpha)
        let bgra = vec![
            0u8, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255,
        ];
        conv.convert(&bgra);

        // Y for black: ((0 + 128) >> 8) + 16 = 16
        assert_eq!(conv.y_plane[0], 16);
        // Cb for black: ((0 + 128) >> 8) + 128 = 128
        assert_eq!(conv.u_plane[0], 128);
        // Cr for black: ((0 + 128) >> 8) + 128 = 128
        assert_eq!(conv.v_plane[0], 128);
    }

    #[test]
    fn yuv_converter_white_pixel() {
        let mut conv = YuvConverter::new(2, 2);
        // 4 white pixels (BGRA: B=255, G=255, R=255, A=255)
        let bgra = vec![
            255u8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        ];
        conv.convert(&bgra);

        // Y for white: ((66*255 + 129*255 + 25*255 + 128) >> 8) + 16 = 235
        assert_eq!(conv.y_plane[0], 235);
        // Cb for white: ((-38*255 - 74*255 + 112*255 + 128) >> 8) + 128 = 128
        assert_eq!(conv.u_plane[0], 128);
        // Cr for white: ((112*255 - 94*255 - 18*255 + 128) >> 8) + 128 = 128
        assert_eq!(conv.v_plane[0], 128);
    }

    #[test]
    fn yuv_converter_dimensions() {
        let conv = YuvConverter::new(1920, 1080);
        assert_eq!(conv.y_plane.len(), 1920 * 1080);
        assert_eq!(conv.u_plane.len(), 960 * 540);
        assert_eq!(conv.v_plane.len(), 960 * 540);
    }

    #[test]
    fn yuv_converter_small_dimensions() {
        let conv = YuvConverter::new(4, 4);
        assert_eq!(conv.y_plane.len(), 16);
        assert_eq!(conv.u_plane.len(), 4);
        assert_eq!(conv.v_plane.len(), 4);
    }

    #[test]
    fn encode_single_frame_to_mp4() {
        let dir = std::env::temp_dir();
        let path = dir.join("vdd_test_encode.mp4");
        let path_str = path.to_str().unwrap();

        let width = 64u32;
        let height = 64u32;
        let bgra: Vec<u8> = (0..width * height)
            .flat_map(|_| [255u8, 0, 0, 255])
            .collect();

        let mut enc = Mp4Encoder::new(path_str, width, height, 5).unwrap();
        enc.encode_frame(&bgra).unwrap();
        let (out_path, frames, _dur) = enc.finish().unwrap();

        assert_eq!(frames, 1);
        assert!(std::path::Path::new(&out_path).exists());
        let size = std::fs::metadata(&out_path).unwrap().len();
        assert!(size > 0, "MP4 file should not be empty");

        let _ = std::fs::remove_file(&out_path);
    }

    #[test]
    fn encode_multiple_frames_to_mp4() {
        let dir = std::env::temp_dir();
        let path = dir.join("vdd_test_multi.mp4");
        let path_str = path.to_str().unwrap();

        let width = 128u32;
        let height = 128u32;

        let mut enc = Mp4Encoder::new(path_str, width, height, 10).unwrap();

        for i in 0..30 {
            let bgra: Vec<u8> = (0..width * height)
                .flat_map(|px| {
                    let x = (px % width) as u8;
                    let y = (px / width) as u8;
                    [x.wrapping_add(i as u8), y, 128, 255]
                })
                .collect();
            enc.encode_frame(&bgra).unwrap();
        }

        let (out_path, frames, _dur) = enc.finish().unwrap();
        assert_eq!(frames, 30);
        assert!(std::fs::metadata(&out_path).unwrap().len() > 100);

        let _ = std::fs::remove_file(&out_path);
    }

    #[test]
    fn encode_frame_rejects_wrong_buffer_size() {
        let dir = std::env::temp_dir();
        let path = dir.join("vdd_test_bad_size.mp4");
        let path_str = path.to_str().unwrap();

        let mut enc = Mp4Encoder::new(path_str, 64, 64, 30).unwrap();
        let too_small = vec![0u8; 100];
        let result = enc.encode_frame(&too_small);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("BGRA buffer size mismatch"));

        // Clean up -- finish will fail since no frames written, that's fine
        let _ = enc.finish();
        let _ = std::fs::remove_file(path_str);
    }
}
