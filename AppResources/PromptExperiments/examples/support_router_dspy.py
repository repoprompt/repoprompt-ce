"""A real DSPy program for Prompt Lab's DSPy runner (dspy==3.4.1).

Use an existing project interpreter with that version installed. RPCE describes the
program's named predictors automatically, evaluates candidate instructions in this
program, and can export normal DSPy state for program.load_state(artifact["state"]).
No model client or credentials are embedded in the exported state.
"""

import dspy

OBJECTIVE = "Preserve support routing accuracy while reducing input and output tokens."
CRITERIA = "The program predicts the independently supplied correct support category."
EXAMPLES = [
    {"id": "train_invoice", "split": "training", "input": "Please send my invoice for last month.", "category": "billing"},
    {"id": "train_crash", "split": "training", "input": "The app crashes whenever I upload a picture.", "category": "technical"},
    {"id": "val_password", "split": "validation", "input": "I forgot my password. How can I reset it?", "category": "account"},
    {"id": "val_refund", "split": "validation", "input": "I was charged twice and need a refund.", "category": "billing"},
    {"id": "test_profile", "split": "hidden_test", "input": "Please help me change the email address on my profile.", "category": "account"},
    {"id": "test_export", "split": "hidden_test", "input": "Exporting a report produces a blank file.", "category": "technical"},
]


class RouteSupport(dspy.Signature):
    """Route the support request to billing, technical, or account based on its primary issue."""

    message: str = dspy.InputField()
    category: str = dspy.OutputField(desc="Exactly one of: billing, technical, account")


def build_program(context):
    return dspy.Predict(RouteSupport)


def make_inputs(example):
    return {"message": example["input"]}


def metric(example, prediction, trace=None):
    correct = prediction.category.strip() == example.category
    return {
        "score": float(correct),
        "feedback": "Correct category." if correct else f"Expected category {example.category}.",
    }
