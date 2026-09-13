# Deployment Report — Splunk AO Multi-Agent Banking Chatbot

## Summary

- Date: 2026-09-13 (Asia/Shanghai)
- Demo state: official intentionally imperfect baseline preserved
- Completed: Phase 0–11, including ACK rollout, Pod network validation and browser-driven live baseline
- Current status: ACK Deployment `1/1 Ready`; ACR image pull, Chainlit, selected application model, Pinecone and Splunk AO ingestion all passed
- Phase 12: optional Experiment runner is ready; execution intentionally awaits the presenter selecting an existing Dataset in the Splunk AO UI
- Destructive operations: none
- Splunk AO control-plane API writes: none
- Pinecone protected index destructive writes: none
- Public application resources created: none

## Source provenance

- Galileo repository: initial repository currently has no Git commit; files are untracked and therefore image tag is marked `uncommitted`.
- Splunk AO upstream: `splunk/splunk-ao-python` commit `53b9df9c4ae01f940a55a08d446b2212f67ff94c`
- ACK infrastructure working clone: `highopes/alicloud-ack-byocni` commit `3587981027117f1c2669c9ff763c0bc0367187f3`
- ACK infrastructure working tree at discovery: clean

The upstream clone under `upstream/splunk-ao-python` was not modified. The `after` sample was copied into `app` before adaptation.

## Local tools used during deployment

| Tool | Version / platform |
|---|---|
| Python | 3.12.14 |
| kubectl | 1.35.1, darwin/arm64 |
| Terraform | 1.16.1, darwin_arm64 |
| Alibaba Cloud CLI | 3.5.0 |
| Docker client/server | 29.8.0 / 29.5.2 |
| Docker buildx | 0.37.1 |
| Local Docker server arch | arm64 |
| ACK target arch | amd64 |

Colima was installed temporarily because no Docker daemon was available. The first VM initialization reported a decompression-stage failure even though the downloaded gzip and 3.3 GiB disk image were complete; a non-destructive retry reused the verified files and started successfully. Per user instruction, the local container stack and large build artifacts were removed after final acceptance evidence was collected; the versions above record what produced the deployed artifact, not what remains installed.

## Important application dependencies

Exact versions are stored in `app/requirements.lock`. Key versions:

| Package | Version |
|---|---|
| splunk-ao | 0.4.0 |
| galileo-core | 4.5.0 |
| chainlit | 2.5.5 |
| langchain | 0.3.30 |
| langchain-openai | 0.3.35 |
| langgraph | 0.4.10 |
| langgraph-prebuilt | 0.2.3 |
| langgraph-supervisor | 0.0.26 |
| pinecone | 7.3.0 |
| openai | 2.54.0 |

`pip check` passed locally and inside the linux/amd64 production image. Three offline unit tests passed. The explicit prebuilt/supervisor pins resolve incompatibilities observed with newer packages and LangGraph 0.4.x.

## Model preflight

### Primary vLLM

- Base URL: configured HTTPS vLLM endpoint (recorded in `.deploy.env`)
- Requested/actual model ID: `Qwen/Qwen3-14B-FP8`
- DNS/TLS: PASS
- `GET /models`: PASS; exact model present
- Ordinary Chat: PASS
- Raw OpenAI-compatible Tool Calling: FAIL capability check; response did not expose a standard parseable `tool_calls` round-trip
- LangChain Tool Calling: primary was not accepted as a usable application tool model

This is a capability failure, not a connectivity/auth/model-name failure. It satisfies the task's only permitted fallback condition because ordinary Chat passed first.

### Bailian fallback

- Provider/model: `bailian/qwen3.7-flash`
- DNS/TLS: PASS
- `GET /models`: PASS
- Ordinary Chat: PASS
- Raw Tool Calling round-trip: PASS
- LangChain `bind_tools` round-trip: PASS

### Resolved application model

- Provider: `bailian`
- Model: `qwen3.7-flash`
- Reason: primary vLLM ordinary Chat passed but actual Tool Calling capability did not
- Runtime record: `.runtime/resolved-model.env`

The four Splunk AO Evaluators continue to use the existing vLLM Qwen Judge Integration. Application fallback did not modify Judge configuration.

## Splunk AO

- Project: `hangwe-Multi-Agent Banking Chatbot - Qwen Judge Demo`
- Agent Stream: `hangwe-Default Agent Stream - Qwen Judge`
- Exact evaluators:
  - `Action Advancement - Qwen`
  - `Action Completion - Qwen`
  - `Tool Errors - Qwen`
  - `Tool Selection Quality - Qwen`
- Control-plane changes made by this task: none

Phase 6 was confirmed by the user in the UI. Some evaluator runs timed out because Splunk AO calls a vLLM endpoint in a remote data center; user-confirmed recompute succeeded for all affected evaluations. This is recorded as Judge latency, not an application failure.

Latest explicit local baseline observation session:

- Session ID: `966e80bb-39a1-4f28-9702-1ec966aacd8e`
- Credit-score direct tool: PASS
- Pinecone direct retrieval: PASS
- Credit-score supervisor route in this run: supervisor -> score agent -> score tool, answer 550
- Credit-card supervisor route in this run: supervisor -> card agent -> Pinecone, grounded no-cashback answer
- Out-of-scope route: no tool, `I don't know`

Earlier baseline executions also exhibited missed delegation/refusal, confirming the intentional prompt omission creates unstable behavior. The successful latest run was not used to “fix” or erase the baseline defect.

## Pinecone

### Protected existing index

- Name: `credit-card-information`
- Status: Ready
- Dimension: 1536
- Metric: cosine
- Integrated model metadata: none
- Namespace: default/empty
- Total vectors at inventory: 10
- Treatment: preserved completely read-only; not deleted, recreated, cleared, or blindly overwritten

Because this is a BYOV-style index and its original embedding model is not known, the application does not guess an embedding model and does not use OpenAI Embeddings.

### Selected isolated index

- Name: `credit-card-information-qwen-demo`
- Integrated embedding: `llama-text-embed-v2`
- Dimension: 1024
- Metric: cosine
- Namespace: `bank-docs`
- Text field: `chunk_text`
- Stable records: 10
- Text search smoke: PASS
- Resolution reason: isolated integrated-embedding index verified

## Local functional validation

- Application module import without external side effects: PASS
- Model preflight: PASS with policy-compliant fallback
- Pinecone inventory/resolve/search: PASS
- Direct credit-score tool: PASS
- Direct Pinecone retrieval: PASS
- Chainlit bind on `127.0.0.1:8000`: PASS
- Chainlit HTTP response: PASS
- Splunk AO baseline Trace flush: PASS
- Offline unit tests: 3/3 PASS
- Secret files: `.secrets` mode 0700; three env files mode 0600

The smoke runner records supervisor baseline outcomes without grading intentional routing failures or changing prompts.

## Dynamic ACK discovery

The following values were read on 2026-09-13 from the current ACK BYOCNI Terraform state and private kubeconfig. They are an observation, not a fixed configuration:

- Current cluster ID: `c2d5f4d1c59604353a3f0c1a50ec2c25c`
- Cluster name: `ack-byocni-wlcb`
- Kubernetes version: `1.36.2-aliyun.1`
- Zone: `cn-wulanchabu-a`
- Private kubeconfig source: current `alicloud-ack-byocni/kubeconfig`
- Explicit context: `ack-byocni-demo`
- Nodes: 3/3 Ready
- Architecture: amd64

All kubectl calls used explicit kubeconfig/context. The global kube context was not treated as authority or modified. `./kup` and `./kiall` were not executed.

## Container image

- Docker Hub source repository: `highope/splunk-ao-banking-qwen-demo`
- ACK deployment repository: existing ACR `highope/multi-agent-banking`
- Tag: `20260913-070526-uncommitted`
- Platform: `linux/amd64`
- Digest: `sha256:4dbda5a22f2c25c8842f7b4afd611e586ac881271f35bcf5274c5a4ca6ba3ba3`
- Immutable reference: `highope/splunk-ao-banking-qwen-demo@sha256:4dbda5a22f2c25c8842f7b4afd611e586ac881271f35bcf5274c5a4ca6ba3ba3`
- Local compressed image size reported by Docker: 131,695,603 bytes
- Non-root user: yes
- `pip check` inside image: PASS
- Local linux/amd64 container HTTP smoke: PASS
- Docker Hub push: PASS
- ACR push: PASS; manifest digest and linux/amd64 image match the Docker Hub build
- Registry digest resolution: PASS
- `latest` tag pushed: no
- Docker auth cleanup after push: PASS

Build context was approximately 2 MB and excluded `.secrets`, `.runtime`, `.env`, venv, Git metadata and kubeconfig.

## ACK deployment status

Namespace and resources successfully applied:

- Namespace: `galileo-demo`
- ConfigMap: `splunk-ao-banking-qwen-config`
- Runtime Secret: `splunk-ao-banking-qwen-runtime`
- Image pull Secret: `registry-pull`
- Deployment: `splunk-ao-banking-qwen`
- Service: `splunk-ao-banking-qwen`, ClusterIP only
- Public external IP: none

Current status:

```text
Deployment Ready: 1/1
Pod: Running, 0 restarts at acceptance
Service: ClusterIP, no external IP
```

The immutable ACR image was pulled successfully in approximately 24 seconds on its first ACK pull. Its digest is:

```text
sha256:4dbda5a22f2c25c8842f7b4afd611e586ac881271f35bcf5274c5a4ca6ba3ba3
```

The earlier Docker Hub failure occurred before layer download and was not an authentication error. The user supplied an existing ACR configuration and explicitly required repository name `multi-agent-banking`; the same image was copied there without creating ACR infrastructure. No random mirror, node proxy or public ACK Service was created.

The first ACR upload stalled on the previous network and ended with a broken connection. After the user switched networks, the remaining transfer completed almost immediately. Future large-transfer stalls should trigger a prompt to switch network followed by a pause, not repeated polling.

The initial ACR Pod reached `CreateContainerConfigError` because Kubernetes could not prove that image user name `app` was non-root. Local inspection verified `app` is UID/GID 999; the Pod security context now explicitly sets `runAsUser: 999` and `runAsGroup: 999`. This infrastructure-only change did not alter Agent behavior.

## ACK network and Web acceptance

From inside the deployed application Pod:

- Application model DNS and authenticated HTTPS `/models`: PASS
- Exact selected model identity `qwen3.7-flash`: PASS
- Pinecone integrated text search: PASS
- Splunk AO DNS/HTTPS: PASS

Chainlit was opened through a local port-forward to the ClusterIP Service. The observed live baseline results were:

| Run | Result |
|---|---|
| Credit score independent session 1 | Correct `550` |
| Credit score independent session 2 | Said it transferred the request, but omitted the score |
| Credit score independent session 3 | `I cannot answer that question.` |
| Credit score independent session 4 | Correct `550` |
| Orbit cashback | Pinecone-grounded answer: no cashback/rewards |
| Out of scope book request | Correctly refused |

New Splunk AO sessions were created and the Pod log showed successful authenticated ingestion calls. This distribution reproduces the intended baseline defect: the business tools are healthy, while supervisor routing/completion is inconsistent. Evaluator results remain a UI checkpoint; remote-vLLM timeout entries may be recomputed as the user previously confirmed.

## Acceptance checklist

| Criterion | Result |
|---|---|
| Baseline intentional prompt preserved | PASS |
| Policy-compliant model selection | PASS |
| Selected model Tool Calling works | PASS locally |
| No OpenAI API dependency | PASS |
| Existing Pinecone index protected | PASS |
| Four existing Qwen Evaluators unchanged | PASS, user UI confirmation |
| Evaluator recompute after latency timeout | PASS, user confirmation |
| Dynamic ACK discovery, no fixed ID assumption | PASS |
| ACK nodes Ready | PASS |
| linux/amd64 image build/push/digest | PASS |
| No Secret in image/manifests/report | PASS; exact credential-value scan and image history/env inspection passed |
| No public application resource | PASS |
| ACK Deployment Ready 1/1 | PASS |
| Pod -> Bailian/Pinecone/Splunk AO network | PASS |
| ACK Chainlit via port-forward | PASS |
| ACK live Trace ingestion | PASS |
| Four evaluator definitions/configuration | PASS, user UI confirmation; recompute works for latency timeouts |
| Optional Experiment | READY; not run because Dataset remains a required presenter/UI choice |
| Local resource cleanup | PASS; see cleanup record below |

## Problems and resolutions

1. `VLLM_MODEL_NAME` initially used a friendly name not advertised by the endpoint. It was changed to the exact `Qwen/Qwen3-14B-FP8` ID and Phase 1 was rerun.
2. vLLM Chat worked but Tool Calling did not produce standard tool calls. Policy-compliant Bailian fallback was validated and selected.
3. Official dependency ranges allowed incompatible LangGraph prebuilt/supervisor versions. Versions were pinned and verified.
4. Existing Pinecone index was BYOV with unknown embeddings. It was preserved and an isolated integrated index was created.
5. During early smoke work, the intentional prompt defect was mistakenly treated as a deployment defect and briefly improved. Those semantic changes and an added corrected dataset were removed. The official baseline prompt is restored and frozen for first-stage deployment.
6. Official sample Dataset contains some references inconsistent with its own current source documents. This is documented as Dataset/reference drift; the Agent is not altered to fabricate stale answers.
7. Colima first initialization failed after download, but cache/image integrity passed. Reusing the files succeeded.
8. ACK could not reach Docker Hub. The user provided an existing ACR configuration and required repository `multi-agent-banking`; pushing and deploying the exact same digest resolved the pull failure.
9. The first ACR transfer stalled on one network. The user switched networks and the remaining upload completed immediately; the documented operating rule is now to ask for a network switch and pause on future large-transfer stalls.
10. ACK rejected the non-numeric Docker `USER app` while enforcing `runAsNonRoot`. The verified UID/GID 999 was added to the Pod security context, after which rollout completed.

## Local cleanup record

After the final image inspection, unit tests, secret scan, ACK rollout check and browser test, the following exact local targets were removed:

- Colima runtime data under `/Users/hangwe/.colima`: 2.1 GB before deletion
- Colima download cache under `/Users/hangwe/Library/Caches/colima`: 317 MB
- application and preflight venvs: 285 MB + 82 MB
- Homebrew Colima/Docker/buildx/Lima/QEMU stack and now-unused QEMU dependencies: approximately 912 MB by package reports
- one known 4 KiB ACR inspection temporary directory

The measured total is approximately 3.7 GB, excluding any additional sparse-disk benefit. Absence of all named directories and packages was verified. Python 3.12 and Alibaba Cloud CLI were retained because they are small compared with the VM stack and are useful for dynamic ACK discovery and later Experiment setup. No ACK namespace, ACR image, Pinecone index, source, runtime record or Secret was removed.

To run a later local Experiment, recreate `app/.venv` from the documented lock/install procedure. Reinstall the container stack only if a new application image must be built.

## Known limitations and next steps

- The Judge endpoint crosses data-center boundaries and can need evaluator recompute.
- Baseline routing is intentionally unstable; a successful single call does not remove the defect.
- Experiment Dataset name remains `ReplaceMe` until the user selects an existing Dataset through the Splunk AO UI.
- Because the Galileo repo has no initial commit, image provenance uses timestamp + `uncommitted`; future builds should include a real commit SHA after user-managed Git initialization/commit.

See `README.md` for the complete Web and Experiment sales demonstration, evaluator interpretation, prompt improvement procedure, talk track, troubleshooting and future hardening recommendations.
