#!/bin/bash
# ============================================================
#  arXiv Prod Lab - 生产级大数据平台一键部署脚本
# ============================================================
#  技术栈清单（按数据流向）：
#
#  1. K3s                    - 轻量级 Kubernetes 发行版，容器编排底座
#  2. Helm                   - Kubernetes 包管理器，用于部署复杂应用
#  3. Argo CD                - GitOps 持续部署，声明式同步集群状态
#  4. MinIO + Operator       - S3 兼容对象存储，数据湖的物理存储底座
#  5. Apache Kafka + Strimzi - 消息管道，实时数据流转与削峰填谷
#  6. Apache Flink + Operator- 实时流计算引擎，5分钟窗口聚合
#  7. Apache Spark + Operator- 离线批计算引擎，全量修正与引用网络分析
#  8. PostgreSQL             - 关系型数据库，存储聚合结果（流批对账）
#  9. Prometheus + Grafana   - 可观测性，指标采集与可视化监控
# 10. DolphinScheduler + Superset - 任务调度 + BI 可视化
# ============================================================
#  硬件要求：16GB+ 内存，100GB+ 磁盘
#  推荐配置：32GB 内存，2TB 硬盘
#  预计总耗时：15-25 分钟（取决于网络速度）
# ============================================================

set -euo pipefail

# ============================================================
# 颜色与日志函数
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step()  { echo -e "\n${BLUE}====> $1${NC}"; }
log_ok()    { echo -e "${CYAN}[OK]${NC} $1"; }

# ============================================================
# 进度管理
# ============================================================
TOTAL_STEPS=10
CURRENT_STEP=0

# 步骤预估时间（秒）
declare -A STEP_TIME=(
    [1]="60"   # K3s
    [2]="30"   # Helm
    [3]="120"  # Argo CD
    [4]="180"  # MinIO
    [5]="240"  # Kafka
    [6]="60"   # Flink
    [7]="60"   # Spark
    [8]="60"   # PostgreSQL
    [9]="180"  # 监控
    [10]="300" # 业务工具
)

show_progress() {
    local step=$1
    local name=$2
    local total=${TOTAL_STEPS}
    local elapsed_total=$(($(date +%s) - START_TIME))
    local est_time=${STEP_TIME[$step]}
    local remaining=0
    for ((i=step; i<=TOTAL_STEPS; i++)); do
        remaining=$((remaining + ${STEP_TIME[$i]}))
    done
    remaining=$((remaining - elapsed_total))
    [ $remaining -lt 0 ] && remaining=0

    echo ""
    echo "============================================================"
    echo -e "${CYAN}进度: [${step}/${total}] ${name}${NC}"
    echo -e "预计剩余时间: ${remaining} 秒 (约 $((remaining / 60)) 分钟)"
    echo -e "已耗时: ${elapsed_total} 秒 (约 $((elapsed_total / 60)) 分钟)"
    echo "============================================================"
    echo ""
}

# ============================================================
# 环境检测
# ============================================================
check_prerequisites() {
    log_step "检测系统环境"

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="darwin"
        log_warn "macOS 环境: 请确保已安装 Docker Desktop"
    else
        log_error "仅支持 Linux 和 macOS"
    fi

    for cmd in curl wget tar gzip; do
        if ! command -v $cmd &> /dev/null; then
            log_error "缺少必要命令: $cmd，请先安装"
        fi
    done

    if ! command -v docker &> /dev/null; then
        log_error "未检测到 Docker，请先安装 Docker"
    fi

    if [[ "$OS" == "linux" ]]; then
        MEM_TOTAL=$(free -g | awk '/^Mem:/{print $2}')
        if [[ $MEM_TOTAL -lt 16 ]]; then
            log_warn "内存 ${MEM_TOTAL}GB，建议至少 16GB"
        else
            log_info "内存: ${MEM_TOTAL}GB ✓"
        fi
    fi

    log_ok "环境检测通过"
}

# ============================================================
# 1. 安装 K3s (预估: 60秒)
# ============================================================
install_k3s() {
    CURRENT_STEP=1
    show_progress $CURRENT_STEP "K3s - 轻量级 Kubernetes"

    if command -v k3s &> /dev/null && sudo k3s kubectl get nodes &> /dev/null; then
        log_warn "K3s 已安装，跳过"
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        return
    fi

    curl -sfL https://get.k3s.io | sh -s - \
        --write-kubeconfig-mode 644 \
        --disable=traefik \
        --disable=servicelb \
        --kube-apiserver-arg "service-node-port-range=30000-32767"

    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    sleep 10
    sudo k3s kubectl wait --for=condition=Ready node --all --timeout=120s

    log_ok "K3s 安装完成 (版本: $(sudo k3s kubectl version --short 2>/dev/null | head -1))"
}

# ============================================================
# 2. 安装 Helm (预估: 30秒)
# ============================================================
install_helm() {
    CURRENT_STEP=2
    show_progress $CURRENT_STEP "Helm - Kubernetes 包管理器"

    if command -v helm &> /dev/null; then
        log_warn "Helm 已安装，跳过"
        return
    fi

    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod +x get_helm.sh
    ./get_helm.sh
    rm -f get_helm.sh

    log_ok "Helm 安装完成 (版本: $(helm version --short 2>/dev/null | head -1))"
}

# ============================================================
# 3. 安装 Argo CD (预估: 120秒)
# ============================================================
install_argocd() {
    CURRENT_STEP=3
    show_progress $CURRENT_STEP "Argo CD - GitOps 持续部署"

    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=180s

    ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "请手动获取")

    cat <<EOF | kubectl apply -n argocd -f -
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-nodeport
spec:
  type: NodePort
  ports:
    - name: http
      port: 80
      targetPort: 8080
      nodePort: 30080
    - name: https
      port: 443
      targetPort: 8080
      nodePort: 30443
  selector:
    app.kubernetes.io/name: argocd-server
EOF

    log_ok "Argo CD 安装完成"
    log_info "密码: ${ARGO_PASSWORD}"
}

# ============================================================
# 4. 安装 MinIO (预估: 180秒)
# ============================================================
install_minio() {
    CURRENT_STEP=4
    show_progress $CURRENT_STEP "MinIO - 分布式对象存储"

    kubectl create namespace minio-operator --dry-run=client -o yaml | kubectl apply -f -
    curl -sSL https://github.com/minio/operator/releases/latest/download/operator.yaml | kubectl apply -n minio-operator -f -
    kubectl wait --for=condition=Available deployment/minio-operator -n minio-operator --timeout=120s

    kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
    cat <<'EOF' | kubectl apply -n minio -f -
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
type: Opaque
stringData:
  accesskey: "minioadmin"
  secretkey: "minioadmin123"
---
apiVersion: minio.min.io/v2
kind: Tenant
metadata:
  name: arxiv-tenant
spec:
  pools:
    - name: pool-0
      servers: 4
      volumesPerServer: 1
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
  credentialsSecret:
    name: minio-creds
  exposeServices:
    console:
      nodePort: 30901
      type: NodePort
    minio:
      nodePort: 30900
      type: NodePort
EOF

    log_ok "MinIO 安装完成"
}

# ============================================================
# 5. 安装 Kafka (预估: 240秒)
# ============================================================
install_kafka() {
    CURRENT_STEP=5
    show_progress $CURRENT_STEP "Apache Kafka - 消息管道"

    kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -
    curl -sSL https://strimzi.io/install/latest?namespace=kafka | kubectl apply -n kafka -f -
    kubectl wait --for=condition=Available deployment/strimzi-cluster-operator -n kafka --timeout=120s

    cat <<'EOF' | kubectl apply -n kafka -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: arxiv-cluster
spec:
  kafka:
    version: 3.7.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: external
        port: 29092
        type: nodeport
        tls: false
    storage:
      type: ephemeral
    resources:
      requests:
        memory: "1Gi"
        cpu: "500m"
      limits:
        memory: "4Gi"
        cpu: "2"
  zookeeper:
    replicas: 3
    storage:
      type: ephemeral
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "1Gi"
        cpu: "1"
EOF

    sleep 30
    log_ok "Kafka 安装完成"
}

# ============================================================
# 6. 安装 Flink (预估: 60秒)
# ============================================================
install_flink() {
    CURRENT_STEP=6
    show_progress $CURRENT_STEP "Apache Flink - 实时流计算"

    kubectl create namespace flink --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -n flink -f https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable/flink-kubernetes-operator.yaml

    kubectl wait --for=condition=Available deployment/flink-kubernetes-operator -n flink --timeout=120s
    log_ok "Flink Operator 安装完成"
}

# ============================================================
# 7. 安装 Spark (预估: 60秒)
# ============================================================
install_spark() {
    CURRENT_STEP=7
    show_progress $CURRENT_STEP "Apache Spark - 离线批计算"

    kubectl create namespace spark-operator --dry-run=client -o yaml | kubectl apply -f -
    helm repo add spark-operator https://kubeflow.github.io/spark-operator 2>/dev/null || true
    helm repo update
    helm install spark-operator spark-operator/spark-operator \
        -n spark-operator \
        --create-namespace \
        --set sparkJobNamespace=default \
        --set enableWebhook=true

    kubectl wait --for=condition=Available deployment/spark-operator -n spark-operator --timeout=120s
    log_ok "Spark Operator 安装完成"
}

# ============================================================
# 8. 安装 PostgreSQL (预估: 60秒)
# ============================================================
install_postgres() {
    CURRENT_STEP=8
    show_progress $CURRENT_STEP "PostgreSQL - 结果存储"

    kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -

    cat <<'EOF' | kubectl apply -n database -f -
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
type: Opaque
stringData:
  password: "arxiv2024"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16.2-alpine
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
        - name: POSTGRES_DB
          value: "arxiv"
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1"
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 50Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
EOF

    kubectl wait --for=condition=ready pod -l app=postgres -n database --timeout=120s
    log_ok "PostgreSQL 安装完成"
}

# ============================================================
# 9. 安装监控 (预估: 180秒)
# ============================================================
install_monitoring() {
    CURRENT_STEP=9
    show_progress $CURRENT_STEP "Prometheus + Grafana - 可观测性"

    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update
    helm install monitoring prometheus-community/kube-prometheus-stack \
        -n monitoring \
        --create-namespace \
        --set grafana.adminPassword=admin \
        --set prometheus.prometheusSpec.retention=15d \
        --set grafana.service.type=NodePort \
        --set grafana.service.nodePort=30300 \
        --set prometheus.service.type=NodePort \
        --set prometheus.service.nodePort=30902

    kubectl wait --for=condition=Available deployment/monitoring-grafana -n monitoring --timeout=180s
    log_ok "监控系统安装完成"
}

# ============================================================
# 10. 安装业务工具 (预估: 300秒)
# ============================================================
install_business_tools() {
    CURRENT_STEP=10
    show_progress $CURRENT_STEP "DolphinScheduler + Superset - 调度与BI"

    # DolphinScheduler
    kubectl create namespace dolphinscheduler --dry-run=client -o yaml | kubectl apply -f -
    helm repo add dolphinscheduler https://apache.github.io/dolphinscheduler 2>/dev/null || true
    helm repo update
    helm install dolphinscheduler dolphinscheduler/dolphinscheduler \
        -n dolphinscheduler \
        --create-namespace \
        --set postgresql.enabled=false \
        --set zookeeper.enabled=false \
        --set master.replicas=1 \
        --set worker.replicas=1 \
        --set alert.replicas=1 \
        --set api.service.type=NodePort \
        --set api.service.nodePort=30500

    # Superset
    kubectl create namespace superset --dry-run=client -o yaml | kubectl apply -f -
    helm repo add superset https://apache-superset.github.io/helm-chart 2>/dev/null || true
    helm repo update
    helm install superset superset/superset \
        -n superset \
        --create-namespace \
        --set config.SECRET_KEY="$(openssl rand -base64 32 2>/dev/null || echo 'change-me-in-production')" \
        --set supersetNode.service.type=NodePort \
        --set supersetNode.service.nodePort=30600 \
        --set postgresql.enabled=true \
        --set postgresql.postgresqlPassword="superset" \
        --set redis.enabled=true

    kubectl wait --for=condition=Available deployment/superset-superset-node -n superset --timeout=180s || true

    # 初始化 Superset
    kubectl exec -n superset deploy/superset-superset-node -- bash -c "superset db upgrade && superset init && superset fab create-admin --username admin --password admin --firstname Admin --lastname User --email admin@admin.com" 2>/dev/null || true

    log_ok "DolphinScheduler + Superset 安装完成"
}

# ============================================================
# 输出部署总结
# ============================================================
print_summary() {
    local total_elapsed=$(($(date +%s) - START_TIME))
    local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="localhost"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}✅ arXiv Prod Lab 部署完成！${NC}"
    echo "============================================================"
    echo -e "${CYAN}总耗时: ${total_elapsed} 秒 (约 $((total_elapsed / 60)) 分钟)${NC}"
    echo ""
    echo -e "${CYAN}📋 组件访问地址:${NC}"
    echo "  Argo CD:          https://${ip}:30443"
    echo "  MinIO API:        http://${ip}:30900"
    echo "  MinIO Console:    http://${ip}:30901"
    echo "  Grafana:          http://${ip}:30300"
    echo "  DolphinScheduler: http://${ip}:30500/dolphinscheduler"
    echo "  Superset:         http://${ip}:30600"
    echo ""
    echo -e "${CYAN}🔑 默认账号密码:${NC}"
    echo "  Argo CD:          admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '请手动获取')"
    echo "  MinIO:            minioadmin / minioadmin123"
    echo "  Grafana:          admin / admin"
    echo "  DolphinScheduler: admin / dolphinscheduler123"
    echo "  Superset:         admin / admin"
    echo ""
    echo -e "${CYAN}📦 组件状态:${NC}"
    kubectl get pods -A --no-headers 2>/dev/null | wc -l | xargs echo "  总 Pod 数:"
    echo ""
    echo -e "${CYAN}🚀 下一步:${NC}"
    echo "  1. 访问各组件 UI 验证部署"
    echo "  2. 配置数据源连接 (PostgreSQL / MinIO)"
    echo "  3. 提交 Flink/Spark 作业"
    echo "============================================================"
}

# ============================================================
# 主流程
# ============================================================
main() {
    START_TIME=$(date +%s)

    echo ""
    echo "   █████╗ ██████╗ ██╗██╗   ██╗    ██████╗ ██████╗  ██████╗ "
    echo "  ██╔══██╗██╔══██╗██║██║   ██║    ██╔══██╗██╔══██╗██╔═══██╗"
    echo "  ███████║██████╔╝██║██║   ██║    ██████╔╝██████╔╝██║   ██║"
    echo "  ██╔══██║██╔══██╗██║╚██╗ ██╔╝    ██╔═══╝ ██╔══██╗██║   ██║"
    echo "  ██║  ██║██║  ██║██║ ╚████╔╝     ██║     ██║  ██║╚██████╔╝"
    echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝      ╚═╝     ╚═╝  ╚═╝ ╚═════╝ "
    echo ""
    echo "  arXiv Prod Lab - 生产级大数据平台实验"
    echo "  技术栈: K3s + Argo CD + MinIO + Kafka + Flink + Spark"
    echo "         + PostgreSQL + Prometheus + Grafana"
    echo "         + DolphinScheduler + Superset"
    echo "============================================================"
    echo ""

    check_prerequisites

    install_k3s
    install_helm
    install_argocd
    install_minio
    install_kafka
    install_flink
    install_spark
    install_postgres
    install_monitoring
    install_business_tools

    print_summary
    log_ok "🎉 一键部署完成！"
}

# 错误处理
trap 'log_error "脚本在行号 $LINENO 失败，请检查日志"' ERR

# 执行
main "$@"
