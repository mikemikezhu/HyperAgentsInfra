---
name: question-type-analysis
description: Classify tracked GVF questions across HyperAgents generations using semantic multi-label annotation and export traceable per-generation CSV statistics.
---

# Question Type Analysis

Analyze what the tracked GVF questions ask about. Produce auditable
annotations and per-generation statistics using the taxonomy below.

## Inputs and scope

Identify the experiment run directory, generation range, and output path
from the user's request and available context.

Read questions from:
`gen_<generation>/agent_output/questions.json`

Keep different runs and methods separate unless the user requests pooling.
Report the exact run and generations analyzed. Do not assume that an
existing analysis CSV represents the latest experiment.

Analyze the tracked question set in each generation, including inherited
questions. This measures the distribution of active questions, not only
newly introduced questions.

Do not assume a fixed number of questions or generations.

## Classification taxonomy

Use these stable numeric IDs and CSV prefixes.

Keep all five categories in the same multi-label analysis. Check the
QuestionModule and Frozen QA prompts used by the analyzed run, including
changes during evolution. Questions ask about observable properties that
can be answered independently for each version; MetaAgent performs the
cross-version reasoning and proposes changes. Types 3 and 4 therefore
label how a question supports comparison or exploration, without requiring
it to request those actions explicitly or proving that MetaAgent used it.
They can overlap with types 1, 2, and 5.

### 1. Implementation reliability

CSV prefix: `interface`

Questions about whether the implementation executes correctly and meets
its input/output contract.

Include:

- Input decoding and preservation of the original task text.
- Output schemas, JSON extraction, and label normalization.
- Malformed or missing responses, retries, and exception handling.
- Execution, entrypoint, and patch-delivery correctness.

Parser thresholds and score-to-label conversion belong here when they
concern output interpretation rather than task decision criteria.

### 2. Current policy design

CSV prefix: `policy_mechanism`

Questions describing how the current policy solves the task or allocates
computation.

Include:

- Review criteria, novelty/evidence thresholds, and borderline decisions.
- Reviewer roles, voting, aggregation, adjudication, and early stopping.
- Sampling settings, reasoning budgets, and model-call or tool budgets.

Describing a parser alone does not qualify. Repair belongs here as well
as type 1 when the question also examines its role in decision-making,
such as whether a repair response becomes an additional vote.

### 3. Cross-version analysis

CSV prefix: `history_comparison`

Questions tracking an observable policy property that supports meaningful
comparisons across strategies, as required by the QuestionModule prompt.
Each version can answer the question independently; the question need not
name another version or explicitly ask for a comparison.

Include:

- Decision criteria, reviewer roles, voting or verification mechanisms,
  and computation allocation expressed in terms that distinguish strategies.
- Observed decision or error patterns tied to an identifiable strategy
  property that can be examined consistently across versions.
- Explicit comparisons of historical policy mechanisms, when present.

In the rationale, identify the property and the strategy contrast its
answers support. Being answerable for each version, mentioning a generation,
or inspecting an output format does not by itself establish a meaningful
strategy comparison. Do not require the observed answers to differ or
MetaAgent to have performed the comparison.

### 4. Exploration

CSV prefix: `exploration`

Questions about observable policy properties or training behavior whose
answers help guide exploration of new strategies, as required by the
QuestionModule prompt. They can diagnose a decision-making limitation
without asking Frozen QA to propose a change.

Include:

- Distinguishing substantive grounds for decisions or errors, such as
  evidence about the central claim versus presentation-only objections,
  to inform which decision strategy should be investigated.
- Examining associations between a reasoning, review, or model-call
  mechanism and observed decisions, where the answer distinguishes
  alternative strategy directions.

In the rationale, identify the diagnostic distinction and the strategy
choice it can inform. Generic usefulness, an error count alone, or a
format/repair audit alone is insufficient. A new strategy need not already
have been proposed or implemented. Do not require questions to contain
proposed changes or assumed causes of performance: the prompt leaves
those inferences to MetaAgent.

### 5. Predictive Behaviour

CSV prefix: `predictive_behaviour`

Questions about observed task predictions, their distribution, and errors.

Include:

- Predicted label counts or proportions, including comparisons with targets.
- Correctness, error directions, and patterns across correct or incorrect cases.
- Decision grounds expressed in actual predictions or misclassified examples.
- Observed verdict changes after verification and whether they improve correctness.

Questions about decision rules in code or prompts alone remain type 2.
When a question also examines decision grounds in actual outputs, assign
both types 2 and 5. Output parsing, schema, and execution-failure audits
alone remain type 1; also assign type 5 when the question separately asks
about task-label distributions or prediction errors.

## Annotation procedure

1. Extract each question's ID, text, generation, and source path.
2. Deduplicate by question ID within the analysis scope. Check that
   repeated IDs have identical text; report conflicts rather than
   silently merging them.
3. Classify each unique question semantically. Assign every applicable
   category, with each category counted at most once per question.
4. Record a short rationale grounded in what the question actually asks.
5. Reuse the annotation whenever the same question reappears, then
   expand annotations back to each generation.

Use the assistant for semantic annotation and deterministic code for
aggregation. When reproducing an existing analysis, reuse its saved
annotations after checking the question IDs, texts, and classification
rules; reclassification is a separate analysis choice.

Do not force questions into mutually exclusive categories or use keyword
matching as the final classifier. Do not infer labels from candidate
accuracy, generation number, or an expected early/late-stage pattern.

If a question remains ambiguous or outside the taxonomy, flag it for
review rather than silently assigning a label or dropping it from the
statistics. Disclose unresolved cases and treat affected rows as
incomplete rather than presenting their shares as final.

Examples:

- "Which JSON wrappers can the parser accept?" -> [1]
- "Does this version use a single review, independent votes, or a
  verification call to decide?" -> [2, 3]
- "Does repair only fix formatting, or does its verdict enter the vote?"
  -> [1, 2, 3]
- "On misclassified papers, does the verdict rely on presentation issues
  or substantive evidence about the central claim?" -> [2, 3, 4, 5]
- "How many false accepts and false rejects occurred?" -> [5]
- "How many predictions are accept or reject, and are any invalid?" -> [1, 5]

## Aggregation

For generation g and category k:

- `n_questions`: number of tracked questions in that generation.
- `count_k`: number of those questions assigned category k.
- `total_labels`: sum of the five category counts (IDs 1, 2, 3, 4, 5).
- `label_share_k`: `count_k / total_labels`.

The default metric is **label share**, not question coverage.
Store shares as fractions from 0 to 1.

Example: four questions with labels [1], [1], [1, 2], [1] produce
five labels and shares of 0.8, 0.2, 0, 0, 0 in category order 1 through 5.

If question coverage is requested, calculate it separately as
`count_k / n_questions`. Coverage can sum to more than 100% under
multi-label classification. Never interchange the two metrics.

Missing files are missing observations, not zero counts. An empty
question set has zero counts and undefined shares; report this explicitly.

## Output

Save the analysis as a standalone CSV file at the requested output path.
For multiple runs, produce one CSV per run unless pooling is requested.

Each row represents one generation. Preserve these column names and order:

- `generation`
- `n_questions`
- `total_labels`
- `interface_count`
- `interface_label_share`
- `policy_mechanism_count`
- `policy_mechanism_label_share`
- `history_comparison_count`
- `history_comparison_label_share`
- `exploration_count`
- `exploration_label_share`
- `predictive_behaviour_count`
- `predictive_behaviour_label_share`
- `question_annotations`
- `source_questions_path`

Store `question_annotations` as a JSON array containing each question's
`question_id`, sorted `types`, and `rationale`.

Preserve source paths so each annotation can be checked against the
original question text. Report both the number of question occurrences
and the number of unique question IDs.

Validate that:

- Every source question is accounted for.
- Counts agree with the per-question annotations.
- `total_labels` equals the sum of category counts.
- Shares sum to 1 whenever the denominator is positive and annotations
  are complete.
- Repeated questions receive consistent annotations.

After saving, report the CSV path, the experiment run and generation
range covered, and any missing or unresolved records.

## Interpretation limits

This analysis covers the formal tracked questions. It does not classify
Frozen QA answers, QuestionModule reasoning, MetaAgent reasoning, or
implemented policy changes.

A zero exploration-question count does not establish that the agent
performed no exploration. Likewise, few cross-version questions do not
establish that the MetaAgent failed to compare historical candidates.

Label share is not token share, attention allocation, usefulness, or
causal contribution to performance. Long and short questions each count
once per assigned category.

Semantic labels remain judgments. Preserve the rubric, annotations,
and rationales so later analyses can be reviewed consistently.
