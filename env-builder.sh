#!/bin/bash
# ============================================================
#  arXiv Prod Lab - 平台层一键部署脚本（阶段一）
#  只负责物理搭建：K3s 集群 + GitOps 控制面（Argo CD）
# ============================================================
#  阶段一（本脚本）：
#  1. Docker                 - 容器运行时（可选）
#  2. K3s                    - 轻量级 Kubernetes 发行版
#  3. containerd 镜像加速    - 国内镜像源
#  4. Helm                   - Kubernetes 包管理器
#  5. Argo CD                - GitOps 控制面
#
#  阶段二（GitOps 仓库，不在本脚本）：
#  MinIO / Kafka / Flink / Spark / PostgreSQL / 监控 /
#  DolphinScheduler / Superset —— 全部声明为 Argo CD Application
# ============================================================
#  硬件要求：16GB+ 内存，100GB+ 磁盘
#  推荐配置：32GB 内存，2TB 硬盘
#  预计总耗时：5-10 分钟
# ============================================================

set -euo pipefail

# ============================================================
# 全局变量
# ============================================================
START_TIME=$(date +%s)
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$IP" ] && IP="localhost"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ============================================================
# 颜色与日志
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_ok()    { echo -e "${CYAN}[OK]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}====> $1${NC}"; }

# ============================================================
# 工具函数：多源下载 + 内容验证
# ============================================================
curl_with_fallback() {
    local -n url_list=$1
    local output_file="/tmp/install_$$.yaml"
    for url in "${url_list[@]}"; do
        echo -e "${GREEN}[INFO]${NC} 尝试从 $url 下载..."
        if curl -sSL --retry 3 --connect-timeout 10 --max-time 120 \
             --tlsv1.2 -H "User-Agent: Mozilla/5.0" \
             "$url" -o "$output_file" 2>/dev/null; then
            if head -n 5 "$output_file" | grep -qE "^(apiVersion|kind):"; then
                echo "$output_file"
                return 0
            else
                echo -e "${YELLOW}[WARN]${NC} 下载的内容不是有效的 YAML，可能是错误页面" >&2
                rm -f "$output_file"
            fi
        fi
    done
    return 1
}

# ============================================================
# 镜像源可用性自检（部署前执行，仅报告不阻断）
# ============================================================
test_mirror_sources() {
    log_step "镜像源可用性自检"
    echo -e "${CYAN}部署前检测各镜像源 / 下载源是否可达，仅报告、不阻断安装。${NC}"
    echo ""

    local ok=0 fail=0
    local item name url code
    # 格式: "显示名|URL"
    local sources=(
        "docker.io 加速 · DaoCloud|https://docker.m.daocloud.io/v2/"
        "docker.io 加速 · 1Panel|https://docker.1ms.run/v2/"
        "registry.k8s.io 镜像 · 阿里云|https://registry.aliyuncs.com/v2/"
        "quay.io 直连|https://quay.io/v2/"
        "ghcr.io 直连|https://ghcr.io/v2/"
        "GitHub Raw · Helm|https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
        "GitHub Raw · ArgoCD|https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
    )

    for item in "${sources[@]}"; do
        name="${item%%|*}"
        url="${item#*|}"
        code=$(curl -sSL -o /dev/null --connect-timeout 5 --max-time 15 \
            -w '%{http_code}' "$url" 2>/dev/null || true)
        if [[ "$code" == "200" || "$code" == "206" || "$code" == "401" || "$code" == "404" ]]; then
            echo -e "  ${GREEN}[OK]${NC}   $name"
            ok=$((ok + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $name (HTTP ${code:-无响应})"
            fail=$((fail + 1))
        fi
    done

    echo ""
    if [ "$fail" -gt 0 ]; then
        log_warn "共 $fail 个源不可达（OK $ok / FAIL $fail），安装时相关组件可能失败"
    else
        log_ok "全部 $ok 个源均可达"
    fi
    echo ""
}

# ============================================================
# 基础组件（串行，必须成功）
# ============================================================
install_docker_and_env() {
    if command -v docker &> /dev/null; then
        log_warn "Docker 已安装，跳过"
        return
    fi
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        log_info "使用官方脚本安装 Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm -f get-docker.sh
        sudo usermod -aG docker $USER
        sudo systemctl enable docker
        sudo systemctl start docker
        sleep 5
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        log_warn "macOS 请手动安装 Docker Desktop: brew install --cask docker"
        exit 1
    else
        log_error "仅支持 Linux 和 macOS"
    fi
    log_ok "Docker 安装完成 (版本: $(docker --version))"
}

install_k3s() {
    if command -v k3s &> /dev/null && sudo k3s kubectl get nodes &> /dev/null; then
        log_warn "K3s 已安装，跳过"
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        return
    fi
    curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | \
      INSTALL_K3S_MIRROR=cn \
      sh -s - \
        --write-kubeconfig-mode 644 \
        --disable=traefik \
        --disable=servicelb \
        --kube-apiserver-arg "service-node-port-range=30000-32767"
    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    sleep 10
    sudo k3s kubectl wait --for=condition=Ready node --all --timeout=120s
    log_ok "K3s 安装完成"
}

configure_containerd_mirror() {
    if ! command -v k3s &> /dev/null; then
        log_warn "K3s 未安装，跳过"
        return
    fi
    sudo mkdir -p /etc/rancher/k3s
    cat <<'EOF' | sudo tee /etc/rancher/k3s/registries.yaml
mirrors:
  docker.io:
    endpoint:
      - "https://docker.m.daocloud.io"
      - "https://docker.1ms.run"
  registry.k8s.io:
    endpoint:
      - "https://registry.aliyuncs.com/google_containers"
EOF
    sudo systemctl restart k3s
    sleep 10
    log_ok "containerd 镜像加速配置完成"
}

install_helm() {
    if command -v helm &> /dev/null; then
        log_warn "Helm 已安装，跳过"
        return
    fi
    local urls=(
        "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
    )
    local success=0
    for url in "${urls[@]}"; do
        log_info "尝试从 $url 下载 Helm 安装脚本..."
        if curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$url" -o get_helm.sh 2>/dev/null; then
            chmod +x get_helm.sh
            ./get_helm.sh
            rm -f get_helm.sh
            success=1
            break
        fi
    done
    if [ $success -eq 0 ]; then
        log_error "Helm 下载失败，请检查网络"
        exit 1
    fi
    log_ok "Helm 安装完成 (版本: $(helm version --short 2>/dev/null | head -1))"
}

# ============================================================
# GitOps 控制面：Argo CD
# ============================================================
install_argocd() {
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    local urls=(
        "https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
    )
    local yaml_file=$(curl_with_fallback urls) || return 1
    kubectl apply -n argocd -f "$yaml_file"
    rm -f "$yaml_file"
    kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
    local retry=0
    ARGO_PASSWORD=""
    while [ $retry -lt 30 ]; do
        ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
        if [ -n "$ARGO_PASSWORD" ]; then
            break
        fi
        sleep 2
        retry=$((retry + 1))
    done
    [ -z "$ARGO_PASSWORD" ] && ARGO_PASSWORD="请手动获取"
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
    echo "ARGO_PASSWORD=$ARGO_PASSWORD" >> /tmp/argo_password.txt
}

# ============================================================
# 输出部署总结
# ============================================================
print_summary() {
    local elapsed=$(($(date +%s) - START_TIME))
    local argo_pass
    if [ -f /tmp/argo_password.txt ]; then
        argo_pass=$(grep ARGO_PASSWORD= /tmp/argo_password.txt 2>/dev/null | cut -d= -f2- || true)
    else
        argo_pass=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null || echo '请手动获取')
    fi
    [ -n "$argo_pass" ] || argo_pass="请手动获取"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}✅ 平台层部署完成${NC}"
    echo -e "${CYAN}总耗时: ${elapsed} 秒 (约 $((elapsed / 60)) 分钟)${NC}"
    echo "============================================================"
    echo -e "${CYAN}📋 访问地址:${NC}"
    echo "  Argo CD:  https://${IP}:30443  (或 kubectl port-forward -n argocd svc/argocd-server 8080:443)"
    echo ""
    echo -e "${CYAN}🔑 默认账号:${NC}"
    echo "  Argo CD:  admin / ${argo_pass}"
    echo ""
    echo -e "${CYAN}🧩 下一步（阶段二 GitOps）:${NC}"
    echo "  1. 创建 Git 仓库（建议 Gitee 或自建 Gitea，避免 GitHub 连通性问题）"
    echo "  2. 用 init-gitops.sh 生成 Application 清单并提交 Git"
    echo "  3. Argo CD 自动同步，各组件以声明式方式部署"
    echo "============================================================"
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo "   █████╗ ██████╗ ██╗██╗   ██╗    ██████╗ ██████╗  ██████╗ "
    echo "  ██╔══██╗██╔══██╗██║██║   ██║    ██╔══██╗██╔══██╗██╔═══██╗"
    echo "  ███████║██████╔╝██║██║   ██║    ██████╔╝██████╔╝██║   ██║"
    echo "  ██╔══██║██╔══██╗██║╚██╗ ██╔╝    ██╔═══╝ ██╔══██╗██║   ██║"
    echo "  ██║  ██║██║  ██║██║ ╚████╔╝     ██║     ██║  ██║╚██████╔╝"
    echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝      ╚═╝     ╚═╝  ╚═╝ ╚═════╝ "
    echo ""
    echo "  arXiv Prod Lab - 平台层部署（阶段一：K3s + Argo CD）"
    echo "============================================================"
    echo ""

    # 阶段0：镜像源可用性自检
    test_mirror_sources

    # 阶段1：基础组件（串行）
    install_docker_and_env || exit 1
    install_k3s || exit 1
    configure_containerd_mirror || exit 1
    install_helm || exit 1
    install_argocd || exit 1

    print_summary
}

# ============================================================
# 错误处理
# ============================================================
trap 'log_error "脚本在行号 $LINENO 遇到致命错误，请检查日志"' ERR

# 执行
main "$@"
