---
name: question-type-analysis
description: Classify tracked GVF question content using semantic multi-label annotation and export CSV statistics; when requested, examine how QA supports cross-version comparison and exploration.
---

# Question Type Analysis

Analyze what the tracked GVF questions ask about. Produce auditable
annotations and per-generation statistics using the taxonomy below.

Check the prompts used by the analyzed run, including changes during
evolution. QuestionModule asks about observable properties that Frozen QA
answers independently for each version. MetaAgent combines those answers
and training history to compare versions and decide what to change.
A question can support comparison or exploration without explicitly
requesting either. Classify its content separately from how its answers
are used.

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
   content category, with each category counted at most once per question.
   For questions phrased as comparisons or proposals, classify their subject;
   this does not establish that MetaAgent performed the comparison or change.
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
  -> [2]
- "What alternative to repeated voting should we try next?" -> [2]
- "How many false accepts and false rejects occurred?" -> [5]
- "Which review criteria are cited in the misclassified examples?" -> [2, 5]
- "How many predictions are accept or reject, and are any invalid?" -> [1, 5]

## Information use, when requested

Analyze these functions separately from question content, using QA answers,
MetaAgent records, and patches:

- **Cross-version analysis:** compare answers about the same property across
  identified versions. Distinguish differences or similarities in the answers
  from evidence that MetaAgent actually compared them. Account for different
  training samples and stochastic outputs when interpreting results.
- **Exploration support:** trace QA information to a concrete proposed change
  or search direction. Distinguish a proposal from its implementation in a
  patch, and a repair or parameter adjustment from a new decision mechanism.

Cite source locations and version IDs. Potential usefulness alone does not
establish use, and a later code change alone does not show that QA motivated
it. State when evidence is insufficient. Assess use separately for each
generation, even when question IDs repeat.

## Aggregation

For generation g and category k:

- `n_questions`: number of tracked questions in that generation.
- `count_k`: number of those questions assigned category k.
- `total_labels`: sum of the three content-category counts (IDs 1, 2, 5).
- `label_share_k`: `count_k / total_labels`.

The default metric is **label share**, not question coverage.
Store shares as fractions from 0 to 1.

Example: four questions with labels [1], [1], [1, 2], [1] produce
five labels and shares of 0.8, 0.2, 0 in category order 1, 2, 5.

If question coverage is requested, calculate it separately as
`count_k / n_questions`. Coverage can sum to more than 100% under
multi-label classification. Never interchange the two metrics.
Information-use findings are not included in the content-share denominator.

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
- `predictive_behaviour_count`
- `predictive_behaviour_label_share`
- `question_annotations`
- `source_questions_path`

Store `question_annotations` as a JSON array containing each question's
`question_id`, sorted `types`, and `rationale`.

If information-use analysis is requested, export its findings to a separate
CSV with `generation,question_id,function,finding,evidence`. Use
`cross_version_analysis` or `exploration_support` for `function`; include
source paths, locations, and version IDs in `evidence`.

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

The default content analysis covers the formal tracked questions.
Information-use analysis separately examines QA answers, MetaAgent records,
and implemented changes. Content-label frequencies do not establish how
much cross-version comparison or exploration MetaAgent performed.

Label share is not token share, attention allocation, usefulness, or
causal contribution to performance. Long and short questions each count
once per assigned category.

Semantic labels remain judgments. Preserve the rubric, annotations,
and rationales so later analyses can be reviewed consistently.
