//! "Easy" effects: gain, normalize, silence trim, mono mixdown.
//!
//! Everything here works on mono `f32` PCM in -1.0..=1.0 and returns a new
//! buffer; nothing mutates the caller's samples.

/// Convert decibels to a linear amplitude factor.
pub fn db_to_amp(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

/// Multiply every sample by `db` decibels of gain, hard-clipping at ±1.
pub fn gain(samples: &[f32], db: f32) -> Vec<f32> {
    let g = db_to_amp(db);
    samples.iter().map(|s| (s * g).clamp(-1.0, 1.0)).collect()
}

/// Peak-normalize so the loudest sample sits at `target_db` dBFS (e.g. -1.0).
/// Silence is returned unchanged rather than divided by zero.
pub fn normalize(samples: &[f32], target_db: f32) -> Vec<f32> {
    let peak = samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
    if peak < 1e-6 {
        return samples.to_vec();
    }
    let g = db_to_amp(target_db) / peak;
    samples.iter().map(|s| s * g).collect()
}

/// Cut leading/trailing silence. A 10 ms window counts as "sound" when its RMS
/// is above `threshold_db` dBFS; `pad_ms` of audio is kept on each side so
/// words don't start abruptly.
pub fn trim_silence(samples: &[f32], sample_rate: u32, threshold_db: f32, pad_ms: f32) -> Vec<f32> {
    let win = ((sample_rate as f32) * 0.010).max(1.0) as usize;
    let thresh = db_to_amp(threshold_db);
    let loud = |start: usize| -> bool {
        let end = (start + win).min(samples.len());
        let chunk = &samples[start..end];
        if chunk.is_empty() {
            return false;
        }
        let rms = (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt();
        rms > thresh
    };

    let windows: Vec<usize> = (0..samples.len()).step_by(win).collect();
    let first = windows.iter().copied().find(|&w| loud(w));
    let last = windows.iter().rev().copied().find(|&w| loud(w));

    match (first, last) {
        (Some(f), Some(l)) => {
            let pad = ((sample_rate as f32) * pad_ms / 1000.0) as usize;
            let start = f.saturating_sub(pad);
            let end = (l + win + pad).min(samples.len());
            samples[start..end].to_vec()
        }
        // All silence: return an empty clip rather than the noise floor.
        _ => Vec::new(),
    }
}

/// Average two channels into one. Uneven lengths are zero-padded.
pub fn mix_to_mono(left: &[f32], right: &[f32]) -> Vec<f32> {
    let n = left.len().max(right.len());
    (0..n)
        .map(|i| {
            let l = left.get(i).copied().unwrap_or(0.0);
            let r = right.get(i).copied().unwrap_or(0.0);
            (l + r) * 0.5
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gain_zero_db_is_identity() {
        let x = [0.1, -0.5, 0.25];
        assert_eq!(gain(&x, 0.0), x.to_vec());
    }

    #[test]
    fn gain_six_db_roughly_doubles_and_clips() {
        let y = gain(&[0.25, 0.9], 6.0206);
        assert!((y[0] - 0.5).abs() < 1e-3);
        assert_eq!(y[1], 1.0);
    }

    #[test]
    fn normalize_hits_target_peak() {
        let y = normalize(&[0.1, -0.2, 0.05], 0.0);
        let peak = y.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!((peak - 1.0).abs() < 1e-6);
        // shape is preserved
        assert!((y[0] / y[1] - (0.1 / -0.2)).abs() < 1e-6);
    }

    #[test]
    fn normalize_leaves_silence_alone() {
        assert_eq!(normalize(&[0.0; 8], -1.0), vec![0.0; 8]);
    }

    #[test]
    fn trim_removes_leading_and_trailing_silence() {
        let sr = 1000;
        let mut x = vec![0.0; 500];
        x.extend(vec![0.5; 200]);
        x.extend(vec![0.0; 300]);
        let y = trim_silence(&x, sr, -40.0, 0.0);
        assert_eq!(y.len(), 200);
        assert!(y.iter().all(|s| *s == 0.5));
    }

    #[test]
    fn trim_keeps_padding() {
        let sr = 1000;
        let mut x = vec![0.0; 500];
        x.extend(vec![0.5; 200]);
        x.extend(vec![0.0; 300]);
        let y = trim_silence(&x, sr, -40.0, 50.0);
        assert_eq!(y.len(), 300);
    }

    #[test]
    fn trim_of_pure_silence_is_empty() {
        assert!(trim_silence(&[0.0; 1000], 1000, -40.0, 10.0).is_empty());
    }

    #[test]
    fn mono_averages_channels() {
        assert_eq!(mix_to_mono(&[1.0, 0.0], &[0.0, 1.0, 0.5]), vec![0.5, 0.5, 0.25]);
    }
}
