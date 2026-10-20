//! Time-based effects: echo and a small Schroeder reverb.

/// Feedback echo.
///
/// `delay_ms` between repeats, `feedback` (0..0.95) sets how fast repeats die
/// away, `mix` (0..1) blends wet against dry. The output is extended so the
/// tail isn't cut off at the end of the clip.
pub fn echo(samples: &[f32], sample_rate: u32, delay_ms: f32, feedback: f32, mix: f32) -> Vec<f32> {
    let d = ((sample_rate as f32 * delay_ms / 1000.0) as usize).max(1);
    let fb = feedback.clamp(0.0, 0.95);
    let mix = mix.clamp(0.0, 1.0);
    // Enough repeats to fall ~60 dB, capped at 3 s of tail.
    let repeats = if fb > 0.0 { (0.001f32.ln() / fb.ln()).ceil() as usize } else { 1 };
    let tail = (d * repeats).min(sample_rate as usize * 3);
    let n = samples.len() + tail;

    let mut wet = vec![0.0f32; n];
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let dry = samples.get(i).copied().unwrap_or(0.0);
        // The delay line holds the dry signal plus its own feedback.
        let delayed = if i >= d { wet[i - d] } else { 0.0 };
        wet[i] = dry + fb * delayed;
        out.push((dry + mix * delayed).clamp(-1.0, 1.0));
    }
    out
}

struct Comb {
    buf: Vec<f32>,
    idx: usize,
    feedback: f32,
    damp: f32,
    store: f32,
}

impl Comb {
    fn new(len: usize, feedback: f32, damp: f32) -> Self {
        Comb { buf: vec![0.0; len.max(1)], idx: 0, feedback, damp, store: 0.0 }
    }
    fn tick(&mut self, x: f32) -> f32 {
        let y = self.buf[self.idx];
        // One-pole low-pass in the loop so high frequencies decay faster, like a real room.
        self.store = y * (1.0 - self.damp) + self.store * self.damp;
        self.buf[self.idx] = x + self.store * self.feedback;
        self.idx = (self.idx + 1) % self.buf.len();
        y
    }
}

struct AllPass {
    buf: Vec<f32>,
    idx: usize,
}

impl AllPass {
    fn new(len: usize) -> Self {
        AllPass { buf: vec![0.0; len.max(1)], idx: 0 }
    }
    fn tick(&mut self, x: f32) -> f32 {
        let b = self.buf[self.idx];
        let y = -x + b;
        self.buf[self.idx] = x + b * 0.5;
        self.idx = (self.idx + 1) % self.buf.len();
        y
    }
}

/// Schroeder/Freeverb-style reverb: four parallel damped combs into two
/// series all-passes. `room` (0..1) sets decay length, `mix` the wet level.
pub fn reverb(samples: &[f32], sample_rate: u32, room: f32, mix: f32) -> Vec<f32> {
    let scale = sample_rate as f32 / 1000.0;
    let fb = 0.7 + 0.28 * room.clamp(0.0, 1.0);
    let mix = mix.clamp(0.0, 1.0);
    let mut combs: Vec<Comb> = [29.7, 37.1, 41.1, 43.7]
        .iter()
        .map(|ms| Comb::new((ms * scale) as usize, fb, 0.2))
        .collect();
    let mut aps: Vec<AllPass> = [5.0, 1.7].iter().map(|ms| AllPass::new((ms * scale) as usize)).collect();

    let tail = (sample_rate as f32 * (0.5 + 2.0 * room.clamp(0.0, 1.0))) as usize;
    let n = samples.len() + tail;
    (0..n)
        .map(|i| {
            let dry = samples.get(i).copied().unwrap_or(0.0);
            let mut wet: f32 = combs.iter_mut().map(|c| c.tick(dry)).sum::<f32>() * 0.25;
            for ap in aps.iter_mut() {
                wet = ap.tick(wet);
            }
            (dry * (1.0 - mix * 0.5) + wet * mix).clamp(-1.0, 1.0)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn echo_repeats_an_impulse() {
        let sr = 1000;
        let mut x = vec![0.0; 10];
        x[0] = 1.0;
        let y = echo(&x, sr, 100.0, 0.5, 1.0);
        assert_eq!(y[0], 1.0);
        assert!((y[100] - 1.0).abs() < 1e-6); // first repeat at full mix
        assert!((y[200] - 0.5).abs() < 1e-6); // decays by feedback
        assert!((y[300] - 0.25).abs() < 1e-6);
        assert!(y.len() > x.len());
    }

    #[test]
    fn echo_with_zero_mix_is_dry() {
        let x = vec![0.3; 50];
        let y = echo(&x, 1000, 10.0, 0.5, 0.0);
        assert!(y[..50].iter().all(|s| (*s - 0.3).abs() < 1e-6));
    }

    #[test]
    fn reverb_adds_a_decaying_tail() {
        let sr = 16_000;
        let mut x = vec![0.0; 1600];
        x[0] = 1.0;
        let y = reverb(&x, sr, 0.5, 0.8);
        assert!(y.len() > x.len());
        let energy = |s: &[f32]| s.iter().map(|v| v * v).sum::<f32>();
        // something is ringing after the impulse...
        assert!(energy(&y[1..3200]) > 0.01);
        // ...and it dies down by the end
        assert!(energy(&y[y.len() - 800..]) < energy(&y[1..3200]));
        assert!(y.iter().all(|s| s.is_finite() && s.abs() <= 1.0));
    }
}
