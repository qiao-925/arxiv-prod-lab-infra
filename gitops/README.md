# GitOps 声明式配置（阶段二）

本目录是 Argo CD 的**单一事实来源**。集群里的一切组件都由这里的 YAML 描述，
不再用手工命令安装。

## 目录结构

```
gitops/
├── root-app.yaml          # app-of-apps 唯一入口（手工 apply 一次）
├── apps/                  # 每个组件一个 Application CR
├── values/                # 各组件的 Helm values（被 apps/ 引用）
└── manifests/             # 无官方 chart 的组件，直接放静态清单
    ├── minio-tenant/
    ├── kafka-cluster/
    └── postgres/
```

## 组件清单

| 组件 | 类型 | 来源 | 版本 | wave |
| :--- | :--- | :--- | :--- | :--- |
| cert-manager | Helm | charts.jetstack.io | v1.21.2 | 0 |
| MinIO Operator | Helm | operator.min.io | 7.1.1 | 0 |
| Kafka (Strimzi) Operator | Helm | strimzi.io/charts | 1.2.0 | 0 |
| Spark Operator | Helm | kubeflow.github.io/spark-operator | 2.5.2 | 0 |
| Flink Operator | Helm | downloads.apache.org | 1.16.0 | 1 |
| MinIO Tenant | 静态 YAML | 本仓库 | — | 1 |
| Kafka 集群 (KRaft) | 静态 YAML | 本仓库 | — | 1 |
| PostgreSQL | 静态 YAML | 本仓库 | — | 1 |
| 监控 (kube-prometheus-stack) | Helm | prometheus-community | 91.4.0 | 2 |
| DolphinScheduler | Helm (git 路径) | apache/dolphinscheduler | 3.2.2 | 2 |
| Superset | Helm | apache.github.io/superset | 0.22.8 | 2 |

### 依赖关系

```
cert-manager (wave 0) ──▶ Flink Operator (wave 1, webhook 需证书)
每个 Operator (wave 0) ──▶ 对应的 CR/实例 (wave 1)
```

### 两种类型的写法差异

```yaml
# Helm 型：双源
spec:
  sources:
    - {repoURL: <本仓库>, ref: values}
    - {repoURL: <chart 仓库>, chart: <名>, targetRevision: <版本>,
       helm: {valueFiles: [$values/gitops/values/...]}}

# 静态 YAML 型：单源
spec:
  source: {repoURL: <本仓库>, path: gitops/manifests/<组件>}
```

## 工作流程

```
改 YAML → git push → Argo CD 感知(3分钟/或立即) → 渲染 → 对比 → 自动 apply
```

## 心智模型

| 你配置 | Argo CD 负责 |
|---|---|
| `repoURL` / `path` / `targetRevision` | 去哪里拉代码 |
| `chart` + `values.yaml` | 用什么 chart、什么参数 |
| `destination.namespace` | 装到哪个命名空间 |
| `syncPolicy` | 自动化程度（自动/手动、是否自愈） |
| `sync-wave` 注解 | **部署顺序**（数字小的先执行） |

## sync-wave 约定

Argo CD **不会自动推断依赖顺序**，必须用注解显式声明：

| wave | 内容 | 例子 |
|---|---|---|
| 0 | Operator / CRD | minio-operator、strimzi、flink-operator |
| 1 | 实例 / CR | minio-tenant、kafka-cluster |
| 2 | 应用层 | monitoring、superset、dolphinscheduler |

## 验收

```bash
kubectl get applications -n argocd          # 所有 App 应为 Synced + Healthy
kubectl get pods -A                          # 各命名空间 Pod Running
```
