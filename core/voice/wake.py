"""Wake-word detection for "Hey CREA" — fully on-device.

Nothing leaves the machine until the phrase fires. The microphone stream is held
locally, scored locally, and discarded; only after a detection does CREA record a
command and transcribe it (also locally, on the free tier).

Two backends, same interface:

  openwakeword  — a trained "hey crea" ONNX model. Lowest CPU, best accuracy.
                  Needs a model file; training one is a separate offline step.
  vad-whisper   — a continuous microphone stream scored by local whisper.
                  No training required, so it works on day one.

Two things this got wrong first time round, both fixed here:

  1. It recorded a window, THEN transcribed, THEN recorded again — so anything
     said during transcription was simply lost. A wake word cannot have deaf
     periods. The stream is now continuous and overlapping windows are scored
     from a rolling buffer.
  2. It matched on hand-written spellings of "CREA". Whisper actually renders
     "Hey CREA" as "Paycray", so nothing ever matched. The real fix is seeding
     the decoder with the name (see voice.stt.prompt); fuzzy matching below is
     the safety net for when it still mishears.
"""
from __future__ import annotations

import difflib
import re
import threading
from abc import ABC, abstractmethod
from collections import deque
from pathlib import Path

SAMPLE_RATE = 16000


class WakeError(RuntimeError):
    pass


class WakeDetector(ABC):
    @abstractmethod
    def wait(self) -> None:
        """Block until the wake phrase is heard."""

    @abstractmethod
    def health(self) -> dict: ...


# ------------------------------------------------------------------ matching

_STRIP = re.compile(r"[^a-z\s]")

def normalise(s: str) -> str:
    return _STRIP.sub("", s.lower()).strip()


def _collapse(s: str) -> str:
    """Reduce a word to a coarse phonetic skeleton.

    Whisper's errors are overwhelmingly phonetic — p/b, k/c/q, i/e/y. Collapsing
    those classes lets "paycray" and "heycrea" land close together without a
    dependency on a full metaphone implementation.
    """
    s = re.sub(r"[^a-z]", "", s.lower())
    for group, rep in (("bp", "p"), ("ckq", "k"), ("gj", "j"), ("dt", "t"),
                       ("sz", "s"), ("vf", "f"), ("iey", "i"), ("ou", "o")):
        for ch in group:
            s = s.replace(ch, rep)
    return s


def matches(heard: str, phrase: str = "hey crea", threshold: float = 0.70) -> bool:
    """True if `heard` plausibly opens with the wake phrase.

    Matching is anchored on the NAME rather than the whole phrase: whisper
    frequently swallows "hey" into the next word ("Hey CREA" -> "Paycray"), so
    requiring it rejects most real activations. It is also anchored to the START
    of the utterance, which is what separates "hey CREA" from "I was in Korea
    last year" — the same phonetic content, in a position that isn't a command.
    """
    h = normalise(heard)
    if not h:
        return False

    name = phrase.replace(" ", "")
    name = name[3:] if name.startswith("hey") else name        # "crea"
    head = h.replace(" ", "")[:8]                              # the wake word comes FIRST
    if name in head:
        return True

    target = _collapse(name)
    hc = _collapse(head)
    for size in (len(target), len(target) + 1):
        for i in range(0, max(1, len(hc) - size + 1)):
            win = hc[i:i + size]
            if len(win) < size:
                break
            if difflib.SequenceMatcher(None, win, target).ratio() >= threshold:
                return True
    return False


_matches = lambda heard, phrase="hey crea": matches(heard, phrase)   # back-compat


# ------------------------------------------------------------------ backends

class OpenWakeWord(WakeDetector):
    def __init__(self, model_path: str, threshold: float):
        self.model_path = Path(model_path)
        self.threshold = threshold
        self._model = None

    def _ensure(self):
        if self._model is not None:
            return
        if not self.model_path.exists():
            raise WakeError(
                f"no wake model at {self.model_path}. Train a 'hey crea' model, "
                "or set voice.wake.provider to 'vad-whisper'."
            )
        try:
            from openwakeword.model import Model
        except ImportError as e:
            raise WakeError("openwakeword not installed") from e
        self._model = Model(wakeword_models=[str(self.model_path)])

    def wait(self) -> None:
        import numpy as np
        import sounddevice as sd
        self._ensure()
        with sd.InputStream(samplerate=SAMPLE_RATE, blocksize=1280,
                            dtype="int16", channels=1) as stream:
            while True:
                chunk, _ = stream.read(1280)
                scores = self._model.predict(np.squeeze(chunk))
                if any(s >= self.threshold for s in scores.values()):
                    return

    def health(self) -> dict:
        return {"provider": "openwakeword", "model_present": self.model_path.exists(),
                "model_path": str(self.model_path)}


class VadWhisper(WakeDetector):
    """Continuous stream, overlapping windows, local whisper. No deaf gaps."""

    def __init__(self, phrase: str, stt, window_s: float = 2.4,
                 hop_s: float = 0.8, rms_gate: float | None = None,
                 speaker=None):
        self.phrase = phrase.lower().strip()
        self.stt = stt
        self.window = int(window_s * SAMPLE_RATE)
        self.min_window = int(1.2 * SAMPLE_RATE)   # score partial buffers too
        self.hop_s = hop_s
        # None = calibrate against the room at startup. A fixed gate is wrong in
        # both directions: too high in a quiet room and it never hears a normal
        # speaking voice; too low in a noisy one and every fan hits whisper.
        self.rms_gate = rms_gate
        self.speaker = speaker     # optional voice-identity check
        self.last_score = None
        self._gate = None          # cached after the first calibration
        self._gate_at = 0.0
        self.last_heard = ""

    # Speech at a normal distance sits around 0.02-0.10 RMS. A gate above this
    # ceiling can never be crossed, so a noisy calibration must not be allowed
    # to set one — that deafens CREA for the whole session.
    GATE_FLOOR = 0.0030
    GATE_CEIL = 0.010

    def _calibrate_passive(self, buf, lock) -> float:
        """Estimate the room's noise floor, robust to transient noise.

        Takes several short samples and keeps the QUIETEST. A door closing or a
        car going past during calibration then costs nothing, where averaging
        over one window would bake it into the gate permanently.
        """
        import numpy as np
        import sounddevice as sd
        floors = []
        for _ in range(6):
            sd.sleep(300)
            with lock:
                sample = np.array(buf, dtype="int16")
            if sample.size:
                floors.append(rms(sample[-int(0.3 * SAMPLE_RATE):]))
        floor = min(floors) if floors else 0.0
        # Deliberately permissive. A false wake is cheap - CREA says "Yep?"
        # and hears nothing. A missed wake is the failure users actually
        # notice, so bias towards listening and let the matcher reject.
        gate = min(max(floor * 2.0, self.GATE_FLOOR), self.GATE_CEIL)
        print(f"[crea] noise floor {floor:.5f} -> gate {gate:.5f}", flush=True)
        return gate

    # One microphone stream for the whole session. Opening and closing streams
    # around each interaction deadlocks CoreAudio on macOS: the IO thread blocks
    # in AudioUnitGetProperty while the main thread waits on a semaphore, and
    # neither ever returns. Keeping one stream open also removes the start-up
    # latency between hearing the phrase and hearing the command.
    def _ensure_stream(self):
        import sounddevice as sd
        if getattr(self, "_stream", None) is not None:
            return self._buf, self._lock
        self._buf = deque(maxlen=self.window)
        self._lock = threading.Lock()

        def cb(indata, frames, t, status):
            with self._lock:
                self._buf.extend(indata[:, 0])

        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="int16",
            blocksize=int(0.1 * SAMPLE_RATE), callback=cb)
        self._stream.start()
        return self._buf, self._lock

    def close(self) -> None:
        st = getattr(self, "_stream", None)
        if st is not None:
            st.stop()
            st.close()
            self._stream = None

    def capture_command(self, max_seconds: float = 9.0, silence_run: float = 1.1,
                        gate: float = 0.006) -> Path:
        """Record what was said after the wake phrase, on the SAME stream."""
        import numpy as np
        import sounddevice as sd
        buf, lock = self._ensure_stream()
        with lock:
            buf.clear()
        collected, quiet, elapsed, step = [], 0.0, 0.0, 0.25
        started = False          # has the speaker actually begun?
        lead_in = 3.0            # how long to wait for them to start
        while elapsed < max_seconds:
            sd.sleep(int(step * 1000))
            with lock:
                chunk = np.array(buf, dtype="int16")
                buf.clear()
            elapsed += step
            if not chunk.size:
                continue
            collected.append(chunk)
            loud = rms(chunk) >= gate
            if loud:
                started = True
                quiet = 0.0
            elif started:
                # Only count silence once they have begun. Otherwise the natural
                # pause between "Yep?" and the question ends the recording before
                # a word is said.
                quiet += step
            elif elapsed >= lead_in:
                break            # they never started; stop waiting
            if started and quiet >= silence_run:
                break
        audio = np.concatenate(collected) if collected else np.zeros(1, dtype="int16")
        return write_wav(audio)

    def wait(self) -> None:
        import numpy as np
        import sounddevice as sd

        buf, lock = self._ensure_stream()

        import time as _t
        gate = self.rms_gate
        if True:
            if gate is None:
                # Calibration costs ~2s, so cache it rather than paying that
                # after every single interaction. Refresh occasionally so the
                # gate still tracks the room across a working day.
                if self._gate is None or _t.time() - self._gate_at > 900:
                    self._gate = self._calibrate_passive(buf, lock)
                    self._gate_at = _t.time()
                gate = self._gate
            while True:
                sd.sleep(int(self.hop_s * 1000))
                with lock:
                    if len(buf) < self.min_window:
                        continue
                    audio = np.array(buf, dtype="int16")
                if rms(audio) < gate:
                    continue                       # silence never reaches whisper
                path = write_wav(audio)
                path_bytes = path.read_bytes()
                try:
                    heard = self.stt.transcribe(path)
                except Exception as e:
                    print(f"[crea] transcribe failed: {e}", flush=True)
                    continue
                finally:
                    path.unlink(missing_ok=True)
                self.last_heard = heard
                if not matches(heard, self.phrase):
                    continue

                # Speaker identity is NOT decided here. A two-second wake phrase
                # carries too little voiced audio for a reliable embedding —
                # measured: enrolment on the phrase alone self-scores only 0.87
                # with a weakest sample of 0.76, and genuine repeats land around
                # 0.65. The command that follows is several seconds of speech,
                # which is where the check actually works. See loop.run().

                with lock:
                    buf.clear()                    # don't re-trigger on the same audio
                return

    def health(self) -> dict:
        return {"provider": "vad-whisper", "phrase": self.phrase,
                "stt": self.stt.health()}


# ------------------------------------------------------------------ audio io

def rms(audio) -> float:
    import numpy as np
    a = np.asarray(audio, dtype="float32") / 32768.0
    return float(np.sqrt((a ** 2).mean())) if a.size else 0.0


def write_wav(audio, sample_rate: int = SAMPLE_RATE) -> Path:
    import os
    import tempfile
    import wave
    import numpy as np
    # See the note in loop.play(): mkstemp hands back an open fd that must be
    # closed, or the wake loop leaks one descriptor per utterance.
    fd, name = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    p = Path(name)
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sample_rate)
        w.writeframes(np.asarray(audio, dtype="int16").tobytes())
    return p


def record_command(max_seconds: float = 9.0, silence_gate: float = 0.009,
                   silence_run: float = 1.1) -> Path:
    """Record until the speaker stops, capped at max_seconds."""
    import numpy as np
    import sounddevice as sd
    chunks, quiet, elapsed, step = [], 0.0, 0.0, 0.25
    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="int16") as st:
        while elapsed < max_seconds:
            block, _ = st.read(int(step * SAMPLE_RATE))
            block = block[:, 0]
            chunks.append(block)
            quiet = quiet + step if rms(block) < silence_gate else 0.0
            elapsed += step
            if quiet >= silence_run and elapsed > 1.0:
                break
    return write_wav(np.concatenate(chunks))


def make_wake(cfg, stt, speaker=None) -> WakeDetector:
    provider = cfg.get("voice.wake.provider")
    if provider == "openwakeword":
        return OpenWakeWord(cfg.get("voice.wake.model_path"),
                            cfg.get("voice.wake.threshold", 0.6))
    if provider == "vad-whisper":
        return VadWhisper(cfg.get("identity.wake_phrase"), stt, speaker=speaker)
    raise WakeError(f"unknown wake provider: {provider}")
