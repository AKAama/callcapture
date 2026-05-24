from app.schemas.models import ConversationAnalysis, DiarizationTurn, SpeakerStats


def test_speaker_stats_defaults():
    s = SpeakerStats(label="You", is_self=True)
    assert s.talk_seconds == 0.0
    assert s.talk_ratio == 0.0
    assert s.words == 0
    assert s.words_per_min == 0.0
    assert s.turns == 0
    assert s.longest_monologue_sec == 0.0


def test_conversation_analysis_roundtrip():
    analysis = ConversationAnalysis(
        recording_type="call_meeting",
        num_speakers=2,
        speakers=[
            SpeakerStats(label="You", is_self=True, talk_seconds=10, talk_ratio=0.4, words=30),
            SpeakerStats(label="Speaker 1", is_self=False, talk_seconds=15, talk_ratio=0.6, words=50),
        ],
    )
    dumped = analysis.model_dump_json()
    restored = ConversationAnalysis.model_validate_json(dumped)
    assert restored.num_speakers == 2
    assert restored.speakers[0].label == "You"


def test_diarization_turn():
    t = DiarizationTurn(speaker="Speaker 1", start=0.0, end=2.5)
    assert t.end == 2.5
