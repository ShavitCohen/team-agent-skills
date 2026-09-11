<!-- shared-component: browser.md v1 sha256=fec9f66ee56b04f4e364bdd46af2506f5d00cf3f33bf81006ce9b3d8bdcebef8 -->
# Browser validation via an isolated local workflow

Any run that verifies browser-visible behavior uses this policy.

Use the repository's documented isolated local workflow and deploy or serve the **exact** reviewed or
built revision. Prefer the project convention when several supported workflows exist. Use local
Kubernetes when the repository or project convention selects it; never impose Kubernetes on a project
that documents another isolated local workflow.

## Availability detection

Before the first environment action, detect availability:

- the required CLI and runtime are installed;
- the repository documents the selected local workflow;
- the workflow can isolate this run from other runs;
- when Kubernetes is selected, a current context exists and is positively identified as a local,
  single-user development cluster.

**If the selected workflow is unavailable, ask the user** rather than skipping verification or
improvising. Present the detected situation and these options:

1. install or start the documented local environment, then continue;
2. use a different local run mode the repository supports, naming it;
3. point the run at a user-supplied local URL that already serves the correct revision;
4. skip browser validation, and record it as **not performed** in every report.

Never silently substitute an alternative, and never claim browser verification that did not run.

## Before local-environment mutations

- obtain explicit permission for deployment and later cleanup when the user has not already granted
  them;
- inspect the selected environment; for Kubernetes, inspect the context, cluster endpoint, and provider
  evidence rather than trusting a context name alone;
- continue only for an unambiguously local, isolated environment;
- fail closed for shared, remote, production, or ambiguous environments;
- record pre-existing namespaces and relevant workloads, and preserve them;
- use safe synthetic data, never production secrets or real user data.

## Provenance

Prove deployment provenance by recording the full revision SHA, build command, image ID or digest,
workload image references, pod readiness, and relevant runtime configuration. Do not infer provenance
from mutable tags such as `latest` or `local`.

## Cleanup

Clean up only resources the run created, and only under the user's stated cleanup authorization. Label
created resources with project, skill, run identifier, and revision so ownership remains provable if
the registry is lost. Never delete pre-existing namespaces, clusters, services, data, or processes.

## Local Kubernetes machine-capacity gate

Apply a read-only capacity gate before cloning, building, starting a container runtime, or creating a
cluster, whenever the selected workflow would create a new local Kubernetes environment.

Measure logical CPU capacity and current load, total and currently available memory, free disk on the
filesystem that will hold source and images, container-runtime CPU and memory allocation when running,
required CLIs, and available local-cluster providers. Start from conservative defaults of four logical
CPUs, eight GiB host memory, four GiB currently available memory, six GiB container-runtime memory,
four runtime CPUs, and twenty GiB free disk. Raise those values when the repository documents larger
requirements; never lower a documented requirement silently.

Classify the result:

- **`proceed`** — every required metric and tool is adequate.
- **`caution`** — pressure or a missing measurement makes success uncertain. Explain it, recommend not
  running when the risk is material, and obtain the user's decision before environment mutation.
- **`do-not-run`** — a required tool or capacity threshold fails. Do not start or modify Kubernetes;
  report the measured blocker and recommend freeing resources, increasing runtime allocation, or using
  a stronger machine.

The gate is host-capacity evidence, not proof that a Kubernetes context is safe. Independently prove
that the selected endpoint and provider are local and single-user. Report context locality as
unverified until that proof exists. Sample capacity again immediately before deployment when near a
threshold and after pods become ready, and stop safely if the deployment begins exhausting the machine.

## Concurrency

Derive the namespace and release name from the run identifier so two runs never deploy over each other,
resolve URLs and ports from the deployment output rather than a fixed port, and delete only the
namespace and resources that run created. When the repository's local workflow supports only one shared
instance, that instance is a mutual-exclusion resource: take a resource lock on it, or ask the user,
and never assume it is idle.
