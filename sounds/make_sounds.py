#!/usr/bin/env python3
# Generates every sound effect in this folder — retro (PS1/PS2-era) synthesis:
# filtered noise, simple oscillators and pitch sweeps, kept soft: everything
# goes through a final damping lowpass (DAMP_HZ) so nothing hisses or stings.
# 22050 Hz mono 16-bit WAV. Re-run to regenerate; the seed keeps it repeatable.
#   python3 sounds/make_sounds.py
import os, wave
import numpy as np

SR = 22050
DAMP_HZ = 2800    # final lowpass on every sound
OUT = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)


# ── building blocks ──────────────────────────────────────────────────────────

def t(dur):
    return np.arange(int(dur * SR)) / SR

def noise(dur):
    return rng.uniform(-1, 1, int(dur * SR))

def lowpass(x, cutoff):
    """One-pole lowpass; cutoff may be a number or a per-sample array."""
    c = np.broadcast_to(np.asarray(cutoff, float), x.shape)
    a = 1 - np.exp(-2 * np.pi * c / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc += a[i] * (x[i] - acc)
        y[i] = acc
    return y

def highpass(x, cutoff):
    return x - lowpass(x, cutoff)

def bandpass(x, lo, hi):
    return lowpass(highpass(x, lo), hi)

def resonate(x, freq, q):
    """Two-pole resonant bandpass (RBJ biquad): rings at `freq`, narrower as q grows."""
    w = 2 * np.pi * freq / SR
    alpha = np.sin(w) / (2 * q)
    b0, b2 = alpha, -alpha
    a0, a1, a2 = 1 + alpha, -2 * np.cos(w), 1 - alpha
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        y[i] = (b0 * x[i] + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x[i], y1, y[i]
    return y

def osc(freq, dur, shape="sine"):
    """Oscillator; freq may be a per-sample array (a sweep)."""
    n = int(dur * SR)
    f = np.broadcast_to(np.asarray(freq, float), (n,))
    ph = 2 * np.pi * np.cumsum(f) / SR
    if shape == "sine":   return np.sin(ph)
    if shape == "square": return np.sign(np.sin(ph))
    if shape == "saw":    return 2 * ((ph / (2 * np.pi)) % 1.0) - 1
    if shape == "tri":    return 2 * np.abs(2 * ((ph / (2 * np.pi)) % 1.0) - 1) - 1
    raise ValueError(shape)

def sweep(f0, f1, dur, curve=1.0):
    k = np.linspace(0, 1, int(dur * SR)) ** curve
    return f0 + (f1 - f0) * k

def env(dur, attack=0.005, decay=None, hold=0.0):
    """Attack, optional hold, then exponential decay to the end."""
    n = int(dur * SR)
    e = np.ones(n)
    na = max(1, int(attack * SR))
    e[:na] = np.linspace(0, 1, na)
    nh = int(hold * SR)
    rest = n - na - nh
    if rest > 0:
        d = decay if decay else (rest / SR) / 5
        e[na + nh:] = np.exp(-np.arange(rest) / SR / d)
    return e

def swell(dur, peak=0.5):
    """Rise then fall (a whoosh): sine-shaped hump peaking at `peak` (0..1)."""
    k = np.linspace(0, 1, int(dur * SR))
    a = np.where(k < peak, k / peak, (1 - k) / (1 - peak))
    return np.sin(a * np.pi / 2) ** 2

def pad(x, dur):
    n = int(dur * SR)
    return np.pad(x, (0, max(0, n - len(x))))[:n]

def mix(*parts):
    n = max(len(p) for p in parts)
    return sum(np.pad(p, (0, n - len(p))) for p in parts)

def at(x, delay):
    return np.concatenate([np.zeros(int(delay * SR)), x])

def crackle(dur, rate, decay=0.004):
    """Sparse random pops — fire crackle, gravel, bubbles."""
    n = int(dur * SR)
    y = np.zeros(n)
    for i in np.nonzero(rng.random(n) < rate / SR)[0]:
        m = min(n - i, int(decay * SR * 6))
        y[i:i + m] += rng.uniform(0.4, 1) * rng.choice([-1, 1]) * np.exp(-np.arange(m) / SR / decay)
    return y

def save(name, x, gain=0.8):
    x = lowpass(lowpass(np.asarray(x, float), DAMP_HZ), DAMP_HZ)   # two poles: a gentle, damped top end
    peak = np.max(np.abs(x)) or 1.0
    x = x / peak * gain
    fade = min(len(x), int(0.004 * SR))          # no click at the end
    x[-fade:] *= np.linspace(1, 0, fade)
    data = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"  {name}.wav  {len(x) / SR:.2f}s")


# ── combat ───────────────────────────────────────────────────────────────────

def swing():
    """A blade swung hard: a quick, noisy metallic "tsching" — a burst of
    noise through a few narrow, inharmonic resonances (steel), not held tones —
    over a short push of air."""
    d = 0.2
    burst = noise(d) * env(d, 0.002, 0.03)
    steel = sum(resonate(burst, f, 18) * a for f, a in ((1350, 1.0), (1980, 0.7), (2470, 0.45)))
    air = bandpass(noise(d), 250, 1000) * swell(d, 0.3) * 0.25
    return mix(steel * 0.7, air)

def throw():
    d = 0.16
    return bandpass(noise(d), sweep(300, 700, d), sweep(1000, 1700, d)) * swell(d, 0.35)

def bow():
    d = 0.4
    f = sweep(210, 190, d)
    string = (osc(f, d) + 0.5 * osc(2 * f, d) + 0.25 * osc(3 * f, d, "tri")) * env(d, 0.002, 0.07)
    snap = bandpass(noise(0.03), 600, 1800) * env(0.03, 0.002, 0.006)
    woosh = bandpass(noise(0.25), 800, 3000) * swell(0.25, 0.3) * 0.3
    return mix(string, snap * 0.8, at(woosh, 0.03))

def magic_cast():
    d = 0.45
    f = sweep(300, 1100, d, 0.7) * (1 + 0.03 * np.sin(2 * np.pi * 18 * t(d)))
    tone = (osc(f, d) + 0.3 * osc(f * 1.5, d, "tri")) * swell(d, 0.6)
    sparkle = bandpass(crackle(d, 60, 0.003), 1200, 2400) * swell(d, 0.7) * 0.3
    return mix(tone, sparkle)

def flame():
    d = 0.7
    roar = lowpass(noise(d), sweep(2500, 600, d)) * env(d, 0.02, 0.22)
    return mix(roar, crackle(d, 60, 0.003) * 0.5 * env(d, 0.01, 0.3))

def fireball_cast():
    d = 0.5
    roar = lowpass(noise(d), sweep(400, 2200, d, 0.5)) * swell(d, 0.55)
    tone = osc(sweep(90, 220, d), d, "saw") * swell(d, 0.55) * 0.25
    return mix(roar, lowpass(tone, 900))

def thud(f0, f1, d, click=0.4, body=1.0):
    tone = osc(sweep(f0, f1, d, 0.4), d) * env(d, 0.002, d / 4) * body
    tick = lowpass(noise(0.02), 3000) * env(0.02, 0.001, 0.004) * click
    return mix(tone, tick)

def hit_default():
    return mix(thud(150, 60, 0.2), lowpass(noise(0.08), 900) * env(0.08, 0.002, 0.02) * 0.5)

def hit_blunt():
    return mix(thud(110, 45, 0.28, click=0.6), lowpass(noise(0.12), 600) * env(0.12, 0.002, 0.03) * 0.7)

def hit_slash():
    d = 0.18
    slice_ = bandpass(noise(d), 900, 2200) * env(d, 0.002, 0.03)
    ring = osc(1300, d) * env(d, 0.001, 0.04) * 0.1
    return mix(slice_, ring, thud(180, 90, 0.1, click=0, body=0.4))

def hit_pierce():
    d = 0.14
    tick = bandpass(noise(0.025), 700, 2200) * env(0.025, 0.001, 0.004) * 0.6
    thunk = osc(sweep(320, 140, d), d, "tri") * env(d, 0.001, 0.03) * 0.7
    return mix(tick, thunk)

def hit_rock():
    d = 0.16
    k1 = bandpass(noise(d), 600, 1400) * env(d, 0.001, 0.02)
    k2 = at(bandpass(noise(0.08), 900, 2200) * env(0.08, 0.001, 0.012) * 0.6, 0.035)
    return mix(k1, k2, thud(200, 120, 0.08, click=0, body=0.5))

def hit_fire():
    d = 0.4
    whoomp = lowpass(noise(d), sweep(1800, 300, d)) * env(d, 0.004, 0.09)
    return mix(whoomp, crackle(d, 80, 0.0025) * 0.5 * env(d, 0.01, 0.15), thud(90, 50, 0.15, click=0, body=0.6))

def hit_magic():
    d = 0.28
    zap = osc(sweep(1400, 250, d, 0.5), d, "square") * env(d, 0.001, 0.06)
    return mix(lowpass(zap, 1800) * 0.6, bandpass(noise(d), 800, 2000) * env(d, 0.002, 0.03) * 0.25)

def block_armor():
    d = 0.4
    parts = [(523, 0.12), (1187, 0.09), (1873, 0.06), (2711, 0.045), (3530, 0.03)]
    clank = sum(osc(f, d) * env(d, 0.001, dec) / (i + 1) for i, (f, dec) in enumerate(parts))
    return mix(clank, bandpass(noise(0.02), 1000, 2500) * env(0.02, 0.001, 0.003) * 0.4)

def block_defend():
    d = 0.16
    knock = (osc(240, d) + 0.5 * osc(470, d)) * env(d, 0.001, 0.03)
    return mix(knock, bandpass(noise(0.04), 400, 2000) * env(0.04, 0.001, 0.008) * 0.6)

def monster_death():
    d = 0.6
    f = sweep(900, 140, d, 0.6) * (1 + 0.06 * np.sin(2 * np.pi * 22 * t(d)))
    squeal = lowpass(osc(f, d, "saw"), 2600) * env(d, 0.01, 0.2)
    return mix(squeal, lowpass(noise(0.5), 700) * env(0.5, 0.01, 0.12) * 0.3)

def player_hurt():
    d = 0.28
    src = osc(sweep(170, 110, d), d, "saw")
    voice = bandpass(src, 500, 900) + 0.6 * bandpass(src, 1000, 1600)
    return voice * env(d, 0.01, 0.07) + lowpass(noise(d), 1200) * env(d, 0.005, 0.03) * 0.15


# ── movement ─────────────────────────────────────────────────────────────────

def step_stone(i):
    """A soft-soled foot on paving: a brief, rounded scuff of noise in the low
    mids over a soft thump — nothing pitched, so nothing rings like tin."""
    d = 0.12
    scuff = bandpass(noise(d), 300 + 60 * i, 1500) * env(d, 0.004, 0.02)
    heel = lowpass(noise(0.05), 500) * env(0.05, 0.002, 0.012) * 0.8
    return mix(scuff, heel, thud(95 + 10 * i, 60, 0.06, click=0, body=0.3))

def step_grass(i):
    d = 0.14
    rustle = bandpass(noise(d), 700 + 150 * i, 2400) * env(d, 0.01, 0.03) * 0.8
    grit = bandpass(crackle(d, 300, 0.002), 900, 2400) * env(d, 0.008, 0.035) * 0.3
    return mix(rustle, grit, thud(80, 50, 0.06, click=0, body=0.3))

def jump():
    d = 0.18
    return bandpass(noise(d), sweep(250, 600, d), 1400) * swell(d, 0.3)

def land():
    return mix(thud(85, 40, 0.18, click=0.3), lowpass(noise(0.1), 1200) * env(0.1, 0.002, 0.025) * 0.6)

def bubbles(d, rate):
    y = np.zeros(int(d * SR))
    for start in np.nonzero(rng.random(len(y)) < rate / SR)[0]:
        bd = rng.uniform(0.02, 0.05)
        b = osc(sweep(rng.uniform(500, 1200), rng.uniform(1300, 2400), bd), bd) * env(bd, 0.002, bd / 3)
        y[start:start + len(b)] += b[:len(y) - start] * 0.4
    return y

def splash():
    d = 0.7
    body = lowpass(noise(d), sweep(3000, 500, d)) * env(d, 0.004, 0.13)
    return mix(body, bubbles(d, 25) * env(d, 0.05, 0.3), thud(70, 40, 0.15, click=0, body=0.5))

def swim():
    d = 0.4
    stroke = lowpass(noise(d), sweep(700, 1800, d)) * swell(d, 0.4)
    return mix(stroke, bubbles(d, 12) * 0.6)

def climb(i):
    """A hand taking hold: a muffled thump and a little cloth rustle."""
    d = 0.16
    grab = thud(130 - 15 * i, 70, 0.1, click=0.15, body=0.8)
    cloth = bandpass(noise(d), 300, 1100) * swell(d, 0.25) * 0.35
    return mix(grab, cloth)


if __name__ == "__main__":
    print("writing to", OUT)
    sounds = {
        "swing": swing, "throw": throw, "bow": bow, "magic_cast": magic_cast,
        "flame": flame, "fireball_cast": fireball_cast,
        "hit_default": hit_default, "hit_blunt": hit_blunt, "hit_slash": hit_slash,
        "hit_pierce": hit_pierce, "hit_rock": hit_rock, "hit_fire": hit_fire, "hit_magic": hit_magic,
        "block_armor": block_armor, "block_defend": block_defend,
        "monster_death": monster_death, "player_hurt": player_hurt,
        "jump": jump, "land": land, "splash": splash, "swim": swim,
    }
    for name, make in sounds.items():
        save(name, make())
    for i in range(3):
        save(f"step_stone_{i + 1}", step_stone(i), 0.8)
        save(f"step_grass_{i + 1}", step_grass(i), 0.6)
    for i in range(2):
        save(f"climb_{i + 1}", climb(i), 0.6)
