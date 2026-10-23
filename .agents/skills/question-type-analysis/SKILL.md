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

Questions explicitly comparing historical versions or examining patterns
across the search history.

Include:

- Current versus earlier policy mechanisms or prompt clauses.
- Previously attempted policy families or recurring modification patterns.
- Strategy differences between historical candidates.

Local current-versus-original comparisons qualify; a question need not
summarize the entire search history.

Mentioning a generation number alone does not qualify. Comparing two
components within the same version does not qualify. Conversation
`msg_history` is not automatically evolutionary search history.

### 4. Exploration

CSV prefix: `exploration`

Questions explicitly requesting new strategy hypotheses, alternative
policy families, or a choice of future search direction.

Include:

- Asking which different decision process should be tried.
- Proposing an untried mechanism to address a failure mode.
- Asking whether to change policy families rather than tune the
  current mechanism.

Describing an existing mechanism or inactive implementation is not
sufficient. A question's potential usefulness for improvement does not,
by itself, make it an exploration question.

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
- "How many independent votes are collected before early stopping?" -> [2]
- "Does repair only fix formatting, or does its verdict enter the vote?"
  -> [1, 2]
- "How does the current voting rule differ from the original version?"
  -> [2, 3]
- "What alternative to repeated voting should we try next?" -> [4]

## Aggregation

For generation g and category k:

- `n_questions`: number of tracked questions in that generation.
- `count_k`: number of those questions assigned category k.
- `total_labels`: sum of the four category counts.
- `label_share_k`: `count_k / total_labels`.

The default metric is **label share**, not question coverage.
Store shares as fractions from 0 to 1.

Example: four questions with labels [1], [1], [1, 2], [1] produce
five labels and shares of 0.8, 0.2, 0, 0.

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
