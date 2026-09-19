# Deployment and Operations Migration Report

## Summary

On 2026-09-19 this repository was migrated from its original, standalone ACK deployment toolchain to the Galileo deployment and maintenance contract used by [highopes/alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni).

The migration is repository-only. No command in this work changed the running ACK cluster, namespace, Deployment, Secret, ConfigMap, Service, image, prompt state, Terraform state, Alibaba Cloud resource, Pinecone object, or Splunk AO control-plane object.

The result has one supported ACK application workflow:

```bash
cp kup.conf.example kup.conf
# Fill the private config and place the project-private ACK kubeconfig at ./kubeconfig.
./kup --galileo-only
```

Ongoing prompt maintenance uses the same commands as the ACK repository:

```bash
./scripts/switch_prompt.sh status
./scripts/switch_prompt.sh baseline
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
./scripts/switch_prompt.sh improved
```

## Authority and comparison baseline

The local read-only comparison source was:

```text
/Users/hangwe/Library/CloudStorage/OneDrive-Cisco/dev/ack-byocni
branch: main
commit: 646f74e057a2c35bdf21fb598c14d51c84327018
```

The reference repository remained clean before and after this migration. It was not edited.

Only the Galileo-specific portion of that repository was brought back here. Terraform, VPC, ACK Worker, Cilium, Hubble, Timescape, Tetragon, mini-boutique and `kiall` remain exclusively owned by `alicloud-ack-byocni` and were intentionally not copied.

## Before and after

| Concern | Previous repository method | Current shared method |
|---|---|---|
| Private configuration | `.deploy.env` plus multiple `.secrets/*.env` and `.runtime/resolved-*.env` files | one ignored `kup.conf` |
| Variable namespace | mixed `ACK_*`, `ACR_*`, `DOCKERHUB_*`, `VLLM_*`, `BAILIAN_*` and application names | the same `GALILEO_*` contract as the ACK repository |
| ACK selection | inspect sibling Terraform state and dynamically discover/regenerate kubeconfig | explicit project-private `kubeconfig` plus stable `ACK_CONTEXT` |
| Deploy/update | separate ACK and generic-Kubernetes deploy scripts | `./kup --galileo-only` |
| Kubernetes templates | four files under `deploy/k8s` plus separate Secret rendering | `ns_galileo/multi-agent-banking.yaml` plus ephemeral Secret creation |
| Registry Secret | generic `registry-pull` selected by multiple image flows | `galileo-registry-pull`, matching the ACK repository |
| Image policy | local build/push workflows and resolved image files | prepublished immutable `linux/amd64` `@sha256:` image only |
| Runtime change rollout | separate generated runtime files and apply scripts | shared Pod-input checksum contract |
| Prompt maintenance | script depended on the old ACK discovery chain | same `kup.conf` bootstrap and `baseline/improved/custom` state model |
| Access | standalone port-forward script | explicit `kubectl --kubeconfig ... --context ... port-forward` |
| Cluster lifecycle | application repo could inspect sibling infrastructure state | no cluster lifecycle code in this repository |

## Shared configuration contract

`kup.conf.example` contains all 27 `GALILEO_*` keys from the reference `kup.conf.example`, with identical public values and meanings. Automated comparison found no missing, extra, or different Galileo assignment.

The shared variables cover:

- namespace, source URL and full source commit;
- immutable image reference and registry pull credential;
- Splunk AO key, Project, Agent Stream and console URL;
- application model provider, model ID, endpoint, key, timeout and retry count;
- Pinecone key, index, namespace and text field;
- Experiment Evaluator list and optional Dataset;
- initial prompt profile, baseline variant and prompt convergence timeout;
- local port-forward port.

This repository adds only the connection values needed to use that contract without owning the cluster: `KUP_WORKDIR`, `KUBECONFIG_FILE`, `ACK_CONTEXT`, `TEST_NAMESPACE`, `RUNTIME_DIR` and `ACK_API_TIMEOUT`.

The private config and kubeconfig are forced to mode 0600. They, rendered files and prompt patch files are Git ignored.

## Current deployment behavior

`./kup --galileo-only` is deliberately the only supported cluster mutation entry in this repository. Running `./kup` without that flag stops with guidance instead of implying that this repository can create ACK infrastructure.

The command performs the following bounded reconciliation:

1. Validates local tools, script syntax and every required Galileo setting.
2. Rejects placeholders, a non-HTTPS model endpoint, unknown model provider, invalid prompt selection, incomplete source SHA, mutable image reference, digest/registry mismatch and multiline Secret values.
3. Uses only the configured private kubeconfig and context to check ACK `/readyz`.
4. Renders the same Namespace, ConfigMap, Deployment and ClusterIP Service topology as the reference repository.
5. Creates the runtime and image-pull Secrets from 0600 temporary files and immediately removes those files.
6. Applies the manifest and waits for the single application Pod to become Ready.
7. Applies the configured prompt through the shared prompt-switching primitive.
8. Verifies the exact image, Service endpoint, cross-namespace HTTP, projected prompt files, application prompt resolver, model identity, Pinecone search and Splunk AO HTTPS.

It does not run Terraform, Alibaba Cloud APIs, Helm, Docker, image push, ACK discovery or cluster add-on operations.

## Resource contract

The rendered manifest is byte-for-byte identical to the reference repository's `ns_galileo/multi-agent-banking.yaml` at the comparison commit. It defines:

- Namespace `${GALILEO_NAMESPACE}`;
- ConfigMap `splunk-ao-banking-qwen-config`;
- Deployment `splunk-ao-banking-qwen` with one replica;
- image pull Secret reference `galileo-registry-pull`;
- runtime Secret reference `splunk-ao-banking-qwen-runtime`;
- projected prompt ConfigMap at `/etc/banking-prompt`;
- non-root UID/GID 999, RuntimeDefault seccomp, no privilege escalation and all capabilities dropped;
- CPU/memory requests and limits matching the ACK repository;
- startup, readiness and liveness TCP probes;
- ClusterIP Service `splunk-ao-banking-qwen`, port 80 to container port 8000.

`GALILEO_POD_INPUTS_CHECKSUM` uses the same ordered runtime input set as the reference implementation. A Secret or ordinary runtime ConfigMap change therefore causes exactly one application rollout. Prompt profile/content is excluded because it is read from a projected ConfigMap and is hot-loaded for new chats.

## Prompt maintenance

`scripts/render_prompt_patch.py` remains byte-for-byte identical to the reference repository. `scripts/switch_prompt.sh` contains the same operational logic and one local bootstrap safeguard: it initializes `SCRIPT_DIR` before sourcing the shared public example, so `KUP_WORKDIR="${SCRIPT_DIR}"` works under `set -u` when the prompt script is invoked directly. This does not alter the cluster contract or prompt state model.

The authoritative runtime state remains the Kubernetes ConfigMap, not a local status file. Supported states are only:

- `baseline`: immutable image's official baseline;
- `improved`: immutable image's improved prompt;
- `custom FILE`: UTF-8 custom prompt stored in the ConfigMap.

Qwen baseline deliberately uses the shared `custom app/prompts/supervisor-baseline-qwen.txt` command. The script validates custom size and content hash, waits for ConfigMap projection/application resolution, and preserves the Pod unless it encounters a legacy Deployment without the projected volume.

## Local application workflow

Local Chainlit, smoke and Experiment helpers now use the same private `kup.conf`:

- `scripts/load_galileo_config.sh` maps `GALILEO_*` values to the unprefixed environment names consumed by the application process;
- `scripts/run_local.sh` starts Chainlit from that mapping;
- `scripts/local_smoke.py` reads the same config directly;
- `scripts/run_experiment.sh` uses the same model, Pinecone, Splunk AO and prompt selection.

There is no second `.env` or resolved-file configuration path. Application-internal environment names remain unchanged because they are the container/runtime interface populated from the shared manifest.

## Removed legacy components

The migration deleted the old deployment and maintenance stack:

- `.agent-context/SPLUNK_AO_ACK_QWEN_TASK.md`
- `.deploy.env`
- root and application `.env.example` files
- all files under `deploy/k8s/`
- `scripts/build_push.sh`
- `scripts/build_push_acr.sh`
- `scripts/push_acr.sh`
- `scripts/deploy_ack.sh`
- `scripts/deploy_kubernetes.sh`
- `scripts/discover_ack.sh`
- `scripts/port_forward.sh`
- `scripts/validate_ack_network.sh`
- `scripts/preflight_models.py`
- `scripts/setup_pinecone.py`
- `scripts/render_k8s.py`
- `scripts/render_registry_auth.py`
- tracked `scripts/__pycache__/*.pyc` artifacts

In a follow-up cleanup authorized by the repository owner, the obsolete untracked `.secrets/` and `.runtime/` contents were deleted. They were replaced locally by an ignored, mode-0600 `kup.conf` containing only the shared Galileo configuration and an ignored, mode-0600 project kubeconfig copied from the reference repository. The copied config excludes Alibaba RAM credentials, ACK provisioning inputs, node passwords, Isovalent repository access, Cilium/Hubble/Tetragon settings and unrelated demo configuration. No rendered `runtime/` output was copied because `kup` regenerates it when reconciliation is explicitly requested.

## Documentation changes

`README.md` was rewritten around the shared operating model. It now documents:

- the strict boundary between ACK lifecycle and Galileo application lifecycle;
- prerequisites and private config creation;
- the single deploy/update command;
- exact parameter rollout behavior;
- status, validation and port-forward commands;
- shared prompt maintenance and demo sequence;
- local operation through the same config;
- Secret/image/context security rules;
- failure modes specific to the shared workflow.

Historical transient cluster IDs, Pod names, old mutable tags, machine cleanup notes and the previous multi-phase deployment diary were removed because they are not reproducible operational instructions.

## Validation performed

No live-cluster command was executed. Validation was intentionally limited to repository and synthetic checks.

Passed:

- `bash -n` for `kup`, prompt switching, config mapping, local run and Experiment scripts;
- Python compile checks for prompt-patch rendering and local smoke code;
- `./kup --help` confirms that only `--galileo-only` is accepted;
- direct prompt-script bootstrap from `kup.conf.example` reaches the expected missing-local-kubeconfig error without an unbound `SCRIPT_DIR` failure;
- all 27 `GALILEO_*` example assignments match the reference repository exactly;
- Kubernetes manifest diff against the reference is empty;
- prompt-patch renderer diff against the reference is empty;
- synthetic rendering parses as four YAML resources in the expected order and confirms immutable image placement and ClusterIP service type;
- a full synthetic `./kup --galileo-only` run with a fake `kubectl` passed preflight, Secret creation, manifest apply, rollout, Qwen prompt convergence, image/endpoint/testcurl checks, Pod smoke and final status without contacting a cluster;
- the local config mapper successfully consumed the existing reference repository's private config without printing its Secret values and selected the expected application model, Pinecone target and Qwen custom profile;
- stale implementation references were absent outside documentation that explicitly records their removal;
- the reference repository worktree remained clean.

Application unit tests were also attempted without installing dependencies. With `PYTHONPATH=app`, six dependency-free settings/prompt tests passed. The import-side-effect test could not run because the local application virtual environment is absent and system Python does not have `langgraph`. No dependency download or environment recreation was performed because this repository-only migration did not require network installation.

Not run by design:

- `./kup --galileo-only` against ACK;
- `scripts/switch_prompt.sh` against the live ConfigMap;
- rollout, Service, testcurl and Pod egress validation;
- local calls to model, Pinecone or Splunk AO;
- image build, push or pull;
- Terraform or Alibaba Cloud operations.

The running ACK system was already deployed through the reference method, and the task explicitly prohibited changing it.

## Operator migration

For an operator moving from the removed workflow:

1. Copy `kup.conf.example` to `kup.conf`. If reusing an existing ACK-repository config that contains an absolute `KUP_WORKDIR`, change it to this repository or restore `${SCRIPT_DIR}` before running anything.
2. Translate the final resolved values into their `GALILEO_*` equivalents; do not copy `.runtime/resolved-*.env` as a new source of truth.
3. Set `GALILEO_IMAGE_REF` to the already-published immutable digest and pair it with the exact source commit.
4. Copy the project-private ACK kubeconfig and verify `ACK_CONTEXT`.
5. Confirm the reference `test/testcurl` workload exists.
6. Run `./kup --galileo-only` once to reconcile the new Secret name, checksum annotation and shared manifest.
7. Use only `scripts/switch_prompt.sh` for temporary prompt changes.

Changing `GALILEO_NAMESPACE` creates a new installation and does not delete the old namespace. There is intentionally no automatic migration cleanup or application-specific destroy command.

## Final state

The repository now presents the same Galileo deployment inputs, Kubernetes resources, configuration rollout behavior, prompt state model, validation behavior and maintenance commands as `alicloud-ack-byocni`, while keeping ACK infrastructure ownership in exactly one place.

The only intentional repository-level difference is scope: this project can reconcile the Galileo application but cannot create or destroy the ACK platform beneath it.
