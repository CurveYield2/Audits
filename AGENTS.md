# Audits Repository Agent Policy

Policy version: v1

This repository stores audit outputs and supporting audit material. It is not a scratch workspace or a place to run uncontrolled retries.

- Before creating a file, inspect the existing audit directory and reuse/update the canonical output when mutation is permitted.
- Do not create repeated `report-v2`, `report-v3`, `final`, `fixed`, `retry`, copied summaries, or repeated analysis files merely because an attempt failed.
- Keep only the current live operational/report version unless an audit authority, publication requirement, or immutable evidence rule explicitly requires historical versions.
- Do not delete sealed/signed/required historical audit evidence solely for cleanup.
- Put every file inside the audit it belongs to; do not dump audit-specific material at repository root or into another audit's directory.
- Do not repeatedly analyze unchanged source/evidence. Re-analysis requires changed source, changed evidence, or an explicit review requirement.
- Before starting any external workflow/simulation/browser execution associated with an audit, inspect active runs and do not start a duplicate same-kind execution for the same audit/target.
- After two materially identical failures with unchanged code/inputs/environment, stop rerunning and diagnose before another attempt.
- Temporary diagnostics belong in runtime/artifact storage rather than permanent audit output unless they are required evidence.
- Before completion, remove superseded operational duplicates and leave one clear current report/state per purpose.
