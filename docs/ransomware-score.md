# Ransomware Readiness Score — Rationale

[Back to the README](../README.md)

This page documents the design of the Ransomware Readiness Score introduced in v2.0. It is meant for readers who need to understand **why the score is what it is** before acting on it — particularly security and risk officers who are deciding whether to use it as input for investment decisions.

## Design intent

The score answers one question: **"if a ransomware attack reached the K10 namespace right now, how well-positioned is the operator to recover?"**

It deliberately does **not** answer:

- "Is this deployment compliant with framework X?" (NIS2, DORA, ISO 27001 etc. — each has its own evaluation methodology)
- "How likely is a successful attack?" (this is a threat-modelling question, not a posture question)
- "Is the data on the source cluster safe?" (the score evaluates K10's resilience, not the cluster's overall security)

The score is a **synthesis indicator**. Its job is to compress a multi-page audit into a single artefact that a CISO can read in 10 seconds and that drives the right follow-up conversation.

## Pillar selection

The 8 pillars were selected to cover three layers of ransomware defence:

| Layer                  | Pillars                                                      | Total weight |
|------------------------|--------------------------------------------------------------|--------------|
| **Recovery capability**| Immutability, Off-cluster export, Disaster Recovery          | 50/100       |
| **Access control**     | Authentication, KMS encryption, Network policies, TLS verif. | 40/100       |
| **Detection / forensics** | Audit logging                                             | 10/100       |

This split (50/40/10) reflects an opinionated stance: **even with perfect access control, an operator without immutable, off-cluster, restorable backups is exposed**. The recovery layer therefore carries the largest cumulative weight. Detection is weighted last because audit logging — useful as it is — does not stop an attack in progress; it informs post-mortem.

## Per-pillar rationale

### Immutability (20 points) — heaviest weight

**Why heaviest**: an attacker with valid credentials can issue `kubectl delete` against backups stored on a mutable target. WORM / object-lock / retention-lock is the single technical control that makes destruction infeasible. Without it, the entire backup chain has the same blast radius as the source cluster.

**Evidence rule**: at least one Location Profile with a non-zero `protectionPeriod` (any value > 0 hours / 0 days). Binary signal — no partial credit. A profile with `protectionPeriod: 0` scores zero on this pillar.

**Known limitation**: KDL does not verify that the bucket-side configuration actually honours the requested protection period. A profile may declare `168h` but point to a bucket without object lock — KDL cannot detect this without listing bucket policies. Operators must cross-check on the storage side.

### Off-cluster export (15 points)

**Why 15**: if the entire cluster is destroyed (volume encryption, control-plane compromise, datacenter loss), local snapshots are unrecoverable. An export to a remote location is the prerequisite for full-cluster DR. It is weighted below immutability because it is necessary-but-not-sufficient (a mutable off-cluster copy is still attackable).

**Evidence rule**: at least one policy with an `export` action. Counts any export, regardless of frequency or retention quality.

**Known limitation**: KDL does not check whether the export target is in the same failure domain as the cluster. An export from cluster A in AZ-1 to a MinIO bucket also in AZ-1 satisfies the pillar but does not satisfy the design intent. Operators must validate geographic separation manually.

### Authentication (15 points)

**Why 15**: an unauthenticated K10 dashboard is a direct path to deletion. An attacker who reaches the dashboard URL can browse, configure profiles, and trigger arbitrary policy runs. Weighted the same as off-cluster export because both are binary gates between the attacker and the data.

**Evidence rule**: `AUTH_METHOD != "none"`. Accepted methods: OIDC, LDAP, OpenShift OAuth, Basic Auth, Token. No quality differentiation between methods at this version — Basic Auth scores the same as OIDC (a known coarseness, see "Limitations" below).

### Disaster Recovery (15 points)

**Why 15**: restores from immutable backups cannot proceed without a functioning K10 control plane. If the catalog and metadata are lost with the cluster, the backups become unindexed blob storage. KDR (Quick DR or Legacy) is the mechanism that restores the catalog itself.

**Evidence rule** *(v2.0, tightened)*: the `k10-disaster-recovery-policy` must be present **and the KDR effective-health verdict must be `ENABLED`** — i.e. the config can actually protect data and the last KDR run succeeded recently. A present-but-incomplete (`CONFIGURED_INCOMPLETE`, e.g. *Quick DR — No Snapshot*) or unhealthy (`CONFIGURED_NOT_HEALTHY`) KDR earns **0 points**, since it would not restore the catalog in a real incident. This avoids a misleading full DR score next to a "config cannot protect data" verdict. See the KDR verdict definition in the Disaster Recovery output section.

### Audit logging (10 points)

**Why 10**: audit logging does not prevent or stop an attack, but it dramatically shortens forensic investigation and helps the operator identify which credentials were used, when, and against which resources. Weighted at 10 to reflect "important for post-incident, not for prevention".

**Evidence rule**: K10-specific audit configuration detected — either cluster logging or S3 export. Does **not** include OpenShift / Kubernetes cluster-wide audit logging (which is good practice but doesn't capture K10-internal operations).

### KMS encryption (10 points)

**Why 10**: data-at-rest encryption protects against backup media theft and adds a defence layer if an attacker exfiltrates raw blocks. Less weight than immutability because it does not protect against deletion — an encrypted backup can still be deleted. Weighted at 10 to reflect "useful defence-in-depth but not a recovery enabler".

**Evidence rule**: KMS provider detected — AWS KMS CMK, Azure Key Vault, or HashiCorp Vault Transit.

### Network policies (10 points)

**Why 10**: K8s NetworkPolicies restrict east-west reach into the K10 namespace, reducing the attack surface for compromised workloads elsewhere on the cluster. Useful hardening, but not a recovery control.

**Evidence rule**: at least one NetworkPolicy in the K10 namespace.

### TLS verification (5 points)

**Why 5**: a profile with `skipSSLVerify=true` opens a MITM window when uploading backups — an attacker on the path can intercept or substitute data. The attack is opportunistic and narrow; hence the low weight. But it's binary and easily fixed, so it appears in the score as an actionable signal rather than buried in a config dump.

**Evidence rule**: zero profiles with `skipSSLVerify=true` (or equivalent `skipCertVerification`). **Any** non-verifying profile zeros the pillar — it is not a percentage of profiles.

## Grade thresholds

| Grade | Range  | Interpretation                                                                 |
|-------|--------|--------------------------------------------------------------------------------|
| A     | ≥ 85   | Excellent posture. All critical recovery + access controls in place.           |
| B     | 70-84  | Good posture, minor gaps. Typically one of {audit, encryption, netpol, TLS}.   |
| C     | 55-69  | Acceptable, several improvements needed. Often missing recovery layer items.   |
| D     | 40-54  | Significant gaps. Likely missing at least one of {immutability, export, DR}.   |
| F     | < 40   | Critical exposure. Recovery layer largely absent.                              |

Thresholds are aligned with CISO-communication conventions (letter grades familiar to non-technical stakeholders). The 15-point bands match the size of the largest single-pillar improvement an operator can make in one step (e.g. adding immutability = +20, jumping from D to B).

## Known limitations

These are limitations the operator should be aware of before using the score for decisions:

1. **Coarse evidence rules.** Pillars are binary: a pillar is either fully scored or zero. There is no partial credit for "Authentication: Basic" vs "Authentication: OIDC", or for "Immutability: 24h" vs "Immutability: 1 year". A future version may introduce sub-scoring within pillars.

2. **No defence-depth verification.** KDL detects configuration **presence**, not configuration **effectiveness**. An immutable profile pointing to a bucket without object-lock still scores 20. An OIDC integration with a wildcard group binding still scores 15. Validation of the *quality* of each control is out of scope.

3. **No threat-model fit.** The same score applies to a regulated financial institution and a dev/test cluster — but their threat models are radically different. Operators in regulated industries should weight pillars higher (e.g. immutability at 30, audit at 20). Operators in dev/test can de-emphasise recovery and use the score as a hygiene check only.

4. **No temporal dimension.** A grade A today does not mean grade A tomorrow. Use `kdl-diff.sh` to track changes over time. A drop from A to B between quarterly snapshots is a meaningful signal — a static grade A is not.

5. **OpenShift audit logging is not detected.** The audit pillar checks for K10-specific audit configuration (S3 export, K10 cluster logging configmap), not for OpenShift cluster-wide audit logging. An OpenShift cluster with comprehensive audit logging may show "audit logging FAIL" — this is by design (the K10-specific signal is what matters for K10-internal forensics) but it surprises operators who expect the score to credit cluster-level controls.

## Customising the score for your organisation

The score is currently fixed in code. If you need different weights for your threat model:

- **Option 1**: fork the script and modify `RANSOM_*_MAX` constants (lines around 3132-3180 of `KDL.sh`). The pillar evidence rules remain the same; only weights change.
- **Option 2**: ignore the synthesised grade and consume `ransomwareReadiness.pillars.*.evidence` directly. Each pillar exposes a boolean — you can build your own scoring logic on top.
- **Option 3**: use the score as a trend indicator only (via `kdl-diff.sh`), ignoring the absolute value.

## Versioning of the rationale

The pillar set and weights are stable for the v2.x series. If the methodology changes (new pillars, re-weighting, threshold adjustments), it will be documented in a new appendix and the JSON output will carry a `ransomwareReadiness.methodologyVersion` field. v2.0 corresponds to methodology version 1.
