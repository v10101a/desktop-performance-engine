#!/usr/bin/env python3
"""Analyze an audio track for BPM + structural key points, and emit timeline markers.

    python3 tools/analyze_track.py "assets/track.mp3" [markers_out.json]

Requires numpy + scipy (see tools/requirements-analysis.txt) and ffmpeg on PATH.
Decodes to mono 22.05 kHz, estimates tempo from an onset-flux envelope
(autocorrelation), lays down a beat grid + downbeats, and finds section
boundaries from RMS-energy novelty. Prints a report and writes a markers JSON.
"""
import sys, os, json, subprocess, tempfile
import numpy as np
from scipy.signal import stft, find_peaks
from scipy.io import wavfile
from scipy.ndimage import uniform_filter1d

SR = 22050
HOP = 512

def load(path):
    tmp = tempfile.mktemp(suffix=".wav")
    subprocess.run(["ffmpeg", "-y", "-i", path, "-ac", "1", "-ar", str(SR),
                    "-c:a", "pcm_s16le", tmp], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sr, data = wavfile.read(tmp)
    os.remove(tmp)
    y = data.astype(np.float64)
    if y.ndim > 1:
        y = y.mean(axis=1)
    return y / (np.abs(y).max() + 1e-9), sr

def onset_envelope(y, sr):
    f, t, Z = stft(y, fs=sr, nperseg=1024, noverlap=1024 - HOP)
    S = np.abs(Z)
    flux = np.sum(np.maximum(0, S[:, 1:] - S[:, :-1]), axis=0)
    flux = np.concatenate([[0.0], flux])
    flux = uniform_filter1d(flux, size=3)
    return flux / (flux.max() + 1e-9), sr / HOP     # envelope, frames-per-second

def estimate_tempo(onset, fps, lo=70, hi=180, prior_center=120.0, prior_octaves=0.5):
    """Autocorrelation comb-filter with harmonic support + a log-normal tempo prior,
    which resolves the common ×2 / ×1.5 metrical ambiguities (e.g. 86 vs 128)."""
    o = onset - onset.mean()
    ac = np.correlate(o, o, mode="full")[len(o) - 1:]
    ac[0] = 0
    def acv(l):
        i = int(round(l))
        return ac[i] if 0 < i < len(ac) else 0.0
    bpms = np.arange(lo, hi + 0.5, 0.5)
    scores = []
    for bpm in bpms:
        l = 60.0 / bpm * fps
        support = acv(l) + 0.5 * acv(l * 2) + 0.5 * acv(l / 2) + 0.3 * acv(l * 4)
        prior = np.exp(-0.5 * (np.log2(bpm / prior_center) / prior_octaves) ** 2)
        scores.append(support * prior)
    bpm = float(bpms[int(np.argmax(scores))])
    return bpm, 60.0 / bpm * fps

def beat_grid(onset, fps, lag):
    P = float(lag)
    best_ph, best = 0, -1
    for ph in range(int(round(P))):
        idx = np.round(np.arange(ph, len(onset), P)).astype(int)
        idx = idx[idx < len(onset)]
        s = onset[idx].sum()
        if s > best: best, best_ph = s, ph
    frames = np.round(np.arange(best_ph, len(onset), P)).astype(int)
    frames = frames[frames < len(onset)]
    return frames, frames / fps

def sections(y, sr, downbeat_times):
    win, hop2 = int(0.5 * sr), int(0.1 * sr)
    rms = np.array([np.sqrt(np.mean(y[i:i + win] ** 2))
                    for i in range(0, len(y) - win, hop2)])
    rt = np.arange(len(rms)) * hop2 / sr
    rms_s = uniform_filter1d(rms, size=15)
    nov = np.abs(np.diff(rms_s, prepend=rms_s[0]))
    fps2 = sr / hop2
    pk, _ = find_peaks(nov, distance=int(8 * fps2), height=nov.mean() + nov.std())
    bounds = [0.0] + [rt[p] for p in pk]
    # snap each boundary to the nearest downbeat (musical alignment)
    if len(downbeat_times):
        bounds = [float(downbeat_times[np.argmin(np.abs(downbeat_times - b))]) for b in bounds]
    bounds = sorted(set(round(b, 2) for b in bounds))
    # per-segment energy → tier + transition label
    segs = []
    edges = bounds + [rt[-1]]
    for i in range(len(bounds)):
        a, b = edges[i], edges[i + 1]
        m = rms_s[(rt >= a) & (rt < b)]
        segs.append(m.mean() if len(m) else 0.0)
    lo, hi = np.percentile(segs, 25), np.percentile(segs, 75)
    tier = lambda e: "low" if e <= lo else ("high" if e >= hi else "mid")
    marks = []
    for i, b in enumerate(bounds):
        e = segs[i]
        prev = segs[i - 1] if i > 0 else e
        if i == 0:
            label, kind = "start", "start"
        elif e > prev * 1.5:
            label, kind = f"drop ({tier(e)})", "drop"
        elif e < prev * 0.66:
            label, kind = f"break ({tier(e)})", "break"
        else:
            label, kind = f"section ({tier(e)})", "section"
        bar = int(np.argmin(np.abs(downbeat_times - b)) + 1) if len(downbeat_times) else 0
        marks.append({"t": round(b, 2), "bar": bar, "label": label, "kind": kind})
    return marks

def main():
    path = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    y, sr = load(path)
    dur = len(y) / sr
    onset, fps = onset_envelope(y, sr)
    bpm, lag = estimate_tempo(onset, fps)
    frames, beats = beat_grid(onset, fps, lag)
    # downbeats: 4/4, pick the beat-phase (0..3) with the most onset energy
    ob = onset[frames]
    off = int(np.argmax([ob[k::4].sum() for k in range(4)]))
    downbeats = beats[off::4]
    secs = sections(y, sr, downbeats)

    print(f"file      : {os.path.basename(path)}")
    print(f"duration  : {dur:.1f}s")
    print(f"BPM       : {bpm:.1f}  (beat every {60/bpm:.3f}s)")
    print(f"beats     : {len(beats)}   downbeats/bars: {len(downbeats)} (offset {off})")
    print(f"sections  : {len(secs)}")
    for m in secs:
        bar = (np.argmin(np.abs(downbeats - m["t"])) + 1) if len(downbeats) else 0
        print(f"  {m['t']:7.2f}s  bar {bar:>3}  {m['label']}")

    markers = {"bpm": round(float(bpm), 1), "duration": round(dur, 2),
               "downbeatOffsetBeats": off,
               "markers": secs}
    if out:
        json.dump(markers, open(out, "w"), indent=2)
        print(f"\nwrote {out}")

if __name__ == "__main__":
    main()
