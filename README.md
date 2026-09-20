# Multi-Agent Banking Chatbot — ACK 演示手册

本文只面向**应用已经部署在 ACK 上之后的演示工程师**。它说明这个 Demo 是什么、为什么要演示、怎样
使用 Chainlit 的六个固定问题完成 Demo 1，以及每一步应该观察什么、怎么讲。

如果 ACK 中还没有这个应用，请先阅读
[DEPLOYMENT_REPORT.md](DEPLOYMENT_REPORT.md)。该文档从 Splunk 官方单机 Demo 开始，覆盖适配、验证、
镜像构建、推送以及第一次安装到既有 ACK 的完整流程。

ACK 的创建、Cilium/Hubble/Tetragon/Timescape、整套应用自动安装以及日常平台运维不在本仓库展开，统一
参见 [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni)。

官方故事的背景可参阅
[Add Evaluations to a Multi-Agent LangGraph Application](https://agent-observability-docs.splunk.com/cookbooks/use-cases/multi-agent-langgraph/multi-agent-langgraph)。

## 本次演示范围

当前只实施 **Demo 1：Chainlit 交互 + Splunk AO 在线 Trace/Evaluator + prompt 修复**。

- 使用官方精简测试中的六个提示词进行交互；
- 先展示故意不完整的 baseline；
- 重点观察与信用评分有关的请求为什么被拒绝或没有正确完成；
- 在 Splunk AO 中证明 Agent 和 Tool 已执行，再把问题定位到 supervisor prompt；
- 只切换到 improved prompt，不换镜像、模型、Pinecone 数据或 ACK Pod；
- 新建会话，重复相同问题，验证问题得到修复。

**Demo 2 暂时只作为 Roadmap。** 它未来会用 Experiment 比较两个模型在同一个 AI 应用上的质量、延迟、
Token/成本与性价比；当前文档不提供 Dataset、Experiment、模型对比或 API 自动化步骤。

## 一句话故事线

Brahe Bank 已经有两个能工作的业务 Agent：一个查询信用卡资料，一个返回固定演示信用分 `550`。但初始
supervisor prompt 只声明了信用卡 Agent，遗漏了信用评分能力。于是底层 Agent/Tool 即使成功，supervisor
也可能拒绝回答或没有把结果交给用户。Splunk AO 把 supervisor、handoff、sub-agent、模型和 Tool 的执行
链展开，帮助演示者证明故障在编排/prompt，而不在网络或 Tool。随后只修正 prompt，再用完全相同的六个
问题复测。

## 应用结构

```text
浏览器
  |
  v
Chainlit Web UI
  |-- 每个新聊天创建一条 Splunk AO Session
  |-- 每个聊天启动时固定本次使用的 supervisor prompt
  |
  v
Brahe Bank Supervisor (LangGraph)
  |-- 信用卡、条款、APR、权益 ------> Credit Card Agent
  |                                    `-> Pinecone retrieval Tool
  |                                         `-> Brahe Bank 产品文档
  |
  `-- 信用评分、基于评分的资格 ------> Credit Score Agent
                                       `-> credit_score_retrieval
                                            `-> 固定演示值 550

supervisor / agent / model / tool / retriever spans
  `-------------------------------------------------> Splunk AO
```

组件职责：

| 组件 | 演示中的作用 |
|---|---|
| Chainlit | 用户交互界面；每次新聊天形成清晰、独立的演示 Session |
| LangGraph supervisor | 判断请求交给哪个 Agent，并负责把 Agent 结果交付给用户 |
| Credit Card Agent | 回答 Orbit/Celestial 产品、费用、APR、权益等问题 |
| Pinecone Tool | 从当前信用卡资料中检索事实，形成 retriever span |
| Credit Score Agent | 调用 Tool 获取演示用户的信用分 |
| Credit Score Tool | 确定性返回 `Your credit score is 550` |
| Splunk AO | 展示执行链、评价路由/Tool/任务完成情况，支持定位 prompt 缺陷 |

`550` 是教学 fixture，不是真实客户数据，也不是一个信用评分系统。

## 首先确认使用哪一套后端

当前演示环境可能接入两套不同的后端。**浏览器 Console、API base URL、鉴权 Header、Project 和 Stream
都必须属于同一套系统，不能交叉使用。**

### 后端 A：Splunk Agent Observability

```text
SPLUNK_AO_CONSOLE_URL=https://console.multitenant.galileocloud.io
```

- 产品文档：
  [What Is Splunk Agent Observability?](https://agent-observability-docs.splunk.com/what-is-splunk-agent-observability)
- Python SDK：`splunk-ao`
- SDK 运行变量：`SPLUNK_AO_API_KEY`、`SPLUNK_AO_CONSOLE_URL`、`SPLUNK_AO_PROJECT`、
  `SPLUNK_AO_AGENT_STREAM`
- 原生 REST API：官方规则是把自托管/定制 Console URL 中的 `console` 换成 `api`；因此该环境对应
  `https://api.multitenant.galileocloud.io/`
- 原生 REST API 鉴权 Header：`Splunk-AO-API-Key`
- API 文档：
  [Splunk Agent Observability REST API](https://agent-observability-docs.splunk.com/api/getting-started)

### 后端 B：Galileo Hosted

```text
SPLUNK_AO_CONSOLE_URL=https://app.galileo.ai/
```

- 产品文档：[What Is Galileo?](https://docs.galileo.ai/what-is-galileo)
- 原生 Python SDK：`galileo`
- 原生 SDK 变量：`GALILEO_API_KEY`、`GALILEO_CONSOLE_URL`、`GALILEO_PROJECT`、
  `GALILEO_LOG_STREAM`
- 原生 REST API base URL：`https://api.galileo.ai`
- 原生 REST API 鉴权 Header：`Galileo-API-Key`
- API 文档：[Galileo REST API](https://docs.galileo.ai/api/getting-started)

### 本仓库中的兼容关系

本应用使用 `splunk-ao` Python SDK。部署配置中的：

```text
GALILEO_SPLUNK_AO_API_KEY
GALILEO_SPLUNK_AO_CONSOLE_URL
GALILEO_SPLUNK_AO_PROJECT
GALILEO_SPLUNK_AO_AGENT_STREAM
```

是这个仓库为了避免与其他组件重名而定义的 `kup.conf` 字段。部署时它们会映射成应用进程的
`SPLUNK_AO_*` 变量。当前 `splunk-ao` SDK 带有面向 Galileo Hosted 的兼容桥，因此应用可以把
`https://app.galileo.ai/` 作为 Console URL 使用。

但兼容桥不表示两套原生 REST API 可以混用。凡是文档、脚本或人工操作直接调用 REST API，都必须明确
写出目标后端：

| 项目 | Splunk AO 后端 | Galileo Hosted 后端 |
|---|---|---|
| Console | `console.multitenant.galileocloud.io` | `app.galileo.ai` |
| API base | `api.multitenant.galileocloud.io` | `api.galileo.ai` |
| API key Header | `Splunk-AO-API-Key` | `Galileo-API-Key` |
| 在线数据容器 | Project + Agent Stream | Project + Log Stream |
| UI 中的质量对象 | Evaluator | Evaluation Metric |

API key、Project、Agent Stream/Log Stream 的名称或 ID 都是后端内对象，不能从一套后端复制到另一套使用。
Demo 1 的正常操作只需要 Chainlit、对应后端的 UI 和仓库中的 prompt 切换脚本，不需要编写 REST 调用。
如果以后增加 API 自动化，必须在脚本名称、配置和文档中标记 `splunk-ao` 或 `galileo-hosted`，禁止只写
含糊的“Galileo API”。

> 本手册的 Splunk AO 后端 A 是给定的 `galileocloud.io` 环境，不是
> `app.<realm>.observability.splunkcloud.com` 形式的 Splunk Observability Cloud SaaS。后者使用 realm 和
> Splunk Observability Cloud token，应遵循其 SaaS 文档，不能套用上表的 standalone API key。

## Demo 1 演示前检查

### 1. 确认当前后端和模型类型

只查看非 Secret 字段，不要打印整个 `kup.conf`：

```bash
grep -E '^GALILEO_(SPLUNK_AO_CONSOLE_URL|SPLUNK_AO_PROJECT|SPLUNK_AO_AGENT_STREAM|APP_MODEL_PROVIDER|APP_MODEL_NAME)=' kup.conf
```

根据 Console URL 打开相应 UI，并确认 API key、Project、Agent Stream/Log Stream 都来自这一后端。

根据模型选择 baseline：

| 当前模型 | 第一阶段使用的 prompt | 原因 |
|---|---|---|
| GPT/OpenAI 类模型 | 内置 `baseline` | 官方遗漏通常足以暴露信用评分路由/交付问题 |
| Qwen/千问类模型 | Qwen 专用 `custom` baseline | Qwen 可能从 Tool schema 推断遗漏能力，需要专门校准的故障 prompt |

### 2. 确认应用和 prompt 状态

```bash
./scripts/switch_prompt.sh status
```

记录输出中的：

- ConfigMap 配置 profile；
- Pod 实际挂载 profile；
- 应用实际解析 profile；
- prompt SHA-256；
- Deployment image digest。

状态三者不一致时不要开始演示。

### 3. 恢复第一阶段 baseline

GPT/OpenAI 类模型：

```bash
./scripts/switch_prompt.sh baseline
```

Qwen/千问类模型：

```bash
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
```

切换完成后必须在 Chainlit 中点击 **New Chat**。已有聊天保留创建时的 graph 和 prompt，不能用旧聊天验证
新 profile。

### 4. 打开 Chainlit

如果演示者本机还没有 port-forward：

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n galileo-demo \
  port-forward svc/splunk-ao-banking-qwen 8000:80
```

浏览器打开 <http://127.0.0.1:8000>。保持另一个标签页打开正确的 Splunk AO/Galileo Console。

### 5. 建议窗口布局

- 左侧：Chainlit；
- 右侧：当前后端的 Project + Agent Stream/Log Stream；
- 终端：只用于 `switch_prompt.sh status|baseline|improved|custom`；
- 不在演示中打开或显示 `kup.conf` 的 Secret 字段。

## 六个固定提示词

六个问题来自 `app/dataset-test.json`，与官方 Demo 的精简测试一致。为了得到六条容易解释的独立 Trace，
建议**每个问题都新建一个 Chainlit 聊天**，不要把六个问题塞进同一个有上下文的会话。

| # | 提示词 | 测试目的 | baseline 应重点观察 | improved 预期 |
|---:|---|---|---|---|
| 1 | `What are the cashback rewards offered by the Orbit Credit Card?` | 信用卡 RAG | 路由到 Card Agent 并调用 Pinecone | 行为不变；按当前文档回答 Orbit 没有 cashback/rewards |
| 2 | `What is my credit score?` | 直接信用评分 | 被拒绝、漏答，或 Tool 返回后 supervisor 未交付 | 返回 `550` |
| 3 | `What is the APR for balance transfers on the Orbit Credit Card?` | 信用卡条款 RAG | 路由到 Card Agent/Pinecone | 行为不变；0% introductory APR 12 个月，之后按文档回答 |
| 4 | `What credit cards am I eligible for?` | 评分 + 产品资格组合任务 | 因 supervisor 未声明评分能力而拒绝或无法完整回答 | 使用 `550`，说明只符合 Orbit 的演示条件 |
| 5 | `What can I do with my credit score?` | 评分结果的业务使用 | 被拒绝或无法把评分交给下游业务判断 | 使用 `550` 给出与 Orbit 资格相关的回答 |
| 6 | `Recommend me a good book.` | 越界请求 | 不调用银行业务 Tool，回答不知道/无法回答 | 行为不变 |

LLM 输出不是逐字确定的。验收看的是路由、Tool、事实依据和任务是否完成，不是标点或固定句式。当前
Pinecone 资料把 Orbit 描述为无 cashback/rewards；`dataset-test.json` 中旧的 cashback reference 与当前
资料存在版本漂移，Chainlit 演示应以实际检索文档为准，不能为了匹配旧 reference 而编造答案。

## Demo 1：逐步操作和讲解话术

### Step 0：开场

操作：展示 Chainlit 和上面的结构图，暂时不要打开错误 Trace。

讲解员话术：

> 这是一个虚构银行的多 Agent 应用。用户只看到一个聊天窗口，背后由 supervisor 把问题分给信用卡
> Agent 或信用评分 Agent。信用卡 Agent 通过 Pinecone 查产品文档，信用评分 Agent 的 Tool 固定返回
> 550。Splunk AO 记录的不只是最终答案，而是每一次路由、模型调用、Tool 调用和结果交付。

### Step 1：证明正常能力与边界

操作：分别新建聊天，运行提示词 1、3、6。

提示词 1 话术：

> 我先问一个产品问题。这个回答应该来自信用卡 Agent 和 Pinecone，而不是模型凭记忆回答。稍后在 Trace
> 中我们会看到 retrieval span，并能核对答案依据。

提示词 3 话术：

> 第二个产品问题换成 APR。我们要证明正常的 Card Agent 路径是健康的，这样后面的失败就不能简单归因
> 于整个应用或网络坏了。

提示词 6 话术：

> 这是一个明显越界的问题。好的 Agent 系统不仅要会调用 Tool，也要知道什么时候不调用。这里应该拒绝
> 或回答不知道，不能让银行 Agent 去推荐图书。

观察点：

- 1、3 应出现 supervisor -> credit-card-agent -> `pinecone_retrieval` -> supervisor；
- 6 不应调用两个银行业务 Tool；
- 当前知识库与回答事实一致；
- 相应 Session 已出现在正确后端，而不是另一套 Console。

### Step 2：暴露信用评分缺陷

操作：分别新建聊天，运行提示词 2、4、5。最先使用提示词 2，因为它最容易把问题缩小到 score 路径。

提示词 2 话术：

> 现在我直接询问信用评分。请注意，系统里并不是没有 score agent，也不是 Tool 没有数据；初始 supervisor
> prompt 没有正式声明这项能力。我们预期看到拒绝、漏答，或者 Tool 已成功但最终没有交付。

提示词 4 话术：

> “我能申请什么卡”是一个组合任务：它既需要用户的 550 分，也需要产品资格资料。它能进一步暴露
> supervisor 是否会把两个能力正确串起来。

提示词 5 话术：

> 这个问题要求系统把信用评分用于业务判断，而不只是复述一个数字。它验证 Tool 结果能否继续推进任务。

如果 GPT official baseline 偶尔正确回答，不要把成功结果伪装成失败。先确认确实使用了 `baseline`，新建
聊天再试；如果模型仍稳定从 schema 推断缺失能力，应明确说明该模型没有重现官方缺陷。Qwen 必须使用
仓库附带的 calibrated custom baseline，不能用 improved 充当第一阶段。

### Step 3：在正确的后端查看 Trace

操作：

1. 根据 `GALILEO_SPLUNK_AO_CONSOLE_URL` 选择 Console；
2. 打开配置对应的 Project；
3. 后端 A 进入 Agent Stream，后端 B 进入 Log Stream；
4. 找到刚才的 Session：GPT baseline 名称包含 `[baseline]`，Qwen baseline 包含 `[custom]`；
5. 展开 supervisor、credit-score-agent、`credit_score_retrieval` 和 handoff-back；
6. 对照最终回答查看各层是否成功。

讲解员话术：

> 最终答案只告诉我们“用户没有得到答案”，但 Trace 告诉我们失败发生在哪里。这里可以看到 supervisor
> 做了什么、是否 handoff、score Tool 是否返回 550、结果是否回到 supervisor，以及 supervisor 最终是否
> 完成用户任务。Agent Observability 的价值是把这些层拆开，而不是把所有错误都叫做“模型不好”。

如果 Trace 中 Tool 没有运行，就把问题定位为 Tool selection/routing；如果 Tool 返回 `550` 而最终拒答，
就把问题定位为 result handling/action completion。不要在没有 Trace 证据时声称是哪一种。

### Step 4：用 Evaluator/Metric 建立证据

不同后端的 UI 名称不同：Splunk AO 使用 **Evaluator**，Galileo Hosted 使用 **Evaluation Metric**。
如果目标 Agent Stream/Log Stream 已配置在线评价，以当前默认 Qwen 配置为例，四个名字为：

- `Action Advancement - Qwen`
- `Action Completion - Qwen`
- `Tool Errors - Qwen`
- `Tool Selection Quality - Qwen`

使用 GPT 或其他 Judge 时，名称可能没有 `- Qwen` 后缀或使用另一组自定义名称；以目标后端 UI 的实际
配置为准，不能为了匹配本文在现场重复创建同名对象。

| 评价维度 | 要回答的问题 | 如何解释 baseline |
|---|---|---|
| Action Advancement | 每一步是否在推进用户任务 | score agent/tool 的调用可能推进了任务，但返回后的 supervisor 没继续完成 |
| Action Completion | 最终是否满足用户请求 | Tool 返回 550 而用户仍被拒绝，就是典型未完成 |
| Tool Errors | Tool 是否真正失败 | 0 error 能排除 score Tool/Pinecone 自身故障 |
| Tool Selection Quality | 是否选择了正确 Agent/Tool | 选对 Tool 但交付失败，进一步指向 supervisor prompt |

讲解员话术：

> 这里最重要的不是某一个总分，而是证据组合。Tool 没报错、选择也可能正确，但 Action Completion 仍然
> 失败。这说明修复目标不是数据库、Kubernetes 或 Tool，而是 supervisor 如何理解和交付这个能力。

Evaluator/Metric 可能异步出现。没有结果时先继续看 Trace，不要在现场重复创建评价对象，也不要跨后端
调用 API 查询。

### Step 5：只修改 prompt

切换前记录 Pod 和镜像：

```bash
kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo \
  -n galileo-demo get pod -l app.kubernetes.io/name=splunk-ao-banking-qwen \
  -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,IMAGE:.spec.containers[0].image'
```

切换：

```bash
./scripts/switch_prompt.sh improved
```

讲解员话术：

> 我们现在根据 Trace 证据只修正 supervisor prompt：明确告诉它存在 credit-score agent，并要求正确交付
> 结果。没有换模型、没有重建镜像、没有改 Pinecone、没有重启 ACK，也没有修改 score Tool 的 550。

脚本会等待 ConfigMap 投影和应用 resolver 收敛，并显示 image digest。正常情况下 Pod 和镜像保持不变。

### Step 6：新建聊天并重复六个问题

操作：切换完成后点击 **New Chat**，仍按 1–6 顺序，每题使用独立聊天。

重点展示：

- 1、3 的 Card Agent/Pinecone 行为没有退化；
- 2 现在返回 `550`；
- 4、5 能使用信用评分完成业务回答；
- 6 仍保持业务边界；
- 新 Session 名称包含 `[improved]`；
- 新 Trace 与 baseline 使用同一模型、Tool、数据和镜像。

讲解员话术：

> 我们用完全相同的输入复测。信用卡检索和越界保护没有改变，原来失败的信用评分路径现在完成了任务。
> 因为唯一变化是 supervisor prompt，所以我们既能解释问题，也能解释为什么这个修复有效。

### Step 7：收尾

讲解员话术：

> 这个 Demo 展示的不是“换一个更强模型就好了”，而是如何用运行中的 Agent Trace 区分路由、Tool、检索
> 和最终交付，再做最小修改并复测。这样修复是可解释、可验证，也更适合进入工程流程。

演示结束后恢复团队约定的第一阶段状态。

GPT/OpenAI 类模型：

```bash
./scripts/switch_prompt.sh baseline
```

Qwen/千问类模型：

```bash
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
```

最后运行：

```bash
./scripts/switch_prompt.sh status
```

## Demo 1 常见现场问题

### 找不到刚才的 Session

- 确认 Chainlit 新聊天已经开始；
- 核对 `GALILEO_SPLUNK_AO_CONSOLE_URL`，不要在另一套后端找；
- 核对 Project 和 Agent Stream/Log Stream；
- 等待 SDK flush/页面刷新；
- 查看 Session profile 标签 `[baseline]`、`[custom]` 或 `[improved]`。

### Prompt 切换后行为没变

运行 `./scripts/switch_prompt.sh status`，确认 configured、mounted、resolved 三种状态一致，然后新建聊天。
旧聊天不会更换 graph/prompt。

### baseline 没有失败

先核对模型和 profile。GPT 使用 official baseline；Qwen 使用 calibrated custom baseline。LLM 仍可能出现行为
差异，应如实展示 Trace，不能修改 Tool 或伪造错误。

### 信用卡答案与旧 reference 不同

以 Pinecone 当前命中的 `app/source-docs/credit-cards/` 内容为准。当前 Orbit 文档说明没有 cashback；旧
`dataset-test.json` 的 cashback reference 已发生版本漂移。

### Evaluator/Metric 没有立即出现

评价通常异步计算。Demo 1 可以先用 Trace 完成定位；不要现场创建重复 Evaluator/Metric，也不要拿另一套
后端的 API key 查询。

### 应用、Pod、CNI 或 ACK 本身异常

停止应用故事线，不要在演示过程中临时修改平台。ACK 日常诊断、自动化重装和全套应用收敛统一回到
[alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) 处理。

## Demo 2 Roadmap：双模型质量与成本比较

未来的 Demo 2 将使用 Experiment，在相同 Dataset、相同工具、相同知识库和相同评价标准下比较两种模型：

- 哪个模型的 Action Completion、Tool Selection 等质量指标更好；
- 哪个模型的延迟和失败率更低；
- 哪个模型消耗的 Token/费用更少；
- 在达到质量门槛后，哪个模型的性价比更高。

当前阶段不生成 Demo 2 的 Dataset、Experiment、自动化脚本、后端 API 操作或讲解话术。实现前必须先分别
确认两套后端对 Experiment、成本指标和 API 的实际支持，再决定目标后端。

## 文档分工

| 需求 | 去哪里 |
|---|---|
| 已部署应用的 Chainlit + Splunk AO 演示 | 本 README |
| 从官方单机 Demo 到第一次安装进既有 ACK | [DEPLOYMENT_REPORT.md](DEPLOYMENT_REPORT.md) |
| ACK 创建、销毁、升级、CNI/Hubble/Tetragon/Timescape 运维 | [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) |
| 自动安装整套 ACK 及其所有应用（含本应用） | [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) |
| Splunk AO 产品与 API | [Splunk AO 文档](https://agent-observability-docs.splunk.com/what-is-splunk-agent-observability) |
| Galileo Hosted 产品与 API | [Galileo 文档](https://docs.galileo.ai/what-is-galileo) |
