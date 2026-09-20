# 从 Splunk 官方单机 Demo 到 ACK 第一次安装

本文是一份实施指南，目标环境是：**ACK 已经存在，但从未安装过 Multi-Agent Banking Chatbot**。

最终结果是：

- Splunk 官方 Chainlit/LangGraph 单机示例被整理为可验证的应用源码；
- 应用模型、Pinecone 和 Splunk AO 后端在构建前完成预检；
- 源码被制作成可追溯的 `linux/amd64` 非 root 镜像并推送到 ACK 可访问的 registry；
- ACK 中第一次创建 Galileo namespace、Secret、ConfigMap、Deployment 和 ClusterIP Service；
- 应用通过 image、rollout、跨 namespace HTTP、prompt、模型、Pinecone 和 Splunk AO 连通性验收；
- 后续演示按 [README.md](README.md) 操作。

本文不负责创建、销毁、升级或日常维护 ACK。VPC、ACK、Worker、Cilium、Hubble、Tetragon、Timescape、
测试 workload，以及自动安装整套 ACK 和全部应用（包括本应用），统一由
[alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) 管理。本仓库只完成应用从官方示例到
第一次安装进既有 ACK 的链路。

## 1. 先理解边界

```text
Splunk 官方单机 Demo
  |
  | 本仓库负责
  v
应用适配 -> 本地验证 -> Pinecone 数据 -> 镜像 build/push -> 第一次 Galileo-only 安装
  |
  | 共享 contract
  v
kup.conf + GALILEO_* + immutable image digest + ./kup --galileo-only

ACK/VPC/CNI/平台组件/全部应用自动化/日常运维
  `-> alicloud-ack-byocni 负责
```

不要在本仓库重新建立 Terraform、ACK 动态发现、CNI 安装、Helm 平台组件或另一套 Kubernetes 部署入口。
否则两个仓库会重新出现不同的事实来源。

## 2. 起点和前置条件

### 2.1 既有 ACK 应满足的条件

目标集群应已经按 `alicloud-ack-byocni` 的 contract 建成并验收：

- ACK API 可访问；
- 节点和 CNI Ready；
- 本机有项目私有 kubeconfig；
- kubeconfig 中存在稳定 context，默认 `ack-byocni-demo`；
- `test` namespace 中有 label 为 `app=testcurl` 的测试 Pod，用于跨 namespace HTTP 验收；
- ACK Node 架构为 `amd64`，或至少能运行本指南发布的 `linux/amd64` 镜像；
- 节点能访问目标私有 registry、应用模型、Pinecone 和选定的 Splunk AO/Galileo 后端。

如果 ACK 尚不存在，或者需要从零自动安装 ACK、Cilium/Hubble/Tetragon/Timescape 和全部演示应用，请停止
本文流程，先使用 [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni)。不要从本仓库
手工拼装平台。

### 2.2 工作站工具

- Git；
- Python 3.11–3.13，示例使用 Python 3.12；
- Docker Engine/Desktop 与 Docker Buildx；
- curl；
- kubectl；
- 能访问 ACK API、模型、Pinecone、Splunk AO 后端和镜像 registry 的网络。

### 2.3 外部服务

- 一个 ACK 可拉取、当前操作者可推送的镜像 repository；
- 一个支持 OpenAI-compatible Chat Completions 和标准 Tool Calling 的模型 endpoint；
- 一个 Pinecone 账号；
- 下文两套后端之一的 API key、Project 和 Agent Stream/Log Stream。

## 3. 选择 Splunk AO 后端，禁止混用 API

当前工程可能使用两套后端。部署前必须先选定一套；Console URL、API key、Project、Stream、REST base URL
和鉴权 Header 必须来自同一后端。

| 项目 | Splunk Agent Observability | Galileo Hosted |
|---|---|---|
| Console URL | `https://console.multitenant.galileocloud.io` | `https://app.galileo.ai/` |
| 产品文档 | [Splunk AO](https://agent-observability-docs.splunk.com/what-is-splunk-agent-observability) | [Galileo](https://docs.galileo.ai/what-is-galileo) |
| 原生 API base | `https://api.multitenant.galileocloud.io/` | `https://api.galileo.ai` |
| 原生 API key Header | `Splunk-AO-API-Key` | `Galileo-API-Key` |
| Python SDK | `splunk-ao` | `galileo` |
| 在线数据容器 | Project + Agent Stream | Project + Log Stream |
| API 文档 | [Splunk AO REST API](https://agent-observability-docs.splunk.com/api/getting-started) | [Galileo REST API](https://docs.galileo.ai/api/getting-started) |

Splunk AO 官方规则是：自托管/定制环境把浏览器 Console URL 中的 `console` 换成 `api` 得到 API base，
所以 `console.multitenant.galileocloud.io` 对应 `api.multitenant.galileocloud.io`。Galileo 官方文档则明确指定
Hosted Console `app.galileo.ai` 使用 `api.galileo.ai`。

本应用使用 `splunk-ao` SDK，并把私有 `kup.conf` 中的 `GALILEO_SPLUNK_AO_*` 映射为 Pod 内的
`SPLUNK_AO_*`。SDK 对 `app.galileo.ai` 保留兼容桥，但任何直接 REST API 自动化仍必须使用上表对应的
API base 和 Header：

- 对 Splunk AO 后端的 API 操作，明确标为 **Splunk AO API**，使用 `Splunk-AO-API-Key`；
- 对 Galileo Hosted 的 API 操作，明确标为 **Galileo Hosted API**，使用 `Galileo-API-Key`；
- 不把一套后端的 key、Project ID、Agent Stream/Log Stream ID 传给另一套；
- 不把 Console URL 当 REST base URL；
- 不在 shell 历史、日志或文档中打印 API key。

本次第一次安装推荐在所选后端 UI 中创建或确认 Project 和 Agent Stream/Log Stream。若组织要求通过 API
自动化，则必须按所选后端的官方 API 文档实现，不能复制另一后端的 curl。

## 4. 获取本仓库与官方来源

克隆本仓库：

```bash
git clone https://github.com/highopes/galileo-demo.git
cd galileo-demo
```

应用来自 Splunk 官方仓库
[`splunk/splunk-ao-python`](https://github.com/splunk/splunk-ao-python) 的：

```text
examples/agent/langgraph-fsi-agent/after
```

本仓库核对的上游提交：

```text
53b9df9c4ae01f940a55a08d446b2212f67ff94c
```

对应的官方教程是
[Add Evaluations to a Multi-Agent LangGraph Application](https://agent-observability-docs.splunk.com/cookbooks/use-cases/multi-agent-langgraph/multi-agent-langgraph)。

如果需要审计“官方单机版到本仓库”的差异，可在 Git 忽略的 `upstream/` 下准备只读副本：

```bash
git clone https://github.com/splunk/splunk-ao-python.git upstream/splunk-ao-python
git -C upstream/splunk-ao-python checkout 53b9df9c4ae01f940a55a08d446b2212f67ff94c
diff -ru \
  --exclude=.venv \
  --exclude=__pycache__ \
  upstream/splunk-ao-python/examples/agent/langgraph-fsi-agent/after \
  app
```

`upstream/` 只用于来源审计，不进入 Git，也不进入 Docker build context。

## 5. 官方单机应用做了哪些 ACK 化改造

官方 `after` 示例包含 Chainlit、LangGraph supervisor、credit-card agent、credit-score agent、Pinecone Tool
和 Splunk AO callback。本仓库保留原故事，但增加了可部署性：

### 5.1 模型配置

- 不再依赖默认 OpenAI 配置；
- 使用统一 OpenAI-compatible model factory；
- 支持配置的 Bailian 或 vLLM endpoint；
- model ID、base URL、API key、timeout、retry 全部显式配置；
- supervisor 和两个 sub-agent 使用同一最终模型；
- import Python module 时不建立外部连接。

### 5.2 Pinecone

- 不再要求 OpenAI Embeddings；
- 使用 Pinecone integrated text search；
- index、namespace、text field 全部配置化；
- `app/source-docs/credit-cards/` 保存构建演示知识库的资料；
- retriever Tool 形成独立 Splunk AO span。

### 5.3 Prompt profile

- `baseline`：保留官方 supervisor 没声明 credit-score 能力的缺陷；
- `improved`：明确声明 credit-score agent 并正确交付结果；
- `custom`：从受控文件/ConfigMap 加载；
- Qwen 使用 `app/prompts/supervisor-baseline-qwen.txt` 重现官方故障语义；
- 每个新 Chainlit chat 固定自己的 graph/prompt，防止一次 Trace 中途变更。

### 5.4 容器与 Kubernetes

- Python 3.12 slim 镜像；
- lock 文件安装依赖；
- 非 root 用户；
- readiness/liveness/startup probe；
- Secret、ConfigMap 和 imagePullSecret 分离；
- image 使用不可变 digest；
- source commit 写入 Deployment annotation；
- prompt 通过 projected ConfigMap 热加载；
- Service 为 ClusterIP，不创建公网入口。

## 6. 创建唯一私有配置

```bash
cp kup.conf.example kup.conf
chmod 600 kup.conf
```

`kup.conf` 是本仓库唯一配置来源。不要恢复 `.secrets/*.env`、`.deploy.env` 或 resolved env。

### 6.1 ACK 连接

```text
KUP_WORKDIR
KUBECONFIG_FILE
ACK_CONTEXT
TEST_NAMESPACE
```

默认 kubeconfig 路径是仓库根目录的 `kubeconfig`，context 为 `ack-byocni-demo`。

### 6.2 镜像来源与 registry

```text
GALILEO_SOURCE_URL
GALILEO_SOURCE_COMMIT
GALILEO_IMAGE_REF
GALILEO_REGISTRY_SERVER
GALILEO_REGISTRY_USERNAME
GALILEO_REGISTRY_PASSWORD
```

第一次 build 前，`GALILEO_IMAGE_REF` 可以暂时保留 `ReplaceMe`；发布脚本会同时写入真实 source commit 和
immutable digest。Registry repository 应预先存在。

### 6.3 Splunk AO/Galileo 后端

```text
GALILEO_SPLUNK_AO_API_KEY
GALILEO_SPLUNK_AO_PROJECT
GALILEO_SPLUNK_AO_AGENT_STREAM
GALILEO_SPLUNK_AO_CONSOLE_URL
```

这些字段都必须指向第 3 节选定的同一后端。对于 Galileo Hosted，配置名仍叫 `AGENT_STREAM`，运行时
SDK 会兼容映射到 Log Stream；它不是允许混用后端 API 的信号。

### 6.4 应用模型

```text
GALILEO_APP_MODEL_PROVIDER
GALILEO_APP_MODEL_NAME
GALILEO_APP_MODEL_BASE_URL
GALILEO_APP_MODEL_API_KEY
GALILEO_MODEL_REQUEST_TIMEOUT
GALILEO_MODEL_MAX_RETRIES
```

base URL 必须是 HTTPS；model name 必须是 `/models` 实际返回的精确 ID。

### 6.5 Pinecone 与 prompt

```text
GALILEO_PINECONE_API_KEY
GALILEO_PINECONE_INDEX_NAME
GALILEO_PINECONE_NAMESPACE
GALILEO_PINECONE_TEXT_FIELD
GALILEO_SUPERVISOR_PROMPT_PROFILE
GALILEO_BASELINE_PROMPT_VARIANT
```

GPT/OpenAI 类模型通常选择 `baseline + official`；Qwen/千问选择 `baseline + qwen`。

## 7. 准备 Python 环境并运行离线测试

```bash
python3.12 -m venv app/.venv
app/.venv/bin/python -m pip install --upgrade pip
app/.venv/bin/python -m pip install -r app/requirements.lock
app/.venv/bin/python -m pip check
(cd app && .venv/bin/python -m unittest discover -s tests -v)
```

`requirements.lock` 同时是 Dockerfile 的安装输入，避免本地与镜像解析出不同依赖。项目固定
`langgraph-supervisor==0.0.26`，并约束 `langgraph-prebuilt<0.3`，以保持与 LangGraph 0.4.x 兼容。

离线测试应在没有模型、Pinecone、Splunk AO 和 ACK 连接的情况下通过；它检查配置、prompt profile 和
import-time 外部副作用。

## 8. 验证最终应用模型

```bash
app/.venv/bin/python scripts/preflight_models.py
```

脚本直接读取 `kup.conf`，不会生成第二份 resolved 配置，也不会自动 fallback。它依次检查：

1. DNS、TCP、TLS；
2. `GET /models` 是否包含精确 model ID；
3. 普通 Chat Completions；
4. 原始 OpenAI-compatible `tool_calls` 两轮往返；
5. LangChain `bind_tools` 与 ToolMessage 往返。

只有普通 Chat 成功不代表能运行 Agent。如果 endpoint 不返回标准 call ID/arguments，或不能继续 ToolMessage，
应停止并选择支持标准 Tool Calling 的模型，再更新 `kup.conf` 后重跑。预检通过前不要 build 镜像。

历史实施曾发现一个 vLLM endpoint 可以普通聊天，但不能完成标准 Tool round-trip；Bailian
`qwen3.7-flash` 完成了全部检查。这个事实只解释为什么必须做 capability preflight，不代表所有部署都必须
选择同一个模型。

## 9. 准备隔离的 Pinecone 数据

先做只读 inventory：

```bash
app/.venv/bin/python scripts/setup_pinecone.py inventory
```

结果写入 Git 忽略、权限受限的 `runtime/pinecone-inventory.json`。默认受保护 index 为
`credit-card-information`；目标 Demo index 来自 `GALILEO_PINECONE_INDEX_NAME`。二者同名时脚本停止。

创建或补齐隔离 index：

```bash
app/.venv/bin/python scripts/setup_pinecone.py prepare
app/.venv/bin/python scripts/setup_pinecone.py smoke
```

默认 `prepare`：

- 创建 AWS `us-east-1`、`llama-text-embed-v2` integrated embedding index；
- 验证已有目标 index 的 model 和 text field，不兼容时停止而不是删除；
- 把 `app/source-docs/credit-cards/*.md` 切块；
- 用稳定 ID 写入配置的 namespace；
- 等待 Orbit cashback 查询命中当前资料。

如组织使用不同 cloud、region 或 integrated embedding model，使用脚本 `--help` 的显式参数。禁止猜测旧
BYOV index 的 embedding，也不要用生产/共享 index 做演示写入。

## 10. 准备后端 Project/Stream 并做本地验收

### 10.1 在正确后端确认对象

按 `GALILEO_SPLUNK_AO_CONSOLE_URL` 打开第 3 节选择的 Console，确认：

- Project 存在；
- `kup.conf` 中的 Project 和 Agent Stream/Log Stream 名称属于该后端；
- API key 属于同一后端并有 trace ingestion 权限。

Project 应预先创建。Agent Stream/Log Stream 可以预先创建；如果不存在且 API key 有权限，SDK 会在第一次
Trace 时按配置名称创建。无论哪种方式，第一次本地 smoke 后都必须在 UI 中确认它存在并收到了 Session。

如果通过 API 创建或查询对象：

- Splunk 后端只使用 Splunk AO API base/Header；
- Galileo Hosted 只使用 Galileo API base/Header；
- 在实施记录中写明是哪一种后端，不要写成模糊的“Galileo API”。

### 10.2 启动本地 Chainlit

```bash
./scripts/run_local.sh
```

浏览器打开 <http://127.0.0.1:8000>，新建聊天并至少验证：

```text
What are the cashback rewards offered by the Orbit Credit Card?
What is my credit score?
Recommend me a good book.
```

### 10.3 真实 smoke

```bash
app/.venv/bin/python scripts/local_smoke.py
```

这个命令会调用真实 model、Pinecone 和选定的 Splunk AO/Galileo 后端，并写入一条标记为 baseline 的
Session。它不是离线测试。执行后到**同一套后端**的正确 Project/Stream 中确认 Trace 已出现，能展开
supervisor、sub-agent、model、Tool 和 retriever。

baseline 的拒答是教学现象，不应被当成基础设施失败。模型认证、Pinecone 检索或 Trace ingestion 失败则
必须在构建前解决。

## 11. 理解生产镜像内容

Dockerfile：

- 基于 `python:3.12-slim`；
- 通过 `app/requirements.lock` 安装并 `pip check`；
- 创建系统用户 `app`；
- 工作目录 `/opt/banking-demo`；
- Chainlit 监听 `0.0.0.0:8000`；
- 不把 API key、`kup.conf`、kubeconfig、runtime、venv、Git 或 upstream checkout 放入镜像。

Pinecone source docs 在 build 前用于准备外部 index，不需要进入运行镜像。Prompt 由代码内置 profile 或 ACK
ConfigMap 投影提供，运行时切换不要求重新 build。

## 12. 构建、冒烟、推送不可变镜像

镜像必须对应一个确定的 Git commit。先检查并提交应用改动：

```bash
git status --short
git rev-parse HEAD
```

工作树必须干净；私有 `kup.conf` 和 kubeconfig 被 Git 忽略，不影响检查。

第一次发布时显式给出无 tag/digest 的 repository：

```bash
./scripts/build_push.sh registry.example.com/project/multi-agent-banking
```

脚本会：

1. 确认 repository 属于 `GALILEO_REGISTRY_SERVER`；
2. 读取完整 HEAD SHA；
3. 构建本地 `linux/amd64` 镜像；
4. 验证容器 UID 为 `999`；
5. 启动容器并完成本地 Chainlit HTTP smoke；
6. 用临时 Docker credential 目录登录 registry；
7. push 带时间和短 SHA 的 tag；
8. 从 registry 解析完整 `sha256` digest；
9. 原子更新私有 `kup.conf` 中的 `GALILEO_SOURCE_COMMIT` 和 `GALILEO_IMAGE_REF`；
10. 清除临时 Docker credential。

以后同一 repository 发布时可以省略参数：

```bash
./scripts/build_push.sh
```

检查来源成对更新：

```bash
grep -E '^GALILEO_(SOURCE_COMMIT|IMAGE_REF)=' kup.conf
```

ACK 只使用 `repository@sha256:...`，不使用 `latest` 或可变 tag。build/push 脚本本身不连接或修改 ACK。

## 13. 准备项目 kubeconfig

从管理该 ACK 的 `alicloud-ack-byocni` 工作目录复制其项目私有 kubeconfig：

```bash
cp /path/to/alicloud-ack-byocni/kubeconfig ./kubeconfig
chmod 600 kubeconfig
```

不要合并到 `~/.kube/config`，不要依赖全局 current-context。先做只读检查：

```bash
kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo get --raw=/readyz
kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo get nodes
kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo \
  -n test get pod -l app=testcurl
```

任何一项不满足时，回到
[alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) 修复平台。不要在本仓库复制一套 ACK
修复流程。

## 14. 第一次安装到 ACK

确认：

- `kup.conf` 和 `kubeconfig` 权限为 0600；
- source SHA 为 40 位小写 Git SHA；
- image 是完整 immutable digest；
- registry credential 有 pull 权限；
- model/Pinecone/backend 已通过本地验收；
- 当前 context 确实是目标 ACK。

执行唯一应用安装入口：

```bash
./kup --galileo-only
```

第一次运行会在尚无 Banking Chatbot 的 ACK 中：

1. 检查配置、占位符、URL、source SHA 和 image digest；
2. 显式使用项目 kubeconfig/context 检查 ACK `/readyz`；
3. 在 `runtime/` 渲染不含 Secret 值的 manifest；
4. 创建 `galileo-demo` namespace；
5. 创建 `splunk-ao-banking-qwen-runtime` Secret；
6. 创建 `galileo-registry-pull` imagePullSecret；
7. 创建 `splunk-ao-banking-qwen-config` ConfigMap；
8. 创建 `splunk-ao-banking-qwen` Deployment；
9. 创建同名 ClusterIP Service；
10. 等待 Pod rollout/Ready；
11. 按 `GALILEO_SUPERVISOR_PROMPT_PROFILE` 与 baseline variant 收敛 prompt；
12. 验证运行镜像、source annotation、Service endpoint、跨 namespace HTTP、projected prompt、应用实际
    profile、精确 model ID、Pinecone search 和后端 HTTPS。

这个模式不会运行 Terraform，不会安装 Helm chart，不会创建/销毁 ACK，也不会修改 Node、Cilium、Hubble、
Tetragon、Timescape 或其他 namespace 的应用。

## 15. 第一次安装后的验收

定义只读 wrapper：

```bash
kctl() {
  kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo "$@"
}
```

### 15.1 资源与镜像

```bash
kctl -n galileo-demo get deployment,pods,service,endpoints
kctl -n galileo-demo get deployment splunk-ao-banking-qwen \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kctl -n galileo-demo get deployment splunk-ao-banking-qwen \
  -o jsonpath='{.spec.template.metadata.annotations.demo\.openai\.com/source-revision}{"\n"}'
```

期望：Deployment `1/1 Ready`、唯一应用 Pod Ready、Service 有 endpoint、image 为 `@sha256:`、source commit
与本次 build 一致。

### 15.2 Prompt

```bash
./scripts/switch_prompt.sh status
```

configured、mounted、resolved profile 应一致。Qwen baseline 在应用中显示为 `custom` 是预期行为，因为它
通过 Qwen 专用文件热加载；GPT official baseline 显示为 `baseline`。

### 15.3 Web

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n galileo-demo \
  port-forward svc/splunk-ao-banking-qwen 8000:80
```

打开 <http://127.0.0.1:8000>，新建聊天运行至少三个 smoke 问题：

```text
What are the cashback rewards offered by the Orbit Credit Card?
What is my credit score?
Recommend me a good book.
```

然后在配置对应的同一 Splunk AO/Galileo 后端确认 Session/Trace 已到达。不要因为两个 Console 都能登录就
在错误后端寻找数据。

完整六提示词演示、讲解话术和 baseline -> improved 流程见 [README.md](README.md)。

## 16. 首次安装完成后的职责移交

本指南到首次验收通过为止。此后：

| 后续工作 | Authority |
|---|---|
| Chainlit Demo 1、六个提示词、prompt 修复演示 | 本仓库 [README.md](README.md) |
| 重新构建 Galileo 应用镜像 | 本仓库 `scripts/build_push.sh` |
| 只刷新 Galileo 应用配置/镜像 | 两仓库兼容的 `./kup --galileo-only` |
| ACK 日常状态、节点、CNI、Hubble、Tetragon、Timescape | [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) |
| 自动创建/销毁整套 ACK | [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) |
| 自动收敛 ACK 中全部演示应用，包括本应用 | [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) |

不要把平台运维说明复制回来。平台仓库是唯一 authority，本仓库只维护应用源码、镜像发布知识、第一次
应用安装和演示手册。

## 17. 安全与可追溯性检查表

- [ ] `kup.conf`、kubeconfig 为 0600 且未提交；
- [ ] 没有 `.secrets/`、`.runtime/`、`.deploy.env` 或 resolved env；
- [ ] API key、registry password 没有写入 README、report、manifest 或镜像；
- [ ] 选定后端的 Console/API base/Header 没有混用；
- [ ] Project 和 Agent Stream/Log Stream 属于同一后端；
- [ ] model preflight 的五层检查全部通过；
- [ ] Pinecone Demo index 与受保护 index 隔离；
- [ ] Git 工作树干净后才构建；
- [ ] `GALILEO_SOURCE_COMMIT` 与 `GALILEO_IMAGE_REF` 成对更新；
- [ ] ACK 使用不可变 `@sha256:`，不使用 `latest`；
- [ ] Service 保持 ClusterIP，没有临时公网 LoadBalancer；
- [ ] 所有 kubectl 显式使用项目 kubeconfig/context；
- [ ] 安装没有触碰 ACK 平台组件和其他 workload。

## 18. 已验证的实施经验

这些问题已经在历史实施中出现，并被当前流程固化：

1. 友好模型名可能不是 endpoint 的真实 ID，必须以 `/models` 为准；
2. 普通 Chat 成功不代表 Tool Calling 兼容，必须完成 raw + LangChain round-trip；
3. 未知 embedding 的旧 Pinecone index 不应被猜测或覆盖，应建立隔离 integrated index；
4. baseline 拒答是教学设计，不能通过修改 Tool 或伪造返回值“修好”；
5. Qwen 可能推断出官方 prompt 遗漏，需使用专门校准的 custom baseline；
6. Kubernetes `runAsNonRoot` 不能只依赖镜像用户名，manifest 显式使用 UID/GID 999；
7. prompt 不应写死为唯一版本，projected ConfigMap 允许在不换镜像、不重启 Pod 的情况下切换；
8. registry tag 只供阅读，部署 identity 必须是 digest；
9. Dataset 中的旧 reference 可能与当前 Pinecone 文档漂移，不能让 Agent 编造事实去迎合旧答案；
10. 后端名称相近不代表 API 相同，Splunk AO 与 Galileo Hosted 的 base URL/Header 必须分别处理。

## 19. 本次文档修订的非操作声明

本次修订只改写本仓库帮助文档：

- 没有修改 `alicloud-ack-byocni`；
- 没有运行 `./kup --galileo-only`；
- 没有执行 kubectl apply/patch、Terraform、Helm 或 Alibaba Cloud API；
- 没有 build/push 镜像；
- 没有写入 Pinecone；
- 没有调用任一 Splunk AO/Galileo 后端的写 API；
- 没有改变当前运行中的 ACK。
