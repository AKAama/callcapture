from app.postprocess.formatter import render_sentiment_section
from app.schemas.models import Sentiment, SpeakerSentiment


def test_none_renders_empty_string():
    assert render_sentiment_section(None) == ""


def test_renders_overall_and_speakers():
    sent = Sentiment(
        overall="positive",
        overall_score=0.5,
        by_speaker={
            "You": SpeakerSentiment(label="positive", score=0.6),
            "Speaker 1": SpeakerSentiment(label="neutral", score=0.0),
        },
    )
    out = render_sentiment_section(sent)
    assert "## Sentiment" in out
    assert "**Overall:** positive (+0.50)" in out
    assert "- **You:** positive (+0.60)" in out
    assert "- **Speaker 1:** neutral (+0.00)" in out


def test_renders_without_speakers():
    sent = Sentiment(overall="negative", overall_score=-0.3)
    out = render_sentiment_section(sent)
    assert "## Sentiment" in out
    assert "**Overall:** negative (-0.30)" in out
