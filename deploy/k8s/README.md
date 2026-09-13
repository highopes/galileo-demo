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

创建的资源仅限当前动态发现集群中的 `galileo-demo`：

- Namespace
- 非 Secret ConfigMap
- runtime Secret
- 与当前镜像 registry 匹配的 `registry-pull` Secret
- 单副本 Deployment
- ClusterIP Service

不会创建 LoadBalancer、Ingress、EIP、DNS、证书、PVC 或数据库。所有命令显式使用项目私有 kubeconfig 和 `ack-byocni-demo` context，不读取或修改全局 kube context。

如果 ACK 持续出现 `ImagePullBackOff` 且事件显示连接 `registry-1.docker.io:443` 超时，应停止。使用现有 ACR，或创建/授权新的 ACR repository，都必须先由用户决定；不要随机替换镜像源。遇到大文件传输长时间无进展，应通知用户切换网络并暂停，不做高频轮询；切换后重新执行脚本会复用已经上传的 layer。
