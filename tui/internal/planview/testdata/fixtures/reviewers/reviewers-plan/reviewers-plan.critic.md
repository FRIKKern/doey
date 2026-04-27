# Critic review

Watch-budget exhaustion fallback is unspecified — the discovery layer
walks the entire `${RUNTIME_DIR}/status/` tree on every render, which
is fine today but should be capped explicitly to bound the worst case.
Please add a guard before merging.

**Verdict:** REVISE
