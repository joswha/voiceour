//! The sidecar's WAV reader (`Sources/ASRSidecarCore/WAVFile.swift`), line for line: strict
//! 16 kHz mono 16-bit PCM, chunks walked from offset 12, a final chunk's overrunning size clamped,
//! the last `data` chunk wins, and each sample is `Float(Int16) * Float(1.0 / 32768.0)`.

/// Why a file was refused, with the Swift reader's wording.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WavError {
    NotRiff,
    Truncated(String),
    Unsupported(String),
}

impl std::fmt::Display for WavError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WavError::NotRiff => write!(f, "not a RIFF/WAVE file"),
            WavError::Truncated(detail) => write!(f, "truncated: {detail}"),
            WavError::Unsupported(detail) => write!(f, "unsupported: {detail}"),
        }
    }
}

impl std::error::Error for WavError {}

/// `WAVFile.readSamples(from:)`.
pub fn read_samples(data: &[u8]) -> Result<Vec<f32>, WavError> {
    if data.len() < 12 {
        return Err(WavError::Truncated("RIFF header".into()));
    }
    if four_cc(data, 0) != Some(*b"RIFF") || four_cc(data, 8) != Some(*b"WAVE") {
        return Err(WavError::NotRiff);
    }
    let mut saw_format = false;
    let mut pcm: Option<std::ops::Range<usize>> = None;
    let mut offset = 12usize;
    while offset + 8 <= data.len() {
        let chunk_id = four_cc(data, offset);
        let declared = read_u32(data, offset + 4) as usize;
        let body = offset + 8;
        let size = declared.min(data.len() - body);
        match chunk_id.as_ref() {
            Some(b"fmt ") => {
                if size < 16 {
                    return Err(WavError::Truncated("fmt chunk".into()));
                }
                validate_format(data, body)?;
                saw_format = true;
            }
            Some(b"data") => pcm = Some(body..body + size),
            _ => {}
        }
        offset = body + declared + declared % 2;
    }
    if !saw_format {
        return Err(WavError::Truncated("missing fmt chunk".into()));
    }
    let pcm = pcm.ok_or_else(|| WavError::Truncated("missing data chunk".into()))?;
    Ok(decode_int16(&data[pcm]))
}

/// `PCMSamples.decodeInt16`: `range.count / 2` little-endian samples, an odd byte ignored.
pub fn decode_int16(bytes: &[u8]) -> Vec<f32> {
    let scale = (1.0f64 / 32768.0) as f32;
    bytes
        .chunks_exact(2)
        .map(|pair| f32::from(i16::from_le_bytes([pair[0], pair[1]])) * scale)
        .collect()
}

fn validate_format(data: &[u8], offset: usize) -> Result<(), WavError> {
    let audio_format = read_u16(data, offset);
    let channels = read_u16(data, offset + 2);
    let sample_rate = read_u32(data, offset + 4);
    let bits_per_sample = read_u16(data, offset + 14);
    if audio_format != 1 {
        return Err(WavError::Unsupported(format!(
            "audio format {audio_format}, expected PCM (1)"
        )));
    }
    if channels != 1 {
        return Err(WavError::Unsupported(format!(
            "{channels} channels, expected 1"
        )));
    }
    if sample_rate != 16_000 {
        return Err(WavError::Unsupported(format!(
            "{sample_rate} Hz, expected 16000 Hz"
        )));
    }
    if bits_per_sample != 16 {
        return Err(WavError::Unsupported(format!(
            "{bits_per_sample}-bit, expected 16-bit"
        )));
    }
    Ok(())
}

/// Swift's `fourCC` yields "" past the end; `None` here (it equals no chunk name either way).
fn four_cc(data: &[u8], offset: usize) -> Option<[u8; 4]> {
    data.get(offset..offset + 4)
        .map(|bytes| [bytes[0], bytes[1], bytes[2], bytes[3]])
}

/// Swift's `readUInt16`/`readUInt32` read 0 past the end.
fn read_u16(data: &[u8], offset: usize) -> u16 {
    data.get(offset..offset + 2)
        .map_or(0, |b| u16::from_le_bytes([b[0], b[1]]))
}

fn read_u32(data: &[u8], offset: usize) -> u32 {
    data.get(offset..offset + 4)
        .map_or(0, |b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(id: &[u8; 4], body: &[u8], declared: Option<u32>) -> Vec<u8> {
        let mut out = id.to_vec();
        out.extend_from_slice(&declared.unwrap_or(body.len() as u32).to_le_bytes());
        out.extend_from_slice(body);
        out
    }

    fn fmt_body(format: u16, channels: u16, rate: u32, bits: u16) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&format.to_le_bytes());
        body.extend_from_slice(&channels.to_le_bytes());
        body.extend_from_slice(&rate.to_le_bytes());
        body.extend_from_slice(&(rate * 2).to_le_bytes());
        body.extend_from_slice(&2u16.to_le_bytes());
        body.extend_from_slice(&bits.to_le_bytes());
        body
    }

    fn riff(chunks: &[Vec<u8>]) -> Vec<u8> {
        let mut out = b"RIFF\0\0\0\0WAVE".to_vec();
        for c in chunks {
            out.extend_from_slice(c);
        }
        out
    }

    fn pcm(samples: &[i16]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    #[test]
    fn decodes_scaled_int16() {
        let data = riff(&[
            chunk(b"fmt ", &fmt_body(1, 1, 16_000, 16), None),
            chunk(b"data", &pcm(&[0, 1, -1, i16::MAX, i16::MIN]), None),
        ]);
        let samples = read_samples(&data).unwrap();
        assert_eq!(
            samples,
            vec![0.0, 1.0 / 32768.0, -1.0 / 32768.0, 32767.0 / 32768.0, -1.0]
        );
    }

    #[test]
    fn skips_padded_odd_chunks_and_keeps_the_last_data_chunk() {
        let data = riff(&[
            chunk(b"LIST", &[1, 2, 3], None),
            vec![0], // pad byte after an odd-sized chunk
            chunk(b"data", &pcm(&[5]), None),
            chunk(b"fmt ", &fmt_body(1, 1, 16_000, 16), None),
            chunk(b"data", &pcm(&[7, 8]), None),
        ]);
        assert_eq!(
            read_samples(&data).unwrap(),
            vec![7.0 / 32768.0, 8.0 / 32768.0]
        );
    }

    #[test]
    fn clamps_an_overrunning_final_chunk_and_drops_an_odd_byte() {
        let mut data = riff(&[chunk(b"fmt ", &fmt_body(1, 1, 16_000, 16), None)]);
        data.extend_from_slice(&chunk(b"data", &[1, 0, 2, 0, 9], Some(1000)));
        assert_eq!(
            read_samples(&data).unwrap(),
            vec![1.0 / 32768.0, 2.0 / 32768.0]
        );
    }

    #[test]
    fn refuses_other_formats() {
        let stereo = riff(&[
            chunk(b"fmt ", &fmt_body(1, 2, 16_000, 16), None),
            chunk(b"data", &pcm(&[0]), None),
        ]);
        assert!(matches!(
            read_samples(&stereo),
            Err(WavError::Unsupported(_))
        ));
        let float = riff(&[
            chunk(b"fmt ", &fmt_body(3, 1, 16_000, 32), None),
            chunk(b"data", &pcm(&[0]), None),
        ]);
        assert!(matches!(
            read_samples(&float),
            Err(WavError::Unsupported(_))
        ));
        let rate = riff(&[
            chunk(b"fmt ", &fmt_body(1, 1, 44_100, 16), None),
            chunk(b"data", &pcm(&[0]), None),
        ]);
        assert!(matches!(read_samples(&rate), Err(WavError::Unsupported(_))));
        assert_eq!(read_samples(b"RIFX\0\0\0\0WAVE"), Err(WavError::NotRiff));
        assert!(matches!(read_samples(b"RIFF"), Err(WavError::Truncated(_))));
        let no_data = riff(&[chunk(b"fmt ", &fmt_body(1, 1, 16_000, 16), None)]);
        assert_eq!(
            read_samples(&no_data),
            Err(WavError::Truncated("missing data chunk".into()))
        );
        let no_fmt = riff(&[chunk(b"data", &pcm(&[0]), None)]);
        assert_eq!(
            read_samples(&no_fmt),
            Err(WavError::Truncated("missing fmt chunk".into()))
        );
    }
}
