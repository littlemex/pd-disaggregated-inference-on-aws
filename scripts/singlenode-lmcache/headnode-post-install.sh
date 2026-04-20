#!/bin/bash
# HeadNode 向け post-install スクリプト
#
# 役割:
#   - Slurm jobcomp ログの出力先 /fsx/logs を事前作成
#     （slurmctld 初回起動時にディレクトリがないと jobcomp/filetxt が失敗する）
#   - その他 HeadNode 固有の初期化（必要に応じて追記）
#
# 設計原則:
#   - 冪等性: 複数回実行しても副作用が増えない
#   - fail-fast: /fsx がマウントされていない場合はエラーで返す
#
# ParallelCluster での配置:
#   HeadNode の CustomActions.OnNodeConfigured.Sequence の冒頭に配置する。
#   docker / nccl / pyxis の前に実行されることを前提とする。

set -uo pipefail

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [headnode-post-install] $*"
}

log "Starting HeadNode post-install"

FSX_ROOT="${FSX_ROOT:-/fsx}"

# /fsx マウント待機（最大 180 秒）
wait_for_fsx() {
    local max_wait="${FSX_MOUNT_TIMEOUT:-180}"
    local waited=0
    while ! mountpoint -q "${FSX_ROOT}" 2>/dev/null; do
        if [[ ${waited} -ge ${max_wait} ]]; then
            return 1
        fi
        log "[INFO] Waiting for ${FSX_ROOT} to be mounted (${waited}s/${max_wait}s)"
        sleep 5
        waited=$((waited + 5))
    done
    return 0
}

if wait_for_fsx; then
    log "${FSX_ROOT} is mounted"
    for d in logs scripts; do
        if mkdir -p "${FSX_ROOT}/${d}"; then
            chmod 777 "${FSX_ROOT}/${d}" 2>/dev/null || true
            log "[OK] ${FSX_ROOT}/${d} ready"
        else
            log "[WARN] Failed to create ${FSX_ROOT}/${d}"
        fi
    done

    # slurmctld が書き込む jobcomp ファイルを事前作成し、slurm ユーザーが書き込めるよう許可する
    # slurmctld は 'slurm' ユーザーで動作するため root:root 所有のままでは Permission denied になる
    touch "${FSX_ROOT}/logs/slurm-jobcomp.txt" 2>/dev/null && \
        chmod 666 "${FSX_ROOT}/logs/slurm-jobcomp.txt" 2>/dev/null || \
        log "[WARN] Failed to create or chmod ${FSX_ROOT}/logs/slurm-jobcomp.txt"
else
    log "[FATAL] ${FSX_ROOT} did not become mounted within ${FSX_MOUNT_TIMEOUT:-180}s"
    exit 1
fi

log "HeadNode post-install finished"
