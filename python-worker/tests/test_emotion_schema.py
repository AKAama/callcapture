from app.schemas.models import ArcPoint, Sentiment, SpeakerStats


def test_speaker_stats_emotion_fields_default_none():
    s = SpeakerStats(label="You")
    assert s.dominant_emotion is None
    assert s.valence is None
    assert s.arousal is None


def test_speaker_stats_with_emotion_roundtrip():
    s = SpeakerStats(label="You", valence=0.7, arousal=0.5, dominant_emotion="content")
    restored = SpeakerStats.model_validate_json(s.model_dump_json())
    assert restored.valence == 0.7
    assert restored.dominant_emotion == "content"


def test_arc_point_and_widened_arc():
    sent = Sentiment(arc=[ArcPoint(t=10.0, score=0.3), ArcPoint(t=30.0, score=-0.2)])
    restored = Sentiment.model_validate_json(sent.model_dump_json())
    assert restored.arc[0].t == 10.0
    assert restored.arc[1].score == -0.2


def test_sentiment_arc_defaults_empty():
    assert Sentiment().arc == []
