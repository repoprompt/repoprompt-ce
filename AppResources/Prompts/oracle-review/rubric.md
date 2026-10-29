# Oracle Review v1 judge checklist

Review only the supplied frozen files, diff and stated contract. The reference describes the essential finding or why a clean change should pass; it is not wording the answer must copy. Reward evidence and restraint. Do not require findings when the change is correct. Treat optional test suggestions as suggestions, not execution evidence. A check about findings passes when there are correctly no findings.

## Checks

- `correct_outcome` (weight 4): Does the review identify the concrete defect described by the reference, or correctly report no demonstrated defect for a clean change?
- `trigger_and_impact` (weight 3): For each defect, does it explain a reachable trigger and the resulting behavior using the supplied contract and code?
- `specific_location` (weight 2): Does each finding name the relevant supplied file and function or line?
- `smallest_fix` (weight 2): Does each finding give a concrete correction to its root cause without unrelated redesign?
- `no_false_positives` (weight 4): Is the review free of invented defects, unsupported repository assumptions and findings contradicted by the explicit product contract?
- `severity_and_grouping` (weight 1): Are consequential defects prioritized and findings sharing a root cause grouped, with style suggestions kept proportionate?
- `honest_evidence` (weight 2): Does the review distinguish evidence from inference and avoid claiming to have run tests or inspected unavailable files?
- `verdict` (weight 1): Does it provide a clear final verdict consistent with the findings?
- `concise` (weight 1): Is the answer proportionate, with no padded findings or unnecessary restatement?
