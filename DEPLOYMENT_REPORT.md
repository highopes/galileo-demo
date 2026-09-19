# Implementation and Deployment Report — Splunk AO Banking Demo on ACK

## 报告范围

本文记录三件事：这个仓库怎样从 Splunk 官方示例演变为可部署 Demo、历史部署验证得出了什么结论、
以及当前如何与 `alicloud-ack-byocni` 共用一套部署和运维 contract。

2026-09-19 的仓库整理只修改本地源码、脚本和文档，没有执行 `kup`、`kubectl apply`、Helm、Terraform、
Alibaba Cloud API 或任何 Splunk AO/Pinecone 写操作，因此没有改变正在运行的 ACK 系统。文中的“历史验收”
描述 2026-09-13 至 2026-09-14 的实际部署记录；当前线上事实应以私有 `kup.conf`、镜像 registry 和 ACK
workload 为准，而不是把报告中的历史值当成动态发现结果。

## 最终工程边界

本仓库不是 ACK 平台仓库的裁剪副本。边界如下：

```text
Splunk 官方 after 示例
  -> 本仓库：理解、适配、测试、数据准备、镜像构建与发布
  -> 共享边界：kup.conf + GALILEO_* + immutable image digest
  -> 两个仓库相同：./kup --galileo-only + switch_prompt.sh + Kubernetes template
  -> ACK 仓库：VPC/ACK/CNI/Hubble/Tetragon/Timescape 生命周期
```

因此，应用开发者可以在本仓库完整学习并重建 Demo；平台运维者可以继续在
`alicloud-ack-byocni` 管理集群。双方从镜像发布之后使用相同变量、资源名称、验收和 prompt 操作，不需要
维护第二份部署知识。

## 源码来源与可追溯性

| 项目 | 来源 |
|---|---|
| 官方 SDK 仓库 | `https://github.com/splunk/splunk-ao-python.git` |
| 官方示例目录 | `examples/agent/langgraph-fsi-agent/after` |
| 核对的官方提交 | `53b9df9c4ae01f940a55a08d446b2212f67ff94c` |
| 本仓库 | `https://github.com/highopes/galileo-demo` |
| ACK 平台仓库 | `https://github.com/highopes/alicloud-ack-byocni` |

官方 checkout 保存在 Git 忽略的 `upstream/splunk-ao-python` 时只作为只读比较基准，不参与镜像构建。
当前镜像发布流程要求工作树干净，以完整 40 位 Git SHA 作为源码身份，并在 push 后把 registry digest 与
源码 SHA 成对写回私有 `kup.conf`。

## 官方应用结构

官方 `after` 示例是一套金融服务多 Agent 应用：

- Chainlit 提供聊天 UI 与会话入口；
- LangGraph supervisor 在 credit-card agent 与 credit-score agent 之间路由；
- credit-card agent 通过检索 Tool 获取 Brahe Bank 信用卡资料；
- credit-score agent 通过确定性 Tool 返回演示值 `550`；
- Splunk AO LangChain callback 记录 supervisor、Agent、模型与 Tool 调用。

一次完整请求不是“一个 prompt 调一个模型”，而是 supervisor 决策、handoff、sub-agent 推理、Tool 调用、
handoff back 和最终交付组成的图。正因为错误可能发生在每一层，Demo 才适合用来展示 Agent
Observability，而不仅是应用日志。

## 本仓库的应用适配

### 配置与模型

官方示例直接依赖环境变量和默认 OpenAI 组件。本仓库增加了不可变 `Settings` 与统一模型 factory：

- provider 只接受 `bailian` 或 `vllm`；
- base URL 必须是 HTTPS；
- model name、endpoint、API key、timeout、retry 都从部署 contract 显式传入；
- supervisor 与两个 Agent 共用同一模型选择，不在模块 import 时创建外部连接；
- 本地脚本只把 `GALILEO_*` 映射为应用变量，不生成另一套配置文件。

`scripts/preflight_models.py` 现在直接验证 `kup.conf` 中的最终模型，覆盖 DNS/TLS、精确 `/models`、普通
Chat、原始 Tool Calling 和 LangChain Tool round-trip。它不再执行隐式 fallback；选择什么模型是配置
决策，预检只给出可复现的通过或停止结果。

### Pinecone

官方 Tool 使用 OpenAI Embeddings 加 Pinecone vector store。本仓库改成 Pinecone integrated text search：

- 应用不再需要 OpenAI key 或未知 embedding model；
- index、namespace、text field 全部配置化；
- Tool 返回 source/title/content，并标记 retriever span；
- `scripts/setup_pinecone.py` 能 inventory、准备隔离 index、写入稳定记录和执行检索 smoke；
- 历史 `credit-card-information` index 被视为受保护对象，不删除、不清空、不覆盖。

### Prompt profile 与实验故事

当前支持三种 profile：

| Profile | 目的 |
|---|---|
| `baseline` | 保留官方“没有声明 credit-score 能力”的故意缺陷 |
| `improved` | 只补充 credit-score 能力和正确交付路径 |
| `custom` | 从受控文件或 ConfigMap 加载演示/候选 prompt |

新 Chainlit 对话开始时才解析 profile、创建 graph，并在 Splunk AO Session 名称中写入 profile。既有会话
保持原 graph，不会因为 ConfigMap 更新而在同一次 Trace 中混入两套 prompt。

Qwen 能从 Tool schema 推断出官方 prompt 未声明的能力，可能让原 baseline 总是正确。因此增加
`app/prompts/supervisor-baseline-qwen.txt`：仍让 score agent/tool 正常执行并返回 `550`，但明确保留
supervisor 未定义结果交付的缺陷。这样 Splunk AO 能展示“Tool 成功而任务仍未完成”，而不是人为制造网络
错误或修改 Tool 返回值。

### Experiment runner

`app/experiment.py` 对已有 Splunk AO Dataset 运行相同 graph，并使用 `kup.conf` 中的 Evaluator 名称。
它只创建 Experiment run，不创建、修改或删除 Dataset/Evaluator。这样 baseline 与 improved 比较可以固定
模型、数据、Pinecone 和评价标准，只改变 supervisor prompt。

## 依赖与容器设计

关键依赖版本由 `app/requirements.lock` 固定。历史部署时的重要版本包括：

| Package | 历史验收版本 |
|---|---:|
| `splunk-ao` | 0.4.0 |
| `galileo-core` | 4.5.0 |
| `chainlit` | 2.5.5 |
| `langchain` | 0.3.30 |
| `langchain-openai` | 0.3.35 |
| `langgraph` | 0.4.10 |
| `langgraph-prebuilt` | 0.2.3 |
| `langgraph-supervisor` | 0.0.26 |
| `pinecone` | 7.3.0 |

LangGraph 0.4.x 与较新的 prebuilt/supervisor 私有 API 不兼容，因此项目显式约束
`langgraph-prebuilt>=0.2.2,<0.3` 并固定 `langgraph-supervisor==0.0.26`。历史本地和镜像内 `pip check`
均通过。

Dockerfile 的安全与可部署特性：

- 基础镜像为 `python:3.12-slim`；
- 从 lock 文件安装依赖并执行 `pip check`；
- 应用位于 `/opt/banking-demo`；
- 使用非 root 系统用户 `app`；
- Chainlit 监听容器 `0.0.0.0:8000`；
- 构建 context 排除私有配置、kubeconfig、runtime、venv、Git 与 upstream checkout。

ACK manifest 还显式设置 UID/GID `999`，解决 Kubernetes 在只有符号用户名时无法证明
`runAsNonRoot` 的问题。

## 历史模型预检结论

最初候选 vLLM 的精确模型为 `Qwen/Qwen3-14B-FP8`。历史检查结果：

- DNS/TLS、认证、`GET /models` 和普通 Chat：通过；
- 标准、可解析的 OpenAI-compatible Tool Calling round-trip：未通过；
- 因此不适合作为这个 LangGraph Demo 的应用模型。

随后验证 Bailian `qwen3.7-flash`：

- DNS/TLS、精确 model ID、普通 Chat：通过；
- 原始 Tool Calling 两轮往返：通过；
- LangChain `bind_tools` 往返：通过。

这说明“endpoint 能聊天”不能证明它能运行 Agent。当前预检脚本已经把这段经验固化成明确的五层检查，
但不会替操作者自动改写 provider。

## 历史 Pinecone 结论

历史 inventory 发现：

| Index | 结论 |
|---|---|
| `credit-card-information` | BYOV 风格、原 embedding 未知；保持只读 |
| `credit-card-information-qwen-demo` | 隔离的 integrated embedding index |

隔离 index 当时使用 `llama-text-embed-v2`、cosine、namespace `bank-docs`、text field `chunk_text`，写入
10 条稳定记录；Orbit cashback text-search smoke 通过。这一选择避免猜测旧 index 的 embedding，也避免
OpenAI Embeddings 依赖。

当前脚本仍坚持相同安全策略：目标与受保护 index 同名就停止；已有目标配置不兼容时也停止，不自动删除
或重建。

## Splunk AO 验证方法

历史演示使用四个 Qwen Evaluator：

- `Action Advancement - Qwen`
- `Action Completion - Qwen`
- `Tool Errors - Qwen`
- `Tool Selection Quality - Qwen`

这些 Evaluator 分别帮助判断路由是否推进任务、最终是否完成用户目标、Tool 是否报错、Tool 是否选对。
对于 intentional baseline，最有价值的证据是：score Tool 已经成功返回 `550`，但 supervisor 最终仍拒绝
回答。它把“工具/网络故障”与“编排/prompt 缺陷”清楚分开。

历史验证还发现 Judge endpoint 跨数据中心时可能超时，UI recompute 后能够完成。这被记录为评价链路延迟，
不应通过修改应用答案来掩盖。

## 历史本地与 ACK 验收

2026-09-13 至 2026-09-14 完成过以下验收：

- 配置与 prompt profile 离线测试：通过；
- 依赖 `pip check`：本地与生产镜像均通过；
- model Tool Calling：选定应用模型通过；
- Pinecone direct retrieval：通过；
- credit-score Tool fixture：通过；
- Chainlit 本地 bind/HTTP：通过；
- Splunk AO Session/Trace flush：通过；
- `linux/amd64` 构建、非 root 与容器 HTTP smoke：通过；
- ACK immutable image pull 与 Deployment `1/1 Ready`：通过；
- Pod 到 model/Pinecone/Splunk AO：通过；
- ClusterIP 与本地 port-forward：通过；
- baseline -> improved -> custom -> baseline 热切换：通过；
- prompt 切换期间 Pod、restart count 与 image digest 保持不变：通过；
- 公网 Service：未创建；
- ACK/ACR/Pinecone/Splunk AO 的破坏性操作：未执行。

历史验收镜像之一来自提交 `bb87e2ceec3e75cf875417984be3de3131e34ea0`，其记录 digest 为：

```text
sha256:794ac724be1455ee15ea5b5904d364e59c3be382c277fa5146ad66b74901ff53
```

这个 digest 只用于保留历史证据，不代表当前应该部署的版本。当前部署必须读取私有 `kup.conf` 中成对的
`GALILEO_SOURCE_COMMIT` 与 `GALILEO_IMAGE_REF`，并由 `kup` 检查完整 SHA/digest。

## 历史问题与解决办法

1. **友好模型名不是 endpoint 的真实 ID。** 改用 `/models` 返回的精确 ID，并把检查固化到 preflight。
2. **vLLM 普通 Chat 可用但 Tool Calling 不兼容。** 先确认普通 Chat，再把失败分类为 Tool capability，
   最终选择通过完整 Tool round-trip 的模型。
3. **LangGraph 依赖范围放入了不兼容版本。** 固定 prebuilt/supervisor 兼容组合并保存 lock。
4. **已有 Pinecone index 的 embedding 未知。** 保持其只读，建立隔离的 integrated index。
5. **曾把故意错误的 baseline 当成应用 bug。** 恢复教学语义：基础设施/Tool 必须健康，最终拒答才是被观察
   的 Agent 缺陷。
6. **官方 baseline 在 Qwen 上过于聪明。** 只调整 supervisor prompt，保留 graph、Tool、数据与固定答案。
7. **Docker Hub 从 ACK 拉取失败。** 使用用户已有的私有 registry；不创建随机 mirror 或公网服务。
8. **第一次大镜像传输因网络中断。** 换网后继续，避免无意义重复 push。
9. **Kubernetes 无法仅凭 `USER app` 验证非 root。** manifest 显式设置已验证的 UID/GID 999。
10. **prompt 写死在镜像导致演示成本高。** 改成 projected ConfigMap，在新聊天加载，并对内容/profile/SHA
    做最终一致性验收。
11. **Qwen baseline 曾出现二次 handoff 循环。** 最终 prompt 约束同一请求只 handoff 一次。
12. **Splunk AO DNS 曾短暂失败。** 有界重试后完整检查通过，记录为瞬态网络，不修改 endpoint 或 Agent。

## 当前镜像发布流程

`scripts/build_push.sh` 把历史手工步骤变成一个有边界的发布过程：

1. 要求 Git 工作树干净并读取完整 HEAD SHA；
2. 只构建 `linux/amd64`；
3. 本地验证 UID 999 和 HTTP；
4. 使用私有 `kup.conf` 中的 registry credential；
5. Docker credential 只放在 0700 临时目录并在退出时清除；
6. push 后从 registry 解析完整 digest；
7. 原子回写 source SHA 与 immutable image reference；
8. 明确把下一步交给 `./kup --galileo-only`，自身不修改 ACK。

这消除了历史报告中“tag 对应一个提交，但工作树还有未提交修改”的不可追溯情况。未来发布不允许
`-dirty` tag 充当来源证明，也不允许 `latest` 进入部署 contract。

## 与 ACK 仓库统一后的配置 contract

当前 `kup.conf.example` 不是 ACK 完整配置的复制品，而是精确保留 Galileo 所需字段的兼容子集：

- `KUP_WORKDIR`、`KUBECONFIG_FILE`、`ACK_CONTEXT`、`TEST_NAMESPACE`；
- 完整 `GALILEO_*` block；
- `RUNTIME_DIR` 与 `ACK_API_TIMEOUT`。

不相关的 Alibaba RAM、ACK Node、CIDR、Cilium/Tetragon/Hubble chart 配置没有复制进来。Galileo block 的
变量名、默认值、枚举语义、资源名称和 checksum 行为与 ACK 仓库保持一致。

共享资源实现包括：

- `ns_galileo/multi-agent-banking.yaml`：两仓库内容一致；
- ConfigMap、runtime Secret、registry pull Secret：名称与键一致；
- Deployment image、source annotation、probe、security context：一致；
- prompt projected volume 与 resolver：一致；
- ClusterIP Service 与 testcurl 跨 namespace HTTP：一致；
- `scripts/switch_prompt.sh` 的 profile/patch/wait/status 行为：一致；
- `./kup --galileo-only` 的配置检查、render、apply、rollout 与最终验收：一致。

本仓库的 `kup` 有意只接受 `--galileo-only`，因为没有 ACK Terraform/Helm 资产。它不能无参数创建基础设施，
但 Galileo-only 路径与 ACK 仓库同一模式兼容。

## 运行时文件迁移

旧模式曾使用 `.secrets/*.env`、`.deploy.env`、`.runtime/resolved-model.env`、动态 ACK discovery 输出以及
多套部署脚本。它们的问题是同一值会在多处被解析、覆盖或回写，最终很难回答哪个文件才是 authority。

当前文件模型：

| 路径 | 性质 | 是否提交 |
|---|---|---:|
| `kup.conf.example` | 公共模板 | 是 |
| `kup.conf` | 唯一私有配置 | 否，0600 |
| `kubeconfig` | 项目私有 ACK 连接 | 否，0600 |
| `runtime/` | 可重建清单/inventory | 否 |

已经彻底删除的旧目录与组件不应恢复：`.secrets/`、`.runtime/`、`.deploy.env`、resolved env、
`discover_ack.sh`、旧
`build_push_acr.sh`、`deploy_ack.sh`、通用 Kubernetes 第二入口和独立 port-forward wrapper。

应用教育能力没有随旧部署组件一起删除：模型预检、Pinecone 准备、源码到镜像发布、本地 smoke、Web
演示和 Experiment 都已保留或恢复，并统一读取 `kup.conf`。

## 当前部署与维护行为

唯一 ACK 应用收敛入口：

```bash
./kup --galileo-only
```

它只操作 Galileo namespace 中的应用资源，不运行 Terraform，不安装 Helm chart，不修改 ACK Node、CNI、
Hubble、Tetragon、Timescape 或其他 workload。

prompt 运维入口：

```bash
./scripts/switch_prompt.sh status
./scripts/switch_prompt.sh baseline
./scripts/switch_prompt.sh improved
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
```

两个仓库观察同一个 ConfigMap，不保存各自的运行时 prompt 状态。`kup --galileo-only` 会按 `kup.conf`
恢复声明状态；临时切换不会重启 Pod 或改变镜像。

## 2026-09-19 仓库修订验证

本轮修订的验证范围刻意限制在本地、只读或离线检查，不访问当前 ACK：

- 官方 upstream commit 与 `app/` 差异重新核对；
- `kup.conf.example` Galileo 字段与 ACK 仓库模板核对；
- Kubernetes template 内容一致性核对；
- shell syntax 检查；
- Python compile/help 检查；
- 6 个不依赖外部 SDK 的 Settings/Prompt-profile 测试通过；本机已清理应用 venv，因此依赖
  `langgraph` 的 import-side-effect 测试本轮未重跑，它在历史生产镜像验收中已通过；
- 私密文件权限与 Git ignore 检查；
- 旧部署入口、`.secrets` 和 resolved runtime 引用扫描；
- README 命令、文件路径与脚本实际参数交叉检查。

没有在本轮执行以下会改变外部状态的动作：镜像 push、Pinecone `prepare`、Splunk AO Experiment、
`./kup --galileo-only` 或 prompt switch。

## 已知限制与后续原则

- baseline 失败是教学设计，不应在第一阶段提前“修好”；
- Dataset 与 Evaluator 属于 Splunk AO UI 中的显式选择，脚本不猜测或创建；
- Judge 跨数据中心可能需要 recompute；
- Pinecone integrated model/cloud/region 的组织选择应显式传给 setup 脚本；
- registry repository 必须预先存在且当前用户有 push、ACK 有 pull 权限；
- 变更应用后必须发布新 digest，不能在 Pod 内修改源码；
- 平台问题回到 `alicloud-ack-byocni` 修复，不能在本仓库重新引入第二套 ACK 生命周期逻辑。

完整的团队操作教程见 [README.md](README.md)。
