from app.schemas.models import ConversationAnalysis, Sentiment, SpeakerSentiment


def test_speaker_sentiment_defaults():
    s = SpeakerSentiment()
    assert s.label == "neutral"
    assert s.score == 0.0


def test_sentiment_defaults_and_roundtrip():
    sent = Sentiment(
        overall="positive",
        overall_score=0.5,
        by_speaker={"You": SpeakerSentiment(label="positive", score=0.6)},
    )
    restored = Sentiment.model_validate_json(sent.model_dump_json())
    assert restored.overall == "positive"
    assert restored.overall_score == 0.5
    assert restored.by_speaker["You"].score == 0.6
    assert restored.arc == []


def test_conversation_analysis_carries_sentiment():
    analysis = ConversationAnalysis(
        recording_type="call_meeting",
        num_speakers=1,
        sentiment=Sentiment(overall="neutral"),
    )
    restored = ConversationAnalysis.model_validate_json(analysis.model_dump_json())
    assert restored.sentiment is not None
    assert restored.sentiment.overall == "neutral"


def test_conversation_analysis_sentiment_optional():
    analysis = ConversationAnalysis()
    assert analysis.sentiment is None
