#!/usr/bin/env python3
"""
CIStream Vocoder Test
---------------------
Simulates cochlear implant hearing to validate audio preprocessing quality.

What it does:
  1. Generates synthetic speech-like audio + cafeteria noise at 0 dB SNR
  2. Applies a Wiener filter to simulate CIStream DSP preprocessing
  3. Runs all three signals through a 16-channel CI vocoder
  4. Saves 6 WAV files you can listen to
  5. Reports objective metrics (SNR gain, envelope correlation, STOI)

Usage:
  python3 vocoder_test.py                        # use generated test audio
  python3 vocoder_test.py speech.wav noise.wav   # use real audio files
"""

import numpy as np
from scipy import signal
from scipy.io import wavfile
import sys, os

SR = 44100

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — AUDIO GENERATION
# Produces speech-like and noise-like signals without needing real recordings.
# The temporal envelope structure (slow amplitude modulations) is what matters
# for CI users — so even synthetic signals reveal the DSP effect.
# ─────────────────────────────────────────────────────────────────────────────

def generate_speech(duration=3.3, sr=SR, onset_ms=300) -> np.ndarray:
    """
    Voiced speech analogue: 300 ms silence then harmonic tone modulated at
    syllable rate (~4 Hz). The silent onset lets the Wiener filter estimate
    the noise floor before speech begins — matching real-world conditions
    (you enter a noisy room, then someone starts talking).
    """
    onset_samples = int(onset_ms * sr / 1000)
    speech_duration = duration - onset_ms / 1000
    n_speech = int(speech_duration * sr)
    t = np.linspace(0, speech_duration, n_speech, endpoint=False)

    # Harmonic stack (simulates vowel formants)
    voice = (np.sin(2 * np.pi * 150 * t) +
             0.6 * np.sin(2 * np.pi * 300 * t) +
             0.4 * np.sin(2 * np.pi * 500 * t) +
             0.3 * np.sin(2 * np.pi * 800 * t) +
             0.2 * np.sin(2 * np.pi * 1200 * t) +
             0.1 * np.sin(2 * np.pi * 2000 * t))

    # Syllable-rate amplitude modulation (4 Hz on-beats, silence between)
    syllable = np.clip(np.sin(2 * np.pi * 4 * t), 0, None) ** 0.5
    for start in np.arange(0.4, speech_duration, 0.7):
        mask = (t >= start) & (t < start + 0.12)
        syllable[mask] *= 0.05

    speech_part = _norm(voice * syllable, 0.70)
    # Prepend silence — noise only during onset, speech after
    return np.concatenate([
        np.zeros(onset_samples, dtype=np.float32), speech_part
    ])


def generate_cafeteria_noise(duration=3.3, sr=SR) -> np.ndarray:
    """
    Restaurant/cafeteria noise: pink noise + a competing talker.
    Pink noise is perceptually realistic background chatter.
    """
    n = int(duration * sr)
    t = np.linspace(0, duration, n, endpoint=False)

    # Pink noise via bilinear-transform approximation
    rng = np.random.default_rng(0)
    white = rng.standard_normal(n)
    b = [0.049922035, -0.095993537, 0.050612699, -0.004408786]
    a = [1, -2.494956002, 2.017265875, -0.522189400]
    pink = signal.lfilter(b, a, white)

    # Interfering talker (different modulation frequency — 3 Hz)
    interferer = (np.sin(2 * np.pi * 220 * t) *
                  np.clip(np.sin(2 * np.pi * 3 * t + 1.2), 0, None) ** 0.5)

    noise = 0.7 * pink + 0.3 * interferer
    return _norm(noise, 0.75).astype(np.float32)


def mix_at_snr(speech: np.ndarray, noise: np.ndarray, snr_db: float) -> np.ndarray:
    """Scale noise so speech+noise has the requested SNR, then sum."""
    speech_rms = _rms(speech)
    noise_rms  = _rms(noise)
    target_noise_rms = speech_rms / 10 ** (snr_db / 20)
    scaled_noise = noise * (target_noise_rms / (noise_rms + 1e-12))
    mixed = speech + scaled_noise
    return _norm(mixed, 0.90).astype(np.float32)


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — DSP SIMULATION
# Approximates what CIStream's DSPProcessor will do in Phase 2.
# Real app will use this same logic on the audio thread, per buffer.
# ─────────────────────────────────────────────────────────────────────────────

def wiener_filter(noisy: np.ndarray, sr=SR,
                  noise_est_ms=200, frame_ms=20, strength=0.80) -> np.ndarray:
    """
    Spectral Wiener filter — the core of Stage 1 (SNR Engine).

    How it works:
      1. Estimate noise power from the first `noise_est_ms` ms (assumes
         noise is stationary at onset — true in most room environments).
      2. Compute a per-frequency gain: G(f) = max(1 - strength * N(f)/S(f), 0)
         where S(f) is the signal power and N(f) is the noise estimate.
         Frequencies dominated by noise get suppressed; speech frequencies pass.
      3. Apply gain in the STFT domain and reconstruct.

    `strength` maps directly to the user's "suppression" slider in the app:
      0.0 = passthrough (Phase 1)
      0.8 = moderate suppression (good default)
      1.0 = aggressive suppression (risks speech distortion)
    """
    frame_len = int(sr * frame_ms / 1000)
    hop = frame_len // 2

    # Step 1: noise estimate
    noise_frames = noisy[:int(sr * noise_est_ms / 1000)]
    _, _, N_stft = signal.stft(noise_frames, sr, nperseg=frame_len, noverlap=hop)
    noise_power = np.mean(np.abs(N_stft) ** 2, axis=1, keepdims=True)

    # Step 2: STFT of full signal + Wiener gain
    f, t_ax, X = signal.stft(noisy, sr, nperseg=frame_len, noverlap=hop)
    signal_power = np.abs(X) ** 2
    # Floor at 0.05 to avoid complete silence (musical noise artefact)
    gain = np.maximum(1.0 - strength * (noise_power / (signal_power + 1e-12)), 0.05)
    X_out = X * gain

    # Step 3: reconstruct
    _, out = signal.istft(X_out, sr, nperseg=frame_len, noverlap=hop)
    out = out[:len(noisy)]
    out = out.astype(np.float32)

    # Match output loudness to input (compression should not change level much)
    scale = _rms(noisy) / (_rms(out) + 1e-12)
    out *= min(scale, 2.0)
    return _norm(out, np.max(np.abs(noisy))).astype(np.float32)


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — CI VOCODER
# Standard research tool: simulates what a cochlear implant user hears.
# Used in virtually all CI signal processing papers for pre-clinical validation.
#
# How it works:
#   A cochlear implant splits incoming sound into N frequency bands and encodes
#   only the slow amplitude envelope of each band — NOT the fine spectral detail.
#   The vocoder replicates this by:
#     1. Band-pass filtering input into N channels (log-spaced, like the cochlea)
#     2. Extracting the amplitude envelope of each band (rectify + low-pass)
#     3. Multiplying the envelope onto a noise carrier in the same frequency band
#     4. Summing all channels
#
# Brand-specific presets (see CI_PROFILES dict below):
#
#   Cochlear Nucleus (ACE strategy)
#     22 physical electrodes, but ACE selects only the 8 highest-energy channels
#     each analysis frame — the rest are silent. This "spectral maxima" approach
#     means effective perceptual channels ≈ 8. We model this by using 8 active
#     channels and suppressing the rest.
#     Frequency range: 188 – 8500 Hz
#
#   MED-EL SONNET (FSP strategy)
#     12 electrodes. Bottom 3 channels (below ~300 Hz) encode temporal fine
#     structure — the rapid oscillation pattern of low-frequency sounds. This is
#     the only CI strategy that partially transmits fine structure. We model this
#     by using sinusoidal carriers (not noise) in the lowest 3 channels, which
#     preserves pitch cues in the bass. The upper 9 channels remain noise-band.
#     Frequency range: 70 – 8500 Hz (wider bass than Cochlear/AB)
#
#   Advanced Bionics Naída CI (HiRes / Fidelity 120)
#     16 physical electrodes. Fidelity 120 uses current steering between adjacent
#     electrodes to create 120 virtual channels — but channel interaction limits
#     practical resolution to ~8–12 perceptual channels. We model this with 16
#     channels (generous estimate, representing a good AB user outcome).
#     Frequency range: 188 – 8000 Hz
#
#   Generic / Research (standard noise-band vocoder)
#     16 channels, 100–8000 Hz. Used in most published CI research. Does not
#     model any specific device — represents an idealized average CI.
# ─────────────────────────────────────────────────────────────────────────────

CI_PROFILES = {
    "cochlear": dict(
        label       = "Cochlear Nucleus (ACE, 8 active channels)",
        n_channels  = 22,          # physical electrodes
        n_active    = 8,           # ACE selects top-N energy channels per frame
        fmin        = 188.0,
        fmax        = 8500.0,
        env_cutoff  = 160.0,
        fine_structure_channels = 0,
    ),
    "medel": dict(
        label       = "MED-EL SONNET (FSP, 12 channels, fine structure in bass)",
        n_channels  = 12,
        n_active    = 12,          # all channels always active in FSP
        fmin        = 70.0,        # wider bass coverage
        fmax        = 8500.0,
        env_cutoff  = 160.0,
        fine_structure_channels = 3,   # bottom 3 use sinusoidal carrier
    ),
    "ab": dict(
        label       = "Advanced Bionics Naída CI (HiRes, 16 channels)",
        n_channels  = 16,
        n_active    = 16,
        fmin        = 188.0,
        fmax        = 8000.0,
        env_cutoff  = 160.0,
        fine_structure_channels = 0,
    ),
    "generic": dict(
        label       = "Generic research vocoder (16 channels, 100–8000 Hz)",
        n_channels  = 16,
        n_active    = 16,
        fmin        = 100.0,
        fmax        = 8000.0,
        env_cutoff  = 160.0,
        fine_structure_channels = 0,
    ),
}


def ci_vocoder(audio: np.ndarray, sr=SR, profile="generic") -> np.ndarray:
    """
    Brand-aware N-channel CI vocoder.

    profile : one of "cochlear", "medel", "ab", "generic"

    Key parameters per profile — see CI_PROFILES dict above for full detail.

    What each parameter does to what you hear:
      n_channels / n_active : more channels = better frequency resolution
                              fewer = harder to separate speech from noise
      fmin                  : lower = more bass (MED-EL covers bass better)
      env_cutoff            : 160 Hz = CI-like sluggish envelope
                              400 Hz = hearing-aid-like faster envelope
      fine_structure_channels: >0 means low-frequency pitch cues survive
                              (MED-EL FSP only) — bass sounds more natural
    """
    p          = CI_PROFILES[profile]
    n_channels = p["n_channels"]
    n_active   = p["n_active"]
    fmin       = p["fmin"]
    fmax       = p["fmax"]
    env_cutoff = p["env_cutoff"]
    n_fs       = p["fine_structure_channels"]   # MED-EL FSP bass channels

    rng = np.random.default_rng(42)
    nyq = sr / 2.0

    # Log-spaced channel edges — matches the cochlear tonotopic frequency map
    edges   = np.logspace(np.log10(fmin), np.log10(fmax), n_channels + 1)
    audio64 = audio.astype(np.float64)
    t       = np.arange(len(audio64)) / sr

    # Per-channel energy (used by Cochlear ACE to select active channels)
    channel_energy = []
    channel_bands  = []
    for i in range(n_channels):
        fl = edges[i]
        fh = min(edges[i + 1], nyq * 0.999)
        sos_bp = signal.butter(4, [fl / nyq, fh / nyq],
                               btype='bandpass', output='sos')
        band = signal.sosfilt(sos_bp, audio64)
        channel_bands.append(band)
        channel_energy.append(float(np.mean(band ** 2)))

    # Cochlear ACE: keep only the n_active highest-energy channels
    if n_active < n_channels:
        threshold_energy = sorted(channel_energy, reverse=True)[n_active - 1]
        active_mask = [e >= threshold_energy for e in channel_energy]
    else:
        active_mask = [True] * n_channels

    output = np.zeros(len(audio64))

    for i in range(n_channels):
        if not active_mask[i]:
            continue                    # ACE: silent channel

        fl = edges[i]
        fh = min(edges[i + 1], nyq * 0.999)
        sos_bp = signal.butter(4, [fl / nyq, fh / nyq],
                               btype='bandpass', output='sos')
        band = channel_bands[i]

        # ── Envelope extraction ───────────────────────────────────────────
        env = np.abs(band)
        sos_lp = signal.butter(2, env_cutoff / nyq, btype='low', output='sos')
        env = np.maximum(signal.sosfilt(sos_lp, env), 0)

        # ── Carrier selection ─────────────────────────────────────────────
        if i < n_fs:
            # MED-EL FSP: sinusoidal carrier at channel centre frequency
            # This preserves temporal fine structure — pitch cues survive
            fc = np.sqrt(fl * fh)       # geometric mean = perceptual centre
            carrier = np.sin(2 * np.pi * fc * t)
        else:
            # Standard noise-band carrier (envelope-only, no pitch)
            carrier = signal.sosfilt(sos_bp, rng.standard_normal(len(audio64)))
            carrier_rms = np.sqrt(np.mean(carrier ** 2)) + 1e-12
            carrier /= carrier_rms

        output += env * carrier

    return _norm(output.astype(np.float32), 0.70)


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — OBJECTIVE METRICS
# ─────────────────────────────────────────────────────────────────────────────

def snr_db(clean: np.ndarray, mixture: np.ndarray) -> float:
    """Input/output SNR estimate (dB). Higher = cleaner signal."""
    n = min(len(clean), len(mixture))
    c, m = clean[:n].astype(np.float64), mixture[:n].astype(np.float64)
    noise = m - c * (np.dot(m, c) / (np.dot(c, c) + 1e-12))
    sig_p = np.mean(c ** 2)
    noi_p = np.mean(noise ** 2) + 1e-12
    return 10 * np.log10(sig_p / noi_p)


def envelope_correlation(clean: np.ndarray, processed: np.ndarray,
                          sr=SR, n_bands=16, fmin=100, fmax=8000) -> float:
    """
    Mean Pearson correlation of temporal envelopes across frequency bands.
    Measures how well the processed signal preserves the speech envelope —
    the primary intelligibility cue for CI users.
    1.0 = perfect envelope preservation, 0.0 = no correlation.
    """
    nyq = sr / 2
    edges = np.logspace(np.log10(fmin), np.log10(fmax), n_bands + 1)
    c64 = clean.astype(np.float64)
    p64 = processed.astype(np.float64)
    rs = []

    for i in range(n_bands):
        fl, fh = edges[i], min(edges[i + 1], nyq * 0.999)
        sos_bp = signal.butter(4, [fl / nyq, fh / nyq],
                               btype='bandpass', output='sos')
        sos_lp = signal.butter(2, 160 / nyq, btype='low', output='sos')

        env_c = signal.sosfilt(sos_lp, np.abs(signal.sosfilt(sos_bp, c64)))
        env_p = signal.sosfilt(sos_lp, np.abs(signal.sosfilt(sos_bp, p64)))

        if np.std(env_c) > 1e-7 and np.std(env_p) > 1e-7:
            rs.append(float(np.corrcoef(env_c, env_p)[0, 1]))

    return float(np.mean(rs)) if rs else 0.0


def try_stoi(clean, test, sr):
    try:
        from pystoi import stoi
        return stoi(clean.astype(np.float64), test.astype(np.float64), sr,
                    extended=False)
    except Exception:
        return None


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — MAIN
# ─────────────────────────────────────────────────────────────────────────────

def _rms(x):      return np.sqrt(np.mean(x.astype(np.float64) ** 2))
def _norm(x, p):  return (x / (np.max(np.abs(x)) + 1e-12) * p).astype(np.float32)

def save(path, audio, sr=SR):
    wavfile.write(path, sr, (np.clip(audio, -1, 1) * 32767).astype(np.int16))
    print(f"  -> {os.path.basename(path)}")


def run(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    bar = "=" * 62

    print(f"\n{bar}\nCIStream Vocoder Test\n{bar}")

    # ── Load or generate audio ────────────────────────────────────────────────
    if len(sys.argv) == 3:
        print("\n[1/5] Loading audio files ...")
        _, speech_raw = wavfile.read(sys.argv[1])
        _, noise_raw  = wavfile.read(sys.argv[2])
        speech = _norm(speech_raw.astype(np.float32), 0.70)
        noise  = _norm(noise_raw.astype(np.float32), 0.75)
        if len(noise) < len(speech):
            noise = np.tile(noise, int(np.ceil(len(speech) / len(noise))))
        noise = noise[:len(speech)]
    else:
        print("\n[1/5] Generating synthetic test audio ...")
        speech = generate_speech(duration=3.3)
        noise  = generate_cafeteria_noise(duration=3.3)

    noisy = mix_at_snr(speech, noise, snr_db=0)   # 0 dB SNR = hard condition

    save(os.path.join(out_dir, "1_clean_speech.wav"),   speech)
    save(os.path.join(out_dir, "2_noisy_0dBSNR.wav"),   noisy)

    # ── CIStream preprocessing simulation ────────────────────────────────────
    print("\n[2/5] Simulating CIStream DSP (Wiener noise suppression) ...")
    processed = wiener_filter(noisy, strength=0.80)
    save(os.path.join(out_dir, "3_cistream_processed.wav"), processed)

    # ── CI vocoder — all four brand profiles ─────────────────────────────────
    print("\n[3/5] Applying CI vocoder (4 brand profiles) ...")
    print("      (this takes ~30 seconds — each brand in its own subfolder)\n")

    for prof in ["cochlear", "medel", "ab", "generic"]:
        info = CI_PROFILES[prof]
        print(f"  [{prof.upper()}] {info['label']}")
        sub = os.path.join(out_dir, prof)
        os.makedirs(sub, exist_ok=True)
        save(os.path.join(sub, "4_vocoded_clean.wav"),     ci_vocoder(speech,    profile=prof))
        save(os.path.join(sub, "5_vocoded_noisy.wav"),     ci_vocoder(noisy,     profile=prof))
        save(os.path.join(sub, "6_vocoded_processed.wav"), ci_vocoder(processed, profile=prof))

    # Use generic for the metrics section
    voc_noisy     = ci_vocoder(noisy)
    voc_processed = ci_vocoder(processed)

    # ── Metrics ───────────────────────────────────────────────────────────────
    print("\n[4/5] Computing metrics ...")

    snr_in   = snr_db(speech, noisy)
    snr_out  = snr_db(speech, processed)
    ec_noisy = envelope_correlation(speech, noisy)
    ec_proc  = envelope_correlation(speech, processed)
    st_noisy = try_stoi(speech, noisy, SR)
    st_proc  = try_stoi(speech, processed, SR)

    # ── Report ────────────────────────────────────────────────────────────────
    print(f"\n{bar}")
    print("RESULTS")
    print(bar)
    print(f"\n  {'Metric':<34} {'Noisy (no app)':>14} {'Processed (app)':>15} {'Gain':>8}")
    print(f"  {'-'*34} {'-'*14} {'-'*15} {'-'*8}")

    def row(label, a, b):
        delta = b - a
        sign  = "+" if delta >= 0 else ""
        print(f"  {label:<34} {a:>14.3f} {b:>15.3f} {sign}{delta:>7.3f}")

    row("SNR (dB)", snr_in, snr_out)
    row("Envelope correlation (0→1)", ec_noisy, ec_proc)
    if st_noisy is not None:
        row("STOI intelligibility (0→1)", st_noisy, st_proc)

    print(f"\n{bar}")
    print("LISTENING TEST")
    print(bar)
    print(f"""
  Four subfolders — each simulates a different CI brand:

    cochlear/   Cochlear Nucleus — ACE strategy, 8 active channels
                Most common brand worldwide. Sounds most "robotic" because
                only the 8 highest-energy frequency bands are active at any
                moment. Low-frequency channels often silent.

    medel/      MED-EL SONNET — FSP strategy, 12 channels
                Lowest 3 channels use a sinusoidal carrier instead of noise.
                This preserves pitch information in the bass — male vs female
                voices sound more distinct. Wider frequency range (down to 70 Hz).

    ab/         Advanced Bionics Naida CI — HiRes, 16 channels
                All 16 channels always active. Most generous simulation.
                Closest to what a good AB user experiences.

    generic/    Standard research vocoder (16 channels, 100-8000 Hz)
                What the published papers use. Not brand-specific.
                Our benchmark condition.

  In each folder, listen in this order:
    4_vocoded_clean.wav       <- best case (no noise)
    5_vocoded_noisy.wav       <- WITHOUT CIStream (noise at 0 dB SNR)
    6_vocoded_processed.wav   <- WITH CIStream

  All files sound robotic. That is correct — the vocoder keeps only
  the slow amplitude envelope of each frequency band. The question is
  whether (6) is more intelligible than (5) in each brand folder.

  Key observation: the MED-EL folder will sound most natural in the
  bass. The Cochlear folder will sound most stripped-down. This
  matches real-world reports from CI users across brands.
""")
    print(f"  Output saved to: {out_dir}")
    print(f"  Saved to: {out_dir}")
    print(f"{bar}\n")


if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
    run(out_dir)
