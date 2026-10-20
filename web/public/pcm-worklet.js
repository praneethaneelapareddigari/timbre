// AudioWorklet that taps the microphone for live sessions (Part 3).
//
// Runs on the audio rendering thread. It doesn't touch the audio; it batches
// the 128-sample render quanta into ~2048-sample blocks and posts copies to the
// main thread, where Rust/WASM resamples them to 16-bit 24 kHz for the socket.
const BLOCK = 2048

class PcmCapture extends AudioWorkletProcessor {
  constructor() {
    super()
    this.buf = new Float32Array(BLOCK)
    this.len = 0
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0]
    if (channel) {
      let i = 0
      while (i < channel.length) {
        const n = Math.min(channel.length - i, BLOCK - this.len)
        this.buf.set(channel.subarray(i, i + n), this.len)
        this.len += n
        i += n
        if (this.len === BLOCK) {
          this.port.postMessage(this.buf.slice(0))
          this.len = 0
        }
      }
    }
    // Keep the processor alive even while the input is momentarily silent.
    return true
  }
}

registerProcessor('pcm-capture', PcmCapture)
