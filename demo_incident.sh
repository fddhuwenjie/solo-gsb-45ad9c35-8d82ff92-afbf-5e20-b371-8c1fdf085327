#!/usr/bin/env bash
# 榫卯意外失效事故演示：事故上报（保存真实连接状态与回执）→ 未消险期间试载/
# 卸撑/快照/拆卸/再次上报一律 409 且不占工序号 → 分步补救（临时支撑救回普通
# 构件，受保护构件只能靠永久连接恢复）→ 名单清空消险、恢复通常工序 →
# 断开使旧试载与预案凭据失效 → 预案预演/确认补救安装（逐步遵守同一规则，
# 失败整单回滚）→ 已有快照保持可用。
#
# 场景：北柱础 S1、南台基 S2；承重梁 C1 仅经榫卯 J1 落在 S1 上，小金柱 C2
#       仅经 J2(C1—C2) 搭在承重梁上（C2 受连续传力保护）；J3(S2—C1)、
#       J4(S2—C2) 为预登记的备用永久路径，T1(S2—C1)、T2(S2—C2) 为临时支撑。
#
# 用法：BASE=http://localhost:8080 ./demo_incident.sh
# 注意：请在空库上运行（如 docker compose 首次启动，或另设 APP_DB 的实例）。
set -euo pipefail
BASE="${BASE:-http://localhost:8080}"

api() {  # api METHOD PATH [JSON]：请求行打印到 stderr，stdout 只留响应便于解析
  local method="$1" path="$2" data="${3:-}"
  echo "==> $method $path ${data}" >&2
  if [ -n "$data" ]; then
    curl -sS -w '\nHTTP %{http_code}\n' -X "$method" "$BASE$path" \
      -H 'Content-Type: application/json' -d "$data"
  else
    curl -sS -w '\nHTTP %{http_code}\n' -X "$method" "$BASE$path"
  fi
  echo
}

expect() {  # expect FILE 期望状态码 描述
  local file="$1" want="$2"; shift 2
  local code
  code="$(grep -E '^HTTP [0-9]+$' "$file" | tail -n 1)"
  if [ "$code" != "HTTP $want" ]; then
    echo "断言失败（$*）：期望 $want，实际 '$code'，完整响应见 $file" >&2
    cat "$file" >&2
    exit 1
  fi
  echo "✔ $* → $want"
}

field() {  # field FILE PYTHON_EXPR：对响应首行 JSON 求值
  head -n 1 "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

echo "---- 1. 登记：S1/S2、C1（J1 落在 S1）、C2（J2 搭在 C1）、备用永久路径 J3/J4、临时支撑 T1/T2 ----"
api POST /supports      '{"id":"S1","name":"北柱础"}'
api POST /supports      '{"id":"S2","name":"南台基"}'
api POST /components    '{"id":"C1","name":"承重梁","min_load":10}'
api POST /components    '{"id":"C2","name":"小金柱","min_load":8}'
api POST /connections   '{"id":"J1","a":"S1","b":"C1"}'
api POST /connections   '{"id":"J2","a":"C1","b":"C2"}'
api POST /connections   '{"id":"J3","a":"S2","b":"C1","in_place":false}'   # 备用永久路径
api POST /connections   '{"id":"J4","a":"S2","b":"C2","in_place":false}'   # 备用永久路径
api POST /temp-supports '{"id":"T1","a":"S2","b":"C1"}'
api POST /temp-supports '{"id":"T2","a":"S2","b":"C2"}'

echo "---- 2. 保护 C2（其永久路径 J2→C1→J1→S1），C1 在 v0 下合格试载 ----"
api POST /steps '{"seq":1,"action":"protect","component":"C2"}' | tee /tmp/ic_protect.txt
expect /tmp/ic_protect.txt 201 "保护 C2（seq 1，不改连接版本）"
api POST /steps '{"seq":2,"action":"test_load","component":"C1","load":12}' | tee /tmp/ic_tl0.txt
expect /tmp/ic_tl0.txt 201 "C1 在 v0 下合格试载（稍后将被事故断开作废）"

echo "---- 3. 事故上报：J1 意外失效——即使 C1 失去施工期路径、受保护的 C2 失去永久路径，仍保存真实连接状态与回执 ----"
api POST /steps '{"seq":3,"action":"report_failure","id":"J1"}' | tee /tmp/ic_report.txt
expect /tmp/ic_report.txt 201 "事故上报 J1（seq 3 落回执，不做整步回滚）"
[ "$(field /tmp/ic_report.txt 'd["result"]["affected_components"]')" = "['C1', 'C2']" ] \
  && [ "$(field /tmp/ic_report.txt 'd["result"]["version"]')" = "1" ] \
  && [ "$(field /tmp/ic_report.txt 'd["result"]["incident_active"]')" = "True" ] \
  && echo "✔ 回执保存真实状态：受影响名单按登记序 [C1, C2]，断开使版本 → v1（旧试载失效）"
api GET /state | tee /tmp/ic_state1.txt
[ "$(field /tmp/ic_state1.txt 'd["incident"]["connection"]')" = "J1" ] \
  && [ "$(field /tmp/ic_state1.txt 'd["incident"]["seq"]')" = "3" ] \
  && [ "$(field /tmp/ic_state1.txt 'd["incident"]["affected_components"]')" = "['C1', 'C2']" ] \
  && [ "$(field /tmp/ic_state1.txt '[c for c in d["components"] if c["id"]=="J1" or c["id"]=="C1"][0]["affected"]')" = "True" ] \
  && [ "$(field /tmp/ic_state1.txt '[c for c in d["connections"] if c["id"]=="J1"][0]["in_place"]')" = "False" ] \
  && echo "✔ /state 按登记序列出受影响构件；J1 真实记为不在位"

echo "---- 4. 未消险期间：试载/卸撑/快照/拆卸/再次上报一律 409 incident_active，且不改状态或工序号 ----"
api POST /steps '{"seq":4,"action":"test_load","component":"C1","load":12}' | tee /tmp/ic_tl_block.txt
expect /tmp/ic_tl_block.txt 409 "试载拒绝"
api POST /steps '{"seq":4,"action":"remove_support","id":"T1"}' | tee /tmp/ic_rm_block.txt
expect /tmp/ic_rm_block.txt 409 "卸撑拒绝"
api POST /snapshots '{}' | tee /tmp/ic_snap_block.txt
expect /tmp/ic_snap_block.txt 409 "验收快照拒绝（验收受阻）"
head -n 1 /tmp/ic_snap_block.txt | grep -q '"error": "incident_active"' \
  && head -n 1 /tmp/ic_snap_block.txt | grep -q '"affected_components": \["C1", "C2"\]' \
  && echo "✔ 三类拒绝均为 incident_active 并附受影响名单"
api POST /steps '{"seq":4,"action":"disassemble","target":"connection","id":"J2"}' | tee /tmp/ic_dis_block.txt
expect /tmp/ic_dis_block.txt 409 "拆卸拒绝（未消险时只允许安装已登记连接/临时支撑）"
api POST /steps '{"seq":4,"action":"report_failure","id":"J2"}' | tee /tmp/ic_re_report.txt
expect /tmp/ic_re_report.txt 409 "再次上报拒绝（一次只处理一处失效）"
api GET /state | tee /tmp/ic_state2.txt
[ "$(field /tmp/ic_state2.txt 'd["last_seq"]')" = "3" ] \
  && [ "$(field /tmp/ic_state2.txt 'd["version"]')" = "1" ] \
  && echo "✔ 五次拒绝均不占工序号、不改状态：last_seq 仍 3、版本仍 v1"

echo "---- 5. 分步补救：临时支撑救回普通构件；受保护构件只能靠永久连接恢复 ----"
api POST /steps '{"seq":4,"action":"install","target":"temp_support","id":"T1"}' | tee /tmp/ic_t1.txt
expect /tmp/ic_t1.txt 201 "搭 T1：C1 施工期路径恢复，名单 [C2]"
[ "$(field /tmp/ic_t1.txt 'd["result"]["incident"]["affected_components"]')" = "['C2']" ] \
  && echo "✔ 名单逐步缩小为 [C2]（每步不得新增成员，可逐步救回）"
api POST /steps '{"seq":5,"action":"install","target":"temp_support","id":"T2"}' | tee /tmp/ic_t2.txt
expect /tmp/ic_t2.txt 201 "搭 T2：C2 受保护，临时支撑不能将其移出名单"
[ "$(field /tmp/ic_t2.txt 'd["result"]["incident"]["affected_components"]')" = "['C2']" ] \
  && echo "✔ 名单仍 [C2]：受保护构件只能靠永久连接恢复"
api POST /steps '{"seq":6,"action":"install","target":"connection","id":"J3"}' | tee /tmp/ic_j3.txt
expect /tmp/ic_j3.txt 201 "装 J3（S2—C1 永久连接）：C2 经 J2→C1→J3→S2 恢复永久路径"
[ "$(field /tmp/ic_j3.txt 'd["result"]["incident"]["affected_components"]')" = "[]" ] \
  && [ "$(field /tmp/ic_j3.txt 'd["result"]["incident"]["active"]')" = "False" ] \
  && echo "✔ 名单清空即消险：事故结束（版本 → v2）"
api GET /state | tee /tmp/ic_state3.txt
[ "$(field /tmp/ic_state3.txt 'd["incident"]')" = "None" ] \
  && echo "✔ /state incident 为 null，恢复通常工序"

echo "---- 6. 通常工序恢复：试载（v2）→ 卸撑 → 验收快照 1 ----"
api POST /steps '{"seq":7,"action":"test_load","component":"C1","load":12}'  | tee /tmp/ic_tl1.txt
expect /tmp/ic_tl1.txt 201 "C1 在 v2 下合格试载"
api POST /steps '{"seq":8,"action":"test_load","component":"C2","load":9}'   | tee /tmp/ic_tl2.txt
expect /tmp/ic_tl2.txt 201 "C2 在 v2 下合格试载"
api POST /steps '{"seq":9,"action":"remove_support","id":"T1"}' | tee /tmp/ic_rm1.txt
expect /tmp/ic_rm1.txt 201 "卸除 T1"
api POST /steps '{"seq":10,"action":"remove_support","id":"T2"}' | tee /tmp/ic_rm2.txt
expect /tmp/ic_rm2.txt 201 "卸除 T2"
api POST /snapshots '{}' | tee /tmp/ic_snap1.txt
expect /tmp/ic_snap1.txt 201 "固化验收快照 1（v2）"

echo "---- 7. 再次失效：断开使旧预案凭据失效（plan_stale） ----"
api POST /plan/preview '{"steps":[{"action":"test_load","component":"C1","load":11}]}' | tee /tmp/ic_pv0.txt
expect /tmp/ic_pv0.txt 200 "预演取得凭据"
TOKEN="$(field /tmp/ic_pv0.txt "d['token']")"
api POST /steps '{"seq":11,"action":"report_failure","id":"J3"}' | tee /tmp/ic_report2.txt
expect /tmp/ic_report2.txt 201 "事故上报 J3（C1/C2 再度受影响，版本 → v3）"
[ "$(field /tmp/ic_report2.txt 'd["result"]["affected_components"]')" = "['C1', 'C2']" ] \
  && echo "✔ 第二处失效同样保存真实状态与回执（上一处已消险才允许再报）"
api POST /plan/confirm "{\"steps\":[{\"action\":\"test_load\",\"component\":\"C1\",\"load\":11}],\"token\":\"$TOKEN\"}" | tee /tmp/ic_cf_stale.txt
expect /tmp/ic_cf_stale.txt 409 "预演后发生事故上报：原凭据失效（plan_stale），不写入任何工序"

echo "---- 8. 事故中预案：逐步遵守同一规则，失败整单回滚；补救安装可预演、确认 ----"
api POST /plan/preview '{"steps":[
  {"action":"install","target":"temp_support","id":"T1"},
  {"action":"test_load","component":"C1","load":11}
]}' | tee /tmp/ic_pv_block.txt
expect /tmp/ic_pv_block.txt 409 "含试载的补救预案：未消险期间试载被拒"
head -n 1 /tmp/ic_pv_block.txt | grep -q '"error": "incident_active"' \
  && head -n 1 /tmp/ic_pv_block.txt | grep -q '"failed_step": {"index": 1, "seq": 13, "action": "test_load"}' \
  && echo "✔ failed_step={index:1, seq:13, action:test_load}，不签发凭据、不落库"
api POST /plan/preview '{"steps":[{"action":"install","target":"connection","id":"J4"}]}' | tee /tmp/ic_pv_ok.txt
expect /tmp/ic_pv_ok.txt 200 "纯补救安装预案预演成功并签发凭据"
[ "$(field /tmp/ic_pv_ok.txt 'd["steps"][0]["result"]["incident"]["active"]')" = "False" ] \
  && echo "✔ 预演逐步可见：装 J4 后名单清空、事故消险"
TOKEN2="$(field /tmp/ic_pv_ok.txt "d['token']")"
api GET /state | tee /tmp/ic_state4.txt
[ "$(field /tmp/ic_state4.txt 'd["last_seq"]')" = "11" ] \
  && [ "$(field /tmp/ic_state4.txt 'd["incident"]["affected_components"]')" = "['C1', 'C2']" ] \
  && echo "✔ 预演不落库：last_seq 仍 11，事故仍未消险"
api POST /plan/confirm "{\"steps\":[{\"action\":\"install\",\"target\":\"connection\",\"id\":\"J4\"}],\"token\":\"$TOKEN2\"}" | tee /tmp/ic_cf_ok.txt
expect /tmp/ic_cf_ok.txt 201 "确认补救预案：整单落库（seq 12），名单清空消险"
api GET /state | tee /tmp/ic_state5.txt
[ "$(field /tmp/ic_state5.txt 'd["incident"]')" = "None" ] \
  && [ "$(field /tmp/ic_state5.txt 'd["version"]')" = "4" ] \
  && echo "✔ 事故结束、恢复通常工序（版本 → v4）"

echo "---- 9. 断开使旧试载失效：v2 试载在 v4 下不被认可，须复验后再验收；已有快照保持可用 ----"
api POST /snapshots '{}' | tee /tmp/ic_snap_block2.txt
expect /tmp/ic_snap_block2.txt 409 "快照拒绝：当前版本 v4 下无合格试载（test_load_missing）"
api POST /steps '{"seq":13,"action":"test_load","component":"C1","load":12}' | tee /tmp/ic_tl3.txt
expect /tmp/ic_tl3.txt 201 "C1 在 v4 下复验合格"
api POST /steps '{"seq":14,"action":"test_load","component":"C2","load":9}'  | tee /tmp/ic_tl4.txt
expect /tmp/ic_tl4.txt 201 "C2 在 v4 下复验合格"
api POST /snapshots '{}' | tee /tmp/ic_snap2.txt
expect /tmp/ic_snap2.txt 201 "固化验收快照 2（v4）"
api GET /snapshots/1 | tee /tmp/ic_snap1_get.txt
[ "$(field /tmp/ic_snap1_get.txt 'd["version"]')" = "2" ] \
  && [ "$(field /tmp/ic_snap1_get.txt 'd["last_seq"]')" = "10" ] \
  && echo "✔ 快照 1 保持 v2/last_seq=10 原样：已有快照不被后续事故与补救改写"

echo "✔ 事故流程完成：上报保存真实状态与回执 → 未消险拒绝不占号 → 分步补救（受保护构件只靠永久连接）→ 消险恢复 → 凭据/试载失效 → 预案补救 → 复验再验收。"
