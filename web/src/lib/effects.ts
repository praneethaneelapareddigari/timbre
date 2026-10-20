// The effect catalogue for the Studio (Part 2). Each effect maps UI params onto
// one Rust function exported from timbre_kit; the chain runs them in order.
import * as kit from 'timbre_kit'
import type { EffectStep } from './api'

export type Tier = 'easy' | 'medium' | 'advanced'

export interface Param {
  key: string
  label: string
  min: number
  max: number
  step: number
  default: number
  unit?: string
}

export interface EffectDef {
  id: string
  label: string
  tier: Tier
  blurb: string
  params: Param[]
  run: (x: Float32Array, sr: number, p: Record<string, number>) => Float32Array
}

export const EFFECTS: EffectDef[] = [
  {
    id: 'anonymize',
    label: 'Voice anonymizer',
    tier: 'advanced',
    blurb: 'Moves pitch and formants independently, so the voice stops sounding like you.',
    params: [
      { key: 'semitones', label: 'Pitch', min: -8, max: 8, step: 0.5, default: -3, unit: 'st' },
      { key: 'formant', label: 'Formants', min: 0.7, max: 1.4, step: 0.01, default: 1.15, unit: '×' },
    ],
    run: (x, sr, p) => kit.anonymize(x, sr, p.semitones, p.formant),
  },
  {
    id: 'noise_reduce',
    label: 'Noise reduction',
    tier: 'advanced',
    blurb: 'Learns the background hiss from pauses and subtracts it (spectral subtraction).',
    params: [{ key: 'strength', label: 'Strength', min: 0.5, max: 3, step: 0.1, default: 1.5 }],
    run: (x, sr, p) => kit.noise_reduce(x, sr, p.strength),
  },
  {
    id: 'formant_shift',
    label: 'Formant shift',
    tier: 'advanced',
    blurb: 'Changes the size of the "vocal tract" without changing the note.',
    params: [{ key: 'ratio', label: 'Ratio', min: 0.7, max: 1.4, step: 0.01, default: 1.2, unit: '×' }],
    run: (x, sr, p) => kit.formant_shift(x, sr, p.ratio),
  },
  {
    id: 'pitch_shift',
    label: 'Pitch shift',
    tier: 'medium',
    blurb: 'Time-stretch + resample: higher or lower, same length.',
    params: [{ key: 'semitones', label: 'Semitones', min: -12, max: 12, step: 0.5, default: 5, unit: 'st' }],
    run: (x, sr, p) => kit.pitch_shift(x, sr, p.semitones),
  },
  {
    id: 'echo',
    label: 'Echo',
    tier: 'medium',
    blurb: 'Feedback delay line.',
    params: [
      { key: 'delay_ms', label: 'Delay', min: 50, max: 1000, step: 10, default: 280, unit: 'ms' },
      { key: 'feedback', label: 'Feedback', min: 0, max: 0.9, step: 0.05, default: 0.4 },
      { key: 'mix', label: 'Mix', min: 0, max: 1, step: 0.05, default: 0.5 },
    ],
    run: (x, sr, p) => kit.echo(x, sr, p.delay_ms, p.feedback, p.mix),
  },
  {
    id: 'reverb',
    label: 'Reverb',
    tier: 'medium',
    blurb: 'Schroeder reverb: four damped combs into two all-passes.',
    params: [
      { key: 'room', label: 'Room size', min: 0, max: 1, step: 0.05, default: 0.6 },
      { key: 'mix', label: 'Mix', min: 0, max: 1, step: 0.05, default: 0.35 },
    ],
    run: (x, sr, p) => kit.reverb(x, sr, p.room, p.mix),
  },
  {
    id: 'high_pass',
    label: 'High-pass filter',
    tier: 'medium',
    blurb: 'Removes rumble and handling noise below the cutoff.',
    params: [{ key: 'cutoff', label: 'Cutoff', min: 40, max: 2000, step: 10, default: 100, unit: 'Hz' }],
    run: (x, sr, p) => kit.high_pass(x, sr, p.cutoff),
  },
  {
    id: 'low_pass',
    label: 'Low-pass filter',
    tier: 'medium',
    blurb: 'Muffles everything above the cutoff — try ~800 Hz for "through the wall".',
    params: [{ key: 'cutoff', label: 'Cutoff', min: 200, max: 12000, step: 50, default: 3000, unit: 'Hz' }],
    run: (x, sr, p) => kit.low_pass(x, sr, p.cutoff),
  },
  {
    id: 'noise_gate',
    label: 'Noise gate',
    tier: 'medium',
    blurb: 'Silences anything quieter than the threshold.',
    params: [{ key: 'threshold', label: 'Threshold', min: -70, max: -10, step: 1, default: -45, unit: 'dB' }],
    run: (x, sr, p) => kit.noise_gate(x, sr, p.threshold),
  },
  {
    id: 'trim_silence',
    label: 'Silence trim',
    tier: 'easy',
    blurb: 'Cuts dead air from the start and end.',
    params: [{ key: 'threshold', label: 'Threshold', min: -70, max: -20, step: 1, default: -45, unit: 'dB' }],
    run: (x, sr, p) => kit.trim_silence(x, sr, p.threshold, 80),
  },
  {
    id: 'gain',
    label: 'Gain',
    tier: 'easy',
    blurb: 'Louder or quieter.',
    params: [{ key: 'db', label: 'Gain', min: -24, max: 24, step: 0.5, default: 6, unit: 'dB' }],
    run: (x, _sr, p) => kit.gain(x, p.db),
  },
  {
    id: 'normalize',
    label: 'Normalize',
    tier: 'easy',
    blurb: 'Scales so the loudest peak sits at the target.',
    params: [{ key: 'target', label: 'Peak', min: -12, max: 0, step: 0.5, default: -1, unit: 'dBFS' }],
    run: (x, _sr, p) => kit.normalize(x, p.target),
  },
]

export const EFFECT_BY_ID = Object.fromEntries(EFFECTS.map((e) => [e.id, e]))

export function defaultParams(def: EffectDef): Record<string, number> {
  return Object.fromEntries(def.params.map((p) => [p.key, p.default]))
}

export interface ChainItem {
  uid: number
  id: string
  params: Record<string, number>
}

let nextUid = 1
export function chainItem(id: string, params?: Record<string, number>): ChainItem {
  return { uid: nextUid++, id, params: { ...defaultParams(EFFECT_BY_ID[id]), ...params } }
}

export const PRESETS: { name: string; chain: () => ChainItem[] }[] = [
  {
    name: 'Anonymous source',
    chain: () => [chainItem('high_pass', { cutoff: 90 }), chainItem('anonymize'), chainItem('normalize')],
  },
  {
    name: 'Podcast clean-up',
    chain: () => [
      chainItem('high_pass', { cutoff: 80 }),
      chainItem('noise_reduce'),
      chainItem('trim_silence'),
      chainItem('normalize'),
    ],
  },
  { name: 'Chipmunk', chain: () => [chainItem('pitch_shift', { semitones: 7 }), chainItem('normalize')] },
  { name: 'Cathedral', chain: () => [chainItem('reverb', { room: 0.95, mix: 0.5 }), chainItem('normalize')] },
  {
    name: 'Old radio',
    chain: () => [
      chainItem('high_pass', { cutoff: 500 }),
      chainItem('low_pass', { cutoff: 2800 }),
      chainItem('gain', { db: 6 }),
    ],
  },
]

/** The chain as stored with the processed recording. */
export function describeChain(chain: ChainItem[]): EffectStep[] {
  return chain.map((c) => ({ id: c.id, ...c.params }))
}
