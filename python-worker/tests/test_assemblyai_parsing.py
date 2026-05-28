"""Tests for the AssemblyAI response-mapping helper.

The actual HTTP flow (upload → submit → poll) needs a live key; we test the
deterministic part — parsing the completed transcript body into the worker's
`TranscriptSegment` shape, including the diarized utterance branch and the
no-diarization fallback.
"""

from __future__ import annotations

from app.transcribe.remote_engine import _assemblyai_segments_from


def test_maps_diarized_utterances_to_segments_with_speaker_labels():
    body = {
        "status": "completed",
        "audio_duration": 12.5,
        "utterances": [
            {"start": 0, "end": 2000, "text": "Hello there", "speaker": "A"},
            {"start": 2100, "end": 5500, "text": "Hi back", "speaker": "B"},
        ],
    }
    segs = _assemblyai_segments_from(body)
    assert len(segs) == 2
    assert segs[0].start == 0.0
    assert segs[0].end == 2.0
    assert segs[0].text == "Hello there"
    assert segs[0].speaker == "Speaker A"
    assert segs[1].speaker == "Speaker B"
    assert segs[1].start == 2.1


def test_missing_speaker_id_leaves_speaker_none():
    body = {"utterances": [{"start": 0, "end": 1000, "text": "x"}]}
    segs = _assemblyai_segments_from(body)
    assert segs[0].speaker is None


def test_no_utterances_falls_back_to_full_text_single_segment():
    body = {"text": "All as one block.", "audio_duration": 7.0}
    segs = _assemblyai_segments_from(body)
    assert len(segs) == 1
    assert segs[0].text == "All as one block."
    assert segs[0].start == 0.0
    assert segs[0].end == 7.0
    assert segs[0].speaker is None


def test_empty_body_returns_no_segments():
    assert _assemblyai_segments_from({}) == []
    assert _assemblyai_segments_from({"text": "   "}) == []
