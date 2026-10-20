//! Pitch shifting and the voice anonymizer.
//!
//! Pitch shift = time-stretch (WSOLA, keeps pitch) followed by resampling back
//! to the original length (scales pitch *and* formants). The anonymizer then
//! re-warps the formants independently, so pitch and timbre can be moved
//! separately — the two cues a listener uses to recognise a voice.

use crate::filters::Biquad;
use crate::spectral::formant_shift;

/// Read `x` at fractional `speed`: output sample i = x[i * speed], linearly
/// interpolated. speed > 1 shortens the clip and raises pitch.
pub fn resample_by(x: &[f32], speed: f32) -> Vec<f32> {
    if x.is_empty() || speed <= 0.0 {
        return Vec::new();
    }
    let out_len = ((x.len() as f32) / speed).floor() as usize;
    (0..out_len)
        .map(|i| {
            let pos = i as f32 * speed;
            let idx = pos as usize;
            let frac = pos - idx as f32;
            let a = x[idx.min(x.len() - 1)];
            let b = x[(idx + 1).min(x.len() - 1)];
            a + (b - a) * frac
        })
        .collect()
}

/// Waveform-similarity overlap-add time stretch. Output is ~`ratio` × input
/// length with pitch unchanged.
///
/// Frames of ~40 ms are taken from the input at an analysis hop of Hs/ratio and
/// laid down at a fixed synthesis hop Hs. Each frame's exact read position is
/// nudged (±10 ms) to the offset whose waveform best lines up with the natural
/// continuation of the previous frame, which avoids the phasey "warble" of
/// plain OLA.
pub fn time_stretch(x: &[f32], sample_rate: u32, ratio: f32) -> Vec<f32> {
    let ratio = ratio.clamp(0.25, 4.0);
    let n = ((sample_rate as f32 * 0.04) as usize).max(64) & !1;
    if x.len() < n * 2 || (ratio - 1.0).abs() < 1e-4 {
        return resample_by(x, 1.0 / ratio);
    }
    let hs = n / 2;
    let ha = hs as f32 / ratio;
    let tol = (sample_rate as f32 * 0.01) as isize;
    let win: Vec<f32> =
        (0..n).map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos()).collect();

    let target_len = (x.len() as f32 * ratio).round() as usize;
    let mut out = vec![0.0f32; target_len + n];
    let max_pos = (x.len() - n) as isize;

    // Similarity of x[a..a+hs] and x[b..b+hs], sampled every `step` for speed.
    let corr = |a: usize, b: usize, step: usize| -> f32 {
        let mut s = 0.0;
        let mut i = 0;
        while i < hs {
            s += x[a + i] * x[b + i];
            i += step;
        }
        s
    };

    let mut prev_pos: usize = 0;
    let mut k = 0usize;
    loop {
        let out_at = k * hs;
        if out_at >= target_len {
            break;
        }
        let nominal = (k as f32 * ha) as isize;
        let pos = if k == 0 {
            0
        } else {
            let natural = (prev_pos + hs) as isize;
            if natural > max_pos {
                nominal.clamp(0, max_pos) as usize
            } else {
                let natural = natural as usize;
                let lo = (nominal - tol).clamp(0, max_pos);
                let hi = (nominal + tol).clamp(0, max_pos);
                // coarse search, then refine around the winner
                let mut best = lo;
                let mut best_c = f32::MIN;
                let mut p = lo;
                while p <= hi {
                    let c = corr(p as usize, natural, 4);
                    if c > best_c {
                        best_c = c;
                        best = p;
                    }
                    p += 4;
                }
                let mut fine_best = best;
                let mut fine_c = f32::MIN;
                for p in (best - 3).max(lo)..=(best + 3).min(hi) {
                    let c = corr(p as usize, natural, 1);
                    if c > fine_c {
                        fine_c = c;
                        fine_best = p;
                    }
                }
                fine_best as usize
            }
        };
        for i in 0..n {
            out[out_at + i] += x[pos + i] * win[i];
        }
        prev_pos = pos;
        k += 1;
    }
    out.truncate(target_len);
    out
}

/// Shift pitch by `semitones` (±12) keeping duration. Formants move with the
/// pitch (the classic "chipmunk" / "giant" effect).
pub fn pitch_shift(x: &[f32], sample_rate: u32, semitones: f32) -> Vec<f32> {
    let semitones = semitones.clamp(-12.0, 12.0);
    if x.is_empty() || semitones.abs() < 1e-3 {
        return x.to_vec();
    }
    let factor = 2f32.powf(semitones / 12.0);
    let mut stretched = time_stretch(x, sample_rate, factor);
    if factor > 1.0 {
        // Reading faster folds content above Nyquist/factor back down; filter it first.
        let cutoff = sample_rate as f32 / 2.0 / factor * 0.9;
        stretched = Biquad::low_pass(sample_rate, cutoff, std::f32::consts::FRAC_1_SQRT_2).run(&stretched);
    }
    let mut y = resample_by(&stretched, factor);
    y.resize(x.len(), 0.0);
    y
}

/// Voice anonymizer: move pitch by `semitones` and formants by `formant_ratio`
/// independently.
///
/// `pitch_shift` scales formants by the same factor as pitch, so we follow it
/// with a formant warp of `formant_ratio / pitch_factor` to land the formants
/// where we actually want them.
pub fn anonymize(x: &[f32], sample_rate: u32, semitones: f32, formant_ratio: f32) -> Vec<f32> {
    let pitch_factor = 2f32.powf(semitones.clamp(-12.0, 12.0) / 12.0);
    let shifted = pitch_shift(x, sample_rate, semitones);
    formant_shift(&shifted, sample_rate, formant_ratio / pitch_factor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    fn sine(freq: f32, sr: u32, n: usize) -> Vec<f32> {
        (0..n).map(|i| (2.0 * PI * freq * i as f32 / sr as f32).sin()).collect()
    }

    /// Estimate frequency from zero crossings in the steady middle section.
    fn freq_of(x: &[f32], sr: u32) -> f32 {
        let mid = &x[x.len() / 4..x.len() * 3 / 4];
        let crossings = mid.windows(2).filter(|w| w[0] <= 0.0 && w[1] > 0.0).count();
        crossings as f32 / (mid.len() as f32 / sr as f32)
    }

    #[test]
    fn resample_halves_length_at_double_speed() {
        let x: Vec<f32> = (0..100).map(|i| i as f32).collect();
        let y = resample_by(&x, 2.0);
        assert_eq!(y.len(), 50);
        assert_eq!(y[10], 20.0);
    }

    #[test]
    fn time_stretch_changes_length_not_pitch() {
        let sr = 16_000;
        let x = sine(300.0, sr, sr as usize);
        let y = time_stretch(&x, sr, 1.5);
        assert_eq!(y.len(), 24_000);
        let f = freq_of(&y, sr);
        assert!((f - 300.0).abs() < 15.0, "got {f} Hz");
    }

    #[test]
    fn pitch_shift_up_an_octave_doubles_frequency() {
        let sr = 16_000;
        let x = sine(200.0, sr, sr as usize);
        let y = pitch_shift(&x, sr, 12.0);
        assert_eq!(y.len(), x.len());
        let f = freq_of(&y, sr);
        assert!((f - 400.0).abs() < 20.0, "got {f} Hz");
    }

    #[test]
    fn pitch_shift_down_lowers_frequency() {
        let sr = 16_000;
        let x = sine(400.0, sr, sr as usize);
        let y = pitch_shift(&x, sr, -5.0);
        let expected = 400.0 * 2f32.powf(-5.0 / 12.0);
        let f = freq_of(&y, sr);
        assert!((f - expected).abs() < 15.0, "got {f} Hz, want {expected}");
    }

    #[test]
    fn anonymize_keeps_length_and_is_finite() {
        let sr = 16_000;
        let x = sine(180.0, sr, sr as usize);
        let y = anonymize(&x, sr, -3.0, 1.15);
        assert_eq!(y.len(), x.len());
        assert!(y.iter().all(|s| s.is_finite()));
        let f = freq_of(&y, sr);
        let expected = 180.0 * 2f32.powf(-3.0 / 12.0);
        assert!((f - expected).abs() < 12.0, "got {f} Hz, want {expected}");
    }
}
