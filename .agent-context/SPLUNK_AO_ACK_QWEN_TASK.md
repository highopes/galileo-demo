# Splunk Agent Observability Multi-Agent Banking Chatbot
## ACK + vLLM/Qwen + Bailian Fallback 部署任务书（供 Codex CLI 执行）

**版本日期：2026-09-13**  
**Codex 工作目录：** `/Users/hangwe/Library/CloudStorage/OneDrive-Cisco/dev/galileo`  
**本文件建议位置：** `.agent-context/SPLUNK_AO_ACK_QWEN_TASK.md`

---

# 1. 任务目标

基于 Splunk Agent Observability 官方 `Multi-agent banking chatbot` 示例，在用户反复创建/销毁的 Alibaba Cloud ACK Managed Kubernetes 环境中，构建一个可重复部署的 Demo。

必须实现：

1. 保留官方样例的 LangGraph Supervisor / Child Agents / Chainlit / Pinecone RAG 基本结构。
2. **应用 LLM 首选**用户已有 OpenAI-compatible vLLM endpoint：
   - Model: `qwen3-14b-fp8`
   - Endpoint root: `https://csco-ai-serving0.aibus88.com`
3. Codex 必须先对 vLLM 做普通 Chat + Tool Calling capability preflight。
4. **仅当 vLLM 普通 Chat 成功，但无法满足本 Demo 所需 Tool Calling 能力时**，应用 LLM 自动改用 Alibaba Cloud Model Studio / Bailian 的：
   - Model: `qwen3.7-flash`
   - Region: `cn-beijing`
   - OpenAI-compatible API
5. 不做“运行中静默自动 failover”。模型选择在部署前通过 preflight **一次性确定**，写入 resolved runtime config，以便行为可审计、可复现。
6. Splunk AO Trace / Session 写入用户已有 Project / Agent Stream。
7. Splunk AO 的四个现有 Custom Evaluator 继续以用户已有 vLLM `qwen3-14b-fp8` 作为 LLM-as-a-Judge；即使应用 LLM fallback 到 Bailian，也**不自动修改 Judge**。
8. 去掉官方 sample RAG 中对 OpenAI Embeddings 的强依赖；优先妥善复用已有 Pinecone index，无法兼容时创建隔离的新 index。
9. 容器化后部署到当前由 `highopes/alicloud-ack-byocni` 创建的 ACK 集群。
10. ACK 会反复 `./kup` / `./kiall`，因此不得依赖固定 Cluster ID 或全局 kube context；每次部署都动态发现当前 Terraform state / cluster ID / kubeconfig。
11. Codex 尽量自动完成代码修改、测试、镜像构建与推送、Kubernetes 部署和验证。
12. **不得通过 API/SDK 自动修改 Splunk AO 控制面复杂对象。**需要 Project / Agent Stream / Integration / Evaluator / Evaluator enablement / Dataset 等写操作时，必须停下来，让用户在 Splunk AO UI 手工处理。

最终逻辑链路：

```text
Browser
  -> Chainlit on ACK
  -> LangGraph Supervisor
       -> Credit Score Agent -> Credit Score Tool
       -> Credit Card Agent  -> Pinecone RAG
  -> Resolved Application LLM
       Preferred: vLLM / qwen3-14b-fp8
       Fallback:  Bailian / qwen3.7-flash

Same Agent execution
  -> Splunk AO SDK
  -> Existing Project / Agent Stream
  -> Trace / Session
  -> Existing "* - Qwen" Evaluators
  -> Existing Splunk AO Custom Model Integration
  -> vLLM / qwen3-14b-fp8 as Judge
```

ACK Pod 不运行 Qwen 模型，因此应用 Pod 不需要 GPU。

---

# 2. 权威上游与开始工作时的核对

开始工作后先核对当前版本，不得只依赖本任务书中的旧假设。

## Splunk AO

- Overview  
  `https://agent-observability-docs.splunk.com/what-is-splunk-agent-observability`
- Multi-agent sample  
  `https://agent-observability-docs.splunk.com/getting-started/sample-projects/multi-agent`
- Evaluators  
  `https://agent-observability-docs.splunk.com/sdk-api/evaluators/evaluators`
- Custom Model Integrations  
  `https://agent-observability-docs.splunk.com/sdk-api/third-party-integrations/model-integrations/custom-model-integrations/custom-model-integrations`
- Python SDK  
  `https://github.com/splunk/splunk-ao-python`
- Sample path  
  `examples/agent/langgraph-fsi-agent/after`

## Alibaba Cloud Model Studio / Bailian

- qwen3.7-flash  
  `https://help.aliyun.com/zh/model-studio/qwen3-7-flash`
- OpenAI-compatible Chat API  
  `https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope`
- Function Calling  
  `https://help.aliyun.com/zh/model-studio/qwen-function-calling`
- API Key  
  `https://help.aliyun.com/zh/model-studio/get-api-key`

当前核对结论：北京区 `qwen3.7-flash` 官方支持 Function Calling。北京区 OpenAI-compatible 推荐使用业务空间专属 host：

```text
https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1
```

## ACK BYOCNI infrastructure

- Repo  
  `https://github.com/highopes/alicloud-ack-byocni`

当前 repo 的关键事实：

- `./kup` 创建 ACK/VPC/worker 等环境。
- `./kiall` 对当前 Terraform state 执行 destroy。
- Terraform output 有 `cluster_id`、`cluster_name`、`kubernetes_version`、`vpc_id`。
- Terraform `alicloud_cs_cluster_credential` 自动把 kubeconfig 写到 repo root 的 `./kubeconfig`。
- Kubernetes context 固定为 `ack-byocni-demo`。
- repo 明确不使用/修改全局 `~/.kube/config`。
- `./kiall` 成功销毁后会删除项目私有 kubeconfig。

因此本项目不得保存长期固定 ACK cluster ID。

## Pinecone

- Quickstart  
  `https://docs.pinecone.io/guides/get-started/quickstart`
- Integrated embedding / llama-text-embed-v2  
  `https://docs.pinecone.io/models/llama-text-embed-v2`

## vLLM

- Tool Calling  
  `https://docs.vllm.ai/en/latest/features/tool_calling/`

开始时记录以下版本到 `DEPLOYMENT_REPORT.md`：

- upstream Splunk AO sample commit SHA
- `alicloud-ack-byocni` commit SHA
- Python
- Docker / buildx
- kubectl
- Terraform
- aliyun CLI
- ACK Kubernetes version
- ACK node architecture
- splunk-ao
- LangChain / langchain-openai
- LangGraph / langgraph-supervisor
- Chainlit
- Pinecone SDK

优先使用当前官方 sample 的依赖组合。不要无目的地把全部依赖升级到 latest。

---

# 3. 用户已有配置

## Splunk AO

```dotenv
SPLUNK_AO_PROJECT="hangwe-Multi-Agent Banking Chatbot - Qwen Judge Demo"
SPLUNK_AO_AGENT_STREAM="hangwe-Default Agent Stream - Qwen Judge"
SPLUNK_AO_CONSOLE_URL="https://console.multitenant.galileocloud.io"
```

Secret：

```dotenv
SPLUNK_AO_API_KEY="<SECRET>"
```

用户已有四个 Custom Evaluator，预期精确名称：

```text
Action Advancement - Qwen
Action Completion - Qwen
Tool Errors - Qwen
Tool Selection Quality - Qwen
```

如果 UI 中实际名称不完全一致，不得猜测或自动创建。停下来请用户提供精确名称。

## Primary application model: vLLM

```dotenv
VLLM_MODEL_NAME="qwen3-14b-fp8"
VLLM_BASE_URL="https://csco-ai-serving0.aibus88.com/v1"
VLLM_API_KEY="<SECRET>"
```

## Fallback application model: Bailian

```dotenv
BAILIAN_MODEL_NAME="qwen3.7-flash"
BAILIAN_BASE_URL="https://ReplaceMe.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
DASHSCOPE_API_KEY="<SECRET>"
```

`ReplaceMe` 为该 API Key 所属业务空间的 WorkspaceId；也可以直接把百炼 API Key 页面显示的 API Host 换算成对应 OpenAI-compatible base URL。

**百炼 API Key 的固定填写位置：**

```text
/Users/hangwe/Library/CloudStorage/OneDrive-Cisco/dev/galileo/.secrets/runtime.env
```

变量名：

```dotenv
DASHSCOPE_API_KEY="在这里填写你的百炼 API Key"
```

不要把 API Key 写入 `.env.example`、代码、任务书、Kubernetes ConfigMap 或 Git。

---

# 4. Model Selection Policy

创建：

```text
scripts/preflight_models.py
```

以及统一 model factory：

```text
app/src/splunk_ao_langgraph_fsi_agent/llm.py
```

## 4.1 Primary vLLM preflight

顺序：

1. TLS/DNS/connectivity
2. `GET /v1/models`
3. 普通 Chat Completions
4. 原始 OpenAI-compatible function/tool call 请求
5. LangChain `ChatOpenAI.bind_tools()` 或最小 ReAct agent tool-call smoke test

最小工具可定义：

```text
get_demo_value(name: string)
```

提示词必须明确需要调用工具。

通过条件：

- 普通 chat 成功。
- model ID 可用。
- 返回标准 `tool_calls`，arguments 可解析。
- LangChain 能消费该结构并完成一次完整 tool round-trip。

## 4.2 何时允许 fallback

只有以下情况允许自动 fallback：

```text
vLLM ordinary chat == PASS
AND
vLLM tool-calling capability == FAIL/UNSUPPORTED
```

例如：

- server 未启用 auto tool choice；
- parser/chat template 导致标准 `tool_calls` 无法产生；
- 返回格式无法被 LangChain 正确消费；
- 模型明确不具备所需 tool-calling 行为。

以下情况**不应静默 fallback**，而应停止并报告配置问题：

- DNS/TLS failure
- endpoint unreachable
- HTTP 401/403
- model not found
- malformed base URL
- repeated 5xx that looks transient

这些不是“模型能力不足”。

## 4.3 Bailian fallback preflight

使用：

```text
model = qwen3.7-flash
base_url = BAILIAN_BASE_URL
api_key = DASHSCOPE_API_KEY
```

执行与 vLLM 相同的：

- normal chat
- raw function calling
- LangChain tool round-trip

Bailian 也失败则停止。

## 4.4 Resolved runtime config

不要在每个请求时重新判断 provider。

Preflight 后生成一个**不含 Secret**的本地文件，例如：

```text
.runtime/resolved-model.env
```

vLLM 成功：

```dotenv
APP_MODEL_PROVIDER="vllm"
APP_MODEL_NAME="qwen3-14b-fp8"
APP_MODEL_BASE_URL="https://csco-ai-serving0.aibus88.com/v1"
APP_MODEL_API_KEY_SOURCE="VLLM_API_KEY"
```

Fallback：

```dotenv
APP_MODEL_PROVIDER="bailian"
APP_MODEL_NAME="qwen3.7-flash"
APP_MODEL_BASE_URL="https://<WorkspaceId>.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
APP_MODEL_API_KEY_SOURCE="DASHSCOPE_API_KEY"
```

Kubernetes Secret 中只把**最终选中的应用模型 Key**映射为：

```text
APP_MODEL_API_KEY
```

应用容器不需要同时看到两个模型 Key。

---

# 5. Splunk AO Judge Policy

Judge 与 Application LLM 是独立路径。

默认保持：

```text
Splunk AO SaaS
 -> Existing Qwen Custom Model Integration
 -> https://csco-ai-serving0.aibus88.com/v1
 -> qwen3-14b-fp8
```

即使 Application LLM 因 Tool Calling fallback 为：

```text
Bailian qwen3.7-flash
```

四个 Qwen Evaluator 仍保持 vLLM `qwen3-14b-fp8`。

理由：

- Agent 需要 Function Calling。
- LLM-as-a-Judge 不需要调用 Agent tools。
- 用户已经完成四个 Qwen Evaluator。
- 不应为了应用 fallback 无故重建 evaluator / integration。

如果 vLLM Judge 本身无法完成 evaluator 所需判断或输出：

- 收集具体 evaluator failure。
- 停止。
- 提示用户人工决定是否新建 Bailian Judge Integration/Evaluator。
- Codex 不得自动做该控制面修改。

---

# 6. Splunk AO Control-plane 边界

Codex 不得自动：

- Create/Delete/Update Project
- Create/Delete/Update Agent Stream
- Create/Delete/Update LLM Integration
- Create/Delete/Update Evaluator
- Enable/Disable Evaluator
- Change evaluator sampling
- Create/Delete Dataset
- Modify Controls / Guardrails
- 删除现有 Splunk AO 对象以“解决问题”

需要这些操作时：

1. 停止当前 phase。
2. 用 3–5 行告诉用户具体 UI 页面与最小操作。
3. 等用户确认完成后继续。

允许：

- 正常发送 Trace / Span / Session。
- 使用现有 Project / Agent Stream。
- 使用现有 Custom Evaluator name string 运行 Experiment。
- 使用已有 Dataset 运行 Experiment。
- 简单 read-only 查询。

---

# 7. Splunk AO 人工 Checkpoint

ACK 正式验收前要求用户确认：

## A. vLLM Judge Integration

在 Splunk AO UI 的 LLM Integrations 中确认：

- Endpoint 指向用户 vLLM OpenAI-compatible endpoint。
- model name 为 `qwen3-14b-fp8`。
- Authentication 正确。
- Playground 普通问答成功。

Judge 不要求 tool calling。

## B. 四个 Qwen Evaluator

确认存在：

- `Action Advancement - Qwen`
- `Action Completion - Qwen`
- `Tool Errors - Qwen`
- `Tool Selection Quality - Qwen`

逐个确认所选 model 为上述 vLLM Qwen Integration。

## C. Agent Stream enablement

目标：

```text
hangwe-Multi-Agent Banking Chatbot - Qwen Judge Demo
 -> hangwe-Default Agent Stream - Qwen Judge
```

确认四个 Qwen evaluator enable。

Demo 建议 sampling 100%。

只由用户在 UI 做。

---

# 8. 官方 sample 的代码改造

## 8.1 保留 ChatOpenAI

无论 vLLM 还是 Bailian，均为 OpenAI-compatible API，因此继续使用：

```python
from langchain_openai import ChatOpenAI
```

统一 factory 只读取：

```text
APP_MODEL_NAME
APP_MODEL_BASE_URL
APP_MODEL_API_KEY
MODEL_REQUEST_TIMEOUT
MODEL_MAX_RETRIES
```

例如：

```python
ChatOpenAI(
    model=...,
    base_url=...,
    api_key=...,
    timeout=...,
    max_retries=...,
)
```

不要把 provider-specific key 硬编码进 Agent modules。

## 8.2 修复 import-time side effect

官方 sample 当前会在 `.env` 完全加载前 import Agent modules，而且 module import 过程中可能创建 agent/model。

改成：

```text
load config
 -> validate env
 -> create supervisor
 -> create child agents
```

要求：

- module import 不建立外部网络连接。
- child agents 在 factory function 内创建。
- 本地 `.env` 只是开发便利；Kubernetes 运行时通过 envFrom/Secret/ConfigMap。

## 8.3 不改变 Demo 语义来“刷分”

第一版保持官方 prompt/agent intent。

不要为了让 Evaluator 全部 1.0：

- 改写为固定答案；
- 绕过 tool；
- 禁掉 supervisor；
- 隐藏失败 trace。

---

# 9. Pinecone 处理策略：保护现有 credit-card-information

用户已经在其他平台多次运行本 Demo，并已有：

```text
credit-card-information
```

这个 index 是既有资产，必须谨慎处理。

## 9.1 先只读 inventory

Codex 首先：

- list indexes
- describe `credit-card-information`
- 查看 dimension / metric / integrated model metadata（如 API 提供）
- 查看 namespaces / vector count
- 只做低风险 query capability 判断

禁止：

```text
DELETE credit-card-information
recreate credit-card-information
blindly upsert/overwrite it
clear namespace
```

不要仅根据 dimension 猜它用的 embedding model。

## 9.2 如果现有 index 可直接按文本查询

如果确认它是 compatible integrated-embedding index，并且 sample 文档可检索：

- 可只读复用它。
- 不重新上传全部 records，除非明确发现数据缺失且写入不会破坏其他 Demo。

## 9.3 如果现有 index 是 BYOV / OpenAI embedding 类型

官方旧 sample 常见模式为：

```text
OpenAIEmbeddings()
 -> vectors
 -> Pinecone index
```

如果当前 `credit-card-information` 属于这种类型，则运行时 query 仍需要相同 embedding model。

本任务不引入 OpenAI API Key，因此：

- 保持 `credit-card-information` 完全只读。
- 创建隔离的新 index：

```text
credit-card-information-qwen-demo
```

- 推荐 Pinecone integrated embedding：

```text
llama-text-embed-v2
```

- namespace：

```text
bank-docs
```

- 文本字段：

```text
chunk_text
```

- 使用稳定 `_id`（filename + chunk number 或 content hash）。
- 用 `upsert_records()`。
- query 时直接使用 text search，避免 `OpenAIEmbeddings()`。

如果 `credit-card-information-qwen-demo` 已存在：

- 先验证 model / field map / namespace compatibility。
- compatible 则幂等复用。
- incompatible 则停止，不删除、不随机再创建第三个 index。

## 9.4 Pinecone integrated embedding 不可用时

停止并报告。

允许的下一步方案：

1. 独立 embedding endpoint；或
2. 容器内本地 embedding model。

不得自动回退到 OpenAI Embeddings。

---

# 10. Experiment runner

主 Demo 优先验证实时 Agent Stream + Evaluator。

Experiment 为第二阶段。

创建：

```text
app/experiment.py
```

Custom evaluator 使用精确名称字符串，例如：

```python
metrics=[
    "Action Advancement - Qwen",
    "Action Completion - Qwen",
    "Tool Errors - Qwen",
    "Tool Selection Quality - Qwen",
]
```

最好从环境变量读取：

```dotenv
SPLUNK_AO_EXPERIMENT_EVALUATORS="Action Advancement - Qwen,Action Completion - Qwen,Tool Errors - Qwen,Tool Selection Quality - Qwen"
```

禁止：

- 自动 create/delete Dataset
- 使用旧 built-in enum 代替用户 custom evaluators
- 无限 polling
- 假设旧 aggregate metric key 一定存在

Dataset 不存在则停下来让用户在 UI 处理。

Polling：

- interval ~10s
- deadline 最长约 10 分钟

Timeout 输出：

- experiment id/name
- current status
- available metrics
- missing evaluator names

然后非 0 退出，不无限等。

---

# 11. ACK infrastructure authority

ACK 由：

```text
https://github.com/highopes/alicloud-ack-byocni
```

负责生命周期。

本任务**不能把 ACK 看成固定集群**。

用户提供本地 infra repo 路径：

```dotenv
ACK_BYOCNI_DIR="ReplaceMe"
```

推荐指向用户实际运行 `./kup` / `./kiall` 的 working clone。

## 11.1 每次部署动态发现集群

创建脚本：

```text
scripts/discover_ack.sh
```

流程：

1. `cd "$ACK_BYOCNI_DIR"`
2. `git status --short`，不修改 infra repo。
3. `terraform output -raw cluster_id`
4. `terraform output -raw cluster_name`
5. `terraform output -raw kubernetes_version`
6. 检查 `$ACK_BYOCNI_DIR/kubeconfig`
7. 使用固定 context：

```text
ack-byocni-demo
```

8. 验证：

```bash
kubectl \
  --kubeconfig "$ACK_BYOCNI_DIR/kubeconfig" \
  --context ack-byocni-demo \
  cluster-info
```

9. 再验证 nodes Ready。

**不要使用 `kubectl config current-context` 作为权威来源。**

## 11.2 kubeconfig 不存在或 stale

如果 Terraform state 仍有有效 `cluster_id`，但 repo kubeconfig 缺失/失效：

- 使用用户提供的 RAM credential + Alibaba Cloud CLI 动态取得当前 cluster kubeconfig。
- 写入 Galileo 项目自己的临时 Secret 路径：

```text
.secrets/ack-kubeconfig
```

- `chmod 600`。
- 不合并到 `~/.kube/config`。
- 后续所有 kubectl 命令显式 `--kubeconfig` + `--context` 或从临时文件读取唯一 context。

## 11.3 如果 Terraform state 没有 active cluster

说明可能刚执行过 `./kiall`。

默认：

```dotenv
ALLOW_ACK_CREATE="0"
```

此时 Codex 停止并明确报告：“当前 ACK BYOCNI Terraform state 没有活动集群”。

如果用户预先设置：

```dotenv
ALLOW_ACK_CREATE="1"
```

且 `$ACK_BYOCNI_DIR/kup.conf` 已经完整、权限为 0600，则 Codex可以使用该项目唯一受支持入口：

```bash
cd "$ACK_BYOCNI_DIR"
./kup
```

不得自行拆开/重写该 repo 的 Terraform + Helm 流程。

**Codex 不得自动执行 `./kiall`，除非用户在当前对话/任务明确要求销毁 ACK。**

---

# 12. Alibaba RAM Credential

用户可提供 RAM AccessKey。

存放到：

```text
.secrets/alicloud.env
```

内容：

```dotenv
ALIBABA_CLOUD_ACCESS_KEY_ID="ReplaceMe"
ALIBABA_CLOUD_ACCESS_KEY_SECRET="ReplaceMe"
ALIBABA_CLOUD_REGION_ID="cn-beijing"
```

权限：

```bash
chmod 600 .secrets/alicloud.env
```

自动化时优先使用环境变量，不把 AK 写进源码，也不要求保存到全局 default profile。

为避免机器上旧 aliyun profile 覆盖本次 credential，可在使用 aliyun CLI 的 shell 中：

```bash
export ALIBABA_CLOUD_IGNORE_PROFILE=TRUE
```

然后 export / source `.secrets/alicloud.env`。

使用前验证 caller identity。

Secret 永远脱敏。

注意：`alicloud-ack-byocni` 自己的 `kup.conf` 使用的变量命名和生命周期由该 repo 管理；不要让 Galileo 项目自动覆盖 working `kup.conf`。如果 `ALLOW_ACK_CREATE=1`，只允许调用现成且完整的 `./kup`。

---

# 13. 建议 Galileo 项目目录

```text
galileo/
├── .agent-context/
│   └── SPLUNK_AO_ACK_QWEN_TASK.md
├── .secrets/
│   ├── runtime.env
│   ├── alicloud.env
│   ├── dockerhub.env
│   └── ack-kubeconfig        # only when dynamically regenerated
├── .runtime/
│   └── resolved-model.env
├── upstream/
│   └── splunk-ao-python/
├── app/
├── deploy/
│   └── k8s/
├── scripts/
│   ├── preflight_models.py
│   ├── discover_ack.sh
│   └── setup_pinecone.py
├── .env.example
├── .deploy.env
├── Dockerfile
├── .dockerignore
├── README.md
└── DEPLOYMENT_REPORT.md
```

规则：

- `upstream/` 只作参照，不修改。
- `app/` 为实际 fork/copy。
- 不覆盖用户未提交工作。
- 先执行 `git status`。
- 禁止 `git reset --hard`、`git clean -fdx`。

---

# 14. Secret files

## `.secrets/runtime.env`

```dotenv
SPLUNK_AO_API_KEY="ReplaceMe"
VLLM_API_KEY="ReplaceMe"
DASHSCOPE_API_KEY="ReplaceMe"
PINECONE_API_KEY="ReplaceMe"
```

**这里就是用户填写百炼 API Key 的位置。**

## `.secrets/alicloud.env`

```dotenv
ALIBABA_CLOUD_ACCESS_KEY_ID="ReplaceMe"
ALIBABA_CLOUD_ACCESS_KEY_SECRET="ReplaceMe"
ALIBABA_CLOUD_REGION_ID="cn-beijing"
```

## `.secrets/dockerhub.env`

```dotenv
DOCKERHUB_USERNAME="ReplaceMe"
DOCKERHUB_PAT="ReplaceMe"
```

全部：

```bash
chmod 600 .secrets/*.env
```

`.gitignore` 必须包含：

```text
.secrets/
.runtime/
.env
*.kubeconfig
kubeconfig
```

---

# 15. Non-secret config

`.env.example` / `.deploy.env` 可包含：

```dotenv
# Splunk AO
SPLUNK_AO_PROJECT="hangwe-Multi-Agent Banking Chatbot - Qwen Judge Demo"
SPLUNK_AO_AGENT_STREAM="hangwe-Default Agent Stream - Qwen Judge"
SPLUNK_AO_CONSOLE_URL="https://console.multitenant.galileocloud.io"

# Model selection
MODEL_SELECTION_MODE="auto"
VLLM_MODEL_NAME="qwen3-14b-fp8"
VLLM_BASE_URL="https://csco-ai-serving0.aibus88.com/v1"
BAILIAN_MODEL_NAME="qwen3.7-flash"
BAILIAN_BASE_URL="https://ReplaceMe.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
MODEL_REQUEST_TIMEOUT="120"
MODEL_MAX_RETRIES="2"

# Pinecone
PINECONE_EXISTING_INDEX="credit-card-information"
PINECONE_DEMO_INDEX="credit-card-information-qwen-demo"
PINECONE_NAMESPACE="bank-docs"
PINECONE_EMBED_MODEL="llama-text-embed-v2"
PINECONE_CLOUD="aws"
PINECONE_REGION="us-east-1"

# Splunk AO custom evaluators
SPLUNK_AO_EXPERIMENT_EVALUATORS="Action Advancement - Qwen,Action Completion - Qwen,Tool Errors - Qwen,Tool Selection Quality - Qwen"

# ACK dynamic infrastructure
ACK_BYOCNI_DIR="ReplaceMe"
ACK_CONTEXT="ack-byocni-demo"
ACK_NAMESPACE="galileo-demo"
ALLOW_ACK_CREATE="0"

# Docker Hub
DOCKERHUB_REPOSITORY="ReplaceMe/splunk-ao-banking-qwen-demo"
```

---

# 16. Local dependency environment

使用全新 Python 3.12 virtualenv。

不要复用历史 Splunk AO demo venv。

基本流程：

```bash
cd app
python3.12 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install .
python -m pip check
```

如果当前 upstream 已切换为 uv/lock，优先采用 upstream 推荐方式。

依赖成功后固化 lock/pins。

---

# 17. Local smoke tests

按顺序：

1. Import all application modules。
2. Model preflight，生成 resolved model config。
3. Pinecone inventory。
4. Pinecone index resolve/reuse/create。
5. Pinecone retrieval smoke test。
6. Chainlit local start。
7. Credit Score Agent/tool path。
8. Credit Card Agent/Pinecone path。
9. Splunk AO local Trace。
10. Secret scan。

本地 Splunk AO Trace 不出现，不进入 ACK deployment。

---

# 18. Docker image

建议：

- `python:3.12-slim`
- non-root user
- `EXPOSE 8000`
- production command：

```bash
chainlit run app.py -h --host 0.0.0.0 --port 8000
```

不要生产环境 `-w`。

`.dockerignore`：

```text
.env
.env.*
!.env.example
.secrets/
.runtime/
.git/
.venv/
__pycache__/
*.pyc
*kubeconfig*
```

构建前动态检查 ACK node architecture：

```bash
kubectl --kubeconfig ... --context ack-byocni-demo \
  get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture
```

Apple Silicon Mac -> amd64 ACK 时使用：

```bash
docker buildx build --platform linux/amd64 ... --push .
```

Tag 至少包含 git SHA 或 timestamp，不只使用 `latest`。

记录 image digest。

---

# 19. Docker Hub

推荐 private repository：

```text
<DockerHubUser>/splunk-ao-banking-qwen-demo
```

不要使用 Docker Hub account password。

用 PAT。

本机 push：Read/Write。
ACK pull：优先单独 Read token（如果实际账号流程方便）。

脚本登录使用：

```bash
printf '%s' "$DOCKERHUB_PAT" | docker login \
  --username "$DOCKERHUB_USERNAME" \
  --password-stdin
```

不要打印 token。

中国大陆 ACK 如果 pull Docker Hub 失败：

- 收集 ImagePullBackOff/registry error。
- 停止并报告。
- 不随机改镜像源。
- 可建议用户决定是否镜像同步到 ACR，但不未经授权创建新的云 registry 资源。

---

# 20. Kubernetes target design

Namespace：

```text
galileo-demo
```

创建：

- Namespace
- ConfigMap
- runtime Secret
- imagePullSecret
- Deployment
- ClusterIP Service
- optional Experiment Job

默认不创建：

- LoadBalancer Service
- EIP
- Ingress
- DNS
- TLS cert
- PVC
- database

Demo 先使用：

```bash
kubectl port-forward
```

## ConfigMap

只包含非 secret resolved config，例如：

- SPLUNK_AO_PROJECT
- SPLUNK_AO_AGENT_STREAM
- SPLUNK_AO_CONSOLE_URL
- APP_MODEL_PROVIDER
- APP_MODEL_NAME
- APP_MODEL_BASE_URL
- MODEL_REQUEST_TIMEOUT
- MODEL_MAX_RETRIES
- resolved Pinecone index
- Pinecone namespace

## Runtime Secret

只包含：

- SPLUNK_AO_API_KEY
- APP_MODEL_API_KEY（映射到最终 chosen provider 的 key）
- PINECONE_API_KEY

如果应用 fallback 到 Bailian，Pod 不需要 VLLM_API_KEY。

如果应用使用 vLLM，Pod 不需要 DASHSCOPE_API_KEY。

Judge key 属于 Splunk AO control plane，不应该注入 Pod 仅仅为了 Judge。

## Deployment

初始：

- replicas: 1
- port: 8000
- `automountServiceAccountToken: false`
- non-root
- reasonable CPU/memory
- TCP startup/readiness/liveness probes

## Service

```text
ClusterIP
80 -> 8000
```

访问：

```bash
kubectl --kubeconfig ... --context ack-byocni-demo \
  -n galileo-demo port-forward svc/splunk-ao-banking-qwen 8000:80
```

浏览器：

```text
http://127.0.0.1:8000
```

---

# 21. Deployment phases

## Phase 0 — Safety / inventory

- `pwd`
- `git status`
- 检查已有文件
- 确认 `.secrets/` ignored
- 记录工具版本
- 记录 upstream SHAs
- 不执行 destructive Git command

## Phase 1 — Model capability preflight

1. vLLM connectivity/chat
2. vLLM raw tool calling
3. vLLM LangChain tool round-trip
4. 若且仅若 capability 不满足，preflight Bailian qwen3.7-flash
5. 写 resolved model config

输出明确：

```text
Resolved application model provider: vllm|bailian
Resolved application model: ...
Reason: ...
```

不得打印 key。

## Phase 2 — Fork current Splunk AO sample

- clone upstream 到 `upstream/splunk-ao-python`
- copy current `after` sample 到 `app/`
- 不修改 upstream clone

## Phase 3 — Code modification

- generic LLM factory
- fix dotenv/import ordering
- eliminate import-time agent creation
- Pinecone safe resolver
- remove runtime `OpenAIEmbeddings`
- add bounded timeouts/retries
- experiment runner

## Phase 4 — Pinecone inventory/resolve

- inspect existing `credit-card-information`
- reuse only if compatible
- otherwise preserve it and create/use isolated `credit-card-information-qwen-demo`

在 report 中写明最终 selected index 和为什么。

## Phase 5 — Local functional validation

- Chainlit
- tool paths
- RAG
- Splunk AO traces

## Phase 6 — Splunk AO manual checkpoint

暂停，让用户确认现有 Qwen Integration + 4 evaluator + enablement。

不修改 Judge，即便 Application fallback 到 Bailian。

## Phase 7 — Dynamic ACK discovery

- source RAM env only when needed
- read `$ACK_BYOCNI_DIR` Terraform outputs
- prefer current infra repo `./kubeconfig`
- validate context exactly `ack-byocni-demo`
- if kubeconfig stale but active cluster exists，dynamically regenerate into `.secrets/ack-kubeconfig`
- never assume previous cluster ID

## Phase 8 — Docker build/push

- determine ACK arch
- build
- local container smoke test
- push
- record digest

## Phase 9 — ACK deployment

- namespace
- Secrets
- ConfigMap
- Deployment
- ClusterIP Service
- rollout status
- pod logs/events

## Phase 10 — ACK network validation

From Pod/debug pod validate：

- DNS
- selected Application LLM endpoint
- Pinecone
- Splunk AO endpoint

如果 resolved Application model 是 Bailian，明确验证 ACK -> Bailian 北京 endpoint。

## Phase 11 — End-to-end live demo

- port-forward
- browser/manual interaction
- tool calls
- RAG
- Splunk AO trace
- four Qwen evaluator results

## Phase 12 — Optional Experiment

仅在实时链路成功后执行。

---

# 22. Demo test cases

Credit score：

```text
What is my credit score?
```

期待：

```text
Supervisor -> Credit Score Agent -> Credit Score Tool
```

Credit card RAG：

```text
What are the cashback rewards offered by the Orbit Credit Card?
```

期待：

```text
Supervisor -> Credit Card Agent -> Pinecone Retrieval
```

再添加一个 out-of-scope 问题，验证 supervisor 和 evaluator 行为。

---

# 23. Acceptance criteria

## Application

- ACK Deployment Ready 1/1
- Chainlit 可通过 port-forward 访问
- resolved model 有明确记录
- 若 vLLM tool calling 可用，则应用必须使用 `qwen3-14b-fp8`
- 只有 vLLM chat 成功而 tool capability 不满足时才允许使用 `qwen3.7-flash`
- selected provider tool calling 实际工作
- Credit Score tool flow 正常
- Pinecone RAG flow 正常
- 不需要 OpenAI API Key

## Splunk AO

Project：

```text
hangwe-Multi-Agent Banking Chatbot - Qwen Judge Demo
```

Agent Stream：

```text
hangwe-Default Agent Stream - Qwen Judge
```

能看到新 trace，并尽可能看到：

- supervisor
- child agents
- tools
- model calls
- timing/token data

## Evaluators

以下四个均产生结果：

- Action Advancement - Qwen
- Action Completion - Qwen
- Tool Errors - Qwen
- Tool Selection Quality - Qwen

Judge 仍为 vLLM Qwen3-14B-FP8，除非用户明确另行改变。

## Pinecone

- 原 `credit-card-information` 未被删除/重建/盲目覆盖。
- 最终 selected index 及理由写入 report。

## ACK lifecycle safety

- 没有依赖历史固定 cluster_id。
- 每次部署动态读取当前 BYOCNI Terraform state / kubeconfig。
- 没有修改全局 kube context。
- 没有调用 `./kiall`。

## Secrets

- no secret in Git
- no real `.env` in image
- no plaintext Secret manifest committed
- no secret in logs/report

---

# 24. Stop conditions

立即停止而非继续猜：

- vLLM auth/network/model configuration failure
- vLLM chat fails（不能把它错误解释为 tool capability failure）
- vLLM tool capability fails且 Bailian fallback 也失败
- Bailian API key/base URL/workspace 不匹配
- ACK Terraform state 无 active cluster 且 `ALLOW_ACK_CREATE=0`
- kubeconfig/context 指向不明确
- ACK Pod 无法访问 resolved model endpoint
- Splunk AO Playground 无法访问 Judge vLLM integration
- Custom Evaluator name 不确定
- 需要修改 Splunk AO control plane
- 现有 Pinecone index compatibility 不明且写操作有风险
- isolated Pinecone demo index 已存在但 schema/model 不兼容
- secret 被 Git tracked
- Docker Hub image pull 在 ACK 失败
- 需要公网 LoadBalancer/EIP
- 大范围 dependency conflict
- destructive Git/cloud action would be required

停止时输出：

1. 已完成 phase
2. 失败的精确命令/操作
3. 脱敏错误
4. 最小人工动作
5. 完成后从哪个命令继续

同一个失败调用不要无意义重复消耗 token。

---

# 25. Required deliverables

至少：

```text
README.md
DEPLOYMENT_REPORT.md
.env.example
.deploy.env
Dockerfile
.dockerignore

app/...

scripts/preflight_models.py
scripts/discover_ack.sh
scripts/setup_pinecone.py

deploy/k8s/namespace.yaml
deploy/k8s/configmap.yaml
deploy/k8s/deployment.yaml
deploy/k8s/service.yaml
deploy/k8s/README.md
```

可增加：

- lock file
- `experiment.py`
- Experiment Job
- smoke scripts

`README.md` 必须写清：

- architecture
- model fallback policy
- where to put Bailian API Key
- local setup
- Pinecone safe handling
- Docker build/push
- dynamic ACK discovery
- ACK deploy
- port-forward
- Splunk AO manual checkpoint
- live validation
- experiment
- cleanup

`DEPLOYMENT_REPORT.md` 必须记录：

- date
- upstream SHAs
- dependency versions
- primary vLLM preflight result
- fallback preflight result（如执行）
- final resolved Application model provider/model
- image tag/digest
- current dynamically discovered ACK cluster ID/name/version
- namespace
- selected Pinecone index
- Splunk Project/Agent Stream
- exact evaluator names
- acceptance result
- known limitations

不得记录任何 Secret。

---

# 26. Cleanup 与重复创建/销毁

Galileo App 自身需要清理时，可删除：

```text
galileo-demo namespace
```

但执行前必须确认 current kubeconfig 指向**当前** ACK BYOCNI cluster。

如果用户后续通过 infra repo：

```bash
./kiall
```

销毁整套 ACK 环境，则 Galileo namespace 会随 cluster 一起消失，不需要额外优雅卸载。

本任务 Codex 不负责执行 `./kiall`，除非用户当次明确要求。

下一次 `./kup` 得到新 cluster 后，重新执行本任务的 dynamic ACK discovery + deploy phases；不得复用上一次 cluster ID/kubeconfig。

---

# 27. Token-efficiency rules

- 先读本任务书，再行动。
- 先 preflight，再改代码。
- 先本地 smoke，再 build。
- 先确定当前 ACK，再 deploy。
- Splunk AO 控制面需要写操作就停，不逆向复杂 API payload。
- 不反复随机试 dependency versions。
- 大日志写本地文件，只总结关键行。
- Secret 永远脱敏。
- 不对同一个失败 endpoint 做大量重复调用。

---

# 28. Definition of Done

必须真实验证：

```text
Browser
 -> ACK Chainlit
 -> LangGraph Supervisor
 -> Child Agent
 -> Tool / Pinecone
 -> resolved Application LLM
```

其中 resolved model 满足：

```text
vLLM qwen3-14b-fp8
OR
Bailian qwen3.7-flash (only after primary tool-capability failure)
```

同时：

```text
Agent execution
 -> Splunk AO
 -> Trace/Session
 -> 4 existing Qwen Evaluators
 -> vLLM qwen3-14b-fp8 Judge
```

并满足：

```text
No OpenAI API dependency
No secret leakage
No destructive Pinecone changes
No fixed ACK cluster ID assumption
No automatic Splunk AO control-plane writes
No unnecessary public ACK resources
```
