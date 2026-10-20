//! Frequency-domain processing: a small FFT, an STFT overlap-add frame loop,
//! formant shifting (spectral-envelope warping) and spectral-subtraction noise
//! reduction.
//!
//! No external crates — a radix-2 FFT is ~40 lines and keeps the WASM small.

use std::f32::consts::PI;

/// In-place iterative radix-2 FFT. `re.len()` must be a power of two.
/// `inverse` computes the unscaled inverse (caller divides by N).
pub fn fft(re: &mut [f32], im: &mut [f32], inverse: bool) {
    let n = re.len();
    debug_assert!(n.is_power_of_two() && im.len() == n);

    // bit-reversal permutation
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j |= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }

    let sign = if inverse { 1.0 } else { -1.0 };
    let mut len = 2;
    while len <= n {
        let ang = sign * 2.0 * PI / len as f32;
        let (w_re, w_im) = (ang.cos(), ang.sin());
        for start in (0..n).step_by(len) {
            let (mut cr, mut ci) = (1.0f32, 0.0f32);
            for k in 0..len / 2 {
                let a = start + k;
                let b = a + len / 2;
                let tr = re[b] * cr - im[b] * ci;
                let ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                let ncr = cr * w_re - ci * w_im;
                ci = cr * w_im + ci * w_re;
                cr = ncr;
            }
        }
        len <<= 1;
    }
}

/// FFT size suited to the sample rate: ~40 ms frames, enough resolution to see
/// the spectral envelope separately from pitch harmonics.
fn frame_size(sample_rate: u32) -> usize {
    if sample_rate >= 32_000 {
        2048
    } else {
        1024
    }
}

fn hann(n: usize) -> Vec<f32> {
    (0..n).map(|i| 0.5 - 0.5 * (2.0 * PI * i as f32 / n as f32).cos()).collect()
}

/// Run `f` on the half-spectrum (bins 0..=N/2) of every STFT frame and
/// resynthesize with weighted overlap-add (Hann analysis + synthesis, 75 %
/// overlap). `f` receives (magnitudes, phases) and edits magnitudes in place.
fn stft_process<F>(samples: &[f32], n: usize, mut f: F) -> Vec<f32>
where
    F: FnMut(&mut [f32], &[f32]),
{
    let hop = n / 4;
    let win = hann(n);
    // Sum of squared Hann windows at 75 % overlap is 1.5.
    let norm = 1.0 / 1.5;
    let len = samples.len();
    let mut out = vec![0.0f32; len + n];
    let mut re = vec![0.0f32; n];
    let mut im = vec![0.0f32; n];
    let mut mag = vec![0.0f32; n / 2 + 1];
    let mut phase = vec![0.0f32; n / 2 + 1];

    // Start one frame early (negative offset) so the first samples get full overlap.
    let mut pos: isize = -(n as isize) + hop as isize;
    while pos < len as isize {
        for i in 0..n {
            let idx = pos + i as isize;
            let s = if idx >= 0 && (idx as usize) < len { samples[idx as usize] } else { 0.0 };
            re[i] = s * win[i];
            im[i] = 0.0;
        }
        fft(&mut re, &mut im, false);
        for k in 0..=n / 2 {
            mag[k] = (re[k] * re[k] + im[k] * im[k]).sqrt();
            phase[k] = im[k].atan2(re[k]);
        }

        f(&mut mag, &phase);

        for k in 0..=n / 2 {
            re[k] = mag[k] * phase[k].cos();
            im[k] = mag[k] * phase[k].sin();
        }
        // Hermitian symmetry so the inverse is real.
        for k in 1..n / 2 {
            re[n - k] = re[k];
            im[n - k] = -im[k];
        }
        fft(&mut re, &mut im, true);
        for i in 0..n {
            let idx = pos + i as isize;
            if idx >= 0 && (idx as usize) < out.len() {
                out[idx as usize] += re[i] / n as f32 * win[i] * norm;
            }
        }
        pos += hop as isize;
    }
    out.truncate(len);
    out
}

/// Smooth spectral envelope of one frame via cepstral liftering: take the log
/// magnitude, keep only the low-quefrency cepstrum (the vocal-tract "shape"),
/// and transform back. Pitch harmonics live at higher quefrencies and drop out.
fn cepstral_envelope(mag: &[f32], n: usize, lifter: usize) -> Vec<f32> {
    let mut re = vec![0.0f32; n];
    let mut im = vec![0.0f32; n];
    for k in 0..=n / 2 {
        re[k] = (mag[k] + 1e-9).ln();
    }
    for k in 1..n / 2 {
        re[n - k] = re[k];
    }
    fft(&mut re, &mut im, true);
    for (i, (r, m)) in re.iter_mut().zip(im.iter_mut()).enumerate() {
        let keep = i <= lifter || i >= n - lifter;
        if keep {
            *r /= n as f32;
            *m /= n as f32;
        } else {
            *r = 0.0;
            *m = 0.0;
        }
    }
    fft(&mut re, &mut im, false);
    (0..=n / 2).map(|k| re[k].exp()).collect()
}

/// Shift formants (the resonances that make a voice recognisable) by `ratio`
/// without changing pitch: >1 sounds smaller/younger, <1 larger/deeper.
///
/// Each frame's magnitude is split into envelope × fine structure; the envelope
/// is resampled along the frequency axis and recombined with the untouched
/// harmonics and phase.
pub fn formant_shift(samples: &[f32], sample_rate: u32, ratio: f32) -> Vec<f32> {
    if samples.is_empty() || (ratio - 1.0).abs() < 1e-3 {
        return samples.to_vec();
    }
    let n = frame_size(sample_rate);
    // ~1.5 ms of quefrency: below typical voice pitch periods (2.5–12 ms).
    let lifter = ((sample_rate as f32 * 0.0015) as usize).clamp(8, n / 8);
    let ratio = ratio.clamp(0.5, 2.0);
    let half = n / 2;

    stft_process(samples, n, |mag, _phase| {
        let env = cepstral_envelope(mag, n, lifter);
        for k in 0..=half {
            // new_env(k) = env(k / ratio), linearly interpolated
            let src = k as f32 / ratio;
            let warped = if src >= half as f32 {
                env[half]
            } else {
                let i = src as usize;
                let frac = src - i as f32;
                env[i] * (1.0 - frac) + env[i + 1] * frac
            };
            mag[k] = mag[k] / env[k] * warped;
        }
    })
}

/// Spectral-subtraction noise reduction.
///
/// Learns a noise profile from the quietest 10 % of frames (the pauses between
/// words), then attenuates each bin by how much of its energy that profile
/// explains. `strength` scales the subtraction (1.0–2.0 is typical); a gain
/// floor and per-bin smoothing keep "musical noise" artefacts down.
pub fn noise_reduce(samples: &[f32], sample_rate: u32, strength: f32) -> Vec<f32> {
    if samples.is_empty() {
        return Vec::new();
    }
    let n = frame_size(sample_rate);
    let bins = n / 2 + 1;

    // Pass 1: collect frame magnitudes to estimate the noise floor.
    let mut frames: Vec<(f32, Vec<f32>)> = Vec::new();
    stft_process(samples, n, |mag, _| {
        let energy: f32 = mag.iter().map(|m| m * m).sum();
        frames.push((energy, mag.to_vec()));
    });
    frames.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let take = (frames.len() / 10).max(1);
    let mut noise = vec![0.0f32; bins];
    for (_, m) in frames.iter().take(take) {
        for k in 0..bins {
            noise[k] += m[k] / take as f32;
        }
    }

    // Pass 2: subtract.
    let floor = 0.08;
    let alpha = strength.clamp(0.0, 4.0);
    let mut prev_gain = vec![1.0f32; bins];
    stft_process(samples, n, |mag, _| {
        for k in 0..bins {
            let g = if mag[k] > 1e-12 { (1.0 - alpha * noise[k] / mag[k]).max(floor) } else { floor };
            let g = 0.6 * g + 0.4 * prev_gain[k];
            prev_gain[k] = g;
            mag[k] *= g;
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, sr: u32, n: usize) -> Vec<f32> {
        (0..n).map(|i| (2.0 * PI * freq * i as f32 / sr as f32).sin()).collect()
    }

    fn rms(x: &[f32]) -> f32 {
        (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt()
    }

    #[test]
    fn fft_round_trip() {
        let orig: Vec<f32> = (0..64).map(|i| ((i * 7) % 13) as f32 - 6.0).collect();
        let mut re = orig.clone();
        let mut im = vec![0.0; 64];
        fft(&mut re, &mut im, false);
        fft(&mut re, &mut im, true);
        for (a, b) in re.iter().zip(orig.iter()) {
            assert!((a / 64.0 - b).abs() < 1e-3);
        }
    }

    #[test]
    fn fft_finds_a_pure_tone() {
        let n = 256;
        let mut re: Vec<f32> = (0..n).map(|i| (2.0 * PI * 8.0 * i as f32 / n as f32).cos()).collect();
        let mut im = vec![0.0; n];
        fft(&mut re, &mut im, false);
        let mags: Vec<f32> = (0..n / 2).map(|k| (re[k] * re[k] + im[k] * im[k]).sqrt()).collect();
        let peak = mags.iter().enumerate().max_by(|a, b| a.1.partial_cmp(b.1).unwrap()).unwrap().0;
        assert_eq!(peak, 8);
    }

    #[test]
    fn stft_identity_reconstructs_the_signal() {
        let sr = 16_000;
        let x = sine(440.0, sr, 8000);
        let y = stft_process(&x, 1024, |_, _| {});
        assert_eq!(y.len(), x.len());
        for i in 0..x.len() {
            assert!((x[i] - y[i]).abs() < 1e-3, "sample {i}: {} vs {}", x[i], y[i]);
        }
    }

    #[test]
    fn formant_shift_keeps_length_and_level() {
        let sr = 16_000;
        let x = sine(220.0, sr, 16_000);
        let y = formant_shift(&x, sr, 1.2);
        assert_eq!(y.len(), x.len());
        assert!(y.iter().all(|s| s.is_finite()));
        // A pure tone has a flat-ish envelope, so energy should be in the same ballpark.
        let ratio = rms(&y) / rms(&x);
        assert!(ratio > 0.3 && ratio < 3.0, "level ratio {ratio}");
    }

    #[test]
    fn noise_reduction_suppresses_steady_hiss() {
        let sr = 16_000;
        // deterministic pseudo-random hiss
        let mut seed = 12345u32;
        let mut noise = || {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            ((seed >> 16) as f32 / 32_768.0 - 1.0) * 0.05
        };
        // 1 s of hiss only, then 1 s tone + hiss
        let mut x: Vec<f32> = (0..sr).map(|_| noise()).collect();
        let tone = sine(440.0, sr, sr as usize);
        x.extend(tone.iter().map(|t| t * 0.5 + noise()));

        let y = noise_reduce(&x, sr, 1.5);
        let hiss_before = rms(&x[2000..14_000]);
        let hiss_after = rms(&y[2000..14_000]);
        assert!(hiss_after < hiss_before * 0.4, "{hiss_after} vs {hiss_before}");
        // the tone survives
        assert!(rms(&y[18_000..30_000]) > 0.25);
    }
}
