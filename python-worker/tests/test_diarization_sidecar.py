import json
from pathlib import Path

from app.analyze.diarization import load_diarization_turns


def test_missing_sidecar_returns_none(tmp_path):
    audio = tmp_path / "abc.wav"
    audio.write_bytes(b"")
    assert load_diarization_turns(str(audio)) is None


def test_valid_sidecar_parsed(tmp_path):
    audio = tmp_path / "abc.wav"
    audio.write_bytes(b"")
    side = tmp_path / "abc_diarization.json"
    side.write_text(json.dumps({"turns": [
        {"speaker": "Speaker 1", "start": 0.0, "end": 2.0},
        {"speaker": "Speaker 2", "start": 2.0, "end": 5.0},
    ]}))
    turns = load_diarization_turns(str(audio))
    assert turns is not None
    assert len(turns) == 2
    assert turns[1].speaker == "Speaker 2"


def test_malformed_sidecar_returns_none(tmp_path):
    audio = tmp_path / "abc.wav"
    audio.write_bytes(b"")
    (tmp_path / "abc_diarization.json").write_text("not json")
    assert load_diarization_turns(str(audio)) is None
