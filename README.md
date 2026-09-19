# Splunk Agent Observability Multi-Agent Banking Demo on ACK

这个仓库是一套从 Splunk 官方示例出发、最终部署到 Alibaba Cloud ACK 的完整教学工程。它不是
`alicloud-ack-byocni` 的 Galileo 子目录副本，也不负责创建 ACK 基础设施。

读完并实际走完本文，团队成员应当能够回答四个问题：

1. Splunk Agent Observability（下文简称 Splunk AO）在 Agent 应用中观察什么；
2. 官方 Multi-Agent Banking Demo 的图、Agent、Tool 和数据流是怎样组成的；
3. 怎样把这个 Python 示例验证、制作成不可变的 `linux/amd64` 镜像并发布到镜像仓库；
4. 怎样在已经由
   [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni)
   管理的 ACK 上部署它，并继续使用与该仓库完全兼容的配置和运维命令。

本仓库负责“官方示例 -> 可验证源码 -> 不可变镜像 -> Galileo 应用部署与演示”；
`alicloud-ack-byocni` 负责“VPC/ACK/Cilium/Hubble/Tetragon 等平台生命周期”。镜像发布以后，两边都以
同一组 `GALILEO_*` 变量、同一份 Kubernetes 模板和同一套命令运维应用：

```bash
./kup --galileo-only
./scripts/switch_prompt.sh status
./scripts/switch_prompt.sh improved
```

## Splunk AO 在这个 Demo 中做什么

普通日志只能告诉我们“应用报错了没有”。一个多 Agent 系统还需要回答：模型为什么选择这个 Agent、
是否调用了正确 Tool、Tool 返回后 supervisor 是否完成了用户任务，以及一次 prompt 修改究竟让结果变好
还是变坏。

这个 Demo 用 Splunk AO 表达两种互补的观察方式：

- **在线 Session/Trace**：每个新 Chainlit 对话创建一个 Splunk AO Session；LangChain callback 把
  supervisor、sub-agent、model 和 tool 调用记录成可展开的执行链。
- **Retriever span**：Pinecone Tool 使用 `@log(span_type="retriever")` 标记检索过程，便于把检索与
  最终回答联系起来。
- **Evaluator**：Agent Stream 上的 Action Advancement、Action Completion、Tool Errors 和
  Tool Selection Quality 用于解释在线行为，而不只是看最终一句答案。
- **Experiment**：同一个 Dataset 分别运行 baseline 与 improved prompt，形成可重复的批量对比。

Splunk AO 不替代模型、Pinecone 或 Kubernetes。它观察并评价应用执行；应用模型仍由 Bailian 或 vLLM
提供，信用卡知识仍从 Pinecone 检索，应用进程仍运行在 Chainlit/LangGraph 中。

## 官方 Demo 的来源与本仓库的改造

应用基于 Splunk 官方仓库
[splunk/splunk-ao-python](https://github.com/splunk/splunk-ao-python)
中的 `examples/agent/langgraph-fsi-agent/after`，本仓库核对的上游提交为：

```text
53b9df9c4ae01f940a55a08d446b2212f67ff94c
```

官方 `after` 示例已经展示了 Chainlit、LangGraph supervisor、两个 Agent 和 Splunk AO callback。本仓库
保留这条教学主线，但为可重复部署做了以下必要改造：

- 用一个显式的 OpenAI-compatible 模型工厂支持 Bailian 或 vLLM，并在启动前校验 provider、model、
  HTTPS endpoint、timeout 和 retry；
- 直接使用 Pinecone integrated embedding search，不再要求 OpenAI Embeddings；
- 把 Pinecone index、namespace 和 text field 全部配置化；
- 把 supervisor prompt 做成 `baseline`、`improved`、`custom` 三种运行时 profile；
- 每个新聊天才解析并固定 prompt，确保一次对话不会在中途混用两个 profile；
- 增加离线测试、真实依赖 smoke、Experiment runner、容器定义和 ACK 资源模板；
- 把部署输入统一为与 `alicloud-ack-byocni` 一致的 `kup.conf` / `GALILEO_*` contract。

如需审阅改造，可以把官方仓库放在 Git 忽略的 `upstream/` 下，再比较官方 `after` 与本仓库 `app/`。
构建镜像不依赖 `upstream/`，Docker context 也明确排除了它。

## 应用结构与一次请求的执行过程

```text
Browser
  |
  v
Chainlit (app/app.py)
  |-- 新聊天：选择 prompt profile，创建 LangGraph，启动 Splunk AO Session
  |
  v
Brahe Bank Supervisor
  |-- 信用卡问题 ----------> Credit Card Agent
  |                            `-> Pinecone retrieval Tool -> 产品文档
  |
  `-- 信用分问题 ----------> Credit Score Agent
                               `-> deterministic Tool -> "Your credit score is 550"

所有 supervisor / agent / model / tool 调用
  `-------------------------------------------> Splunk AO trace + evaluators
```

关键实现分别位于：

| 位置 | 作用 |
|---|---|
| `app/app.py` | Chainlit 入口、聊天生命周期、流式输出、Splunk AO Session |
| `app/src/.../agents/supervisor_agent.py` | 编译 supervisor graph 并挂接两个 Agent |
| `app/src/.../agents/credit_card_information_agent.py` | 创建带 Pinecone Tool 的 ReAct Agent |
| `app/src/.../agents/credit_score_agent.py` | 创建带固定信用分 Tool 的 ReAct Agent |
| `app/src/.../tools/pinecone_retrieval_tool.py` | integrated text search 和 retriever span |
| `app/src/.../tools/credit_score_tool.py` | 为教学提供确定性的 `550` fixture |
| `app/src/.../prompt_profiles.py` | baseline、improved、custom prompt 解析 |
| `app/experiment.py` | 在已有 Splunk AO Dataset/Evaluator 上运行 Experiment |
| `app/source-docs/credit-cards/` | 创建演示 Pinecone 数据时使用的信用卡资料 |

### 为什么故意保留一个错误版本

官方故事的重点不是证明 Agent 永远正确，而是展示可观测性怎样发现和修复 Agent 编排问题。Graph 中一直
存在 credit-score agent，Tool 也一直能返回 `550`；baseline supervisor 却没有把 credit-score 能力列入
受支持能力，最终可能漏答或拒答。improved prompt 明确加入该能力，因此能够把 Tool 结果交付给用户。

`qwen3.7-flash` 有时会仅凭 Tool schema 推断出缺失能力，使官方 baseline 看上去“意外正确”。因此仓库
另外提供 `app/prompts/supervisor-baseline-qwen.txt`：它保持相同缺陷，同时让 Qwen 的第一阶段结果稳定可演示。
这个调整只影响 supervisor prompt，不伪造 Tool 错误，也不修改 `550` 的返回值。

## 两个仓库的职责边界

| 工作 | 本仓库 | `alicloud-ack-byocni` |
|---|---:|---:|
| 解释 Splunk AO 与官方 Banking Demo | 是 | 否 |
| 修改、测试应用源码 | 是 | 否 |
| 准备/验证模型与 Pinecone | 是 | 否 |
| 构建、冒烟并发布 Galileo 镜像 | 是 | 否 |
| 创建 VPC、ACK、Worker、CNI | 否 | 是 |
| 安装 Cilium/Hubble/Tetragon/Timescape | 否 | 是 |
| 部署/刷新 Galileo workload | 是 | 是，命令和行为相同 |
| 切换 prompt、查看状态、port-forward | 是 | 是，命令和行为相同 |

这里不会恢复旧的 ACK 动态发现、Terraform state 读取、`.secrets/*.env`、`.deploy.env`、另一套 manifest
或另一套 deploy/port-forward 入口。平台先由 `alicloud-ack-byocni` 建好；应用从镜像发布开始使用两边
一致的 contract。

## 仓库目录

```text
app/                                      官方示例的可部署版本、文档数据和测试
Dockerfile                                可复现的非 root 应用镜像
kup.conf.example                          唯一私有配置模板（只保留 Galileo 所需字段）
kup                                       与 ACK 仓库兼容的 Galileo-only 收敛入口
kubeconfig                                私有 ACK kubeconfig，Git 忽略
ns_galileo/multi-agent-banking.yaml       与 ACK 仓库相同的资源模板
scripts/preflight_models.py               模型与 Tool Calling 能力预检
scripts/setup_pinecone.py                  Pinecone inventory/prepare/smoke
scripts/build_push.sh                      build、容器 smoke、push、digest 回写
scripts/run_local.sh                       用 kup.conf 启动本地 Chainlit
scripts/local_smoke.py                     真实 Tool/Graph/Splunk AO smoke
scripts/run_experiment.sh                  baseline/improved/custom Experiment
scripts/switch_prompt.sh                   ACK 中的 prompt 热切换与验收
scripts/load_galileo_config.sh             GALILEO_* 到应用变量的唯一映射
runtime/                                   可再生成的清单与 inventory，Git 忽略
DEPLOYMENT_REPORT.md                       实现、验证、问题与运维决策记录
```

私有文件只有 `kup.conf` 和 `kubeconfig`。`runtime/` 是可删除、可重建的输出，不是配置来源。旧的
`.secrets/` 与 `.runtime/` 目录已经删除，不再保存或解析任何 resolved env。

## 前置条件

本地工作站需要：

- Python 3.11–3.13，本文示例使用 Python 3.12；
- Docker Engine/Desktop 与 Docker Buildx；
- Git、curl、kubectl；
- 能推送且 ACK 能拉取的镜像仓库；
- 一个 Splunk AO API key，以及已有或准备创建的 Project、Agent Stream、Evaluator、Dataset；
- 一个支持标准 OpenAI-compatible Chat Completions 和 Tool Calling 的 Bailian 或 vLLM endpoint；
- 一个 Pinecone 账号，推荐使用 integrated embedding index；
- 一个已经由 `alicloud-ack-byocni` 完成部署并验收的 ACK 集群。

应用 Pod 不运行模型，也不需要 GPU。ACK 节点只运行 Chainlit/LangGraph 客户端进程。

## 从源码到 ACK 的完整流程

### Phase 0：创建唯一私有配置

```bash
cp kup.conf.example kup.conf
chmod 600 kup.conf
```

编辑 `kup.conf`。模板只保留部署 Galileo 必需的集群连接字段和与 ACK 仓库同名、同义的
`GALILEO_*` 字段：

| 分组 | 必须核对的变量 |
|---|---|
| ACK 连接 | `KUBECONFIG_FILE`、`ACK_CONTEXT`、`TEST_NAMESPACE` |
| 镜像与来源 | `GALILEO_SOURCE_URL`、`GALILEO_SOURCE_COMMIT`、`GALILEO_IMAGE_REF` |
| Registry | `GALILEO_REGISTRY_SERVER`、`GALILEO_REGISTRY_USERNAME`、`GALILEO_REGISTRY_PASSWORD` |
| Splunk AO | `GALILEO_SPLUNK_AO_API_KEY`、Project、Agent Stream、Console URL |
| 应用模型 | provider、精确 model name、HTTPS base URL、API key、timeout、retry |
| Pinecone | API key、隔离 index、namespace、text field |
| 演示/Experiment | Evaluator 列表、可选 Dataset、prompt profile、local port |

如果已经有 `alicloud-ack-byocni/kup.conf`，把其中 Galileo block 的值填入本仓库模板即可；不要把
Alibaba RAM key、ACK Node 密码、Isovalent entitlement 等与本应用无关的私密字段复制进来。变量名与值
可以原样使用，所以部署后的两个仓库没有翻译层。

`GALILEO_IMAGE_REF` 在第一次构建前可以暂时保留 `ReplaceMe`；Phase 7 的发布脚本会同时写入真实
`GALILEO_SOURCE_COMMIT` 和不可变 digest reference。不要手工把 `latest` 当作部署输入。

### Phase 1：建立可复现的 Python 环境

```bash
python3.12 -m venv app/.venv
app/.venv/bin/python -m pip install --upgrade pip
app/.venv/bin/python -m pip install -r app/requirements.lock
app/.venv/bin/python -m pip check
(cd app && .venv/bin/python -m unittest discover -s tests -v)
```

`requirements.lock` 也是 Dockerfile 的安装输入，因此本地测试与镜像使用同一依赖集合。当前版本特别固定
了相互兼容的 LangGraph、`langgraph-prebuilt` 和 `langgraph-supervisor` 组合。

离线单元测试不会访问模型、Pinecone、Splunk AO 或 ACK，主要验证配置、prompt profile 与 import-time
无网络副作用。

### Phase 2：验证最终应用模型

```bash
app/.venv/bin/python scripts/preflight_models.py
```

预检直接读取 `kup.conf` 中最终要部署的那一个模型，不产生另一份 resolved env，也不自动 fallback。
它依次验证：

1. endpoint DNS、TCP 和 TLS；
2. `GET /models` 返回精确的 `GALILEO_APP_MODEL_NAME`；
3. 普通 Chat Completions；
4. 原始 OpenAI-compatible `tool_calls` 两轮往返；
5. 与应用一致的 LangChain `bind_tools` 往返。

只有普通聊天成功并不够。这个 Demo 的 supervisor 和两个 Agent 都依赖标准 Tool Calling；缺失 call id、
非标准 arguments 或不能接收 ToolMessage，都会在真实 Graph 中失败。

### Phase 3：安全准备 Pinecone

先只做 inventory：

```bash
app/.venv/bin/python scripts/setup_pinecone.py inventory
```

报告写入 `runtime/pinecone-inventory.json`，不包含 API key。脚本默认把官方历史 index
`credit-card-information` 视为受保护、只读对象，并把 `GALILEO_PINECONE_INDEX_NAME` 视为本 Demo 的隔离
目标。两者同名时会停止，不会冒险覆盖。

创建或补齐隔离 index：

```bash
app/.venv/bin/python scripts/setup_pinecone.py prepare
app/.venv/bin/python scripts/setup_pinecone.py smoke
```

`prepare` 的行为是：

- 不存在时创建 AWS `us-east-1`、`llama-text-embed-v2` integrated embedding index；
- 已存在时验证 embedding model 与 `GALILEO_PINECONE_TEXT_FIELD`，不兼容就停止；
- 从 `app/source-docs/credit-cards/*.md` 切块，使用稳定 ID 写入配置的 namespace；
- 等待 Orbit Credit Card cashback 查询命中预期资料。

如需不同 cloud、region 或 integrated model，使用 `--help` 查看显式参数。脚本不会退回 OpenAI
embedding，也不会删除任何 index。

### Phase 4：本地运行与真实 smoke

启动 Web 应用：

```bash
./scripts/run_local.sh
```

打开 <http://127.0.0.1:8000>。本地启动与 ACK 使用同一个 `kup.conf`，`load_galileo_config.sh` 只负责把
`GALILEO_*` 映射为应用进程需要的变量，不存在第二份环境文件。

另一个终端可运行真实 smoke：

```bash
app/.venv/bin/python scripts/local_smoke.py
```

它验证固定信用分 Tool、Pinecone 检索、三个代表性问题的完整 Graph，并把一次明确标记的 baseline
Session 发送给 Splunk AO。baseline 最终答错是待观察的教学现象，不会被脚本错误地当成基础设施失败；
Tool、检索或遥测连接失败则会停止。

### Phase 5：Splunk AO UI checkpoint

这一步需要演示者在 Splunk AO UI 中确认，仓库脚本不会擅自创建、修改或删除控制面对象：

1. `GALILEO_SPLUNK_AO_PROJECT` 对应的 Project 存在；
2. `GALILEO_SPLUNK_AO_AGENT_STREAM` 存在且能够看到 Phase 4 的 Session；
3. 展开 Trace 能看到 supervisor、credit-card/credit-score agent、model、tool/retriever spans；
4. `kup.conf` 中列出的四个 Evaluator 已挂到正确的 Agent Stream；
5. 如需 Phase 12，创建或确认 Dataset，并把精确名称写入
   `GALILEO_SPLUNK_AO_EXPERIMENT_DATASET`。

推荐 Dataset 至少包含以下三类输入和 reference：

| 输入 | 期望关注点 |
|---|---|
| `What is my credit score?` | 应调用 score agent/tool 并交付 `550` |
| `What cashback rewards does the Orbit Credit Card offer?` | 应检索到 Orbit 资料，不臆造 rewards |
| `Recommend me a good book.` | 应保持银行业务边界，不错误调用业务 Tool |

### Phase 6：理解镜像内容与安全边界

`Dockerfile` 使用 `python:3.12-slim`，安装 lock 文件，创建系统用户 `app`，以非 root 用户运行 Chainlit，
并只暴露 8000 端口。镜像包含应用代码和静态资源，不包含：

- `kup.conf`、kubeconfig 或任何 API key；
- `runtime/`、临时文件或本地 venv；
- `upstream/` 官方源码 checkout；
- ACK/Terraform/Alibaba Cloud 凭据；
- Pinecone source docs、测试代码或本地运维状态。

运行时的 prompt 由 ConfigMap 投影，因此 baseline/improved/custom 切换不需要重建镜像。

### Phase 7：构建、冒烟、推送并记录不可变镜像

先确保应用源码修改已经提交；镜像发布脚本会拒绝脏工作树，避免“镜像内容无法对应 Git SHA”。然后运行：

```bash
./scripts/build_push.sh registry.example.com/project/multi-agent-banking
```

repository 必须属于 `GALILEO_REGISTRY_SERVER`，参数中不要写 tag 或 digest。脚本会：

1. 用当前 commit 生成带时间和短 SHA 的临时 tag；
2. 构建 `linux/amd64` 本地镜像；
3. 验证容器运行用户为 UID `999`；
4. 启动容器并对 Chainlit HTTP 做本地 smoke；
5. 用临时 Docker credential 目录登录并推送同一平台镜像；
6. 从 registry 解析完整 digest；
7. 原子更新私有 `kup.conf` 中的 `GALILEO_SOURCE_COMMIT` 和 `GALILEO_IMAGE_REF`。

如果 `kup.conf` 已经有同一 repository 的 digest，参数可以省略：

```bash
./scripts/build_push.sh
```

发布完成后核对两项来源必须成对变化：

```bash
grep -E '^GALILEO_(SOURCE_COMMIT|IMAGE_REF)=' kup.conf
```

tag 方便人阅读，ACK 永远使用 `repository@sha256:...`。脚本不会部署到 ACK。

### Phase 8：由 ACK 仓库准备平台

在 `alicloud-ack-byocni` 仓库中按其 README 完成：

```bash
./kup
```

这一步负责 ACK、Cilium、Hubble、Tetragon、Timescape、测试 workload 和 Galileo 的平台依赖。对于已经
建好的集群，不要在本仓库重复执行任何基础设施创建动作。

把该项目生成的私有 kubeconfig 复制到本仓库，不要合并进全局 `~/.kube/config`：

```bash
cp /path/to/alicloud-ack-byocni/kubeconfig ./kubeconfig
chmod 600 kubeconfig
```

默认固定 context 是 `ack-byocni-demo`。本仓库所有命令都显式指定项目 kubeconfig 和 context，不读取或
改变全局 current-context。`test` namespace 还应有 label 为 `app=testcurl` 的测试 Pod；Galileo 收敛会
用它验证跨 namespace ClusterIP HTTP。

### Phase 9：部署或刷新 Galileo

```bash
./kup --galileo-only
```

这是本仓库唯一的 ACK 部署入口，也是 ACK 仓库在只修改 Galileo 配置时使用的同一入口。它按顺序：

1. 检查工具、私有文件权限、所有必需变量和占位符；
2. 验证 40 位 source SHA、HTTPS model URL 和完整 image digest；
3. 使用显式 kubeconfig/context 检查 ACK `/readyz`；
4. 在 `runtime/` 渲染不含 Secret 值的 manifest；
5. 收敛 namespace、runtime Secret、registry pull Secret、ConfigMap、Deployment 和 ClusterIP Service；
6. 等待应用 Pod rollout/Ready，并按配置收敛 prompt；
7. 验证实际 image、Service endpoint、跨 namespace HTTP、projected prompt、精确模型、Pinecone search
   和 Splunk AO HTTPS。

它不会运行 Terraform，不会创建/删除 ACK，不会升级或重启 Node、Cilium、Hubble、Timescape、Tetragon
或其他 workload。本次仓库整理也不会执行这条命令，不会改变正在运行的 ACK。

### Phase 10：查看状态并访问 Web

定义一个只读 wrapper：

```bash
kctl() {
  kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo "$@"
}
```

检查 workload、镜像和 prompt：

```bash
kctl -n galileo-demo get deployment,pods,service,endpoints
kctl -n galileo-demo get deployment splunk-ao-banking-qwen \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
./scripts/switch_prompt.sh status
```

用本地端口访问 ClusterIP Service：

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n galileo-demo \
  port-forward svc/splunk-ao-banking-qwen 8000:80
```

打开 <http://127.0.0.1:8000>。默认不创建公网 LoadBalancer 或 Ingress。

### Phase 11：完成两阶段演示

第一阶段恢复 Qwen baseline：

```bash
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
./scripts/switch_prompt.sh status
```

每次切换后都新建 Chainlit 聊天，然后依次提问：

1. `What is my credit score?`
2. `What are the cashback rewards offered by the Orbit Credit Card?`
3. `Recommend me a good book.`

预期看到：

- score agent 和 Tool 能返回 `550`，但 baseline supervisor 没有正确交付结果；
- credit-card agent 调用 Pinecone，并根据 Orbit 文档回答；
- 越界问题不应调用银行业务 Agent；
- Splunk AO Session 名称带 `[custom]`，Trace 展示完整 handoff/tool/model 链路。

第二阶段只切 prompt：

```bash
./scripts/switch_prompt.sh improved
```

不要换模型、镜像、Pinecone 数据或 Evaluator。新建聊天并重复相同问题；credit-score 回答应交付 `550`，
新的 Splunk AO Session 名称带 `[improved]`。这时可以用同一观察标准说明改动为什么有效。

#### 怎样解读四个 Evaluator

| Evaluator | 在本 Demo 中回答的问题 | baseline 的典型证据 |
|---|---|---|
| Action Advancement | supervisor 的每一步是否把任务向前推进 | 能 handoff 到 score agent，说明前半段可能是好的 |
| Action Completion | 最终是否真正满足用户请求 | Tool 已返回 `550`，最终拒答仍应判为未完成 |
| Tool Errors | Tool 本身是否执行失败 | score Tool 与 Pinecone 都成功时，不应归因于基础设施 |
| Tool Selection Quality | 是否选择了正确 Agent/Tool | 选对 score Tool 但未交付，能把问题定位到 supervisor |

这组证据是演示的关键：最终答案错误不等于模型、网络或 Tool 都坏了。先沿 Trace 证明 retrieval/Tool
健康，再用 Action Completion 说明业务目标未完成，最后把改动限制在 supervisor prompt。切换 improved
后沿同一 Trace 层次重新验证，就能说明改善来自哪一处，而不是只展示两张答案截图。

一个简洁的讲解顺序是：

1. “这是两个业务 Agent 和两个 Tool 都已经存在的系统。”
2. “第一阶段 Tool 已经给出正确事实，但 supervisor 丢掉了结果。”
3. “Splunk AO 把选择、调用、返回、最终交付分开，所以能定位到编排而非基础设施。”
4. “我们没有重建镜像，只修订运行时 prompt，并用相同问题和 Evaluator 复测。”
5. “交互验证后再用 Dataset/Experiment 扩大样本，避免用单次成功代表整体质量。”

演示结束后恢复 `kup.conf` 的声明状态：

```bash
./kup --galileo-only
```

也可以加载任意非敏感 prompt：

```bash
./scripts/switch_prompt.sh custom app/prompts/supervisor-production-example.txt
./scripts/switch_prompt.sh custom /absolute/path/to/my-supervisor-prompt.txt
```

脚本拒绝空文件和超过 100 KiB 的文件，等待 ConfigMap 投影和应用 resolver 一致，并对 custom 内容校验
SHA-256。ConfigMap 对 namespace 读者可见，不能放密码、API key 或客户数据。

### Phase 12：运行可重复的 Experiment

把已有 Dataset 的名称填入私有 `kup.conf` 后运行：

```bash
./scripts/run_experiment.sh baseline
./scripts/run_experiment.sh improved
```

Qwen 专用 baseline 使用：

```bash
./scripts/run_experiment.sh custom app/prompts/supervisor-baseline-qwen.txt
```

runner 只读取已有 Dataset/Evaluator，并创建一次 Experiment run；它不会创建、修改或删除 Dataset 和
Evaluator。每次运行会输出 Experiment 名称、ID、链接，并等待 aggregate metrics 出现。比较时固定
Dataset、模型、Pinecone 和 Evaluator，只改变 supervisor prompt。

## 部署后的统一运维 contract

### 参数怎样生效

| `kup.conf` 修改类型 | 正确动作 | 影响 |
|---|---|---|
| Splunk AO/model/Pinecone key 或普通 runtime 参数 | `./kup --galileo-only` | checksum 变化，只滚动 Chatbot Pod |
| `GALILEO_IMAGE_REF` / `GALILEO_SOURCE_COMMIT` | 先发布镜像，再 `./kup --galileo-only` | 只更新 Chatbot Deployment |
| registry pull credential | `./kup --galileo-only` | 更新 imagePullSecret；镜像不变时不强制滚动 |
| baseline/improved/custom prompt | `scripts/switch_prompt.sh ...` | ConfigMap 热加载，不换镜像、不重启 Pod |
| `GALILEO_LOCAL_PORT` | 下次本地访问时读取 | 不修改 workload |
| namespace | 视为迁移 | 在新 namespace 部署，不猜测删除旧 namespace |

Secret 和 `envFrom` 值只在进程启动时读取，所以只编辑 `kup.conf` 或手工 patch Kubernetes Secret 不会
改变当前进程。必须重新运行 `./kup --galileo-only`，让 checksum 驱动可验证的 RollingUpdate。

两个仓库没有各自的“当前 prompt 状态”。唯一运行时事实来源是同一个
`galileo-demo/splunk-ao-banking-qwen-config` ConfigMap；在任一仓库切换，另一边的 `status` 会看到相同
结果。再次运行 `./kup --galileo-only` 会按各自兼容的 `kup.conf` 恢复声明状态。

### 资源与 Secret 边界

应用 namespace 默认是 `galileo-demo`，包含：

- `splunk-ao-banking-qwen` Deployment 和 ClusterIP Service；
- `splunk-ao-banking-qwen-config` ConfigMap；
- `splunk-ao-banking-qwen-runtime` Secret；
- `galileo-registry-pull` imagePullSecret。

应用 Pod 只接收 Splunk AO、最终应用模型和 Pinecone 的 API key。Alibaba RAM AccessKey、ACR push
credential、ACK Node 密码、Docker Hub PAT、Judge key 都不进入 Pod。runtime Secret 与 registry auth
由 0600 临时文件创建并立即删除；持久化的 rendered manifest 不含 Secret 值。

## 重新发布应用的标准循环

以后修改应用时始终走同一条链，不在 ACK Pod 内手工改文件：

```text
修改 app/ 或 Dockerfile
  -> 离线测试
  -> 模型/Pinecone/本地 smoke（按改动范围）
  -> 提交 Git
  -> scripts/build_push.sh
  -> 核对 commit + digest
  -> ./kup --galileo-only
  -> 查看 rollout/status/Trace
```

这样任意运行中的 Pod 都能同时回答“运行哪一个 digest”和“它来自哪一个 Git commit”。

## Troubleshooting

### `kup.conf` 或 kubeconfig 不存在

从 `kup.conf.example` 创建私有配置，并从 ACK 仓库复制项目 kubeconfig；两者权限都应为 0600。不要恢复
`.secrets/` 或把变量拆成多份 env 文件。

### 模型普通 Chat 成功，但 Agent 不调用 Tool

运行 `scripts/preflight_models.py`。重点看 raw 与 LangChain Tool round-trip，不要只看 `/models` 或普通
聊天。确认 endpoint 是正确的 OpenAI-compatible base URL，且精确 model ID 支持 Tool Calling。

### Pinecone 查询没有 Orbit 内容

先运行 `inventory`，确认 index 是 integrated embedding、text field/namespace 与 `kup.conf` 相同；再运行
`prepare` 和 `smoke`。不要把 Demo 数据写入受保护的 `credit-card-information`。

### 构建脚本拒绝脏工作树

先审阅并提交源码改动。私有 `kup.conf` 和 kubeconfig 被 Git 忽略，不影响干净状态。禁止为了绕过检查
临时复制未提交源码到别处构建，否则 source commit 会失真。

### `ImagePullBackOff`

确认 `GALILEO_IMAGE_REF` 是完整 `@sha256:` 引用、registry host 与 `GALILEO_REGISTRY_SERVER` 相同、pull
credential 有权限，并重新运行 `./kup --galileo-only`。

### 找不到 `testcurl`

先回到 `alicloud-ack-byocni` 完成或修复平台部署。本仓库不会静默跳过跨 namespace 验收，也不会自行
创建一套不同的测试 workload。

### Prompt 切换后行为没有变化

运行 `./scripts/switch_prompt.sh status`，等待 projected ConfigMap 和 resolver SHA 一致，然后在 Chainlit
中新建聊天。已有聊天保留创建时的 Graph/prompt，这是为了保证 Trace 可比较。

### 配置变了但进程仍使用旧值

运行 `./kup --galileo-only`。仅编辑文件或 Secret 不会更新已有进程的环境变量。

### Experiment 一直等待 Evaluator

在 Splunk AO UI 检查 Dataset 名称、Evaluator 名称与 Agent Stream 绑定。runner 不会自动创建或猜测
这些控制面对象；超时会输出已有 metrics 和仍等待的配置名称。

### RAG 回答与 Dataset reference 不一致

先以 `app/source-docs/credit-cards/` 和 Pinecone 实际命中文档核对事实。如果 Dataset 保留了旧版本答案，
应修订 Dataset/reference 或明确版本，而不是让 Agent 编造与当前知识库冲突的答案。

## 安全与清理

- `kup.conf`、`kubeconfig`、`runtime/`、本地 venv 和临时目录都被 Git/Docker context 排除；
- 不在文档、命令行参数或日志中打印 API key；
- 不把项目 kubeconfig 合并到全局 kubeconfig；
- 不为临时演示创建公网 LoadBalancer；
- 不从本仓库销毁 ACK 或修改其平台组件；
- 可删除 `runtime/` 后重新运行相应命令生成，不要删除 `kup.conf` 当作普通 cleanup。

更完整的来源、适配、历史问题和验证记录见 [DEPLOYMENT_REPORT.md](DEPLOYMENT_REPORT.md)。

## 参考

- [Splunk Agent Observability Python SDK](https://github.com/splunk/splunk-ao-python)
- [本 Demo 的 ACK 平台项目](https://github.com/highopes/alicloud-ack-byocni)
- [LangGraph](https://github.com/langchain-ai/langgraph)
- [Chainlit](https://github.com/Chainlit/chainlit)
