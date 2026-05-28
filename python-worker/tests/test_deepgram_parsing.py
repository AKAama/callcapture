"""Tests for the Deepgram response-mapping helpers.

The HTTP call needs a live key; we test the deterministic parts — query-string
building (language fallback to `multi` for unsupported codes) and the response
mapping (paragraphs preferred, word-grouping fallback, flat-transcript fallback).
"""

from __future__ import annotations

from app.transcribe.remote_engine import (
    _deepgram_params,
    _deepgram_segments_from,
)


# ---- query params --------------------------------------------------------


def test_params_use_language_multi_for_auto():
    p = _deepgram_params(language="auto", model="nova-3")
    assert p["language"] == "multi"
    assert p["model"] == "nova-3"
    assert p["diarize"] == "true"
    assert p["sentiment"] == "true"


def test_params_pass_through_supported_language():
    p = _deepgram_params(language="uk", model="nova-3")
    assert p["language"] == "uk"


def test_params_fall_back_to_multi_for_unknown_language():
    """Sending an unknown code would be rejected with a 400. Fall back instead."""
    p = _deepgram_params(language="xx", model="nova-3")
    assert p["language"] == "multi"


# ---- response parsing ----------------------------------------------------


def _body_with_paragraphs() -> dict:
    return {
        "results": {
            "channels": [
                {
                    "alternatives": [
                        {
                            "transcript": "Hello there. Hi back.",
                            "paragraphs": {
                                "paragraphs": [
                                    {
                                        "speaker": 0,
                                        "start": 0.0,
                                        "end": 2.0,
                                        "sentences": [{"text": "Hello there."}],
                                    },
                                    {
                                        "speaker": 1,
                                        "start": 2.1,
                                        "end": 3.5,
                                        "sentences": [{"text": "Hi back."}],
                                    },
                                ]
                            },
                        }
                    ]
                }
            ]
        }
    }


def test_prefers_paragraphs_with_speaker_labels():
    segs = _deepgram_segments_from(_body_with_paragraphs())
    assert len(segs) == 2
    assert segs[0].speaker == "Speaker 0"
    assert segs[0].text == "Hello there."
    assert segs[1].speaker == "Speaker 1"


def test_word_grouping_fallback_groups_by_speaker():
    body = {
        "results": {
            "channels": [
                {
                    "alternatives": [
                        {
                            "transcript": "hi there hello",
                            "words": [
                                {"word": "hi", "punctuated_word": "Hi",
                                 "start": 0.0, "end": 0.5, "speaker": 0},
                                {"word": "there", "punctuated_word": "there",
                                 "start": 0.5, "end": 1.0, "speaker": 0},
                                {"word": "hello", "punctuated_word": "Hello",
                                 "start": 1.2, "end": 1.6, "speaker": 1},
                            ],
                        }
                    ]
                }
            ]
        }
    }
    segs = _deepgram_segments_from(body)
    assert len(segs) == 2
    assert segs[0].speaker == "Speaker 0"
    assert segs[0].text == "Hi there"
    assert segs[1].speaker == "Speaker 1"
    assert segs[1].text == "Hello"


def test_flat_transcript_single_segment_fallback():
    body = {
        "results": {
            "channels": [
                {
                    "alternatives": [
                        {"transcript": "All as one block."}
                    ]
                }
            ]
        }
    }
    segs = _deepgram_segments_from(body)
    assert len(segs) == 1
    assert segs[0].text == "All as one block."
    assert segs[0].speaker is None


def test_empty_or_malformed_returns_empty_list():
    assert _deepgram_segments_from({}) == []
    assert _deepgram_segments_from({"results": {}}) == []
