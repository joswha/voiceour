//! Port of `MercuryNoise` (Sources/Voiceour/MercuryNoise.swift): counter-based SplitMix64.

/// `MercuryNoiseStream` identifiers the room draws use.
pub mod stream {
    pub const ROOM_LOBES: u32 = 4;
    pub const ROOM_INTENSITY: u32 = 7;
    pub const ROOM_CHROMA: u32 = 8;
}

#[derive(Clone, Copy, Debug)]
pub struct Noise {
    seed: u64,
}

impl Noise {
    pub fn new(seed: u64) -> Self {
        Self { seed }
    }

    /// Uniform on `[0, 1)` from the top 53 bits.
    #[inline(always)]
    pub fn uniform(&self, stream: u32, counter: u64) -> f64 {
        (self.bits(stream, counter) >> 11) as f64 * f64::from_bits(0x3CA0_0000_0000_0000) // 0x1p-53
    }

    /// Uniform on the sphere: `z` uniform on `[-1, 1)` and the azimuth uniform.
    #[inline(always)]
    pub fn unit_vector(&self, stream: u32, counter: u64) -> [f64; 3] {
        let height = 2.0 * self.uniform(stream, counter.wrapping_mul(2)) - 1.0;
        let angle = 2.0
            * std::f64::consts::PI
            * self.uniform(stream, counter.wrapping_mul(2).wrapping_add(1));
        let radius = crate::swift::max(0.0, 1.0 - height * height).sqrt();
        [radius * angle.cos(), radius * angle.sin(), height]
    }

    #[inline(always)]
    fn bits(&self, stream: u32, counter: u64) -> u64 {
        let mut state = self.seed ^ ((stream as u64) << 40) ^ counter;
        state = (state ^ (state >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        state = (state ^ (state >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        state ^ (state >> 31)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scale_constant_is_two_to_minus_fifty_three() {
        assert_eq!(f64::from_bits(0x3CA0_0000_0000_0000), 2f64.powi(-53));
    }

    #[test]
    fn uniform_is_half_open() {
        let noise = Noise::new(0x5155_4943_4B53_4C56);
        for counter in 0..10_000 {
            let value = noise.uniform(stream::ROOM_LOBES, counter);
            assert!((0.0..1.0).contains(&value));
        }
    }
}
