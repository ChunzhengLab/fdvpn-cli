fdvpn() {
    emulate -L zsh
    setopt local_options pipe_fail no_aliases

    local cmd="${1:-status}"
    local STATE_DIR="${TMPDIR:-/tmp}"
    STATE_DIR="${STATE_DIR%/}/fdvpn-${UID}"

    if [ -L "${STATE_DIR}" ] || { [ -e "${STATE_DIR}" ] && [ ! -d "${STATE_DIR}" ]; }; then
        echo "VPN 状态目录异常: ${STATE_DIR}"
        return 1
    fi

    if [ ! -d "${STATE_DIR}" ]; then
        (umask 077 && command mkdir -p "${STATE_DIR}") || {
            echo "无法创建 VPN 状态目录: ${STATE_DIR}"
            return 1
        }
    fi
    chmod 700 "${STATE_DIR}" 2>/dev/null

    local PID_FILE="${STATE_DIR}/openconnect.pid"
    local INFO_FILE="${STATE_DIR}/session.info"

    case "${cmd}" in
        start)
            local VPN_USER
            VPN_USER=$(security find-generic-password -s "fdvpn" -a "user" -w 2>/dev/null)

            if [ -z "${VPN_USER}" ]; then
                echo "无法从 Keychain 读取 VPN 用户名"
                return 1
            fi

            if pgrep -x "Surge" > /dev/null 2>&1; then
                echo "检测到 Surge 正在运行，与复旦 VPN 不兼容，请先退出 Surge"
                return 1
            fi

            if [ -f "${PID_FILE}" ]; then
                local pid
                local command_name=""
                pid=$(command cat "${PID_FILE}" 2>/dev/null | tr -d '[:space:]') || pid=""
                [[ "${pid}" =~ ^[0-9]+$ ]] || pid=""
                if [ -n "${pid}" ]; then
                    command_name=$(ps -p "${pid}" -o comm= 2>/dev/null) || command_name=""
                fi
                if [ -n "${pid}" ] && [ "${command_name##*/}" = "openconnect" ]; then
                    echo "VPN 已经在运行 (PID: ${pid})"
                    return 0
                fi
            fi

            if ! command -v expect > /dev/null 2>&1; then
                echo "缺少 expect，无法自动处理空 authgroup 和密码提示"
                return 1
            fi

            if [ -f "${PID_FILE}" ]; then
                rm -f "${PID_FILE}" "${INFO_FILE}"
            fi

            VPN_USER="${VPN_USER}" PID_FILE="${PID_FILE}" expect <<'EOF'
                log_user 0
                set timeout 30

                proc restore_tty {} {
                    catch {stty echo}
                }

                proc fail {message {code 1}} {
                    restore_tty
                    send_user -- "$message\n"
                    exit $code
                }

                proc read_secret {prompt} {
                    restore_tty
                    send_user -- $prompt
                    stty -echo
                    if {[catch {expect_user -re "(.*)\n"}]} {
                        fail "已取消输入"
                    }
                    set value $expect_out(1,string)
                    restore_tty
                    send_user -- "\n"
                    return $value
                }

                trap {
                    restore_tty
                    exit 130
                } {SIGINT SIGTERM}

                if {[catch {
                    set vpn_pass [string trimright [exec security find-generic-password -s fdvpn -a pass -w]]
                } err]} {
                    fail "无法从 Keychain 读取 VPN 密码"
                }

                spawn sudo -p {[fdvpn sudo] Password: } openconnect \
                    --protocol=array \
                    --server=te.sslvpn.fudan.edu.cn \
                    --user=$env(VPN_USER) \
                    --servercert=pin-sha256:fKjnuyPmDbOieXuypYfgcg/LvpZvuTVQYB1U1213Cd4= \
                    --background \
                    --pid-file=$env(PID_FILE)

                expect {
                    -re {\[fdvpn sudo\] Password:\s*$} {
                        send -- "[read_secret {[fdvpn] 请输入本机 sudo 密码: }]\r"
                        exp_continue
                    }
                    -re {(?i)sorry,\s*try\s*again\.?\s*$} {
                        exp_continue
                    }
                    -re {(?i)authgroup[^:]*:\s*$} {
                        send -- "\r"
                        exp_continue
                    }
                    -re {(?i)password[^:]*:\s*$} {
                        send -- "$vpn_pass\r"
                        exp_continue
                    }
                    timeout {
                        fail "VPN 启动超时，请检查网络、sudo 密码或 VPN 凭据"
                    }
                    eof
                }

                catch wait result
                restore_tty
                lassign $result _ _ _ exit_status
                exit $exit_status
EOF
            local expect_status=$?
            if [ "${expect_status}" -ne 0 ]; then
                return "${expect_status}"
            fi

            local ok=0
            for _ in {1..10}; do
                local pid
                local command_name=""
                pid=$(command cat "${PID_FILE}" 2>/dev/null | tr -d '[:space:]') || pid=""
                [[ "${pid}" =~ ^[0-9]+$ ]] || pid=""
                if [ -n "${pid}" ]; then
                    command_name=$(ps -p "${pid}" -o comm= 2>/dev/null) || command_name=""
                fi
                if [ -n "${pid}" ] && [ "${command_name##*/}" = "openconnect" ]; then
                    ok=1
                    break
                fi
                sleep 1
            done

            if [ "${ok}" -eq 1 ]; then
                local start_time
                start_time="$(date '+%Y-%m-%d %H:%M:%S')"
                printf 'START_TIME=%s\n' "${start_time}" > "${INFO_FILE}"
                echo "VPN 已成功启动"
                echo "启动时间: ${start_time}"
            else
                echo "VPN 启动失败，请检查网络或权限"
                return 1
            fi
            ;;
        status)
            if [ ! -f "${PID_FILE}" ]; then
                echo "VPN 未运行"
                return
            fi
            local PID
            local command_name=""
            PID=$(command cat "${PID_FILE}" 2>/dev/null | tr -d '[:space:]') || PID=""
            [[ "${PID}" =~ ^[0-9]+$ ]] || PID=""
            if [ -n "${PID}" ]; then
                command_name=$(ps -p "${PID}" -o comm= 2>/dev/null) || command_name=""
            fi
            if [ -n "${PID}" ] && [ "${command_name##*/}" = "openconnect" ]; then
                echo "VPN 正在运行 (PID: ${PID})"
                if [ -f "${INFO_FILE}" ]; then
                    local start_time=$(grep '^START_TIME=' "${INFO_FILE}" | cut -d= -f2-)
                    local start_ts=$(date -j -f '%Y-%m-%d %H:%M:%S' "${start_time}" '+%s' 2>/dev/null)
                    echo "启动时间: ${start_time}"
                    if [ -n "${start_ts}" ]; then
                        local duration=$(( $(date '+%s') - start_ts ))
                        printf "运行时长: %02d:%02d:%02d\n" $((duration/3600)) $((duration%3600/60)) $((duration%60))
                    fi
                fi
            else
                echo "VPN 未运行，已清理残留文件"
                rm -f "${PID_FILE}" "${INFO_FILE}"
            fi
            ;;
        stop)
            if [ ! -f "${PID_FILE}" ]; then
                echo "VPN 未运行"
                return
            fi
            local PID
            local command_name=""
            local i
            local stopped=0
            PID=$(command cat "${PID_FILE}" 2>/dev/null | tr -d '[:space:]') || PID=""
            [[ "${PID}" =~ ^[0-9]+$ ]] || PID=""
            if [ -n "${PID}" ]; then
                command_name=$(ps -p "${PID}" -o comm= 2>/dev/null) || command_name=""
            fi

            if [ -z "${PID}" ] || [ "${command_name##*/}" != "openconnect" ]; then
                echo "VPN 未运行，已清理残留文件"
                rm -f "${PID_FILE}" "${INFO_FILE}"
                return
            fi

            if [ -f "${INFO_FILE}" ]; then
                local start_time=$(grep '^START_TIME=' "${INFO_FILE}" | cut -d= -f2-)
                local start_ts=$(date -j -f '%Y-%m-%d %H:%M:%S' "${start_time}" '+%s' 2>/dev/null)
                echo "启动时间: ${start_time}"
                if [ -n "${start_ts}" ]; then
                    local duration=$(( $(date '+%s') - start_ts ))
                    printf "运行时长: %02d:%02d:%02d\n" $((duration/3600)) $((duration%3600/60)) $((duration%60))
                fi
            fi

            echo "正在停止 VPN..."

            sudo kill -INT "${PID}" 2>/dev/null || {
                echo "无法向 VPN 进程发送 SIGINT"
                return 1
            }

            for i in {1..8}; do
                command_name=$(ps -p "${PID}" -o comm= 2>/dev/null) || command_name=""
                if [ "${command_name##*/}" != "openconnect" ]; then
                    stopped=1
                    break
                fi
                sleep 1
            done

            if [ "${stopped}" -ne 1 ] && [ "${command_name##*/}" = "openconnect" ]; then
                echo "VPN 进程仍未退出，尝试发送 SIGTERM"
                sudo kill -TERM "${PID}" 2>/dev/null || {
                    echo "无法向 VPN 进程发送 SIGTERM"
                    return 1
                }

                for i in {1..5}; do
                    command_name=$(ps -p "${PID}" -o comm= 2>/dev/null) || command_name=""
                    if [ "${command_name##*/}" != "openconnect" ]; then
                        stopped=1
                        break
                    fi
                    sleep 1
                done
            fi

            if [ "${stopped}" -ne 1 ] && [ "${command_name##*/}" = "openconnect" ]; then
                echo "VPN 进程未正常退出，尝试强制终止"
                sudo kill -KILL "${PID}" 2>/dev/null || {
                    echo "无法强制终止 VPN 进程"
                    return 1
                }

                for i in {1..3}; do
                    command_name=$(ps -p "${PID}" -o comm= 2>/dev/null) || command_name=""
                    if [ "${command_name##*/}" != "openconnect" ]; then
                        stopped=1
                        break
                    fi
                    sleep 1
                done
            fi

            command_name=$(ps -p "${PID}" -o comm= 2>/dev/null) || command_name=""
            if [ "${command_name##*/}" = "openconnect" ]; then
                echo "VPN 停止失败，请检查权限或进程"
                return 1
            fi

            rm -f "${PID_FILE}" "${INFO_FILE}"
            echo "VPN 已成功停止"
            ;;
        -h|--help|help)
            echo "用法: fdvpn {start|status|stop}"
            ;;
        *)
            echo "用法: fdvpn {start|status|stop}"
            echo "  fdvpn         查看 VPN 状态 (默认)"
            echo "  fdvpn start   启动 VPN"
            echo "  fdvpn status  查看 VPN 状态"
            echo "  fdvpn stop    停止 VPN"
            ;;
    esac
}
