//! Streaming helper for Part 3: turns the browser's Float32 mic frames
//! (usually 44.1/48 kHz) into 16-bit PCM at the session rate, chunk by chunk.
//!
//! It is stateful so chunk boundaries are seamless — the fractional read
//! position and the last input sample carry over between calls, which a
//! stateless per-chunk resample would get wrong (clicks every chunk).

pub struct Resampler {
    step: f64,
    pos: f64,
    prev: f32,
}

impl Resampler {
    pub fn new(from_rate: u32, to_rate: u32) -> Self {
        Resampler { step: from_rate as f64 / to_rate as f64, pos: 0.0, prev: 0.0 }
    }

    /// Consume `input`, returning as many output samples as it covers.
    ///
    /// `pos` is measured relative to the start of `input`; index -1 is the last
    /// sample of the previous chunk (`prev`), so interpolation can straddle the
    /// boundary.
    pub fn push(&mut self, input: &[f32]) -> Vec<i16> {
        let mut out = Vec::with_capacity((input.len() as f64 / self.step) as usize + 1);
        let len = input.len() as f64;
        let at = |i: isize, prev: f32| -> f32 { if i < 0 { prev } else { input[i as usize] } };
        loop {
            // pos >= -1 always holds here (see the rebase below).
            let i = self.pos.floor() as isize;
            if i + 1 >= input.len() as isize {
                break;
            }
            let frac = (self.pos - i as f64) as f32;
            let a = at(i, self.prev);
            let b = at(i + 1, self.prev);
            out.push(to_i16(a + (b - a) * frac));
            self.pos += self.step;
        }
        if let Some(last) = input.last() {
            self.prev = *last;
        }
        // Rebase so the next chunk's index 0 follows this chunk's last sample.
        self.pos -= len;
        out
    }
}

pub fn to_i16(s: f32) -> i16 {
    let v = (s.clamp(-1.0, 1.0) * 32767.0).round();
    v as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_rate_passes_samples_through() {
        let mut r = Resampler::new(16_000, 16_000);
        let a = r.push(&[0.0, 0.5, -0.5]);
        let b = r.push(&[1.0, -1.0]);
        let all: Vec<i16> = a.into_iter().chain(b).collect();
        // The final sample is held back until the next chunk arrives (it's
        // needed as the left side of the next interpolation).
        assert_eq!(all, vec![0, 16_384, -16_384, 32_767]);
    }

    #[test]
    fn downsample_by_two_produces_half_the_samples() {
        let mut r = Resampler::new(48_000, 24_000);
        let mut total = 0;
        for _ in 0..100 {
            total += r.push(&[0.1; 128]).len();
        }
        assert!((total as i32 - 6400).abs() <= 1, "got {total}");
    }

    #[test]
    fn chunked_output_matches_one_shot_output() {
        let input: Vec<f32> = (0..1000).map(|i| ((i as f32) * 0.05).sin()).collect();
        let mut one = Resampler::new(44_100, 24_000);
        let whole = one.push(&input);
        let mut chunked = Resampler::new(44_100, 24_000);
        let mut parts = Vec::new();
        for c in input.chunks(128) {
            parts.extend(chunked.push(c));
        }
        assert_eq!(whole.len(), parts.len());
        for (a, b) in whole.iter().zip(parts.iter()) {
            assert!((*a as i32 - *b as i32).abs() <= 1);
        }
    }
}
