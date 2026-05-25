from unittest.mock import MagicMock, patch

from app.analyze.sentiment import analyze_sentiment
from app.postprocess.llm_client import LLMError
from app.schemas.models import TranscriptSegment


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="great, thanks!", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="not sure about that", speaker="Speaker 1"),
    ]


def test_empty_segments_returns_none():
    assert analyze_sentiment([]) is None


def test_happy_path_parses_llm_json(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "positive",
        "overall_score": 0.7,
        "by_speaker": {
            "You": {"label": "positive", "score": 0.8},
            "Speaker 1": {"label": "negative", "score": -0.4},
        },
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent is not None
    assert sent.overall == "positive"
    assert sent.overall_score == 0.7
    assert sent.by_speaker["You"].label == "positive"
    assert sent.by_speaker["Speaker 1"].score == -0.4


def test_scores_clamped_and_labels_normalized(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "ecstatic",            # unknown -> neutral
        "overall_score": 5.0,             # clamp -> 1.0
        "by_speaker": {"You": {"label": "positive", "score": -9.0}},  # clamp -> -1.0
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent.overall == "neutral"
    assert sent.overall_score == 1.0
    assert sent.by_speaker["You"].score == -1.0
    # Speaker 1 absent from output -> filled neutral
    assert sent.by_speaker["Speaker 1"].label == "neutral"
    assert sent.by_speaker["Speaker 1"].score == 0.0


def test_no_key_on_cloud_returns_neutral_fallback(monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    sent = analyze_sentiment(_segs())
    assert sent.overall == "neutral"
    assert sent.overall_score == 0.0
    assert set(sent.by_speaker) == {"You", "Speaker 1"}
    assert all(s.label == "neutral" for s in sent.by_speaker.values())


def test_llm_error_returns_neutral_fallback(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.side_effect = LLMError("boom")
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent.overall == "neutral"
    assert set(sent.by_speaker) == {"You", "Speaker 1"}


def test_non_dict_by_speaker_does_not_raise(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "positive",
        "overall_score": 0.5,
        "by_speaker": [{"You": "positive"}],  # a list, not a dict
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent.overall == "positive"
    assert set(sent.by_speaker) == {"You", "Speaker 1"}
    assert all(s.label == "neutral" for s in sent.by_speaker.values())


def test_non_dict_speaker_entry_does_not_raise(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "neutral",
        "overall_score": 0.0,
        "by_speaker": {"You": ["nope"], "Speaker 1": {"label": "negative", "score": -0.5}},
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent.by_speaker["You"].label == "neutral"
    assert sent.by_speaker["Speaker 1"].label == "negative"
    assert sent.by_speaker["Speaker 1"].score == -0.5


def test_non_finite_scores_become_zero(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "overall": "positive",
        "overall_score": float("nan"),
        "by_speaker": {"You": {"label": "positive", "score": float("inf")}},
    }
    with patch("app.analyze.sentiment.LLMClient", return_value=fake):
        sent = analyze_sentiment(_segs())
    assert sent.overall_score == 0.0
    assert sent.by_speaker["You"].score == 0.0
