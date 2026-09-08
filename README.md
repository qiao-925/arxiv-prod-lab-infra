# arxiv-prod-lab-infra

arXiv Prod Lab — 生产级大数据平台一键部署基础设施。

## ✨ 一键安装

通过 curl 从 GitHub 拉取并执行部署脚本，无需手动下载：

```bash
curl -fsSL https://raw.githubusercontent.com/qiao-925/arxiv-prod-lab-infra/main/env-builder.sh | bash
```

> 国内网络较慢时，可使用镜像加速：
> ```bash
> curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/qiao-925/arxiv-prod-lab-infra/main/env-builder.sh | bash
> ```

或先下载到本地再执行（便于审计脚本内容）：

```bash
curl -fsSL -o env-builder.sh https://raw.githubusercontent.com/qiao-925/arxiv-prod-lab-infra/main/env-builder.sh
chmod +x env-builder.sh
./env-builder.sh
```

## 📦 技术栈

| # | 组件 | 用途 |
|---|------|------|
| 1 | K3s | 轻量级 Kubernetes 容器编排底座 |
| 2 | Helm | Kubernetes 包管理器 |
| 3 | Argo CD | GitOps 持续部署 |
| 4 | MinIO + Operator | S3 兼容对象存储（数据湖底座） |
| 5 | Kafka + Strimzi | 实时消息管道 |
| 6 | Flink + Operator | 实时流计算（5 分钟窗口聚合） |
| 7 | Spark + Operator | 离线批计算 |
| 8 | PostgreSQL | 聚合结果存储（流批对账） |
| 9 | Prometheus + Grafana | 可观测性与监控 |
| 10 | DolphinScheduler + Superset | 任务调度 + BI 可视化 |

## ⚙️ 硬件要求

- 最低：16GB+ 内存，100GB+ 磁盘
- 推荐：32GB 内存，2TB 硬盘
- 预计耗时：15-25 分钟（取决于网络速度）

## 🔧 本地开发

```bash
# 修改脚本后做语法检查
bash -n env-builder.sh

# 提交并推送后，curl 命令立即生效
git add env-builder.sh
git commit -m "Add env-builder deploy script"
git push origin main
```
