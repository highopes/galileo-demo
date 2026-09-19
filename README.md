# Splunk AO Multi-Agent Banking Chatbot — ACK + Qwen Demo

这是 Splunk Agent Observability Multi-agent banking chatbot 的 ACK 演示实现。应用通过 Chainlit 展示 LangGraph supervisor、credit-card agent、credit-score agent、Pinecone 检索与 Splunk Agent Observability trace，并通过可热切换的 supervisor prompt 对比故障版与改进版行为。

本仓库的 ACK 部署和运维约定与 [alicloud-ack-byocni](https://github.com/highopes/alicloud-ack-byocni) 完全共用一套 Galileo contract：

- 私有配置统一为 `kup.conf`，应用设置统一使用 `GALILEO_*` 变量。
- 应用收敛统一使用 `./kup --galileo-only`。
- Kubernetes 模板统一为 `ns_galileo/multi-agent-banking.yaml`。
- Secret、ConfigMap、Pod 输入校验和、滚动更新和验收检查采用相同逻辑。
- Prompt 维护统一使用 `scripts/switch_prompt.sh` 和 `scripts/render_prompt_patch.py`。
- 项目私有 kubeconfig、固定 context、ClusterIP 和本地 port-forward 采用相同安全边界。

本仓库不创建或销毁 ACK、VPC、Worker、Cilium、Hubble、Timescape、Tetragon 或测试 workload。完整 ACK 环境仍由 `alicloud-ack-byocni` 的 `./kup` 和 `./kiall` 管理；本仓库只提供相同的 Galileo-only 手工收敛入口。

## Demo 目标

第一阶段使用故意不完整的 supervisor prompt：credit-score agent 和工具可以成功返回 `550`，但 supervisor 可能因为没有被明确告知如何处理该能力而漏答或拒绝。第二阶段只把 prompt 切换到 `improved`，不更换镜像、模型、Pinecone 数据或 Evaluator，从而在 Splunk AO 中对比相同系统的两种 Agent 行为。

默认 `kup.conf.example` 与 ACK 项目保持相同选择：

- application model：`bailian/qwen3.7-flash`
- Pinecone index：`credit-card-information-qwen-demo`
- Pinecone namespace：`bank-docs`
- 初始 prompt：Qwen baseline，通过 `custom app/prompts/supervisor-baseline-qwen.txt` 热加载
- Service：ClusterIP，不创建 Ingress 或公网 LoadBalancer

这些只是公共默认值。API key、endpoint、镜像 digest 和 registry credential 必须写入 Git 忽略的私有 `kup.conf`。

## 架构与职责边界

```text
Browser
  |
  | kubectl port-forward
  v
ClusterIP Service / galileo-demo
  |
  v
Chainlit + LangGraph Pod
  |-- Supervisor
  |    |-- Credit Card Agent --> Pinecone integrated search
  |    `-- Credit Score Agent --> deterministic score tool
  |-- Bailian or vLLM application model
  `-- Splunk Agent Observability

ACK/VPC/Cilium/Hubble/Tetragon lifecycle
  `-- owned only by alicloud-ack-byocni
```

应用 Pod 不运行模型，不需要 GPU。它只保存三类运行期 Secret：Splunk AO API key、最终 application model API key 和 Pinecone API key。Alibaba RAM AccessKey、ACR push credential、Docker Hub credential、Judge key 和 ACK Node 密码不会进入 Pod。

## 仓库中的部署组件

```text
kup.conf.example                         唯一私有配置模板
kup                                      Galileo-only 收敛入口
ns_galileo/multi-agent-banking.yaml      与 ACK 项目一致的资源模板
scripts/switch_prompt.sh                 baseline/improved/custom 热切换
scripts/render_prompt_patch.py           安全生成 ConfigMap patch
scripts/load_galileo_config.sh           本地运行时的 GALILEO_* 映射
scripts/run_local.sh                      使用同一 kup.conf 本地运行
scripts/local_smoke.py                    使用同一 kup.conf 做本地 smoke
scripts/run_experiment.sh                 使用同一 kup.conf 运行 Experiment
Dockerfile                               应用镜像定义
app/                                     Chainlit/LangGraph 应用与测试
```

旧的 `.deploy.env`、`.secrets/*.env` 部署输入、ACK 动态发现、独立 build/push/deploy/port-forward 脚本以及 `deploy/k8s` 多文件模板已经移除。不要恢复这些入口，否则两个仓库会重新形成两套配置与运维方式。

## 前置条件

### ACK 环境

目标集群应已按 `alicloud-ack-byocni` 建成，并满足：

- 项目私有 kubeconfig 可用，默认文件为仓库根目录的 `kubeconfig`。
- kubeconfig 中存在稳定 context `ack-byocni-demo`。
- ACK API 可访问，节点和 CNI 已 Ready。
- `test` namespace 中存在 label 为 `app=testcurl` 的测试 Pod。Galileo-only 收敛会像 ACK 项目一样从该 Pod 验证跨 namespace ClusterIP HTTP，不会静默跳过。
- 本机已安装 `kubectl` 和 Python 3。

如果尚未创建 ACK 环境，请先在 `alicloud-ack-byocni` 中完成 `./kup`。本仓库不会读取 Terraform state、调用 Alibaba Cloud API、创建集群或修复 kubeconfig。

### 外部服务

准备以下已有资源：

- 一个已发布的 `linux/amd64` 应用镜像，必须使用完整不可变 `@sha256:` reference。
- 对该镜像有 pull 权限的 registry credential。
- Splunk AO Project、Agent Stream 和 API key。
- 支持 OpenAI-compatible API 的 Bailian 或 vLLM endpoint、精确 model ID 和 API key。
- 已准备好数据的 Pinecone integrated-embedding index、namespace、text field 和 API key。

本仓库的收敛脚本不会创建 ACR repository、Pinecone index、Splunk AO Project、Agent Stream、Evaluator 或 Dataset，也不会构建和推送镜像。镜像应通过组织批准的构建流程从本仓库 `Dockerfile` 生成；更新镜像时同时更新 `GALILEO_SOURCE_COMMIT` 和 `GALILEO_IMAGE_REF`，禁止使用 `latest` 或可变 tag 作为部署引用。

## 配置

```bash
cp kup.conf.example kup.conf
cp /path/to/ack-byocni/kubeconfig ./kubeconfig
chmod 600 kup.conf kubeconfig
```

然后编辑私有 `kup.conf`。至少替换：

| 变量 | 含义 |
|---|---|
| `GALILEO_IMAGE_REF` | registry 中完整的 `linux/amd64` 不可变 digest reference |
| `GALILEO_REGISTRY_SERVER` | 与镜像 reference 匹配的 registry host |
| `GALILEO_REGISTRY_USERNAME` | 镜像 pull 用户名 |
| `GALILEO_REGISTRY_PASSWORD` | 镜像 pull 密码或 token |
| `GALILEO_SPLUNK_AO_API_KEY` | Splunk AO API key |
| `GALILEO_APP_MODEL_BASE_URL` | HTTPS OpenAI-compatible base URL |
| `GALILEO_APP_MODEL_API_KEY` | application model API key |
| `GALILEO_PINECONE_API_KEY` | Pinecone API key |

同时核对 Project、Agent Stream、model、Pinecone index/namespace/text field、Evaluator 列表和可选 Dataset。`GALILEO_SOURCE_COMMIT` 必须是该镜像实际对应的 40 位小写 Git SHA；示例值与 `alicloud-ack-byocni` 当前部署基线一致，不表示任意新镜像都对应这个 commit。

`kup.conf`、`kubeconfig`、`runtime/` 和 `.runtime/` 都被 Git 忽略。脚本将前两者权限收敛为 0600。Kubernetes runtime Secret 和 registry auth 只通过 0600 临时文件生成，应用后立即删除；持久化的 rendered manifest 不包含 Secret 值。

如果需要复用 ACK 仓库的私有配置，可把同一份 `kup.conf` 复制到本仓库；Galileo 相关变量、路径语义和默认 context 完全兼容。若原文件把 `KUP_WORKDIR` 写成 ACK 仓库的绝对路径，复制后应改成本仓库绝对路径，或恢复为示例中的 `${SCRIPT_DIR}`，以免 rendered file 写回参考仓库。不要用 symlink 让两个仓库共享会被误编辑的 Secret 文件。

## 部署或刷新 Galileo

```bash
./kup --galileo-only
```

这是本仓库唯一的 ACK 部署/配置刷新入口。命令按以下顺序执行：

1. 检查 `kubectl`、Python、脚本语法、配置占位符、完整 source SHA、HTTPS model URL 和不可变 image digest。
2. 显式使用私有 kubeconfig 与 `ACK_CONTEXT` 检查 `/readyz`，不读取或改变全局 current-context。
3. 生成 `runtime/galileo-multi-agent-banking.yaml`。
4. 创建 namespace（若不存在），并收敛 `splunk-ao-banking-qwen-runtime` 与 `galileo-registry-pull` 两个 Secret。
5. 应用 ConfigMap、Deployment 和 ClusterIP Service。
6. 等待唯一应用 Pod rollout 和 Ready。
7. 按 `kup.conf` 收敛 baseline/improved prompt。
8. 验证 image reference、Service endpoint、跨 namespace HTTP、projected prompt、应用 resolver、精确 model ID、Pinecone search 和 Splunk AO HTTPS。

该命令不会运行 Terraform，不会升级或重启 ACK Node、Cilium、Hubble、Timescape、Tetragon 或其他 workload。

### 参数怎样生效

| `kup.conf` 修改类型 | 生效方式 | 影响范围 |
|---|---|---|
| Splunk AO、model、Pinecone key 或非 Secret runtime 参数 | `./kup --galileo-only` 更新 Secret/ConfigMap；Pod 模板校验和变化后滚动 | 只替换 Chatbot Pod |
| `GALILEO_IMAGE_REF`、`GALILEO_SOURCE_COMMIT` | 应用新不可变镜像与来源标记 | 只滚动 Chatbot Deployment |
| registry pull 用户名或密码 | 重建 imagePullSecret | 只影响以后的镜像拉取；镜像未变时不强制滚动 |
| `GALILEO_SUPERVISOR_PROMPT_PROFILE`、`GALILEO_BASELINE_PROMPT_VARIANT` | projected ConfigMap 热加载 | Pod 与镜像保持不变 |
| 临时 baseline/improved/custom 切换 | `scripts/switch_prompt.sh` | Pod 与镜像保持不变 |
| `GALILEO_LOCAL_PORT`、`GALILEO_PROMPT_SYNC_TIMEOUT_SEC` | 下次本地访问或收敛时读取 | 不单独修改 workload |

Secret 和普通 `envFrom` 值只在进程启动时读取，因此只编辑 `kup.conf` 或只手工 patch Secret 不会改变现有进程。应重新运行 `./kup --galileo-only`，让 checksum 驱动一次可验证的 RollingUpdate。若修改 `GALILEO_NAMESPACE`，脚本会在新 namespace 部署另一套应用，不会猜测并删除旧 namespace；这应视为迁移。

## 查看状态与访问 Web

定义只读 wrapper：

```bash
kctl() {
  kubectl --kubeconfig ./kubeconfig --context ack-byocni-demo "$@"
}
```

查看资源：

```bash
kctl -n galileo-demo get deployment,pods,service
kctl -n galileo-demo get deployment splunk-ao-banking-qwen \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
./scripts/switch_prompt.sh status
```

本地访问：

```bash
kubectl \
  --kubeconfig ./kubeconfig \
  --context ack-byocni-demo \
  -n galileo-demo \
  port-forward svc/splunk-ao-banking-qwen 8000:80
```

打开 <http://127.0.0.1:8000>。Service 保持 ClusterIP；不要为了演示创建公网 LoadBalancer。

## Prompt 演示与维护

`scripts/switch_prompt.sh` 默认读取同一份 `kup.conf` 中的 kubeconfig、ACK context 和 Galileo namespace。需要临时指向另一个集群时，可显式设置：

```bash
export KUBECONFIG_FILE="$PWD/kubeconfig"
export KUBE_CONTEXT="ack-byocni-demo"
export KUBE_NAMESPACE="galileo-demo"
```

三种运行时状态与 ACK 项目一致：

| 演示提示词 | 命令 | profile / Session 标签 |
|---|---|---|
| 官方 baseline | `./scripts/switch_prompt.sh baseline` | `baseline` / `[baseline]` |
| Qwen baseline | `./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt` | `custom` / `[custom]` |
| 改进版 | `./scripts/switch_prompt.sh improved` | `improved` / `[improved]` |

任意自定义 prompt：

```bash
./scripts/switch_prompt.sh custom app/prompts/supervisor-production-example.txt
./scripts/switch_prompt.sh custom /absolute/path/to/supervisor-prompt.txt
```

脚本拒绝空文件和大于 100 KiB 的内容，patch 后等待 projected ConfigMap 和应用 resolver 收敛，并对 custom 内容验证 SHA-256。升级后的 Deployment 不会因为 prompt 切换而重启；只有检测到缺少 projected volume 的旧 Deployment 时，兼容逻辑才会滚动一次应用 Pod。

每次切换后必须在 Chainlit 中新建聊天。已有 Session 保留创建时的 agent/prompt，避免一次对话混用两个 profile。ConfigMap 对 namespace 内有读取权限的用户可见，不要把密码、API key、客户数据或其他 Secret 放进 prompt。

再次运行 `./kup --galileo-only` 会按 `kup.conf` 恢复目标状态。默认 `baseline + qwen` 等价于重新执行 Qwen baseline 的 custom 热加载。

### 建议演示顺序

1. 运行 Qwen baseline，创建新聊天并输入 `What is my credit score?`。观察 score agent/tool 返回 `550` 后 supervisor 的失败交付。
2. 输入 `What are the cashback rewards offered by the Orbit Credit Card?`。预期 credit-card agent 通过 Pinecone 给出 grounded answer。
3. 输入 `Recommend me a good book.`。预期不调用银行业务 agent，并回答不知道或无法回答。
4. 在 Splunk AO 中查看 supervisor、sub-agent、tool 和 model spans，以及 Action Advancement、Action Completion、Tool Errors、Tool Selection Quality Evaluator。
5. 执行 `./scripts/switch_prompt.sh improved`，新建聊天并重复 credit-score 请求。预期正确返回 `550`。
6. 演示结束后执行 Qwen baseline 命令，或重新运行 `./kup --galileo-only` 恢复私有配置指定状态。

## 本地运行与测试

本地流程也只读取 `kup.conf`，不再使用 `.deploy.env`、`.secrets/*.env` 或 `.runtime/resolved-*.env`。

```bash
python3.12 -m venv app/.venv
app/.venv/bin/python -m pip install --upgrade pip
app/.venv/bin/python -m pip install ./app
app/.venv/bin/python -m pip check
app/.venv/bin/python -m unittest discover -s app/tests -v
```

启动本地 Chainlit：

```bash
./scripts/run_local.sh
```

执行会调用真实 model、Pinecone 和 Splunk AO 的 smoke：

```bash
app/.venv/bin/python scripts/local_smoke.py
```

运行 Experiment：

```bash
./scripts/run_experiment.sh baseline
./scripts/run_experiment.sh improved
./scripts/run_experiment.sh custom app/prompts/supervisor-production-example.txt
```

Experiment 需要 `GALILEO_SPLUNK_AO_EXPERIMENT_DATASET` 指向已经由用户在 Splunk AO UI 中确认的 Dataset。脚本不会创建或修改 Project、Agent Stream、Integration、Evaluator、sampling 或 Dataset。

## 安全与变更边界

- 所有 Kubernetes 操作都显式指定项目私有 kubeconfig 和 context。
- `GALILEO_IMAGE_REF` 必须与 `GALILEO_REGISTRY_SERVER` 匹配，并以完整小写 `sha256` digest 结尾。
- Pod 以 UID/GID 999 non-root 运行，禁用 service-account token、privilege escalation，并 drop 所有 Linux capabilities。
- 运行期 Secret 不写入 manifest、日志或镜像。
- ConfigMap 只保存非 Secret 配置与 prompt。
- 本仓库没有 `kiall`，也不提供 namespace 删除脚本。集群销毁只能在拥有 Terraform state 的 `alicloud-ack-byocni` 中执行 `./kiall`。
- 不要为了“清理应用”运行 ACK 项目的 `./kiall`；它会销毁该 Terraform state 拥有的完整演示环境。

## Troubleshooting

### `kup.conf` 或 kubeconfig 不存在

复制 `kup.conf.example`，填写所有 `ReplaceMe`，并把目标 ACK 的项目私有 kubeconfig 放到配置指定路径。不要合并到 `~/.kube/config`。

### ACK API 不可达

确认 `KUBECONFIG_FILE`、`ACK_CONTEXT`、公网 API server 或本地网络/VPN。脚本不会动态扫描 Alibaba Cloud 账号，也不会从 Terraform state 重新生成 kubeconfig。

### `ImagePullBackOff`

确认 `GALILEO_IMAGE_REF` 是 `GALILEO_REGISTRY_SERVER` 下完整 `@sha256:` reference，registry pull 用户名/密码有 repository 权限，并确认 ACK Node 能访问 registry。脚本不会回退到 `latest`。

### 找不到 `testcurl`

这表示目标 ACK 尚未满足参考仓库的验收拓扑。先用 `alicloud-ack-byocni` 收敛 `test` workload，再重跑 `./kup --galileo-only`。不要删除这项检查来制造假成功。

### model、Pinecone 或 Splunk AO 检查失败

Pod 内 `pod_network_smoke.py` 要求：model HTTPS `/models` 可认证访问且包含精确 `GALILEO_APP_MODEL_NAME`；Pinecone text search 至少返回一个结果；Splunk AO console 能建立 HTTPS 连接。修复私有配置或外部服务后重跑 Galileo-only 收敛。

### Prompt 切换超时

运行 `./scripts/switch_prompt.sh status` 对比 ConfigMap、挂载文件、resolver 和内容 hash。Kubernetes ConfigMap 投影最终一致；切换脚本会等待最多约 180 秒，`GALILEO_PROMPT_SYNC_TIMEOUT_SEC` 则控制 `kup` 的最终复核上限。

### 配置改了但进程仍使用旧值

不要只 patch Secret 或 ConfigMap。运行 `./kup --galileo-only`，让共享 checksum contract 触发应用 Pod 的精确 RollingUpdate，并等待完整验收。

## 部署记录

仓库迁移、删除项、静态验证结果与未执行的 live 操作记录在 [DEPLOYMENT_REPORT.md](DEPLOYMENT_REPORT.md)。该报告描述仓库当前可复现方法，不再保存某一次临时集群 ID、Pod 名称、旧镜像 tag 或本机清理流水账。

## 参考

- [ACK BYOCNI Cilium/Tetragon Demo](https://github.com/highopes/alicloud-ack-byocni)
- [Splunk AO Multi-agent banking chatbot sample](https://agent-observability-docs.splunk.com/getting-started/sample-projects/multi-agent)
- [Splunk AO Multi-agent LangGraph evaluations](https://agent-observability-docs.splunk.com/cookbooks/use-cases/multi-agent-langgraph/multi-agent-langgraph)
- [Pinecone integrated embedding indexes](https://docs.pinecone.io/guides/indexes/create-an-index)
