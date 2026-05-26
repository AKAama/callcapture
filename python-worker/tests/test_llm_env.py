from app.postprocess.llm_env import (
    LlmEnv,
    format_speaker_tone_lines,
    resolve_llm_env,
    transcript_text,
    warn,
)
from app.schemas.models import TranscriptSegment


def test_resolve_defaults(monkeypatch):
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    monkeypatch.delenv("LLM_MODEL", raising=False)
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    env = resolve_llm_env()
    assert isinstance(env, LlmEnv)
    assert env.base_url == "https://openrouter.ai/api/v1"
    assert env.model == "google/gemini-2.5-flash"
    assert env.api_key == ""
    assert env.is_local is False


def test_resolve_local_detection(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "http://localhost:11434/v1")
    assert resolve_llm_env().is_local is True


def test_resolve_reads_overrides(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    monkeypatch.setenv("LLM_MODEL", "anthropic/claude-sonnet-4.6")
    monkeypatch.setenv("LLM_API_KEY", "sk-x")
    env = resolve_llm_env()
    assert env.model == "anthropic/claude-sonnet-4.6"
    assert env.api_key == "sk-x"
    assert env.is_local is False


def test_transcript_text_plain():
    segs = [TranscriptSegment(start=0.0, end=1.0, text="hi", speaker="You")]
    assert transcript_text(segs) == "[You] hi"


def test_transcript_text_timestamps():
    segs = [TranscriptSegment(start=2.0, end=3.0, text="hi", speaker="You")]
    assert transcript_text(segs, timestamps=True) == "[2.0s] [You] hi"


def test_transcript_text_no_speaker():
    segs = [TranscriptSegment(start=0.0, end=1.0, text="hi")]
    assert transcript_text(segs) == "hi"


def test_transcript_text_multiple_segments():
    segs = [
        TranscriptSegment(start=0.0, end=1.0, text="hello", speaker="A"),
        TranscriptSegment(start=1.0, end=2.0, text="world", speaker="B"),
    ]
    assert transcript_text(segs) == "[A] hello\n[B] world"


def test_transcript_text_empty():
    assert transcript_text([]) == ""


def test_warn_writes_json(capsys):
    warn("boom")
    assert '{"warning": "boom"}' in capsys.readouterr().err


def test_format_speaker_tone_lines_none_and_empty():
    assert format_speaker_tone_lines(None) == []
    assert format_speaker_tone_lines({}) == []


def test_format_speaker_tone_lines_formats_entries():
    emotion = {"You": {"valence": 0.3, "arousal": 0.2, "dominant_emotion": "calm"}}
    lines = format_speaker_tone_lines(emotion)
    assert lines == ["- You sounded calm (valence 0.30, arousal 0.20)."]


def test_format_speaker_tone_lines_skips_unparseable():
    emotion = {"Bad": {"valence": "nope"}, "You": {"valence": 0.1, "arousal": 0.1}}
    lines = format_speaker_tone_lines(emotion)
    assert len(lines) == 1
    assert lines[0].startswith("- You sounded neutral")
