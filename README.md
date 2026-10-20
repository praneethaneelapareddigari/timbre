# timbre — a voice recorder built on Phoenix + React + Rust/WASM

**Live demo:** not deployed yet · **Demo video:** not recorded yet

I built all three parts of the assignment, plus the transcription bonus:

| Part | What it does | Where |
| --- | --- | --- |
| **1 · Record & save** | Records the mic with `MediaRecorder`, uploads it to Phoenix, stores it in SQLite, and lists recordings with playback, rename and delete. | `web/src/components/Recorder.tsx`, `RecordingList.tsx` · `api/lib/timbre/recordings*`, `RecordingController` |
| **2 · Voice processing (WASM)** | 12 effects written in Rust (more than the 3 required), chained in any order, with before/after waveforms and playback. The processed clip is saved as a new recording that links back to its source. | `web/crates/timbre_kit/src/*` · `web/src/components/Studio.tsx`, `lib/effects.ts` |
| **3 · Multiplayer merge** | A session gets a share link. Each participant's mic streams live over Phoenix Channels, and the server mixes all the tracks into one saved recording. | `api/lib/timbre/sessions*`, `audio/mixer.ex`, `SessionChannel` · `web/src/components/Session.tsx`, `public/pcm-worklet.js` |
| **Bonus · Transcribe & summarize** | Uses Whisper for the transcript and an LLM for a title and summary. Only active when `OPENAI_API_KEY` is set. | `api/lib/timbre/ai.ex` |

## Running it

```bash
nix develop --impure   # or: direnv allow  (or install the toolchain by hand, see below)
just setup             # build WASM, npm install, mix deps.get + create/migrate the DB
just dev               # API :4010 + web :5173
just test              # cargo test (30 DSP tests) + mix test
```

Open http://localhost:5173. To try a session, click **Session → Start a new session**, then open the copied link in a second tab or on another device.

Optional: `export OPENAI_API_KEY=sk-...` before `just dev` enables the **Transcribe** button.

## How it works

### Part 1: recordings

- **Storage.** The browser uploads whatever `MediaRecorder` produced (WebM/Opus in Chrome/Firefox, MP4/AAC in Safari) as multipart. Phoenix stores the bytes in a `recordings.data` BLOB, alongside metadata: title, kind, mime, size, duration, effect chain, source recording, and transcript.
- **Lean list queries.** List and show queries select every column *except* `data`, so listing doesn't load audio into memory. The bytes are only read by `GET /api/recordings/:id/audio`.
- **Range requests.** The audio endpoint supports HTTP `Range`. Without it, Safari won't play the file and no browser can seek.

### Part 2: effects in Rust/WASM

Everything is hand-written in Rust with no DSP crates, so the WASM stays small. Each effect is unit-tested natively with `cargo test`.

| Tier | Effects | Technique |
| --- | --- | --- |
| Easy | gain, normalize, silence trim, mono mixdown | peak scaling; 10 ms RMS windows |
| Medium | echo, reverb, low-pass, high-pass, noise gate, pitch shift | feedback delay; Schroeder combs + all-passes; RBJ biquads; envelope follower with hold; **WSOLA** time-stretch + resample |
| Advanced | **voice anonymizer**, **noise reduction**, formant shift | radix-2 FFT + STFT overlap-add; cepstral spectral envelope warping; spectral subtraction with a learned noise floor |

**How the anonymizer works.** It moves pitch and formants independently. A plain pitch shift scales both by the same factor, so the anonymizer follows it with a formant warp of `formant_ratio / pitch_factor`. That leaves the formants exactly where we want them. Pitch and formants are the two main cues for recognizing a voice, which is why we move both.

**Performance.** For 30 s of 48 kHz audio, natively, pitch shift takes ~0.13 s and anonymize or noise reduction ~0.8 s. In WASM it's somewhat slower, and the Studio shows the measured time.

### Part 3: live sessions

```
tab A ─┐  mic → AudioWorklet → Rust StreamResampler (→ 24 kHz s16)
tab B ─┼─ binary frames <<take, offset, pcm>> over Phoenix Channel "session:CODE"
tab C ─┘                    │
               SessionChannel → Sessions.Server (GenServer per code)
                                 buffers each participant's chunks
              stop → wait for every "flushed" (or 2 s) → Mixer → WAV → Recordings
```

- **One GenServer per session.** Each session is a process registered under its share code. It monitors each participant's channel process, so closing a tab removes that participant. It shuts down after sitting empty.
- **Chunks are positioned by sample offset, not arrival order.** A late or lost chunk becomes a few ms of silence instead of throwing the rest of the track out of sync. Chunks are also tagged with the take number, so stragglers can't leak into the next take.
- **Two-phase stop.** Stopping broadcasts "stopping". Each client sends its last partial frame and acks with "flushed", and the server mixes once everyone has acked or 2 s pass. Without this, the last ~100 ms of every voice would be lost.
- **Mixing without clipping.** The mixer sums tracks in a 32-bit accumulator and scales down only if the sum would clip. A single speaker stays at full volume. Averaging the tracks instead would make everyone quieter as more people join.
- **Why Channels and not WebRTC.** The server needs the audio anyway to mix it. Channels keep that path simple, and they showcase Phoenix's strength in fan-in over many sockets. WebRTC would mainly win if participants needed to hear each other with low latency.
- **Seamless resampling across chunks.** The Rust `StreamResampler` keeps its fractional position and the previous sample between chunks. A naive per-chunk resample would click at every chunk boundary.

## Trade-offs and what I'd do next

- **Audio in SQLite.** This keeps the stack to the one store the scaffold provides. In production I'd put the bytes in object storage (S3/R2/Tigris), keep only a key in the row, and serve playback through signed URLs.
- **Sessions live in memory on one node.** That's fine with SQLite on a single Fly machine. Scaling out would need a distributed registry (Horde, or `:global`) with sticky routing, or a shared store for chunks.
- **Alignment assumes similar network latency.** Each participant starts counting samples when the "start" broadcast reaches them, so two people with very different latency end up a few tens of ms apart. Next steps would be per-client clock-offset estimation (ping/pong RTT), per-track loudness normalization before mixing, and streaming the mix incrementally instead of at stop.
- **Heavy effects run on the main thread.** The page freezes for a moment on long clips. Next I'd move the WASM into a Web Worker.
- **Late joiners sit out the current take.** Someone who joins mid-take is included from the next one.

## Deploy (Fly.io)

The single `Dockerfile` builds WASM, the Vite bundle and an Elixir release. Phoenix then serves the API, the WebSocket and the frontend from one origin.

```bash
fly launch --no-deploy --copy-config          # pick a unique app name; update fly.toml
fly volumes create timbre_data --size 1 --region bom
fly secrets set SECRET_KEY_BASE=$(openssl rand -base64 48)
fly secrets set OPENAI_API_KEY=sk-...         # optional, enables Transcribe
fly deploy
```

Migrations run on boot (`Timbre.Release.migrate/0`).

## Toolchain without Nix

Install Elixir 1.18+, Node 22+, Rust via [rustup](https://rustup.rs) with `rustup target add wasm32-unknown-unknown`, [`wasm-pack`](https://rustwasm.github.io/wasm-pack/) and [`just`](https://github.com/casey/just), then run the same `just` commands.

| Command | What |
| --- | --- |
| `just setup` | build WASM + install all deps |
| `just dev` | run API and web together |
| `just test` | Rust (`cargo test`) + Elixir (`mix test`) suites |
| `just check` | web typecheck + API format check |
| `just build` | production build of web + API |

Run `just --list` for everything else (`api`, `web`, `build-wasm`, `db-*`).
