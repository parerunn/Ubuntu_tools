#!/bin/bash

cd $(dirname $0)

_APISERVER=127.0.0.1:10085
_V2CTL=/usr/local/bin/v2ctl


# Date
curDate=$(date "+%Y-%m-%d")
curMonth=$(date "+%Y-%m")
last_day_s=$(( $(date +%s) - 86000 ))
last_day=$(date -d @$last_day_s "+%Y-%m-%d")
last_day_month=$(date -d @$last_day_s "+%Y-%m")

apidata () {
    local ARGS=
    if [[ $1 == "reset" ]]; then
      ARGS="reset: true"
    fi
    $_V2CTL api --server=$_APISERVER StatsService.QueryStats "${ARGS}" \
    # cat Data.txt \
    | awk '{
        if (match($1, /name:/)) {
            f=1; gsub(/^"|link"$/, "", $2);
            split($2, p,  ">>>");
            printf "%s %s %s\t", p[1],p[2],p[4];
        }
        else if (match($1, /value:/) && f){ f = 0; printf "%.0f\n", $2; }
        else if (match($0, /^>$/) && f) { f = 0; print 0; }
    }'
}

print_sum() {
    local DATA="$1"
    local PREFIX="$2"
    local SORTED=$(echo "$DATA" | grep "^${PREFIX}" | sort -r)

    echo -e "${SORTED}" \
    | awk '{print "[""'$curDate'""]", $2, $3, $4}' \
    | column -t
}

# 获取当日累积流量Byte
DATA=$(apidata $1)
# print_sum "$DATA" "user" >> $curMonth.txt
todayData=$( print_sum "$DATA" "user" )
echo "$todayData" >> $curMonth.txt

# 计算当日流量

# 检查last_day_month.txt是否存在
if test -f $last_day_month.txt;then
#echo $(grep $last_day < $last_day_month.txt)
    lastDayData=$(grep $last_day < $last_day_month.txt)
    # echo "$lastDayData"
    if [ "$lastDayData" ];then
        # todayData=$(grep $curDate < $curMonth.txt)
        # echo "$todayData"
        # for u in $todayData
        echo "$todayData" | while read u
        do
        # echo "$u"
            username=$(echo $u | awk '{print $2}')
            usertype=$(echo $u | awk '{print $3}')
            # echo $username
            luserdata=$(echo "$lastDayData" | grep $username | grep $usertype | awk '{print $4}')
            # echo $luserdata
            if [ "$luserdata" ];then
                userDataUse=$(echo $[ $(echo $u | awk '{print $4}') - $luserdata ] | numfmt --suffix=B --to=iec)
                echo -e "[$curDate] $username $usertype $userDataUse"  | column -t >> "$curMonth"_daily.txt
            fi
        done
    fi
fi