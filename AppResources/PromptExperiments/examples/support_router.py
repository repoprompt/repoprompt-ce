"""Small importable project experiment, using RPCE's selected execution model.

Select this file with the Python program runner. No API keys or extra packages are
needed by this module. Replace the examples and metric with your application's task.
For your own SDK client, return its full measured input/output counts explicitly;
context.complete already aggregates those counts across execution calls.
"""

SEED_PROMPT = """You route customer support requests. Read the entire customer message
and decide which team is responsible. Use billing for payments, refunds, invoices,
and incorrect charges. Use technical for bugs, crashes, outages, and broken product
behavior. Use account for passwords, signing in, and profile or account changes.
Think about the customer's primary request and select exactly one of those teams.
Your complete response must be exactly billing, technical, or account in lowercase.
Do not include an explanation, punctuation, or any other text."""

OBJECTIVE = "Keep routing accuracy and the one-label output contract while reducing model token use."
CRITERIA = "The routing label exactly matches the independently supplied expected category."
EXAMPLES = [
    {"id": "train_invoice", "split": "training", "input": "Please send my invoice for last month.", "expected_output": "billing"},
    {"id": "train_crash", "split": "training", "input": "The app crashes whenever I upload a picture.", "expected_output": "technical"},
    {"id": "val_password", "split": "validation", "input": "I forgot my password. How can I reset it?", "expected_output": "account"},
    {"id": "val_refund", "split": "validation", "input": "I was charged twice and need a refund.", "expected_output": "billing"},
    {"id": "test_profile", "split": "hidden_test", "input": "Please help me change the email address on my profile.", "expected_output": "account"},
    {"id": "test_export", "split": "hidden_test", "input": "Exporting a report produces a blank file.", "expected_output": "technical"},
]


def evaluate(candidate, example, context):
    completion = context.complete([
        {"role": "system", "content": candidate},
        {"role": "user", "content": example["input"]},
    ])
    actual = completion["output"].strip()
    expected = example["expected_output"]
    correct = actual == expected
    return {
        "score": float(correct),
        "feedback": "Correct routing and format." if correct else f"Expected exactly {expected}; preserve the one-label contract.",
        "output": completion["output"],
    }
