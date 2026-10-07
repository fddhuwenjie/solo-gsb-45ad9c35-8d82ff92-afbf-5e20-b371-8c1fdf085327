#!/usr/bin/env bash
# 现场事故演示：已在位榫卯意外失效 → 沿 /steps 上报（即使构件失去施工期路径、
# 受保护构件失去永久路径，也保存真实连接状态与回执，/state 按登记顺序列出受影响
# 构件，事故持久保存）→ 一次只处理一处、事故期试载/卸撑/验收快照被拒（不改状态
# 或工序号）→ 只允许安装事先登记的连接或临时支撑分步救回（名单不得新增，受保护
# 构件只能靠永久连接）→ 名单清空结束事故、恢复通常工序 → 补救也可走预案预演/
# 确认，逐步遵守同一规则，失败整单回滚。
#
# 场景：北柱础 S1、南台基 S2；前金柱 C1 经榫卯 J1 落在 S1，后金柱 C2 经 J2(C1—C2)
#       挂在 C1 上；J3(S2—C2) 为预登记的备用永久榫卯，T1(S2—C1) 为临时支撑。
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

echo "---- 1. 登记：C1 经 J1 落 S1；C2 经 J2 挂在 C1；J3 为备用永久榫卯；T1 临时支撑 ----"
api POST /supports      '{"id":"S1","name":"北柱础"}'
api POST /supports      '{"id":"S2","name":"南台基"}'
api POST /components    '{"id":"C1","name":"前金柱","min_load":10}'
api POST /components    '{"id":"C2","name":"后金柱","min_load":8}'
api POST /connections   '{"id":"J1","a":"S1","b":"C1"}'
api POST /connections   '{"id":"J2","a":"C1","b":"C2"}'
api POST /connections   '{"id":"J3","a":"S2","b":"C2","in_place":false}'
api POST /temp-supports '{"id":"T1","a":"S2","b":"C1"}'

echo "---- 2. 事故前的正常工序与验收快照（之后保持可用、不被改写）----"
api POST /steps '{"seq":1,"action":"test_load","component":"C1","load":11}' | tee /tmp/ic_tl1.txt
expect /tmp/ic_tl1.txt 201 "C1 合格试载（v0）"
api POST /steps '{"seq":2,"action":"test_load","component":"C2","load":9}' | tee /tmp/ic_tl2.txt
expect /tmp/ic_tl2.txt 201 "C2 合格试载（v0）"
api POST /snapshots '{}' | tee /tmp/ic_snap0.txt
expect /tmp/ic_snap0.txt 201 "事故前固化快照 1"
api POST /steps '{"seq":3,"action":"protect","component":"C2"}' | tee /tmp/ic_prot.txt
expect /tmp/ic_prot.txt 201 "把 C2 列为连续传力保护对象（其永久路径 J2—C1—J1）"

echo "---- 3. 现场发现在位榫卯 J1 意外失效：沿 /steps 上报，保存真实断开状态 ----"
api POST /steps '{"seq":4,"action":"report_failure","id":"J1"}' | tee /tmp/ic_report.txt
expect /tmp/ic_report.txt 201 "事故上报成功：即使 C1 失施工期路径、受保护 C2 失永久路径也保存"
[ "$(field /tmp/ic_report.txt 'd["result"]["affected_components"]')" = "['C1', 'C2']" ] \
  && echo "✔ 受影响构件按登记顺序：C1、C2"
[ "$(field /tmp/ic_report.txt 'd["result"]["version"]')" = "1" ] \
  && echo "✔ 断开使连接状态版本 → v1：旧试载与旧预案凭据失效"
[ "$(field /tmp/ic_report.txt 'd["result"]["status"]')" = "open" ] \
  && echo "✔ 事故状态 open（未消险）"
api GET /state | tee /tmp/ic_state1.txt
[ "$(field /tmp/ic_state1.txt 'd["incident"]["affected_components"]')" = "['C1', 'C2']" ] \
  && [ "$(field /tmp/ic_state1.txt '[c["affected"] for c in d["components"]]')" = "[True, True]" ] \
  && [ "$(field /tmp/ic_state1.txt '[j["in_place"] for j in d["connections"] if j["id"]=="J1"][0]')" = "False" ] \
  && echo "✔ /state：incident.affected_components=[C1,C2]、两构件 affected=true、J1 真实不在位"
api GET /steps/4 | tee /tmp/ic_receipt.txt
[ "$(field /tmp/ic_receipt.txt 'd["action"]')" = "report_failure" ] \
  && echo "✔ 事故上报沿现有 /steps 顺序留下真实回执（seq 4）"

echo "---- 4. 一次只处理一处；事故期试载/拆卸/卸撑/再上报/快照全部拒绝，不改状态或工序号 ----"
api POST /steps '{"seq":5,"action":"report_failure","id":"J2"}' | tee /tmp/ic_second.txt
expect /tmp/ic_second.txt 409 "未消险再上报另一处失效 → incident_open"
api POST /steps '{"seq":5,"action":"test_load","component":"C1","load":20}' | tee /tmp/ic_tl_block.txt
expect /tmp/ic_tl_block.txt 409 "事故期试载 → incident_in_progress"
api POST /steps '{"seq":5,"action":"disassemble","target":"connection","id":"J2"}' | tee /tmp/ic_dis_block.txt
expect /tmp/ic_dis_block.txt 409 "事故期拆卸 → incident_in_progress"
api POST /steps '{"seq":5,"action":"remove_support","id":"T1"}' | tee /tmp/ic_rm_block.txt
expect /tmp/ic_rm_block.txt 409 "事故期卸撑 → incident_in_progress"
api POST /snapshots '{}' | tee /tmp/ic_snap_block.txt
expect /tmp/ic_snap_block.txt 409 "事故期验收快照受阻 → incident_in_progress（不固化任何内容）"
api GET /state | tee /tmp/ic_state2.txt
[ "$(field /tmp/ic_state2.txt 'd["last_seq"]')" = "4" ] \
  && [ "$(field /tmp/ic_state2.txt '[j["in_place"] for j in d["connections"] if j["id"]=="J2"][0]')" = "True" ] \
  && echo "✔ 多次拒绝不改状态或工序号：last_seq 仍 4，J2 仍在位，事故仍开"

echo "---- 5. 分步补救（一）：安装事先登记的临时支撑 T1，救回非保护成员 C1 ----"
api POST /steps '{"seq":5,"action":"install","target":"temp_support","id":"T1"}' | tee /tmp/ic_remedy1.txt
expect /tmp/ic_remedy1.txt 201 "安装 T1（事先登记）：C1 经 T1→S2 获得施工期路径"
[ "$(field /tmp/ic_remedy1.txt 'd["result"]["affected_components"]')" = "['C2']" ] \
  && [ "$(field /tmp/ic_remedy1.txt 'd["result"]["incident_status"]')" = "open" ] \
  && echo "✔ 名单缩小为 [C2]：受保护 C2 只能靠永久连接恢复，临时支撑救不回（事故仍开）"
api GET /state | tee /tmp/ic_state3.txt
[ "$(field /tmp/ic_state3.txt '[c["affected"] for c in d["components"] if c["id"]=="C2"][0]')" = "True" ] \
  && [ "$(field /tmp/ic_state3.txt '[c["permanent_reachable"] for c in d["components"] if c["id"]=="C2"][0]')" = "False" ] \
  && echo "✔ /state：C2 仍 affected、permanent_reachable=false（仅凭永久连接不可达）"

echo "---- 6. 分步补救（二）：安装事先登记的备用永久榫卯 J3，受保护 C2 永久恢复，名单清空 ----"
api POST /steps '{"seq":6,"action":"install","target":"connection","id":"J3"}' | tee /tmp/ic_remedy2.txt
expect /tmp/ic_remedy2.txt 201 "安装备用永久榫卯 J3（S2—C2）：C2 永久恢复"
[ "$(field /tmp/ic_remedy2.txt 'd["result"]["affected_components"]')" = "[]" ] \
  && [ "$(field /tmp/ic_remedy2.txt 'd["result"]["incident_status"]')" = "closed" ] \
  && echo "✔ 受影响名单清空，事故在 seq 6 当步结束（可逐步救回，每步名单不新增成员）"
api GET /incidents | tee /tmp/ic_incidents.txt
[ "$(field /tmp/ic_incidents.txt 'len(d)')" = "1" ] \
  && [ "$(field /tmp/ic_incidents.txt 'd[0]["initial_affected_components"]')" = "['C1', 'C2']" ] \
  && [ "$(field /tmp/ic_incidents.txt 'd[0]["closed_seq"]')" = "6" ] \
  && echo "✔ 事故记录持久保存：连接 J1、上报 seq 4、初始/最终名单、closed_seq=6 均可查"

echo "---- 7. 名单清空后恢复通常工序：旧试载已随断开失效，重新试载后卸撑、快照 ----"
api POST /steps '{"seq":7,"action":"remove_support","id":"T1"}' | tee /tmp/ic_rm_after.txt
expect /tmp/ic_rm_after.txt 409 "恢复后卸撑先因旧试载失效被拒（test_load_missing，非事故闸门）"
api POST /steps '{"seq":7,"action":"test_load","component":"C1","load":12}' | tee /tmp/ic_tl1b.txt
expect /tmp/ic_tl1b.txt 201 "C1 在当前版本重新合格试载"
api POST /steps '{"seq":8,"action":"test_load","component":"C2","load":10}' | tee /tmp/ic_tl2b.txt
expect /tmp/ic_tl2b.txt 201 "C2 在当前版本重新合格试载"
api POST /steps '{"seq":9,"action":"remove_support","id":"T1"}' | tee /tmp/ic_rm_ok.txt
expect /tmp/ic_rm_ok.txt 201 "卸除 T1：两构件均仅凭永久连接（J2—J3）抵达 S2"
api POST /snapshots '{}' | tee /tmp/ic_snap1.txt
expect /tmp/ic_snap1.txt 201 "消险后固化新快照（id=2）"
api GET /snapshots/1 | tee /tmp/ic_snap_old.txt
[ "$(field /tmp/ic_snap_old.txt 'd["last_seq"]')" = "2" ] \
  && echo "✔ 已有快照保持可用且未改写：快照 1 仍是事故前 last_seq=2 的样子"

echo "---- 8. 第二处事故经预案预演/确认补救：逐步遵守同一规则，失败整单回滚 ----"
api POST /steps '{"seq":10,"action":"unprotect","component":"C2"}' | tee /tmp/ic_unprot.txt
expect /tmp/ic_unprot.txt 201 "解除 C2 保护（恢复普通施工期规则）"
api POST /steps '{"seq":11,"action":"report_failure","id":"J3"}' | tee /tmp/ic_report2.txt
expect /tmp/ic_report2.txt 201 "第二处事故上报（J1 此前未修复，J3 再断 → C1、C2 均失路径）"
# 8a. 预案夹带非补救动作 → 逐步拒绝、不签发凭据、整单不落库
api POST /plan/preview '{"steps":[{"action":"test_load","component":"C2","load":99}]}' | tee /tmp/ic_pv_block.txt
expect /tmp/ic_pv_block.txt 409 "预案事故期试载被逐步规则拒绝（不签发）"
head -n 1 /tmp/ic_pv_block.txt | grep -q '"failed_step": {"index": 0, "seq": 12, "action": "test_load"}' \
  && echo "✔ failed_step 指出清单第 1 步（seq 12, test_load）"
# 8b. 成功补救预案：T1(S2—C1) 一搭，C1 直达、C2 经 J2 绕行同获施工期路径 → 名单清空
api POST /plan/preview '{"steps":[{"action":"install","target":"temp_support","id":"T1"}]}' | tee /tmp/ic_pv_ok.txt
expect /tmp/ic_pv_ok.txt 200 "补救预案预演成功，签发 planv2- 凭据（预演不落库）"
[ "$(field /tmp/ic_pv_ok.txt 'd["steps"][0]["result"]["incident_status"]')" = "closed" ] \
  && echo "✔ 预演逐步反映：该步后名单清空、事故当步结束"
TOKEN="$(field /tmp/ic_pv_ok.txt "d['token']")"
api GET /state | tee /tmp/ic_state4.txt
[ "$(field /tmp/ic_state4.txt 'd["incident"] is not None')" = "True" ] \
  && echo "✔ 预演不留下改动：事故仍开、T1 未搭"
api POST /plan/confirm "{\"steps\":[{\"action\":\"install\",\"target\":\"temp_support\",\"id\":\"T1\"}],\"token\":\"$TOKEN\"}" \
  | tee /tmp/ic_cf_ok.txt
expect /tmp/ic_cf_ok.txt 201 "凭据确认：补救工序落库（seq 12），事故当步结束"
[ "$(field /tmp/ic_cf_ok.txt '[r["seq"] for r in d["receipts"]]')" = "[12]" ] \
  && [ "$(field /tmp/ic_cf_ok.txt 'd["receipts"][0]["result"]["affected_components"]')" = "[]" ] \
  && echo "✔ 回执 seq 12，affected_components=[]，incident_status=closed"
api POST /plan/confirm "{\"steps\":[{\"action\":\"install\",\"target\":\"temp_support\",\"id\":\"T1\"}],\"token\":\"$TOKEN\"}" \
  | tee /tmp/ic_cf_again.txt
expect /tmp/ic_cf_again.txt 409 "凭据整单仅可用一次（重用 → plan_stale）"

echo "---- 9. 查询：/incidents 持久保存全部事故；/state 无未消险事故 ----"
api GET /incidents | tee /tmp/ic_incidents2.txt
[ "$(field /tmp/ic_incidents2.txt '[(i["id"], i["connection"], i["closed_seq"]) for i in d]')" \
  = "[(1, 'J1', 6), (2, 'J3', 12)]" ] \
  && echo "✔ 两起事故均持久保存并已关闭（事故状态不随结束而删除）"
api GET /state | tee /tmp/ic_state5.txt
[ "$(field /tmp/ic_state5.txt 'd["incident"]')" = "None" ] \
  && [ "$(field /tmp/ic_state5.txt 'd["last_seq"]')" = "12" ] \
  && echo "✔ 当前无未消险事故，正常工序从 seq 13 继续"

echo "✔ 现场事故流程完成：上报保存真实状态 → 一次一处 → 分步补救（名单只减不增、受保护只靠永久连接）→ 名单清空结束 → 试载/卸撑/快照恢复 → 预案预演确认同规则、失败整单回滚。"
