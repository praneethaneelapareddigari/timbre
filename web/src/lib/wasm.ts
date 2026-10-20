// Load the Rust/WASM module exactly once; every caller awaits the same promise.
import init from 'timbre_kit'

export const wasmReady: Promise<void> = init().then(() => undefined)
