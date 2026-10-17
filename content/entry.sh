#!/bin/sh
# Hindsight LPK entrypoint (upgrade-safe)。
#
# 职责：
#   1. 把「部署参数」翻译成官方 Hindsight 的环境变量。平台按 lzc-manifest.yml
#      渲染出的是带 HINDSIGHT_ 前缀的名字（HINDSIGHT_LZC_LLM_PROVIDER 等）；
#      旧名（无前缀 LZC_LLM_PROVIDER 等）仍被接受，作为向后兼容的回退。
#      只在值非空时导出 —— 官方对 embeddings/reranker 用的是
#      os.getenv(KEY, DEFAULT) 两参形式，空字符串会「覆盖掉」内置默认值（例如把
#      本地嵌入模型路径清空），所以绝不能把空值原样 export 成 HINDSIGHT_API_*。
#   2. 支持 extra_env 高级入口（KEY=VALUE;KEY2=VALUE2），覆盖部署参数页没列的官方变量。
#   3. 清理上一个容器留下的嵌入式 PostgreSQL 实例标记（只删标记文件，不动用户数据），
#      避免「卸载后立即重装」时 pg0 误判 Instance already running 而启动失败。
#   4. root 时先修正数据目录属主（UID 1000），再降权到 hindsight 执行官方 start-all.sh
#      （官方 start-all.sh 与嵌入式 pg0 都要求非 root，initdb 拒绝 root 运行）。
set -eu

# ---------- 1. 部署参数 → 官方环境变量 ----------
# set_env <NAME> <VALUE>：VALUE 为空则不动，避免覆盖官方默认值；不打印敏感值。
set_env() {
    [ -n "${2:-}" ] || return 0
    eval "export $1=\"\$2\""
    echo "[entry] 已应用部署参数 -> $1"
}

# get_param <NAME>：读部署参数。优先取 manifest 当前注入的名字
# HINDSIGHT_LZC_<NAME>，为空时回退到旧名 LZC_<NAME>（向后兼容历史包/手工传入）。
get_param() {
    eval "_pval=\${HINDSIGHT_LZC_$1:-}"
    if [ -z "$_pval" ]; then
        eval "_pval=\${LZC_$1:-}"
    fi
    printf '%s' "$_pval"
}

# --- 大模型（事实提取 / 整合 / 反思）---
_llm_provider="$(get_param LLM_PROVIDER)"
[ -n "$_llm_provider" ] || _llm_provider="none"
set_env HINDSIGHT_API_LLM_PROVIDER "$_llm_provider"
set_env HINDSIGHT_API_LLM_MODEL "$(get_param LLM_MODEL)"
set_env HINDSIGHT_API_LLM_API_KEY "$(get_param LLM_API_KEY)"
set_env HINDSIGHT_API_LLM_BASE_URL "$(get_param LLM_BASE_URL)"

# 镜像内置的离线模型缓存（镜像里 HF_HUB_OFFLINE=1 / TRANSFORMERS_OFFLINE=1，
# 意味着**只能**用缓存里已有的模型，联网下载不会发生）。
HF_CACHE_DIR=/home/hindsight/.cache/huggingface/hub
BUNDLED_EMB_MODEL="BAAI/bge-small-en-v1.5"
BUNDLED_RR_MODEL="cross-encoder/ms-marco-MiniLM-L-6-v2"

# bundled_model <用户填的模型名> <内置默认模型>
# local 供应商只在「模型确实在镜像缓存里」或「填的是本地目录」时才原样使用；
# 否则回退到内置模型并打日志。
# 为什么必须兜住：审核 #20233 反馈「嵌入重排 local启动报错」——local 供应商一旦拿到
# 缓存里没有的模型名（例如把 provider 名误填进模型框、或填了云端模型名），
# 在离线模式下加载必然失败，应用启动即报错。
bundled_model() {
    _want="${1:-}"
    _def="${2:-}"
    if [ -z "$_want" ]; then
        printf '%s' "$_def"
        return 0
    fi
    # 直接给了本地模型目录：原样使用
    if [ -d "$_want" ]; then
        printf '%s' "$_want"
        return 0
    fi
    _slug="models--$(printf '%s' "$_want" | sed 's#/#--#g')"
    if [ -d "$HF_CACHE_DIR/$_slug" ]; then
        printf '%s' "$_want"
        return 0
    fi
    if [ "$_want" != "$_def" ]; then
        echo "[entry] 本地模型 '$_want' 不在镜像内置缓存里（离线模式无法下载），改用内置模型 '$_def'"
    fi
    printf '%s' "$_def"
}

# --- 嵌入模型 ---
# 【2026-10-13 返工 #20353】嵌入**只支持 local（内置离线模型）**。
# 实测证据（容器日志）：官方 embeddings 运行时对非 local 供应商「初始化即验证/
# 加载」，任何不可用配置都会让整个容器启动即退出（exit 3，主日志
# "ExceptionGroup: unhandled errors in a TaskGroup"）：
#   - openai：不可达超时崩、可达但凭据/端点无效同样崩；
#   - tei：同类（远端服务不可验证）；
#   - onnx：按内置缓存路径加载 model.onnx 也崩（镜像内该运行时不可用）。
# 云端/onnx 的可用性无法在启动前可靠判定，「配了就起不来」正是审核驳回
# 「启动报错」的现场。因此这里把一切非 local 的历史残留或手工配置统一回退到
# 内置本地模型，并在日志中说明（应用保证可启动；与 #20233 的 local 模型名
# 回退策略一脉相承）。
_emb_provider="$(get_param EMBEDDINGS_PROVIDER)"
[ -n "$_emb_provider" ] || _emb_provider="local"
if [ "$_emb_provider" != "local" ]; then
    echo "[entry] 嵌入供应商 '$_emb_provider' 不受支持（仅 local，保证任何网络环境下都可启动），已回退内置本地模型 $BUNDLED_EMB_MODEL"
    _emb_provider="local"
fi
set_env HINDSIGHT_API_EMBEDDINGS_PROVIDER "local"
set_env HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL "$(bundled_model "$(get_param EMBEDDINGS_MODEL)" "$BUNDLED_EMB_MODEL")"

# --- 重排模型（recall 的 cross-encoder 重排）---
_rr_provider="$(get_param RERANKER_PROVIDER)"
[ -n "$_rr_provider" ] || _rr_provider="local"
set_env HINDSIGHT_API_RERANKER_PROVIDER "$_rr_provider"
case "$_rr_provider" in
    cohere)
        set_env HINDSIGHT_API_RERANKER_COHERE_API_KEY "$(get_param RERANKER_API_KEY)"
        set_env HINDSIGHT_API_RERANKER_COHERE_MODEL "$(get_param RERANKER_MODEL)"
        set_env HINDSIGHT_API_RERANKER_COHERE_BASE_URL "$(get_param RERANKER_BASE_URL)"
        ;;
    openrouter)
        set_env HINDSIGHT_API_RERANKER_OPENROUTER_API_KEY "$(get_param RERANKER_API_KEY)"
        set_env HINDSIGHT_API_RERANKER_OPENROUTER_MODEL "$(get_param RERANKER_MODEL)"
        set_env HINDSIGHT_API_RERANKER_OPENROUTER_BASE_URL "$(get_param RERANKER_BASE_URL)"
        ;;
    litellm)
        set_env HINDSIGHT_API_RERANKER_LITELLM_API_KEY "$(get_param RERANKER_API_KEY)"
        set_env HINDSIGHT_API_RERANKER_LITELLM_MODEL "$(get_param RERANKER_MODEL)"
        set_env HINDSIGHT_API_RERANKER_LITELLM_API_BASE "$(get_param RERANKER_BASE_URL)"
        ;;
    tei)
        set_env HINDSIGHT_API_RERANKER_TEI_URL "$(get_param RERANKER_BASE_URL)"
        ;;
    local)
        set_env HINDSIGHT_API_RERANKER_LOCAL_MODEL "$(bundled_model "$(get_param RERANKER_MODEL)" "$BUNDLED_RR_MODEL")"
        ;;
esac

# ---------- 2. extra_env 高级入口 ----------
_extra_env="$(get_param EXTRA_ENV)"
if [ -n "$_extra_env" ]; then
    _saved_ifs=$IFS
    IFS=';'
    for _kv in $_extra_env; do
        case "$_kv" in
            *=*)
                _k=${_kv%%=*}
                _v=${_kv#*=}
                case "$_k" in
                    [A-Za-z_]*)
                        eval "export $_k=\"\$_v\""
                        echo "[entry] extra_env 已应用 -> $_k"
                        ;;
                    *)
                        echo "[entry] extra_env 跳过非法变量名：$_k"
                        ;;
                esac
                ;;
            '')
                ;;
            *)
                echo "[entry] extra_env 跳过无法解析的片段"
                ;;
        esac
    done
    IFS=$_saved_ifs
fi

echo "[entry] LLM=$HINDSIGHT_API_LLM_PROVIDER 嵌入=${HINDSIGHT_API_EMBEDDINGS_PROVIDER:-local} 重排=${HINDSIGHT_API_RERANKER_PROVIDER:-local}"

# 验收/排障用：LZC_ENTRY_DRY_RUN=1 时只打印参数解析结果并退出（不启动任何服务）。
if [ "${LZC_ENTRY_DRY_RUN:-}" = "1" ]; then
    echo "[entry][dry-run] LLM  provider=${HINDSIGHT_API_LLM_PROVIDER:-none} model=${HINDSIGHT_API_LLM_MODEL:-DEFAULT}"
    echo "[entry][dry-run] 嵌入 provider=${HINDSIGHT_API_EMBEDDINGS_PROVIDER:-local} model=${HINDSIGHT_API_EMBEDDINGS_LOCAL_MODEL:-DEFAULT}"
    echo "[entry][dry-run] 重排 provider=${HINDSIGHT_API_RERANKER_PROVIDER:-local} model=${HINDSIGHT_API_RERANKER_LOCAL_MODEL:-DEFAULT}"
    exit 0
fi

# ---------- 3. 清理陈旧嵌入式 PG 实例标记 ----------
# 数据目录 bind 自 /lzcapp/var/data，卸载不会删除它。上一个容器退出时留下的
# instances/<name>/instance.json 记录的 pid 在新容器里已不存在（或已是别的进程），
# 但 pg0 会据此认为实例仍在运行，直接报：
#   Failed to start embedded PostgreSQL after 5 attempts. ... Instance already running (pid: ...)
# 处理：标记存在、却找不到「属于本实例数据目录的 postgres 进程」时，只删除该标记文件；
# 库数据一律保留（绝不删 instances/<name>/data）。
if [ -d /home/hindsight/.pg0/instances ]; then
    for _marker in /home/hindsight/.pg0/instances/*/instance.json; do
        [ -f "$_marker" ] || continue
        _pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_marker" | head -n 1)
        _ddir=$(sed -n 's/.*"data_dir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_marker" | head -n 1)
        _alive=0
        if [ -n "$_pid" ] && [ -r "/proc/$_pid/cmdline" ]; then
            _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null || true)
            case "$_cmd" in
                *postgres*)
                    if [ -z "$_ddir" ]; then
                        _alive=1
                    elif printf '%s' "$_cmd" | grep -qF -- "$_ddir"; then
                        _alive=1
                    fi
                    ;;
            esac
        fi
        if [ "$_alive" = "1" ]; then
            echo "[entry] 实例标记有效：本实例 postgres 正在运行（pid=$_pid），保留 $_marker"
        else
            rm -f "$_marker"
            echo "[entry] 已清理陈旧实例标记（无对应 postgres 进程，pid=${_pid:-未知}）：$_marker"
        fi
    done
fi

# ---------- 3b. 校验嵌入式 PG 数据目录是否是可用的集群 ----------
# 【2026-10-14 返工 #20462 修复】历史版本在「首次初始化中途崩溃」时会留下半初始化的数据目录：
# data/ 在，但缺 PG_VERSION 或 global/pg_control。此时 pg0 重试 5 次后放弃并让进程退出：
#   RuntimeError: Failed to start embedded PostgreSQL after 5 attempts. Last error:
#   pg_ctl: directory "..." is not a database cluster directory
# 平台表现就是「启动报错 / 应用状态错误」。旧包只清陈旧实例标记（第 3 段），不处理这种情况，
# 所以同一台机器连续两轮都报启动失败（#20353、#20462 同因）。
# 处理：数据目录不是可用集群时，整体改名备份为同目录下的 data.broken-<时间戳>，再删实例标记，
# 让 pg0 重新初始化干净集群。**不删除任何用户数据**，备份留在 /lzcapp/var/data 下可人工还原。
PG_INSTANCES=/home/hindsight/.pg0/instances
if [ -d "$PG_INSTANCES" ]; then
    for _data in "$PG_INSTANCES"/*/data; do
        [ -d "$_data" ] || continue
        if [ -f "$_data/PG_VERSION" ] && [ -f "$_data/global/pg_control" ]; then
            echo "[entry] PG 数据目录自检通过：$_data"
            continue
        fi
        _bak="$_data.broken-$(date +%Y%m%d-%H%M%S)"
        echo "[entry] PG 数据目录不是可用集群（缺 PG_VERSION 或 global/pg_control），已备份为 $_bak 并重新初始化：$_data"
        mv "$_data" "$_bak" 2>/dev/null || true
        rm -f "$(dirname "$_data")/instance.json" 2>/dev/null || true
    done
fi

# ---------- 4. 数据目录属主 + 降权启动 ----------
if [ "$(id -u)" = "0" ]; then
    # 数据目录在容器内 /home/hindsight/.pg0（bind 自 /lzcapp/var/data）
    if [ -d /home/hindsight/.pg0 ]; then
        chown -R 1000:1000 /home/hindsight/.pg0 2>/dev/null || true
    fi
    # 模型缓存（镜像预置）若被 root 触碰过也修正
    if [ -d /home/hindsight/.cache ]; then
        chown -R 1000:1000 /home/hindsight/.cache 2>/dev/null || true
    fi
    export HOME=/home/hindsight
    exec setpriv --reuid=1000 --regid=1000 --keep-groups /usr/bin/bash /app/start-all.sh
fi

exec /usr/bin/bash /app/start-all.sh
