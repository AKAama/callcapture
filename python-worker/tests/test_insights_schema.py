import pytest
from pydantic import ValidationError

from app.schemas.models import ConversationAnalysis, Insights


def test_defaults_all_empty():
    i = Insights()
    assert i.title == "Untitled"
    assert i.summary == ""
    assert i.key_points == []
    assert i.action_items == []
    assert i.recommended_actions == []
    assert i.dynamics == ""
    assert i.opportunities == []
    assert i.reflections == []
    assert i.outline == []
    assert i.key_concepts == []
    assert i.qa == []
    assert i.takeaways == []


def test_summary_length_validator():
    with pytest.raises(ValidationError):
        Insights(summary="x" * 501)


def test_frozen_instance():
    i = Insights()
    with pytest.raises(ValidationError):
        i.summary = "nope"


def test_conversation_analysis_carries_insights():
    a = ConversationAnalysis(insights=Insights(title="T", summary="S", key_points=["k"]))
    assert a.insights is not None
    assert a.insights.title == "T"
    assert a.model_dump()["insights"]["summary"] == "S"


def test_conversation_analysis_insights_default_none():
    assert ConversationAnalysis().insights is None
