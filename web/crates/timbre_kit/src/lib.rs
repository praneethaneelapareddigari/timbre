//! timbre_kit — the client-side Rust that compiles to WebAssembly.
//!
//! The browser decodes audio to mono `f32` PCM, hands it to these functions and
//! gets a new buffer back (wasm-bindgen maps `&[f32]` / `Vec<f32>` to
//! `Float32Array`). All DSP is plain Rust in the submodules, so `cargo test`
//! exercises it natively without a browser.
//!
//! | tier     | effect                                   | fn                      |
//! |----------|------------------------------------------|-------------------------|
//! | easy     | gain, normalize, silence trim, mono      | `gain`, `normalize`, `trim_silence`, `mix_to_mono` |
//! | medium   | echo, reverb, low/high-pass, noise gate, pitch shift | `echo`, `reverb`, `low_pass`, `high_pass`, `noise_gate`, `pitch_shift` |
//! | advanced | anonymizer (pitch + formant), noise reduction, formant shift | `anonymize`, `noise_reduce`, `formant_shift` |
//!
//! Part 3 also uses `StreamResampler` to turn live mic frames into 16-bit PCM.

use wasm_bindgen::prelude::*;

pub mod basic;
pub mod filters;
pub mod pitch;
pub mod space;
pub mod spectral;
pub mod stream;

/// Root-mean-square level of a block of `f32` PCM samples (each in -1.0..=1.0).
///
/// Takes a `Float32Array` straight from the Web Audio API and returns a single
/// scalar the UI can render as a meter.
#[wasm_bindgen]
pub fn rms_level(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

// --- easy -------------------------------------------------------------------

#[wasm_bindgen]
pub fn gain(samples: &[f32], db: f32) -> Vec<f32> {
    basic::gain(samples, db)
}

#[wasm_bindgen]
pub fn normalize(samples: &[f32], target_db: f32) -> Vec<f32> {
    basic::normalize(samples, target_db)
}

#[wasm_bindgen]
pub fn trim_silence(samples: &[f32], sample_rate: u32, threshold_db: f32, pad_ms: f32) -> Vec<f32> {
    basic::trim_silence(samples, sample_rate, threshold_db, pad_ms)
}

#[wasm_bindgen]
pub fn mix_to_mono(left: &[f32], right: &[f32]) -> Vec<f32> {
    basic::mix_to_mono(left, right)
}

// --- medium -----------------------------------------------------------------

#[wasm_bindgen]
pub fn echo(samples: &[f32], sample_rate: u32, delay_ms: f32, feedback: f32, mix: f32) -> Vec<f32> {
    space::echo(samples, sample_rate, delay_ms, feedback, mix)
}

#[wasm_bindgen]
pub fn reverb(samples: &[f32], sample_rate: u32, room: f32, mix: f32) -> Vec<f32> {
    space::reverb(samples, sample_rate, room, mix)
}

#[wasm_bindgen]
pub fn low_pass(samples: &[f32], sample_rate: u32, cutoff_hz: f32) -> Vec<f32> {
    filters::low_pass(samples, sample_rate, cutoff_hz)
}

#[wasm_bindgen]
pub fn high_pass(samples: &[f32], sample_rate: u32, cutoff_hz: f32) -> Vec<f32> {
    filters::high_pass(samples, sample_rate, cutoff_hz)
}

#[wasm_bindgen]
pub fn noise_gate(samples: &[f32], sample_rate: u32, threshold_db: f32) -> Vec<f32> {
    filters::noise_gate(samples, sample_rate, threshold_db)
}

#[wasm_bindgen]
pub fn pitch_shift(samples: &[f32], sample_rate: u32, semitones: f32) -> Vec<f32> {
    pitch::pitch_shift(samples, sample_rate, semitones)
}

// --- advanced ---------------------------------------------------------------

#[wasm_bindgen]
pub fn formant_shift(samples: &[f32], sample_rate: u32, ratio: f32) -> Vec<f32> {
    spectral::formant_shift(samples, sample_rate, ratio)
}

#[wasm_bindgen]
pub fn anonymize(samples: &[f32], sample_rate: u32, semitones: f32, formant_ratio: f32) -> Vec<f32> {
    pitch::anonymize(samples, sample_rate, semitones, formant_ratio)
}

#[wasm_bindgen]
pub fn noise_reduce(samples: &[f32], sample_rate: u32, strength: f32) -> Vec<f32> {
    spectral::noise_reduce(samples, sample_rate, strength)
}

// --- streaming (Part 3) -----------------------------------------------------

/// Stateful resampler exported as a JS class: `new StreamResampler(48000, 24000)`
/// then `.push(float32Chunk)` → `Int16Array` ready to send over the socket.
#[wasm_bindgen]
pub struct StreamResampler(stream::Resampler);

#[wasm_bindgen]
impl StreamResampler {
    #[wasm_bindgen(constructor)]
    pub fn new(from_rate: u32, to_rate: u32) -> StreamResampler {
        StreamResampler(stream::Resampler::new(from_rate, to_rate))
    }

    pub fn push(&mut self, input: &[f32]) -> Vec<i16> {
        self.0.push(input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rms_of_silence_is_zero() {
        assert_eq!(rms_level(&[0.0; 128]), 0.0);
    }

    #[test]
    fn rms_of_empty_is_zero() {
        assert_eq!(rms_level(&[]), 0.0);
    }

    #[test]
    fn rms_of_full_scale_is_one() {
        assert!((rms_level(&[1.0, -1.0, 1.0, -1.0]) - 1.0).abs() < 1e-6);
    }
}
