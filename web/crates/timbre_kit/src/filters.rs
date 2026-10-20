//! Biquad filters (RBJ "Audio EQ Cookbook") and a noise gate.

use std::f32::consts::PI;

/// A direct-form-I biquad. Coefficients are pre-normalized by a0.
#[derive(Clone, Copy)]
pub struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

impl Biquad {
    fn from_coeffs(b0: f32, b1: f32, b2: f32, a0: f32, a1: f32, a2: f32) -> Self {
        Biquad {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    /// Second-order low-pass at `cutoff` Hz with resonance `q` (0.707 = Butterworth).
    pub fn low_pass(sample_rate: u32, cutoff: f32, q: f32) -> Self {
        let (cos_w, alpha) = Self::omega(sample_rate, cutoff, q);
        let b1 = 1.0 - cos_w;
        Self::from_coeffs(b1 / 2.0, b1, b1 / 2.0, 1.0 + alpha, -2.0 * cos_w, 1.0 - alpha)
    }

    /// Second-order high-pass at `cutoff` Hz.
    pub fn high_pass(sample_rate: u32, cutoff: f32, q: f32) -> Self {
        let (cos_w, alpha) = Self::omega(sample_rate, cutoff, q);
        let b0 = (1.0 + cos_w) / 2.0;
        Self::from_coeffs(b0, -(1.0 + cos_w), b0, 1.0 + alpha, -2.0 * cos_w, 1.0 - alpha)
    }

    fn omega(sample_rate: u32, cutoff: f32, q: f32) -> (f32, f32) {
        // Keep the cutoff strictly inside (0, Nyquist) or the maths blows up.
        let nyquist = sample_rate as f32 / 2.0;
        let f = cutoff.clamp(10.0, nyquist * 0.99);
        let w = 2.0 * PI * f / sample_rate as f32;
        (w.cos(), w.sin() / (2.0 * q.max(0.1)))
    }

    pub fn tick(&mut self, x: f32) -> f32 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }

    pub fn run(mut self, samples: &[f32]) -> Vec<f32> {
        samples.iter().map(|&s| self.tick(s)).collect()
    }
}

pub fn low_pass(samples: &[f32], sample_rate: u32, cutoff: f32) -> Vec<f32> {
    Biquad::low_pass(sample_rate, cutoff, std::f32::consts::FRAC_1_SQRT_2).run(samples)
}

pub fn high_pass(samples: &[f32], sample_rate: u32, cutoff: f32) -> Vec<f32> {
    Biquad::high_pass(sample_rate, cutoff, std::f32::consts::FRAC_1_SQRT_2).run(samples)
}

/// One-pole smoothing coefficient for a time constant of `ms` milliseconds.
fn coeff(sample_rate: u32, ms: f32) -> f32 {
    if ms <= 0.0 {
        return 0.0;
    }
    (-1.0 / (sample_rate as f32 * ms / 1000.0)).exp()
}

/// Noise gate: mutes audio whose level stays below `threshold_db`.
///
/// A fast peak follower tracks the level; the gate opens when it crosses the
/// threshold, stays open for a short hold, and the gain is smoothed so opening
/// and closing don't click.
pub fn noise_gate(samples: &[f32], sample_rate: u32, threshold_db: f32) -> Vec<f32> {
    let thresh = 10f32.powf(threshold_db / 20.0);
    let env_attack = coeff(sample_rate, 1.0);
    let env_release = coeff(sample_rate, 50.0);
    let gain_attack = coeff(sample_rate, 3.0);
    let gain_release = coeff(sample_rate, 80.0);
    let hold_samples = (sample_rate as f32 * 0.05) as usize;

    let mut env = 0.0f32;
    let mut gain = 0.0f32;
    let mut hold = 0usize;

    samples
        .iter()
        .map(|&x| {
            let level = x.abs();
            let c = if level > env { env_attack } else { env_release };
            env = c * env + (1.0 - c) * level;

            let target = if env >= thresh {
                hold = hold_samples;
                1.0
            } else if hold > 0 {
                hold -= 1;
                1.0
            } else {
                0.0
            };
            let c = if target > gain { gain_attack } else { gain_release };
            gain = c * gain + (1.0 - c) * target;
            x * gain
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, sr: u32, secs: f32) -> Vec<f32> {
        let n = (sr as f32 * secs) as usize;
        (0..n).map(|i| (2.0 * PI * freq * i as f32 / sr as f32).sin()).collect()
    }

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt()
    }

    #[test]
    fn low_pass_keeps_lows_and_cuts_highs() {
        let sr = 48_000;
        let low = low_pass(&sine(100.0, sr, 0.5), sr, 1000.0);
        let high = low_pass(&sine(10_000.0, sr, 0.5), sr, 1000.0);
        // skip the filter's start-up transient
        assert!(rms(&low[4800..]) > 0.65);
        assert!(rms(&high[4800..]) < 0.02);
    }

    #[test]
    fn high_pass_keeps_highs_and_cuts_lows() {
        let sr = 48_000;
        let low = high_pass(&sine(50.0, sr, 0.5), sr, 2000.0);
        let high = high_pass(&sine(10_000.0, sr, 0.5), sr, 2000.0);
        assert!(rms(&low[4800..]) < 0.01);
        assert!(rms(&high[4800..]) > 0.65);
    }

    #[test]
    fn gate_mutes_quiet_and_passes_loud() {
        let sr = 16_000;
        let quiet: Vec<f32> = sine(200.0, sr, 0.5).iter().map(|s| s * 0.001).collect();
        let loud = sine(200.0, sr, 0.5);
        assert!(rms(&noise_gate(&quiet, sr, -40.0)) < 1e-4);
        let out = noise_gate(&loud, sr, -40.0);
        assert!(rms(&out[1600..]) > 0.65);
    }
}
