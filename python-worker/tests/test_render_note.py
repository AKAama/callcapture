from app.postprocess.formatter import render_note
from app.schemas.models import (
    Insights,
    Sentiment,
    SpeakerSentiment,
    SpeakerStats,
    TranscriptSegment,
)


def _speakers():
    return [
        SpeakerStats(label="You", is_self=True, talk_seconds=30.0, talk_ratio=0.6,
                     words=100, words_per_min=140.0, turns=5, dominant_emotion="calm"),
        SpeakerStats(label="Speaker 1", talk_ratio=0.4, words=60, words_per_min=120.0,
                     turns=4, dominant_emotion="sad"),
    ]


def _sentiment():
    return Sentiment(overall="positive", overall_score=0.5,
                     by_speaker={"You": SpeakerSentiment(label="positive", score=0.6)})


def _segs():
    return [TranscriptSegment(start=0.0, end=2.0, text="hi", speaker="You")]


def test_call_note_sections():
    ins = Insights(title="Deal", summary="Closed.", dynamics="You led.",
                   opportunities=["push"], recommended_actions=["send"],
                   action_items=["call Bob"])
    out = render_note("call_meeting", ins, _sentiment(), _speakers(), _segs())
    assert out.startswith("---\n")
    assert "recording_type: call_meeting" in out
    assert "# Deal" in out
    assert "**Summary:** Closed." in out
    assert "## Participants" in out
    assert "| You |" in out
    assert "Tone" in out  # at least one speaker has dominant_emotion
    assert "## Sentiment" in out
    assert "**Overall:** positive (+0.50)" in out
    assert "## Conversation Insights" in out
    assert "You led." in out
    assert "### Opportunities" in out
    assert "### Recommended Actions" in out
    assert "### Action Items" in out
    assert "- [ ] call Bob" in out
    assert "- **You:** positive (+0.60)" in out  # per-speaker sentiment line
    assert "## Transcript" in out


def test_frontmatter_escapes_quotes_in_title():
    ins = Insights(title='Talk about "pricing"', summary="S")
    out = render_note("voice_memo", ins, None, [], [])
    assert 'title: "Talk about \\"pricing\\""' in out


def test_call_note_omits_empty_sections():
    ins = Insights(title="T", summary="S")
    out = render_note("call_meeting", ins, None, [], [])
    assert "## Participants" not in out  # no speakers
    assert "## Sentiment" not in out      # sentiment None
    assert "## Conversation Insights" not in out
    assert "## Transcript" not in out
    assert "sentiment:" not in out        # frontmatter omits sentiment when None


def test_memo_note_shape():
    ins = Insights(title="Memo", summary="Did stuff.", key_points=["a", "b"],
                   action_items=["do x"], reflections=["why?"])
    out = render_note("voice_memo", ins, _sentiment(), [], _segs())
    assert "# Memo" in out
    assert "## Summary" in out
    assert "Did stuff." in out
    assert "## Key Points" in out
    assert "- a" in out
    assert "## Action Items" in out
    assert "- [ ] do x" in out
    assert "## Reflections" in out
    assert "- why?" in out
    assert "## Transcript" not in out
    assert "## Participants" not in out
    assert "## Sentiment" not in out      # memo body has no Sentiment section
    assert "sentiment: positive" in out   # but frontmatter carries it


def test_lecture_note_shape():
    ins = Insights(title="Bio", summary="Cells.", outline=["intro"],
                   key_concepts=["cell"], qa=["Q/A"], takeaways=["divide"])
    out = render_note("lecture", ins, None, [], _segs())
    assert "# Bio" in out
    assert "## Outline" in out
    assert "- intro" in out
    assert "## Key Concepts" in out
    assert "## Summary" in out
    assert "Cells." in out
    assert "## Q&A" in out
    assert "## Takeaways" in out
    assert "- divide" in out


def test_unknown_type_falls_back_to_call():
    ins = Insights(title="X", summary="Y", dynamics="Z")
    out = render_note("interview", ins, None, [], [])
    assert "# X" in out
    assert "## Conversation Insights" in out  # call renderer (dynamics present)


def test_none_insights_renders_minimal():
    out = render_note("voice_memo", None, None, [], [])
    assert out.startswith("---\n")
    assert "# Untitled" in out


def test_participants_table_without_tone():
    speakers = [SpeakerStats(label="You", talk_ratio=1.0, words=10,
                             words_per_min=100.0, turns=1)]
    out = render_note("call_meeting", Insights(title="T", summary="S"), None, speakers, [])
    assert "## Participants" in out
    assert "| 100% |" in out      # talk_ratio 1.0 -> 100%
    assert "Tone" not in out      # no dominant_emotion on any speaker
