from unittest.mock import MagicMock, patch

from app.analyze.insights import analyze_insights
from app.postprocess.llm_client import LLMError
from app.schemas.models import Insights, Sentiment, TranscriptSegment


def _segs():
    return [
        TranscriptSegment(start=0.0, end=2.0, text="let's close the deal", speaker="You"),
        TranscriptSegment(start=2.0, end=4.0, text="I need to think", speaker="Speaker 1"),
    ]


def test_empty_returns_none():
    assert analyze_insights([], recording_type="call_meeting") is None


def test_no_key_cloud_returns_fallback(monkeypatch):
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    ins = analyze_insights(_segs(), recording_type="voice_memo")
    assert isinstance(ins, Insights)
    assert ins.summary != ""
    assert ins.key_points  # fallback fills key_points from segments
    assert ins.reflections == []  # type-specific extras stay empty in fallback


def test_call_happy_path_filters_to_call_fields(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "Deal Call",
        "summary": "Discussed closing.",
        "dynamics": "You drove it.",
        "opportunities": ["address hesitation"],
        "recommended_actions": ["send proposal"],
        "action_items": ["follow up Monday"],
        "outline": ["should be dropped"],  # not a call field
    }
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="call_meeting")
    assert ins.title == "Deal Call"
    assert ins.dynamics == "You drove it."
    assert ins.opportunities == ["address hesitation"]
    assert ins.recommended_actions == ["send proposal"]
    assert ins.action_items == ["follow up Monday"]
    assert ins.outline == []  # dropped — not in call field set


def test_lecture_uses_lecture_prompt_and_fields(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": "Bio 101",
        "summary": "Cells.",
        "outline": ["intro", "mitosis"],
        "key_concepts": ["cell"],
        "qa": ["Q: why? A: because"],
        "takeaways": ["cells divide"],
    }
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="lecture")
    system_arg = fake.complete_json.call_args.kwargs["system"]
    assert "lecture/talk" in system_arg
    assert ins.outline == ["intro", "mitosis"]
    assert ins.takeaways == ["cells divide"]
    assert ins.action_items == []  # not a lecture field


def test_defensive_parse_drops_non_str_and_clamps(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {
        "title": 123,                       # non-str -> derived from first segment
        "summary": "x" * 600,               # clamped to 499
        "key_points": ["ok", 5, "", "  "],   # drops 5, "", "  "
        "action_items": "not a list",        # -> []
    }
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="voice_memo")
    assert len(ins.summary) == 499
    assert ins.key_points == ["ok"]
    assert ins.action_items == []
    assert ins.title == "let's close the deal"  # from segments[0].text


def test_llm_error_returns_fallback(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.side_effect = LLMError("boom")
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        ins = analyze_insights(_segs(), recording_type="call_meeting")
    assert ins.summary != ""  # fallback summary from segments


def test_context_block_includes_sentiment_and_tone(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {"title": "t", "summary": "s"}
    sent = Sentiment(overall="positive", overall_score=0.5)
    emo = {"You": {"valence": 0.3, "arousal": 0.2, "dominant_emotion": "calm"}}
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        analyze_insights(_segs(), recording_type="call_meeting", sentiment=sent, emotion=emo)
    user_arg = fake.complete_json.call_args.kwargs["user"]
    assert "Overall sentiment: positive" in user_arg
    assert "You sounded calm" in user_arg


def test_no_context_block_when_no_sentiment_or_emotion(monkeypatch):
    monkeypatch.setenv("LLM_API_KEY", "k")
    monkeypatch.setenv("LLM_BASE_URL", "https://openrouter.ai/api/v1")
    fake = MagicMock()
    fake.complete_json.return_value = {"title": "t", "summary": "s"}
    with patch("app.analyze.insights.LLMClient", return_value=fake):
        analyze_insights(_segs(), recording_type="call_meeting")
    user_arg = fake.complete_json.call_args.kwargs["user"]
    assert "Context:" not in user_arg
    assert user_arg.startswith("Transcript:")
