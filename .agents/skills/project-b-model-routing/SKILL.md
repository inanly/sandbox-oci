---
name: project-b-model-routing
description: Choose model-specific subagents for implementation, testing and documentation inside the sandbox-oci Project B repository.
---

Use Astra Low for coordination and correctness-sensitive rootfs/containerd work. Use Terra Medium for bounded implementation, fixtures and tests; Luna Medium for concise documentation and repetitive edits. Preserve a task's explicit Sol Medium assignment. Escalate unresolved cross-component or runtime correctness problems to Astra High with a minimal reproduction and evidence.

The main conversation's model is selected by the user; do not claim this skill switches it. Select supported model and reasoning effort explicitly when spawning workers. Different-model workers receive a standalone task or limited context, not a full-history fork.

Delegate only an independently executable bounded task while the coordinator has useful work. Tiny searches and edits stay local. Maximum three workers plus coordinator; workers do not recursively delegate. Assign disjoint file ownership. Only the coordinator mutates the shared Docker/kind environment.

Include objective, allowed paths, interfaces and acceptance criteria in each assignment. Require changed files, actual checks and unresolved issues in the report. Announce actual worker model and reason. If a model is unavailable, disclose it before using a materially different fallback.

Escalate when the task needs an unassigned design decision or a failed fix repeats the same problem. Do not repeatedly retry without new evidence. Review core semantics and API changes; do not repeat every worker operation. Never infer subscription savings from API pricing.
