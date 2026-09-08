# arxiv-prod-lab-infra

arXiv Prod Lab — 生产级大数据平台一键部署基础设施。

## ✨ 一键安装

> ⚠️ 本仓库当前为 **private**，匿名 `curl raw.githubusercontent.com` 会返回 404。
> 请使用下面的 `gh`（GitHub CLI）命令——它复用你本机已登录的 GitHub 凭据，无需任何手动下载：

```bash
gh api -H "Accept: application/vnd.github.raw" \
  repos/qiao-925/arxiv-prod-lab-infra/contents/env-builder.sh?ref=main | bash
```

首次使用需先登录并授予仓库读取权限：

```bash
gh auth login            # 按提示登录
gh auth setup-git        # （可选）让 git clone 也复用 gh 凭据
```

或者先下载到本地再执行（便于审计脚本内容）：

```bash
gh api -H "Accept: application/vnd.github.raw" \
  -o env-builder.sh \
  repos/qiao-925/arxiv-prod-lab-infra/contents/env-builder.sh?ref=main
chmod +x env-builder.sh
./env-builder.sh
```

> 若仓库未来改为 public，可还原为真正的匿名一键 curl：
> ```bash
> curl -fsSL https://raw.githubusercontent.com/qiao-925/arxiv-prod-lab-infra/main/env-builder.sh | bash
> ```

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

# 提交并推送
git add env-builder.sh
git commit -m "Update env-builder deploy script"
git push origin main
```
