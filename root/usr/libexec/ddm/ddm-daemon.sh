#!/bin/sh
#
# SPDX-License-Identifier: Apache-2.0
#
# luci-app-ddm 后台采集/告警守护进程
#
# 周期性地调用 `ddm check` 检查所有 SFP 模块的 DDM 指标，
# 当指标进入 warning/alarm 状态或恢复正常时写入 syslog。
#
# 用法: ddm-daemon.sh [interval_seconds] [log_changes_only]

INTERVAL="${1:-60}"
CHANGES_ONLY="${2:-1}"
STATE_FILE="/var/run/ddm.state"

[ -x /usr/bin/ddm ] || exit 1

case "$INTERVAL" in
	''|*[!0-9]*) INTERVAL=60 ;;
esac
[ "$INTERVAL" -lt 5 ] && INTERVAL=5

log_line() {
	logger -t ddm -p "$1" "$2"
}

# 1 = 只在状态变化时记录
should_log() {
	[ "$CHANGES_ONLY" != "1" ] && return 0

	local current prev

	current="$1"
	prev="$(cat "$STATE_FILE" 2>/dev/null)"

	[ "$current" = "$prev" ] && return 1

	printf '%s' "$current" > "$STATE_FILE"

	return 0
}

while :; do
	output="$(/usr/bin/ddm check 2>/dev/null)"
	ret=$?

	if [ "$ret" -eq 1 ]; then
		if should_log "$output"; then
			printf '%s\n' "$output" | while IFS= read -r line; do
				[ -n "$line" ] && log_line daemon.warn "$line"
			done
		fi
	elif [ -f "$STATE_FILE" ]; then
		rm -f "$STATE_FILE"
		log_line daemon.info "SFP DDM alarm/warning cleared"
	fi

	sleep "$INTERVAL"
done
