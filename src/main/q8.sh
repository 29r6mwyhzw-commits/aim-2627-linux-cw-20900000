#!/bin/bash
# Q8：repair 时识别并停止采集器、修复 HTTP 服务；cleanup 时停止修复后的服务。
# 完整接口与验收规格见 Problem.pdf。只修改本文件，不修改测试或工具。
set -eu
input=${1:?需要输入目录}
output=${2:?需要输出目录}

action=${3:-repair}

source "$input/process.env"
case "$action" in
    repair)
        process_user=$(ps -p "$TARGET_PID" -o user=)
        process_state=$(ps -p "$TARGET_PID" -o stat=)
        process_command=$(ps -ww -p "$TARGET_PID" -o args=)

        printf 'pid=%s\nuser=%s\nstate=%s\ncommand=%s\n' \
            "$TARGET_PID" "$process_user" "$process_state" "$process_command" \
            > "$output/process.txt"
        cat "$WORKER_LOG" > "$output/collector-sample.log"
        kill -TERM "$TARGET_PID"
        for attempt in {1..30}; do
            if grep -Fxq "STOP $TARGET_TOKEN" "$WORKER_LOG"; then
                break
            fi
            sleep 0.1
        done

        grep -Fxq "STOP $TARGET_TOKEN" "$WORKER_LOG"
        kill -TERM "$SERVICE_PID"
        for attempt in {1..30}; do
            service_state=$(ps -p "$SERVICE_PID" -o stat=) || service_state=""

            case "$service_state" in
                ""|Z*)
                    break
                    ;;
            esac

            sleep 0.1
        done

        case "$service_state" in
            ""|Z*) ;;
            *)
                printf 'Old HTTP service did not stop\n' >&2
                exit 1
                ;;
        esac
        cat > "$output/server.conf" <<EOF
bind=127.0.0.1
port=$TARGET_PORT
route=/status
EOF
        bash "$START_TOOL" "$output/server.conf" "$output/service"
        for attempt in {1..20}; do
            if curl --noproxy '*' --silent --show-error --max-time 0.2 \
                --output "$output/http-body.txt" \
                --write-out '%{http_code}\n' \
                "http://127.0.0.1:$TARGET_PORT/status" \
                > "$output/http-status.txt"; then

                if grep -Fxq '200' "$output/http-status.txt"; then
                    break
                fi
            fi

            sleep 0.1
        done

        grep -Fxq '200' "$output/http-status.txt"
        grep -Fxq 'SENTRY READY' "$output/http-body.txt"
        ;;
    cleanup)
        new_service_pid=$(cat "$output/service/pid")
        kill -TERM "$new_service_pid"

        for attempt in {1..30}; do
            service_state=$(ps -p "$new_service_pid" -o stat=) || service_state=""

            case "$service_state" in
                ""|Z*)
                    break
                    ;;
            esac

            sleep 0.1
        done

        case "$service_state" in
            ""|Z*) ;;
            *)
                printf 'Repaired HTTP service did not stop\n' >&2
                exit 1
                ;;
        esac
        ;;
    *)
        printf 'Unknown action: %s\n' "$action" >&2
        exit 1
        ;;
esac
