# GitOps 声明式配置（阶段二）

本目录是 Argo CD 的**单一事实来源**。集群里的一切组件都由这里的 YAML 描述，
不再用手工命令安装。

## 目录结构

```
gitops/
├── root-app.yaml          # app-of-apps 唯一入口（手工 apply 一次）
├── apps/                  # 每个组件一个 Application（参数直接内联在 helm.values）
│   ├── cert-manager.yaml        # wave 0
│   ├── minio-operator.yaml      # wave 0
│   ├── kafka-operator.yaml      # wave 0
│   ├── spark-operator.yaml      # wave 0
│   ├── flink-operator.yaml      # wave 1
│   ├── minio-tenant.yaml        # wave 1
│   ├── kafka-cluster.yaml       # wave 1
│   ├── postgres.yaml            # wave 1
│   ├── monitoring.yaml          # wave 2
│   ├── dolphinscheduler.yaml    # wave 2
│   └── superset.yaml            # wave 2
└── manifests/             # 无官方 chart 的组件，放静态清单
    ├── minio-tenant/
    ├── kafka-cluster/
    └── postgres/
```

> 原则：**一个组件一个文件**。Helm 型组件的参数直接写在 `apps/*.yaml` 的
> `helm.values` 里，不再单独拆 `values/` 目录、也没有多源 `$values` 引用。

## 组件清单

| 组件 | 写法 | 来源 | 版本 | wave |
| :--- | :--- | :--- | :--- | :--- |
| cert-manager | Helm 内联 | charts.jetstack.io | v1.21.2 | 0 |
| MinIO Operator | Helm 内联 | operator.min.io | 7.1.1 | 0 |
| Kafka (Strimzi) Operator | Helm 内联 | strimzi.io/charts | 1.2.0 | 0 |
| Spark Operator | Helm 内联 | kubeflow.github.io/spark-operator | 2.5.2 | 0 |
| Flink Operator | Helm 内联 | downloads.apache.org | 1.16.0 | 1 |
| MinIO Tenant | 静态 YAML | 本仓库 | — | 1 |
| Kafka 集群 (KRaft) | 静态 YAML | 本仓库 | — | 1 |
| PostgreSQL | 静态 YAML | 本仓库 | — | 1 |
| 监控 (kube-prometheus-stack) | Helm 内联 | prometheus-community | 91.4.0 | 2 |
| DolphinScheduler | Helm 内联 (git 路径) | apache/dolphinscheduler | 3.2.2 | 2 |
| Superset | Helm 内联 | apache.github.io/superset | 0.22.8 | 2 |

### 依赖关系

```
cert-manager (wave 0) ──▶ Flink Operator (wave 1, webhook 需证书)
每个 Operator (wave 0) ──▶ 对应的 CR/实例 (wave 1)
```

## 两种写法

```yaml
# ① Helm 型：单 source（chart 仓库）+ helm.values 内联参数
spec:
  source:
    repoURL: <chart 仓库>
    chart: <名>
    targetRevision: <版本>
    helm:
      releaseName: <名>
      values: |
        <你的参数，直接写这里>

# ② 静态 YAML 型：单 source 指向本仓库目录
spec:
  source:
    repoURL: https://github.com/qiao-925/arxiv-prod-lab-infra.git
    path: gitops/manifests/<组件>
```

## 工作流程

```
改 YAML → git push → Argo CD 感知(约 3 分钟/或立即) → 渲染 → 对比 → 自动 apply
```

## 心智模型

| 你配置 | Argo CD 负责 |
|---|---|
| `repoURL` / `chart` / `path` | 去哪里拉 chart 或清单 |
| `helm.values` | 用什么参数覆盖 chart 默认值 |
| `destination.namespace` | 装到哪个命名空间 |
| `syncPolicy` | 自动化程度（自动/手动、是否自愈、是否清理） |
| `sync-wave` 注解 | **部署顺序**（数字小的先执行） |

## sync-wave 约定

Argo CD **不会自动推断依赖顺序**，必须用注解显式声明：

| wave | 内容 | 例子 |
|---|---|---|
| 0 | Operator / CRD | minio-operator、strimzi、spark-operator |
| 1 | 实例 / CR | minio-tenant、kafka-cluster、postgres |
| 2 | 应用层 | monitoring、superset、dolphinscheduler |

## 验收

```bash
kubectl get applications -n argocd          # 所有 App 应为 Synced + Healthy
kubectl get pods -A                          # 各命名空间 Pod Running
```
