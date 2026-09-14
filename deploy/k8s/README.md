# ACK Kubernetes deployment

本目录只保存无 Secret 的模板。`${...}` 变量由 `scripts/deploy_ack.sh` 在 `.runtime` 临时目录渲染；渲染文件和临时 Secret 文件在脚本退出时删除。

部署前提：

- `scripts/preflight_models.py` 已生成 `.runtime/resolved-model.env`。
- `scripts/setup_pinecone.py resolve` 已生成 `.runtime/resolved-pinecone.env`。
- `scripts/build_push.sh` 已生成 `.runtime/image.env`。
- ACK 使用 ACR 时，`scripts/push_acr.sh` 已生成 `.runtime/acr-image.env`；当前已有 repository 必须是 `multi-agent-banking`。
- 用户已在 Splunk AO UI 完成 Integration、四个 Evaluator 和 Agent Stream enablement 的人工 checkpoint。

部署：

```bash
./scripts/deploy_ack.sh
./scripts/validate_ack_network.sh
./scripts/port_forward.sh
```

然后访问 `http://127.0.0.1:8000`。

同一镜像在 baseline/improved/custom prompt 之间切换：

```bash
./scripts/switch_prompt.sh status
./scripts/switch_prompt.sh custom app/prompts/supervisor-baseline-qwen.txt
./scripts/switch_prompt.sh improved
./scripts/switch_prompt.sh custom /absolute/path/to/prompt.txt
```

当前已部署镜像中的官方原始 `baseline` 会被 `qwen3.7-flash` 自动补全而看不到故障，因此第一条 `custom` 命令是当前 ACK 的 Qwen baseline。它保留一次完整 score agent/tool 调用，却让未列明的 score 结果在 Supervisor 回程时进入兜底；`improved` 正确交付 550。下次从最新源码构建镜像后，可直接用 `./scripts/switch_prompt.sh baseline`，并获得 `[baseline]` Session 标签。

切换仅更新挂载的 ConfigMap；升级后的运行 Pod 不重启，也不重建镜像或集群。脚本会等待 ConfigMap 投影生效并核验应用 resolver；只有检测到未挂载该配置的旧 Deployment 时，才兼容性地滚动一次应用 Pod。每次切换后新建 Chainlit 聊天；Splunk AO Session 名称会包含 prompt profile。

创建的资源仅限当前动态发现集群中的 `galileo-demo`：

- Namespace
- 非 Secret ConfigMap
- runtime Secret
- 与当前镜像 registry 匹配的 `registry-pull` Secret
- 单副本 Deployment
- ClusterIP Service

不会创建 LoadBalancer、Ingress、EIP、DNS、证书、PVC 或数据库。所有命令显式使用项目私有 kubeconfig 和 `ack-byocni-demo` context，不读取或修改全局 kube context。

如果 ACK 持续出现 `ImagePullBackOff` 且事件显示连接 `registry-1.docker.io:443` 超时，应停止。使用现有 ACR，或创建/授权新的 ACR repository，都必须先由用户决定；不要随机替换镜像源。遇到大文件传输长时间无进展，应通知用户切换网络并暂停，不做高频轮询；切换后重新执行脚本会复用已经上传的 layer。

在非 ACK 的通用 Kubernetes 上，创建 `.secrets/generic-k8s.env` 后运行：

```bash
./scripts/deploy_kubernetes.sh
```

该脚本只使用显式 `KUBE_CONTEXT`/可选 `KUBECONFIG_FILE`，不调用 ACK/Terraform。完整变量、验证、prompt 切换与清理步骤见根目录 README 的“在其他通用 Kubernetes 环境部署”。
